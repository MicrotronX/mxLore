unit mx.Tool.Onboard;

interface

uses
  System.SysUtils, System.IOUtils, System.JSON, Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool;

function HandleOnboardDeveloper(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// Helper: Read all files from a skill directory into a JSON array
// ---------------------------------------------------------------------------
function ReadSkillFiles(const ASkillDir: string): TJSONArray;
var
  Files: TJSONArray;
  FilePath, RelPath, Content: string;
  FileObj: TJSONObject;
  AllFiles: TArray<string>;
begin
  Files := TJSONArray.Create;
  try
    AllFiles := TDirectory.GetFiles(ASkillDir, '*.*',
      TSearchOption.soAllDirectories);
    for FilePath in AllFiles do
    begin
      // Only include .md files
      if not SameText(ExtractFileExt(FilePath), '.md') then
        Continue;
      // Relative path from skill dir (forward slashes)
      RelPath := StringReplace(
        ExtractRelativePath(IncludeTrailingPathDelimiter(ASkillDir), FilePath),
        '\', '/', [rfReplaceAll]);
      Content := TFile.ReadAllText(FilePath, TEncoding.UTF8);
      FileObj := TJSONObject.Create;
      FileObj.AddPair('path', RelPath);
      FileObj.AddPair('content', Content);
      Files.AddElement(FileObj);
    end;
  except
    Files.Free;
    raise;
  end;
  Result := Files;
end;

// ---------------------------------------------------------------------------
// Helper: Read proxy info (INI template from claude-setup/proxy/)
// ---------------------------------------------------------------------------
function ReadProxyInfo(const ABasePath: string): TJSONObject;
var
  ProxyInfo: TJSONObject;
  ExeFound: Boolean;
  IniContent: string;
  SearchPath: string;
begin
  ProxyInfo := TJSONObject.Create;
  try
    // Search for proxy exe: same paths as HandleProxyDownload
    ExeFound := False;
    for SearchPath in [
      ABasePath + 'mxMCPProxy.exe',
      ABasePath + 'proxy' + PathDelim + 'mxMCPProxy.exe',
      ABasePath + 'claude-setup' + PathDelim + 'proxy' + PathDelim + 'mxMCPProxy.exe'] do
      if FileExists(SearchPath) then
      begin
        ExeFound := True;
        Break;
      end;
    ProxyInfo.AddPair('exe_available', TJSONBool.Create(ExeFound));
    ProxyInfo.AddPair('download_hint',
      'Download via Admin-Server: GET /api/download/proxy');

    // Search for INI template
    IniContent := '';
    for SearchPath in [
      ABasePath + 'claude-setup' + PathDelim + 'proxy' + PathDelim + 'mxMCPProxy.ini',
      ABasePath + 'proxy' + PathDelim + 'mxMCPProxy.ini',
      ABasePath + 'mxMCPProxy.ini'] do
      if FileExists(SearchPath) then
      begin
        IniContent := TFile.ReadAllText(SearchPath, TEncoding.UTF8);
        Break;
      end;
    ProxyInfo.AddPair('ini_template', IniContent);
  except
    ProxyInfo.Free;
    raise;
  end;
  Result := ProxyInfo;
end;

{ HandleOnboardDeveloper
  Returns developer info, assigned projects, skills from filesystem,
  reference files, and proxy info.
  Optional scope parameter: all (default), skills, reference, proxy, projects }

function HandleOnboardDeveloper(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  Data, ProjectObj, SkillObj, RefFileObj: TJSONObject;
  Projects, Skills, RefFiles: TJSONArray;
  BasePath, SkillsDir, SkillName, SkillFilter, RefDir, RefPath, RefContent, Scope: string;
  SkillDirs, RefFileList: TArray<string>;
  IncludeAll: Boolean;
begin
  Auth := MxGetThreadAuth;

  if Auth.DeveloperId = 0 then
    raise EMxError.Create('AUTH_ERROR', 'Could not identify developer from API key');

  // Scope filter: all (default), skills, reference, proxy, projects
  Scope := 'all';
  if (AParams <> nil) and (AParams.GetValue('scope') <> nil) then
    Scope := AParams.GetValue<string>('scope', 'all').ToLower;
  IncludeAll := (Scope = 'all');

  // Optional skill_name filter (for --self-update: only return one skill)
  SkillFilter := '';
  if (AParams <> nil) and (AParams.GetValue('skill_name') <> nil) then
    SkillFilter := AParams.GetValue<string>('skill_name', '');

  Data := TJSONObject.Create;
  try
    // Developer info (always included)
    Data.AddPair('developer_id', TJSONNumber.Create(Auth.DeveloperId));
    Data.AddPair('developer_name', Auth.DeveloperName);
    Data.AddPair('is_admin', TJSONBool.Create(Auth.IsAdmin));
    Data.AddPair('key_name', Auth.KeyName);

    // Assigned projects
    if IncludeAll or (Scope = 'projects') then
    begin
      Projects := TJSONArray.Create;
      Qry := AContext.CreateQuery(
        'SELECT p.id, p.slug, p.name AS project_name, dpa.access_level ' +
        'FROM projects p ' +
        'JOIN developer_project_access dpa ON dpa.project_id = p.id ' +
        'WHERE dpa.developer_id = :dev_id AND p.is_active = TRUE ' +
        'ORDER BY p.slug');
      try
        Qry.ParamByName('dev_id').AsInteger := Auth.DeveloperId;
        Qry.Open;
        while not Qry.Eof do
        begin
          ProjectObj := TJSONObject.Create;
          ProjectObj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          ProjectObj.AddPair('slug', Qry.FieldByName('slug').AsString);
          ProjectObj.AddPair('project_name', Qry.FieldByName('project_name').AsString);
          ProjectObj.AddPair('access_level', Qry.FieldByName('access_level').AsString);
          Projects.AddElement(ProjectObj);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
      Data.AddPair('projects', Projects);
    end;

    BasePath := ExtractFilePath(ParamStr(0));

    // Skills from filesystem (claude-setup/skills/)
    if IncludeAll or (Scope = 'skills') then
    begin
      SkillsDir := BasePath + 'claude-setup/skills/';
      Skills := TJSONArray.Create;
      Data.AddPair('skills', Skills);
      if TDirectory.Exists(SkillsDir) then
      begin
        SkillDirs := TDirectory.GetDirectories(SkillsDir);
        for var Dir in SkillDirs do
        begin
          SkillName := ExtractFileName(Dir);
          if (SkillFilter <> '') and not SameText(SkillName, SkillFilter) then
            Continue;
          SkillObj := TJSONObject.Create;
          SkillObj.AddPair('name', SkillName);
          SkillObj.AddPair('files', ReadSkillFiles(Dir));
          Skills.AddElement(SkillObj);
        end;
      end;
    end;

    // Reference files from filesystem (claude-setup/reference/)
    if IncludeAll or (Scope = 'reference') then
    begin
      RefDir := BasePath + 'claude-setup/reference/';
      RefFiles := TJSONArray.Create;
      Data.AddPair('reference_files', RefFiles);
      if TDirectory.Exists(RefDir) then
      begin
        RefFileList := TDirectory.GetFiles(RefDir, '*.md');
        for RefPath in RefFileList do
        begin
          try
            RefContent := TFile.ReadAllText(RefPath, TEncoding.UTF8);
            RefFileObj := TJSONObject.Create;
            RefFileObj.AddPair('filename', ExtractFileName(RefPath));
            RefFileObj.AddPair('content', RefContent);
            RefFiles.AddElement(RefFileObj);
          except
            on E: Exception do
              AContext.Logger.Log(mlWarning, '[mx_onboard_developer] Reference file read failed: ' + RefPath + ' - ' + E.Message);
          end;
        end;
      end;
    end;

    // Hook files from filesystem (claude-setup/hooks/)
    if IncludeAll or (Scope = 'hooks') then
    begin
      var HookDir := BasePath + 'claude-setup/hooks/';
      var HookFiles := TJSONArray.Create;
      Data.AddPair('hook_files', HookFiles);
      if TDirectory.Exists(HookDir) then
      begin
        var HookFileList := TDirectory.GetFiles(HookDir, '*.*');
        for var HookPath in HookFileList do
        begin
          try
            var HookContent := TFile.ReadAllText(HookPath, TEncoding.UTF8);
            var HookFileObj := TJSONObject.Create;
            HookFileObj.AddPair('filename', ExtractFileName(HookPath));
            HookFileObj.AddPair('content', HookContent);
            HookFiles.AddElement(HookFileObj);
          except
            on E: Exception do
              AContext.Logger.Log(mlWarning,
                '[mx_onboard_developer] Hook file read failed: ' + HookPath +
                ' - ' + E.Message);
          end;
        end;
      end;
    end;

    // Proxy info
    if IncludeAll or (Scope = 'proxy') then
      Data.AddPair('proxy', ReadProxyInfo(BasePath));

    // MCP server instructions for Tool Search discovery
    if IncludeAll then
      Data.AddPair('mcp_instructions',
        'Project knowledge database (MariaDB + Delphi MCP-Server). ' +
        'Search for mx_* tools when working with: project documentation, ' +
        'specs, plans, decisions (ADRs), session notes, feature requests, ' +
        'bug reports, skill evolution findings, cross-project relations, ' +
        'developer environments, or multi-agent communication. Key tools: ' +
        'mx_briefing (project overview), mx_search (full-text search), ' +
        'mx_detail (document content), mx_session_start (begin session), ' +
        'mx_create_doc/mx_update_doc (write), mx_skill_record_finding ' +
        '(skill evolution). 40 tools total.');

    // mx_rules: CLAUDE.md template with markers for auto-update
    if IncludeAll or (Scope = 'mx_rules') then
    begin
      var RulesPath := BasePath + 'claude-setup/CLAUDE.md';
      var RulesObj := TJSONObject.Create;
      if FileExists(RulesPath) then
      begin
        RulesObj.AddPair('content',
          TFile.ReadAllText(RulesPath, TEncoding.UTF8));
        RulesObj.AddPair('available', TJSONBool.Create(True));
      end
      else
      begin
        RulesObj.AddPair('content', '');
        RulesObj.AddPair('available', TJSONBool.Create(False));
      end;
      Data.AddPair('mx_rules', RulesObj);
    end;

    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

end.
