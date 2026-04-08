unit mx.Admin.Api.Global;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Config;

procedure HandleGetGlobalStats(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

procedure HandleGetActivity(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandlePostBackup(const C: THttpServerContext;
  AConfig: TMxConfig; ALogger: IMxLogger);

procedure HandlePostCleanup(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetAccessLogStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetPrefetchStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetHealth(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

procedure HandleGetActiveSessions(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetSkillEvolution(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetRecallMetrics(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetGraphStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetLessonStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetEmbeddingStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetTokenStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

// Shared backup logic (used by HandlePostBackup and auto-backup at boot)
function MxRunBackup(AConfig: TMxConfig; ALogger: IMxLogger): string;

// Boot timestamp (set by TMxServerBoot.Create, read by HandleGetHealth)
procedure MxSetBootTime(ATime: TDateTime);

implementation

uses
  System.SysUtils, System.JSON, System.IOUtils, System.Classes,
  System.DateUtils, System.Types, System.Math,
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}
  FireDAC.Comp.Client,
  mx.Admin.Server;

var
  GBootTime: TDateTime = 0;

procedure MxSetBootTime(ATime: TDateTime);
begin
  GBootTime := ATime;
end;

procedure HandleGetGlobalStats(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, Stats, Settings, DocTypes: TJSONObject;
  EnvArr: TJSONArray;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // --- Document counts by type ---
    DocTypes := TJSONObject.Create;
    Qry := Ctx.CreateQuery(
      'SELECT doc_type, COUNT(*) AS cnt FROM documents ' +
      'WHERE status != ''deleted'' GROUP BY doc_type');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        DocTypes.AddPair(Qry.FieldByName('doc_type').AsString,
          TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // --- Aggregate stats ---
    Stats := TJSONObject.Create;
    Stats.AddPair('doc_types', DocTypes);

    Qry := Ctx.CreateQuery(
      'SELECT ' +
      '(SELECT COUNT(*) FROM documents WHERE status != ''deleted'') AS total_docs, ' +
      '(SELECT COUNT(*) FROM projects WHERE is_active = TRUE) AS active_projects, ' +
      '(SELECT COUNT(*) FROM projects) AS total_projects, ' +
      '(SELECT COUNT(*) FROM developers WHERE is_active = TRUE) AS active_developers, ' +
      '(SELECT COUNT(*) FROM developers) AS total_developers, ' +
      '(SELECT COUNT(*) FROM client_keys WHERE is_active = TRUE) AS active_keys');
    try
      Qry.Open;
      Stats.AddPair('total_documents', TJSONNumber.Create(Qry.FieldByName('total_docs').AsInteger));
      Stats.AddPair('active_projects', TJSONNumber.Create(Qry.FieldByName('active_projects').AsInteger));
      Stats.AddPair('total_projects', TJSONNumber.Create(Qry.FieldByName('total_projects').AsInteger));
      Stats.AddPair('active_developers', TJSONNumber.Create(Qry.FieldByName('active_developers').AsInteger));
      Stats.AddPair('total_developers', TJSONNumber.Create(Qry.FieldByName('total_developers').AsInteger));
      Stats.AddPair('active_keys', TJSONNumber.Create(Qry.FieldByName('active_keys').AsInteger));
    finally
      Qry.Free;
    end;

    Json.AddPair('stats', Stats);

    // --- Server settings ---
    Settings := TJSONObject.Create;
    case AConfig.AclMode of
      amOff:     Settings.AddPair('developer_acl_mode', 'off');
      amAudit:   Settings.AddPair('developer_acl_mode', 'audit');
      amEnforce: Settings.AddPair('developer_acl_mode', 'enforce');
    end;
    Settings.AddPair('admin_port', TJSONNumber.Create(AConfig.AdminPort));
    Settings.AddPair('mcp_port', TJSONNumber.Create(AConfig.ServerPort));
    Json.AddPair('settings', Settings);

    // --- Global environment variables ---
    EnvArr := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT de.id, de.env_key, de.env_value ' +
      'FROM developer_environments de ' +
      'LEFT JOIN projects p ON p.id = de.project_id ' +
      'WHERE p.slug = ''_global'' OR de.project_id IS NULL ' +
      'ORDER BY de.env_key');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Item.AddPair('key', Qry.FieldByName('env_key').AsString);
        Item.AddPair('value', Qry.FieldByName('env_value').AsString);
        EnvArr.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('global_env', EnvArr);

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Global stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure HandleGetActivity(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Projects: TJSONArray;
  ProjObj: TJSONObject;
  Changes: TJSONArray;
  LastSlug: string;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    Projects := TJSONArray.Create;

    Qry := Ctx.CreateQuery(
      'SELECT p.slug AS project_slug, p.name AS project_name, ' +
      '  d.title AS doc_title, d.doc_type, ' +
      '  dr.changed_by, dr.change_reason, dr.changed_at ' +
      'FROM doc_revisions dr ' +
      'JOIN documents d ON dr.doc_id = d.id ' +
      'JOIN projects p ON d.project_id = p.id ' +
      'WHERE dr.changed_at > NOW() - INTERVAL 7 DAY ' +
      '  AND p.is_active = TRUE ' +
      'ORDER BY p.slug, dr.changed_at DESC ' +
      'LIMIT 50');
    try
      Qry.Open;
      LastSlug := '';
      ProjObj := nil;
      Changes := nil;

      while not Qry.Eof do
      begin
        if Qry.FieldByName('project_slug').AsString <> LastSlug then
        begin
          LastSlug := Qry.FieldByName('project_slug').AsString;
          ProjObj := TJSONObject.Create;
          ProjObj.AddPair('slug', LastSlug);
          ProjObj.AddPair('name', Qry.FieldByName('project_name').AsString);
          Changes := TJSONArray.Create;
          ProjObj.AddPair('changes', Changes);
          Projects.Add(ProjObj);
        end;

        var Item := TJSONObject.Create;
        Item.AddPair('title', Qry.FieldByName('doc_title').AsString);
        Item.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Item.AddPair('changed_by', Qry.FieldByName('changed_by').AsString);
        Item.AddPair('reason', Qry.FieldByName('change_reason').AsString);
        Item.AddPair('changed_at', MxDateStr(Qry.FieldByName('changed_at')));
        Changes.Add(Item);

        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    Json.AddPair('projects', Projects);
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Activity feed error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

function MxRunBackup(AConfig: TMxConfig; ALogger: IMxLogger): string;
var
  DumpExe, BackupDir, CmdLine: string;
  {$IFDEF MSWINDOWS}
  SI: TStartupInfo;
  PI: TProcessInformation;
  ExitCode: DWORD;
  {$ENDIF}
begin
  Result := '';

  // Find mysqldump / mariadb-dump
  DumpExe := IncludeTrailingPathDelimiter(AConfig.VendorHome) + 'bin\mariadb-dump.exe';
  if not FileExists(DumpExe) then
  begin
    DumpExe := IncludeTrailingPathDelimiter(AConfig.VendorHome) + 'bin\mysqldump.exe';
    if not FileExists(DumpExe) then
      raise Exception.Create('mysqldump/mariadb-dump not found at ' + AConfig.VendorHome);
  end;

  // Backup directory
  BackupDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'backups';
  ForceDirectories(BackupDir);
  Result := TPath.Combine(BackupDir,
    'mxai_knowledge_' + FormatDateTime('yyyy-mm-dd_hhnnss', Now) + '.sql');

  // Write temp credentials file (avoids password in process list)
  var CredFile := TPath.Combine(BackupDir, '.backup_creds.cnf');
  var Creds := TStringList.Create;
  try
    Creds.Add('[mysqldump]');
    Creds.Add('password=' + AConfig.DBPassword);
    Creds.SaveToFile(CredFile, TEncoding.ANSI);
  finally
    Creds.Free;
  end;

  try
    // Build command line (no password on CLI)
    CmdLine := Format('"%s" --defaults-extra-file="%s" --host=%s --port=%d --user=%s ' +
      '--single-transaction --routines --triggers --result-file="%s" %s',
      [DumpExe, CredFile, AConfig.DBHost, AConfig.DBPort, AConfig.DBUsername,
       Result, AConfig.DBDatabase]);

    ALogger.Log(mlInfo, 'Backup starting: ' + Result);

    // Execute mysqldump
    {$IFDEF MSWINDOWS}
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    FillChar(PI, SizeOf(PI), 0);

    if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
      CREATE_NO_WINDOW, nil, nil, SI, PI) then
      raise Exception.Create('CreateProcess error ' + IntToStr(GetLastError));

    WaitForSingleObject(PI.hProcess, 60000); // max 60 sec
    GetExitCodeProcess(PI.hProcess, ExitCode);
    CloseHandle(PI.hProcess);
    CloseHandle(PI.hThread);

    if ExitCode <> 0 then
      raise Exception.Create('mysqldump exit code ' + IntToStr(ExitCode));
    {$ENDIF}
  finally
    // Always delete temp credentials file
    if FileExists(CredFile) then
      System.SysUtils.DeleteFile(CredFile);
  end;

  ALogger.Log(mlInfo, 'Backup completed: ' + Result);
end;

procedure HandlePostBackup(const C: THttpServerContext;
  AConfig: TMxConfig; ALogger: IMxLogger);
var
  BackupFile: string;
  Json: TJSONObject;
begin
  Json := TJSONObject.Create;
  try
    BackupFile := MxRunBackup(AConfig, ALogger);
    Json.AddPair('success', TJSONBool.Create(True));
    Json.AddPair('file', BackupFile);
    Json.AddPair('size_bytes', TJSONNumber.Create(TFile.GetSize(BackupFile)));
    Json.AddPair('timestamp', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Backup error: ' + E.Message);
      MxSendError(C, 500, E.Message);
    end;
  end;
end;

procedure HandlePostCleanup(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ArchivedCount: Integer;
  Json: TJSONObject;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    ArchivedCount := 0;

    // Find session_notes older than 30 days, active/draft, without open tasks
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.content FROM documents d ' +
      'WHERE d.doc_type = ''session_note'' ' +
      '  AND d.status IN (''active'', ''draft'') ' +
      '  AND d.updated_at < NOW() - INTERVAL 30 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        // Only archive if no open tasks in content
        if Pos('- [ ]', Qry.FieldByName('content').AsString) = 0 then
        begin
          var UpdQry := Ctx.CreateQuery(
            'UPDATE documents SET status = ''archived'' WHERE id = :id');
          try
            UpdQry.ParamByName('id').AsInteger := Qry.FieldByName('id').AsInteger;
            UpdQry.ExecSQL;
            Inc(ArchivedCount);
          finally
            UpdQry.Free;
          end;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    if ArchivedCount > 0 then
      ALogger.Log(mlInfo, Format('Auto-cleanup: %d session notes archived', [ArchivedCount]));

    Json.AddPair('archived_count', TJSONNumber.Create(ArchivedCount));
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Cleanup error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure HandleGetAccessLogStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, Summary: TJSONObject;
  ByTool, ByDay, TopDocs: TJSONArray;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // --- Summary ---
    Summary := TJSONObject.Create;
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total, ' +
      '  MIN(created_at) AS first_entry, ' +
      '  MAX(created_at) AS last_entry, ' +
      '  COUNT(DISTINCT session_id) AS unique_sessions, ' +
      '  COUNT(DISTINCT project_id) AS unique_projects, ' +
      '  DATEDIFF(MAX(created_at), MIN(created_at)) AS days_span ' +
      'FROM access_log');
    try
      Qry.Open;
      Summary.AddPair('total_entries', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
      Summary.AddPair('first_entry', MxDateStr(Qry.FieldByName('first_entry')));
      Summary.AddPair('last_entry', MxDateStr(Qry.FieldByName('last_entry')));
      Summary.AddPair('unique_sessions', TJSONNumber.Create(Qry.FieldByName('unique_sessions').AsInteger));
      Summary.AddPair('unique_projects', TJSONNumber.Create(Qry.FieldByName('unique_projects').AsInteger));
      Summary.AddPair('days_span', TJSONNumber.Create(Qry.FieldByName('days_span').AsInteger));
    finally
      Qry.Free;
    end;
    Json.AddPair('summary', Summary);

    // --- By tool ---
    ByTool := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT tool_name, COUNT(*) AS cnt ' +
      'FROM access_log GROUP BY tool_name ORDER BY cnt DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('tool', Qry.FieldByName('tool_name').AsString);
        Item.AddPair('count', TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        ByTool.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('by_tool', ByTool);

    // --- By day (last 14 days) ---
    ByDay := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT DATE(created_at) AS day, COUNT(*) AS cnt, ' +
      '  COUNT(DISTINCT session_id) AS sessions ' +
      'FROM access_log ' +
      'WHERE created_at > NOW() - INTERVAL 14 DAY ' +
      'GROUP BY DATE(created_at) ORDER BY day');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('date', MxDateStr(Qry.FieldByName('day')));
        Item.AddPair('entries', TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        Item.AddPair('sessions', TJSONNumber.Create(Qry.FieldByName('sessions').AsInteger));
        ByDay.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('by_day', ByDay);

    // --- Top accessed docs (for prefetch candidates) ---
    TopDocs := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT al.doc_id, d.title, d.doc_type, COUNT(*) AS cnt, ' +
      '  COUNT(DISTINCT al.session_id) AS in_sessions ' +
      'FROM access_log al ' +
      'JOIN documents d ON d.id = al.doc_id ' +
      'WHERE al.doc_id > 0 AND al.tool_name = ''mx_detail'' ' +
      'GROUP BY al.doc_id, d.title, d.doc_type ' +
      'ORDER BY in_sessions DESC, cnt DESC LIMIT 15');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('doc_id', TJSONNumber.Create(Qry.FieldByName('doc_id').AsInteger));
        Item.AddPair('title', Qry.FieldByName('title').AsString);
        Item.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Item.AddPair('access_count', TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        Item.AddPair('in_sessions', TJSONNumber.Create(Qry.FieldByName('in_sessions').AsInteger));
        TopDocs.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('top_docs', TopDocs);

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Access log stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure HandleGetPrefetchStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry, TopQry: TFDQuery;
  Json: TJSONObject;
  Projects: TJSONArray;
  ProjObj: TJSONObject;
  TopArr: TJSONArray;
  TotalCandidates: Integer;
  ProjSlug: string;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    Projects := TJSONArray.Create;
    TotalCandidates := 0;

    // Per-project candidate counts
    Qry := Ctx.CreateQuery(
      'SELECT p.slug, p.name, COUNT(*) AS candidate_count ' +
      'FROM access_patterns ap ' +
      'JOIN projects p ON ap.project_id = p.id ' +
      'GROUP BY ap.project_id, p.slug, p.name ' +
      'ORDER BY candidate_count DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        ProjObj := TJSONObject.Create;
        ProjSlug := Qry.FieldByName('slug').AsString;
        ProjObj.AddPair('slug', ProjSlug);
        ProjObj.AddPair('name', Qry.FieldByName('name').AsString);
        var CandCount := Qry.FieldByName('candidate_count').AsInteger;
        ProjObj.AddPair('candidate_count', TJSONNumber.Create(CandCount));
        Inc(TotalCandidates, CandCount);

        // Top-3 candidates for this project by score
        TopArr := TJSONArray.Create;
        TopQry := Ctx.CreateQuery(
          'SELECT ap.doc_id, d.title, d.doc_type, ap.score, ap.reason ' +
          'FROM access_patterns ap ' +
          'JOIN documents d ON ap.doc_id = d.id ' +
          'JOIN projects p ON ap.project_id = p.id ' +
          'WHERE p.slug = :slug ' +
          'ORDER BY ap.score DESC LIMIT 3');
        try
          TopQry.ParamByName('slug').AsString := ProjSlug;
          TopQry.Open;
          while not TopQry.Eof do
          begin
            var Item := TJSONObject.Create;
            Item.AddPair('doc_id', TJSONNumber.Create(TopQry.FieldByName('doc_id').AsInteger));
            Item.AddPair('title', TopQry.FieldByName('title').AsString);
            Item.AddPair('doc_type', TopQry.FieldByName('doc_type').AsString);
            Item.AddPair('score', TJSONNumber.Create(TopQry.FieldByName('score').AsFloat));
            Item.AddPair('reason', TopQry.FieldByName('reason').AsString);
            TopArr.Add(Item);
            TopQry.Next;
          end;
        finally
          TopQry.Free;
        end;
        ProjObj.AddPair('top_candidates', TopArr);

        Projects.Add(ProjObj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    Json.AddPair('projects', Projects);
    Json.AddPair('total_candidates', TJSONNumber.Create(TotalCandidates));
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Prefetch stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure HandleGetHealth(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Json, BackupObj: TJSONObject;
  DbOk: Boolean;
  BackupDir: string;
  Files: TStringDynArray;
  LastTime: TDateTime;
  I: Integer;
  BestTime: TDateTime;
  BestFile: string;
begin
  Json := TJSONObject.Create;
  try
    Json.AddPair('server_version', MXAI_VERSION);
    Json.AddPair('build', TJSONNumber.Create(MXAI_BUILD));

    // Uptime
    if GBootTime > 0 then
      Json.AddPair('uptime_seconds',
        TJSONNumber.Create(SecondsBetween(Now, GBootTime)))
    else
      Json.AddPair('uptime_seconds', TJSONNumber.Create(0));

    // DB status
    DbOk := False;
    try
      DbOk := APool.TestConnection;
    except
      // swallow
    end;
    if DbOk then
      Json.AddPair('db_status', 'ok')
    else
      Json.AddPair('db_status', 'error');

    // Last backup info
    BackupDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'backups';
    BackupObj := TJSONObject.Create;
    try
      if TDirectory.Exists(BackupDir) then
      begin
        Files := TDirectory.GetFiles(BackupDir, '*.sql');
        if Length(Files) > 0 then
        begin
          BestTime := 0;
          BestFile := '';
          for I := 0 to High(Files) do
          begin
            LastTime := TFile.GetLastWriteTime(Files[I]);
            if LastTime > BestTime then
            begin
              BestTime := LastTime;
              BestFile := Files[I];
            end;
          end;
          BackupObj.AddPair('file', ExtractFileName(BestFile));
          BackupObj.AddPair('size_bytes', TJSONNumber.Create(TFile.GetSize(BestFile)));
          BackupObj.AddPair('age_hours',
            TJSONNumber.Create(RoundTo(HourSpan(Now, BestTime), -1)));
          BackupObj.AddPair('timestamp',
            FormatDateTime('yyyy-mm-dd hh:nn:ss', BestTime));
        end
        else
          BackupObj.AddPair('file', TJSONNull.Create);
      end
      else
        BackupObj.AddPair('file', TJSONNull.Create);
    except
      on E: Exception do
        BackupObj.AddPair('error', E.Message);
    end;
    Json.AddPair('last_backup', BackupObj);

    // ACL mode
    case AConfig.AclMode of
      amOff:     Json.AddPair('acl_mode', 'off');
      amAudit:   Json.AddPair('acl_mode', 'audit');
      amEnforce: Json.AddPair('acl_mode', 'enforce');
    end;

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Health endpoint error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure HandleGetActiveSessions(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Sessions: TJSONArray;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    Sessions := TJSONArray.Create;

    Qry := Ctx.CreateQuery(
      'SELECT s.id AS session_id, p.slug AS project, p.name AS project_name, ' +
      '  COALESCE(d.name, s.instance_id) AS developer, ' +
      '  ck.name AS key_name, ' +
      '  s.setup_version, ' +
      '  s.started_at, s.last_heartbeat ' +
      'FROM sessions s ' +
      'JOIN projects p ON s.project_id = p.id ' +
      'LEFT JOIN developers d ON s.developer_id = d.id ' +
      'LEFT JOIN client_keys ck ON s.client_key_id = ck.id ' +
      'WHERE s.ended_at IS NULL ' +
      '  AND (s.last_heartbeat > NOW() - INTERVAL 2 HOUR ' +
      '       OR (s.last_heartbeat IS NULL ' +
      '           AND s.started_at > NOW() - INTERVAL 2 HOUR)) ' +
      'ORDER BY s.started_at DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('session_id', TJSONNumber.Create(Qry.FieldByName('session_id').AsInteger));
        Item.AddPair('project', Qry.FieldByName('project').AsString);
        Item.AddPair('project_name', Qry.FieldByName('project_name').AsString);
        Item.AddPair('developer', Qry.FieldByName('developer').AsString);
        if not Qry.FieldByName('key_name').IsNull then
          Item.AddPair('key_name', Qry.FieldByName('key_name').AsString)
        else
          Item.AddPair('key_name', TJSONNull.Create);
        if not Qry.FieldByName('setup_version').IsNull then
          Item.AddPair('setup_version', Qry.FieldByName('setup_version').AsString)
        else
          Item.AddPair('setup_version', TJSONNull.Create);
        Item.AddPair('started_at', MxDateStr(Qry.FieldByName('started_at')));
        if not Qry.FieldByName('last_heartbeat').IsNull then
          Item.AddPair('last_heartbeat', MxDateStr(Qry.FieldByName('last_heartbeat')))
        else
          Item.AddPair('last_heartbeat', TJSONNull.Create);
        Sessions.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    Json.AddPair('active_sessions', Sessions);
    if MXAI_SETUP_VERSION <> '' then
      Json.AddPair('setup_version', MXAI_SETUP_VERSION);
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Active sessions error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/skill-evolution — Skill Evolution Dashboard Stats
// ---------------------------------------------------------------------------
procedure HandleGetSkillEvolution(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, SkillObj: TJSONObject;
  BySkill, RecentArr, ParamsArr: TJSONArray;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    // 1. Findings by skill (aggregated)
    BySkill := TJSONArray.Create;
    Json.AddPair('by_skill', BySkill);
    Qry := Ctx.CreateQuery(
      'SELECT skill_name, ' +
      '  COUNT(*) AS total, ' +
      '  SUM(CASE WHEN user_reaction = ''pending'' THEN 1 ELSE 0 END) AS pending, ' +
      '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN 1 ELSE 0 END) AS confirmed, ' +
      '  SUM(CASE WHEN user_reaction = ''dismissed'' THEN 1 ELSE 0 END) AS dismissed, ' +
      '  SUM(CASE WHEN user_reaction = ''false_positive'' THEN 1 ELSE 0 END) AS false_pos ' +
      'FROM skill_findings ' +
      'GROUP BY skill_name ORDER BY total DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        SkillObj := TJSONObject.Create;
        SkillObj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        SkillObj.AddPair('total', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
        SkillObj.AddPair('pending', TJSONNumber.Create(Qry.FieldByName('pending').AsInteger));
        SkillObj.AddPair('confirmed', TJSONNumber.Create(Qry.FieldByName('confirmed').AsInteger));
        SkillObj.AddPair('dismissed', TJSONNumber.Create(Qry.FieldByName('dismissed').AsInteger));
        SkillObj.AddPair('false_positives', TJSONNumber.Create(Qry.FieldByName('false_pos').AsInteger));
        BySkill.AddElement(SkillObj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // 2. Recent findings (last 7 days)
    RecentArr := TJSONArray.Create;
    Json.AddPair('recent', RecentArr);
    Qry := Ctx.CreateQuery(
      'SELECT f.finding_uid, f.skill_name, f.rule_id, f.severity, ' +
      '  f.title, f.user_reaction, f.created_at, p.slug AS project ' +
      'FROM skill_findings f ' +
      'JOIN projects p ON p.id = f.project_id ' +
      'WHERE f.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY) ' +
      'ORDER BY f.created_at DESC LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        SkillObj := TJSONObject.Create;
        SkillObj.AddPair('uid', Qry.FieldByName('finding_uid').AsString);
        SkillObj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        SkillObj.AddPair('rule', Qry.FieldByName('rule_id').AsString);
        SkillObj.AddPair('severity', Qry.FieldByName('severity').AsString);
        SkillObj.AddPair('title', Qry.FieldByName('title').AsString);
        SkillObj.AddPair('reaction', Qry.FieldByName('user_reaction').AsString);
        SkillObj.AddPair('project', Qry.FieldByName('project').AsString);
        SkillObj.AddPair('created', FormatDateTime('yyyy-mm-dd hh:nn', Qry.FieldByName('created_at').AsDateTime));
        RecentArr.AddElement(SkillObj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // 3. Active tuning params
    ParamsArr := TJSONArray.Create;
    Json.AddPair('params', ParamsArr);
    Qry := Ctx.CreateQuery(
      'SELECT sp.skill_name, sp.param_key, sp.param_value, sp.version, ' +
      '  sp.change_reason, sp.updated_at, p.slug AS project ' +
      'FROM skill_params sp ' +
      'JOIN projects p ON p.id = sp.project_id ' +
      'ORDER BY sp.updated_at DESC LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        SkillObj := TJSONObject.Create;
        SkillObj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        SkillObj.AddPair('key', Qry.FieldByName('param_key').AsString);
        SkillObj.AddPair('value', Qry.FieldByName('param_value').AsString);
        SkillObj.AddPair('version', TJSONNumber.Create(Qry.FieldByName('version').AsInteger));
        SkillObj.AddPair('reason', Qry.FieldByName('change_reason').AsString);
        SkillObj.AddPair('project', Qry.FieldByName('project').AsString);
        SkillObj.AddPair('updated', FormatDateTime('yyyy-mm-dd hh:nn', Qry.FieldByName('updated_at').AsDateTime));
        ParamsArr.AddElement(SkillObj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Skill evolution stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/recall-metrics — Recall effectiveness metrics (C6, Plan#1231)
// ---------------------------------------------------------------------------
procedure HandleGetRecallMetrics(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  GateArr, OutcomeArr, LessonsArr: TJSONArray;
  Total, Hits: Integer;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // --- Hitrate (30 days) ---
    Total := 0;
    Hits := 0;
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total, ' +
      '  SUM(CASE WHEN treffer_count > 0 THEN 1 ELSE 0 END) AS hits ' +
      'FROM recall_log WHERE created_at > NOW() - INTERVAL 30 DAY');
    try
      Qry.Open;
      Total := Qry.FieldByName('total').AsInteger;
      Hits := Qry.FieldByName('hits').AsInteger;
    finally
      Qry.Free;
    end;
    Json.AddPair('total', TJSONNumber.Create(Total));
    Json.AddPair('hits', TJSONNumber.Create(Hits));
    if Total > 0 then
      Json.AddPair('hitrate_pct', TJSONNumber.Create(Round((Hits / Total) * 100)))
    else
      Json.AddPair('hitrate_pct', TJSONNumber.Create(0));

    // --- Gate-Level distribution (30 days) ---
    GateArr := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT COALESCE(gate_level, ''NONE'') AS gate_level, COUNT(*) AS cnt ' +
      'FROM recall_log WHERE created_at > NOW() - INTERVAL 30 DAY ' +
      'GROUP BY gate_level ORDER BY cnt DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('level', Qry.FieldByName('gate_level').AsString);
        Item.AddPair('count', TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        GateArr.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('gate_levels', GateArr);

    // --- Outcome distribution (30 days) ---
    OutcomeArr := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT outcome, COUNT(*) AS cnt ' +
      'FROM recall_log WHERE created_at > NOW() - INTERVAL 30 DAY ' +
      'GROUP BY outcome ORDER BY cnt DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('outcome', Qry.FieldByName('outcome').AsString);
        Item.AddPair('count', TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        OutcomeArr.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('outcomes', OutcomeArr);

    // --- Top-10 Lessons by effectiveness ---
    LessonsArr := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title, d.violation_count, d.success_count ' +
      'FROM documents d ' +
      'WHERE d.doc_type = ''lesson'' AND d.status != ''deleted'' ' +
      'ORDER BY (d.violation_count + d.success_count) DESC LIMIT 10');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Item.AddPair('title', Qry.FieldByName('title').AsString);
        Item.AddPair('violations', TJSONNumber.Create(Qry.FieldByName('violation_count').AsInteger));
        Item.AddPair('successes', TJSONNumber.Create(Qry.FieldByName('success_count').AsInteger));
        LessonsArr.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('top_lessons', LessonsArr);

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Recall metrics error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/graph-stats — Knowledge Graph statistics
// ---------------------------------------------------------------------------
procedure HandleGetGraphStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    Qry := Ctx.CreateQuery(
      'SELECT ' +
      '(SELECT COUNT(*) FROM graph_nodes) AS node_count, ' +
      '(SELECT COUNT(*) FROM graph_edges) AS edge_count, ' +
      '(SELECT COUNT(DISTINCT node_type) FROM graph_nodes) AS type_count');
    try
      Qry.Open;
      Json.AddPair('node_count', TJSONNumber.Create(Qry.FieldByName('node_count').AsInteger));
      Json.AddPair('edge_count', TJSONNumber.Create(Qry.FieldByName('edge_count').AsInteger));
      Json.AddPair('type_count', TJSONNumber.Create(Qry.FieldByName('type_count').AsInteger));
    finally
      Qry.Free;
    end;
    MxSendJson(C, 200, Json);
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Graph stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/lesson-stats — Lesson count statistics
// ---------------------------------------------------------------------------
procedure HandleGetLessonStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total FROM documents ' +
      'WHERE doc_type = ''lesson'' AND status <> ''deleted''');
    try
      Qry.Open;
      Json.AddPair('total', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
    finally
      Qry.Free;
    end;
    MxSendJson(C, 200, Json);
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Lesson stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/embedding-stats — Semantic Search embedding statistics
// ---------------------------------------------------------------------------
procedure HandleGetEmbeddingStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    Qry := Ctx.CreateQuery(
      'SELECT ' +
      '  COUNT(*) AS total_docs, ' +
      '  SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END) AS embedded, ' +
      '  SUM(CASE WHEN embedding_stale = 1 AND embedding IS NULL THEN 1 ELSE 0 END) AS stale ' +
      'FROM documents WHERE status <> ''deleted'' ' +
      'AND doc_type IN (''spec'',''plan'',''decision'',''lesson'',''note'',' +
      '''reference'',''snippet'',''bugreport'',''feature_request'',''todo'',''assumption'')');
    try
      Qry.Open;
      var Total := Qry.FieldByName('total_docs').AsInteger;
      var Embedded := Qry.FieldByName('embedded').AsInteger;
      var Stale := Qry.FieldByName('stale').AsInteger;
      Json.AddPair('total_docs', TJSONNumber.Create(Total));
      Json.AddPair('embedded', TJSONNumber.Create(Embedded));
      Json.AddPair('stale', TJSONNumber.Create(Stale));
      if Total > 0 then
        Json.AddPair('coverage_pct', TJSONNumber.Create(Round(Embedded * 100 / Total)))
      else
        Json.AddPair('coverage_pct', TJSONNumber.Create(0));
    finally
      Qry.Free;
    end;
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// ---------------------------------------------------------------------------
// GET /global/token-stats — Token efficiency metrics (for marketing)
// ---------------------------------------------------------------------------
procedure HandleGetTokenStats(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    // Total token weight of all active docs (= what you'd load without MCP)
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS doc_count, COALESCE(SUM(token_estimate), 0) AS total_tokens ' +
      'FROM documents WHERE status <> ''deleted''');
    try
      Qry.Open;
      Json.AddPair('total_docs', TJSONNumber.Create(Qry.FieldByName('doc_count').AsInteger));
      Json.AddPair('total_tokens', TJSONNumber.Create(Qry.FieldByName('total_tokens').AsInteger));
    finally
      Qry.Free;
    end;

    // Average UNIQUE tokens delivered per session (distinct docs, no double-counting)
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(DISTINCT sub.session_id) AS session_count, ' +
      '  COALESCE(AVG(sub.sess_tokens), 0) AS avg_delivered ' +
      'FROM (' +
      '  SELECT a.session_id, SUM(d.token_estimate) AS sess_tokens ' +
      '  FROM (SELECT DISTINCT session_id, doc_id FROM access_log ' +
      '        WHERE created_at > NOW() - INTERVAL 30 DAY) a ' +
      '  JOIN documents d ON d.id = a.doc_id ' +
      '  GROUP BY a.session_id) sub');
    try
      Qry.Open;
      var SessionCount := Qry.FieldByName('session_count').AsInteger;
      var AvgDelivered := Round(Qry.FieldByName('avg_delivered').AsFloat);
      Json.AddPair('sessions_30d', TJSONNumber.Create(SessionCount));
      Json.AddPair('avg_tokens_per_session', TJSONNumber.Create(AvgDelivered));
    finally
      Qry.Free;
    end;

    // MCP tool call count (last 30 days, from tool_call_log)
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS call_count FROM tool_call_log ' +
      'WHERE created_at > NOW() - INTERVAL 30 DAY');
    try
      Qry.Open;
      Json.AddPair('mcp_calls_30d', TJSONNumber.Create(Qry.FieldByName('call_count').AsInteger));
    finally
      Qry.Free;
    end;

    // Total sessions (from sessions table, more accurate than access_log)
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total_sessions FROM sessions ' +
      'WHERE started_at > NOW() - INTERVAL 30 DAY');
    try
      Qry.Open;
      Json.AddPair('total_sessions_30d', TJSONNumber.Create(Qry.FieldByName('total_sessions').AsInteger));
    finally
      Qry.Free;
    end;

    // Savings: what you'd need without MCP vs what MCP delivered (unique docs, no double-count)
    Qry := Ctx.CreateQuery(
      'SELECT COALESCE(AVG(sess_available), 0) AS avg_available, ' +
      '  COALESCE(AVG(sess_delivered), 0) AS avg_delivered ' +
      'FROM (' +
      '  SELECT s.session_id, ' +
      '    (SELECT SUM(d2.token_estimate) FROM documents d2 ' +
      '     WHERE d2.project_id IN (SELECT DISTINCT d3.project_id FROM access_log a2 ' +
      '       JOIN documents d3 ON d3.id = a2.doc_id WHERE a2.session_id = s.session_id) ' +
      '     AND d2.status <> ''deleted'') AS sess_available, ' +
      '    SUM(d.token_estimate) AS sess_delivered ' +
      '  FROM (SELECT DISTINCT session_id, doc_id FROM access_log ' +
      '        WHERE created_at > NOW() - INTERVAL 30 DAY) s ' +
      '  JOIN documents d ON d.id = s.doc_id ' +
      '  GROUP BY s.session_id ' +
      '  HAVING sess_available > 0' +
      ') sub');
    try
      Qry.Open;
      var AvgAvailable := Qry.FieldByName('avg_available').AsFloat;
      var AvgDelivered := Qry.FieldByName('avg_delivered').AsFloat;
      if AvgAvailable > 0 then
        Json.AddPair('savings_pct', TJSONNumber.Create(
          Max(0, Round((1 - (AvgDelivered / AvgAvailable)) * 100))))
      else
        Json.AddPair('savings_pct', TJSONNumber.Create(0));
      Json.AddPair('avg_available_tokens', TJSONNumber.Create(Round(AvgAvailable)));
    finally
      Qry.Free;
    end;

    MxSendJson(C, 200, Json);
  except
    on E: Exception do
    begin
      ALogger.Log(mlError, 'Token stats error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
  Json.Free;
end;

end.
