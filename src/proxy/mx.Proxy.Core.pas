unit mx.Proxy.Core;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.SyncObjs, System.IOUtils, System.Net.HttpClient, System.Net.URLClient,
  Winapi.Windows,
  mx.Proxy.Config, mx.Proxy.Http;

type
  // Background thread that polls agent inbox and writes to file
  TMxAgentPollThread = class(TThread)
  private
    FServerUrl: string;
    FApiKey: string;
    FProject: string;
    FInterval: Integer;
    FInboxDir: string;
    FWrittenIds: string;       // IDs written to file, for ACK after Hook deletes
    FKnownIds: TList<Integer>; // already fetched IDs, prevents duplicates
    FShutdownEvent: TEvent;
    function GetInboxFilePath: string;
    function GetTmpFilePath: string;
    procedure WriteInboxFile(const AJson: string; const AIds: string);
    procedure CheckAndAck;
  protected
    procedure Execute; override;
  public
    constructor Create(const AServerUrl, AApiKey, AProject, AInboxDir: string;
      AInterval: Integer);
    destructor Destroy; override;
    procedure RequestShutdown;
  end;

  TMxStdioProxy = class
  private
    FConfig: TMxProxyConfig;
    FLock: TCriticalSection;
    FSessionId: string;
    FShutdownRequested: Boolean;
    FAgentThread: TMxAgentPollThread;
    FProjectSlug: string;
    procedure WriteOutput(const ALine: string);
    function GetSessionId: string;
    procedure SetSessionId(const AValue: string);
    procedure HandleLine(const ALine: string);
    function MakeParseError: string;
    procedure TryDetectProject(const AParsed: TJSONValue);
  public
    constructor Create(AConfig: TMxProxyConfig);
    destructor Destroy; override;
    procedure Run;
  end;

implementation

var
  GProxyInstance: TMxStdioProxy = nil;

function ConsoleCtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  if GProxyInstance <> nil then
  begin
    GProxyInstance.FShutdownRequested := True;
    if GProxyInstance.FAgentThread <> nil then
      GProxyInstance.FAgentThread.RequestShutdown;
  end;
  Result := True;
end;

{ TMxAgentPollThread }

constructor TMxAgentPollThread.Create(const AServerUrl, AApiKey, AProject,
  AInboxDir: string; AInterval: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServerUrl := AServerUrl;
  FApiKey := AApiKey;
  FProject := AProject;
  FInboxDir := AInboxDir;
  FInterval := AInterval;
  FWrittenIds := '';
  FKnownIds := TList<Integer>.Create;
  FShutdownEvent := TEvent.Create(nil, True, False, '');

  // Ensure inbox directory exists
  ForceDirectories(FInboxDir);
end;

destructor TMxAgentPollThread.Destroy;
begin
  FShutdownEvent.Free;
  FKnownIds.Free;
  inherited;
end;

function TMxAgentPollThread.GetInboxFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(FInboxDir) +
    'agent_inbox_' + FProject + '.json';
end;

function TMxAgentPollThread.GetTmpFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(FInboxDir) +
    'agent_inbox_' + FProject + '.tmp';
end;

procedure TMxAgentPollThread.WriteInboxFile(const AJson: string;
  const AIds: string);
var
  TmpPath, JsonPath: string;
  Retry: Integer;
begin
  TmpPath := GetTmpFilePath;
  JsonPath := GetInboxFilePath;

  // Write to .tmp first (no BOM — bash scripts can't handle it)
  var Bytes := TEncoding.UTF8.GetBytes(AJson);
  TFile.WriteAllBytes(TmpPath, Bytes);

  // Atomic rename .tmp -> .json (retry on sharing violation)
  for Retry := 1 to 3 do
  begin
    if MoveFileEx(PChar(TmpPath), PChar(JsonPath),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      FWrittenIds := AIds;
      Exit;
    end;
    if Retry < 3 then
      Sleep(50);
  end;

  // Rename failed after retries — clean up tmp
  TFile.Delete(TmpPath);
  WriteLn(ErrOutput, '[mxProxy] Failed to write inbox file after 3 retries');
end;

procedure TMxAgentPollThread.CheckAndAck;
var
  Http: THTTPClient;
begin
  // If we wrote IDs and the file is gone (Hook consumed it), send ACK
  if (FWrittenIds = '') then Exit;
  if FileExists(GetInboxFilePath) then Exit;

  try
    Http := THTTPClient.Create;
    try
      Http.ConnectionTimeout := 5000;
      Http.ResponseTimeout := 5000;
      Http.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
      Http.Get(FServerUrl + '?agent_ack=' + FWrittenIds);
    finally
      Http.Free;
    end;
  except
    on E: Exception do
      WriteLn(ErrOutput, '[mxProxy] ACK failed: ' + E.Message);
  end;

  // Clear regardless of ACK success (prevent infinite retry)
  FWrittenIds := '';
  FKnownIds.Clear;
end;

procedure TMxAgentPollThread.RequestShutdown;
begin
  Terminate;
  FShutdownEvent.SetEvent;
end;

procedure TMxAgentPollThread.Execute;
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  Url, Body: string;
  Parsed: TJSONValue;
  Count: Integer;
  FileJson: TJSONObject;
  NewIds: string;
begin
  Url := FServerUrl + '?agent_inbox=' + FProject;

  while not Terminated do
  begin
    // Check if Hook consumed the file (ACK needed)
    CheckAndAck;

    try
      Http := THTTPClient.Create;
      try
        Http.ConnectionTimeout := 5000;
        Http.ResponseTimeout := 5000;
        Http.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
        Response := Http.Get(Url);

        if Response.StatusCode = 200 then
        begin
          Body := Response.ContentAsString;
          Parsed := TJSONObject.ParseJSONValue(Body);
          if (Parsed <> nil) and (Parsed is TJSONObject) then
          begin
            try
              Count := (Parsed as TJSONObject).GetValue<Integer>('count', 0);
              if Count > 0 then
              begin
                var MsgArr := (Parsed as TJSONObject).GetValue('messages');
                if (MsgArr <> nil) and (MsgArr is TJSONArray) then
                begin
                  // Filter duplicates
                  var NewArr := TJSONArray.Create;
                  NewIds := '';
                  try
                    for var I := 0 to (MsgArr as TJSONArray).Count - 1 do
                    begin
                      var MsgId := ((MsgArr as TJSONArray).Items[I] as TJSONObject)
                        .GetValue<Integer>('id', 0);
                      if (MsgId > 0) and not FKnownIds.Contains(MsgId) then
                      begin
                        FKnownIds.Add(MsgId);
                        NewArr.AddElement(
                          (MsgArr as TJSONArray).Items[I].Clone as TJSONValue);
                        if NewIds <> '' then NewIds := NewIds + ',';
                        NewIds := NewIds + IntToStr(MsgId);
                      end;
                    end;

                    // Write file if new messages
                    if NewArr.Count > 0 then
                    begin
                      FileJson := TJSONObject.Create;
                      try
                        FileJson.AddPair('v', TJSONNumber.Create(1));
                        FileJson.AddPair('ts',
                          FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
                        FileJson.AddPair('ids', NewIds);
                        FileJson.AddPair('messages', NewArr.Clone as TJSONArray);
                        WriteInboxFile(FileJson.ToJSON, NewIds);
                      finally
                        FileJson.Free;
                      end;
                    end;
                  finally
                    NewArr.Free;
                  end;
                end;
              end;
            finally
              Parsed.Free;
            end;
          end
          else
            Parsed.Free;
        end;
      finally
        Http.Free;
      end;
    except
      on E: Exception do
        WriteLn(ErrOutput, '[mxProxy] Agent poll error: ' + E.Message);
    end;

    // Wait for interval or shutdown
    if FShutdownEvent.WaitFor(Cardinal(FInterval * 1000)) = wrSignaled then
      Break;
  end;
end;

{ TMxStdioProxy }

constructor TMxStdioProxy.Create(AConfig: TMxProxyConfig);
begin
  inherited Create;
  FConfig := AConfig;
  FLock := TCriticalSection.Create;
  FShutdownRequested := False;
  FSessionId := '';
  FProjectSlug := '';
  FAgentThread := nil;

  GProxyInstance := Self;
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);

  // Debug: log working directory and CLAUDE.md detection
  WriteLn(ErrOutput, '[mxProxy] CWD: ' + GetCurrentDir);

  // WorkDir: override CWD if configured (for deployments where EXE is not in project dir)
  if FConfig.WorkDir <> '' then
  begin
    if DirectoryExists(FConfig.WorkDir) then
    begin
      SetCurrentDir(FConfig.WorkDir);
      WriteLn(ErrOutput, '[mxProxy] WorkDir changed to: ' + FConfig.WorkDir);
    end
    else
      WriteLn(ErrOutput, '[mxProxy] WorkDir not found: ' + FConfig.WorkDir);
  end;

  // Try to detect project slug from CLAUDE.md in working directory
  if FConfig.AgentPolling and FileExists('CLAUDE.md') then
  begin
    try
      var ClaudeMd := TFile.ReadAllText('CLAUDE.md', TEncoding.UTF8);
      var SlugPos := Pos('**Slug:**', ClaudeMd);
      if SlugPos > 0 then
      begin
        var AfterSlug := Copy(ClaudeMd, SlugPos + 9, 100);
        // Trim spaces, backticks, newlines
        AfterSlug := Trim(AfterSlug);
        AfterSlug := StringReplace(AfterSlug, '`', '', [rfReplaceAll]);
        // Take first word
        var SpacePos := Pos(' ', AfterSlug);
        var NlPos := Pos(#10, AfterSlug);
        var CrPos := Pos(#13, AfterSlug);
        if (SpacePos > 0) then AfterSlug := Copy(AfterSlug, 1, SpacePos - 1);
        if (NlPos > 0) and (NlPos < Length(AfterSlug)) then AfterSlug := Copy(AfterSlug, 1, NlPos - 1);
        if (CrPos > 0) and (CrPos < Length(AfterSlug)) then AfterSlug := Copy(AfterSlug, 1, CrPos - 1);
        AfterSlug := Trim(AfterSlug);

        if AfterSlug <> '' then
        begin
          FProjectSlug := AfterSlug;
          WriteLn(ErrOutput, '[mxProxy] Slug from CLAUDE.md: ' + FProjectSlug);

          // Auto-start polling thread
          FAgentThread := TMxAgentPollThread.Create(
            FConfig.ServerUrl, FConfig.ApiKey,
            FProjectSlug, FConfig.InboxDir,
            FConfig.AgentPollInterval);
          FAgentThread.Start;
          WriteLn(ErrOutput, '[mxProxy] Agent polling auto-started for ' + FProjectSlug);
        end;
      end;
    except
      on E: Exception do
        WriteLn(ErrOutput, '[mxProxy] CLAUDE.md read failed: ' + E.Message);
    end;
  end;
end;

destructor TMxStdioProxy.Destroy;
begin
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
  GProxyInstance := nil;
  if FAgentThread <> nil then
  begin
    FAgentThread.RequestShutdown;
    FAgentThread.WaitFor;
    FAgentThread.Free;
  end;
  FLock.Free;
  inherited;
end;

procedure TMxStdioProxy.WriteOutput(const ALine: string);
begin
  FLock.Enter;
  try
    WriteLn(ALine);
    Flush(Output);
  finally
    FLock.Leave;
  end;
end;

function TMxStdioProxy.GetSessionId: string;
begin
  FLock.Enter;
  try
    Result := FSessionId;
  finally
    FLock.Leave;
  end;
end;

procedure TMxStdioProxy.SetSessionId(const AValue: string);
begin
  FLock.Enter;
  try
    FSessionId := AValue;
  finally
    FLock.Leave;
  end;
end;

function TMxStdioProxy.MakeParseError: string;
var
  Resp, Err: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    Resp.AddPair('id', TJSONNull.Create);
    Err := TJSONObject.Create;
    Err.AddPair('code', TJSONNumber.Create(-32700));
    Err.AddPair('message', 'Parse error');
    Resp.AddPair('error', Err);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

// Detect project slug from any tools/call request with 'project' parameter
procedure TMxStdioProxy.TryDetectProject(const AParsed: TJSONValue);
var
  Obj, Params, Args: TJSONObject;
begin
  if not (AParsed is TJSONObject) then Exit;
  Obj := AParsed as TJSONObject;

  if Obj.GetValue<string>('method', '') <> 'tools/call' then Exit;

  if Obj.GetValue('params') = nil then Exit;
  if not (Obj.GetValue('params') is TJSONObject) then Exit;
  Params := Obj.GetValue('params') as TJSONObject;

  if Params.GetValue('arguments') = nil then Exit;
  if not (Params.GetValue('arguments') is TJSONObject) then Exit;
  Args := Params.GetValue('arguments') as TJSONObject;

  var Project := Args.GetValue<string>('project', '');
  if Project = '' then Exit;

  FProjectSlug := Project;

  // Start polling thread
  FAgentThread := TMxAgentPollThread.Create(
    FConfig.ServerUrl, FConfig.ApiKey,
    FProjectSlug, FConfig.InboxDir,
    FConfig.AgentPollInterval);
  FAgentThread.Start;
  WriteLn(ErrOutput, '[mxProxy] Agent polling started for ' +
    FProjectSlug + ' (every ' + IntToStr(FConfig.AgentPollInterval) + 's)');
end;

procedure TMxStdioProxy.HandleLine(const ALine: string);
var
  HttpClient: TMxProxyHttpClient;
  Responses: TArray<string>;
  NewSessionId: string;
  Parsed: TJSONValue;
  I: Integer;
begin
  if ALine.Trim = '' then
    Exit;

  Parsed := TJSONObject.ParseJSONValue(ALine);
  if Parsed = nil then
  begin
    WriteOutput(MakeParseError);
    Exit;
  end;

  // Detect project from any request to start polling
  if FConfig.AgentPolling and (FAgentThread = nil) then
    TryDetectProject(Parsed);

  Parsed.Free;

  HttpClient := TMxProxyHttpClient.Create(
    FConfig.ServerUrl, FConfig.ApiKey,
    FConfig.ConnectionTimeout, FConfig.ReadTimeout);
  try
    HttpClient.SessionId := GetSessionId;
    Responses := HttpClient.Forward(ALine, NewSessionId);

    if NewSessionId <> '' then
      SetSessionId(NewSessionId)
    else if (GetSessionId <> '') and (HttpClient.SessionId = '') then
      SetSessionId('');

    for I := 0 to High(Responses) do
      WriteOutput(Responses[I]);
  finally
    HttpClient.Free;
  end;
end;

procedure TMxStdioProxy.Run;
var
  Line: string;
begin
  while not FShutdownRequested do
  begin
    try
      ReadLn(Line);
      HandleLine(Line);
    except
      on E: EInOutError do
        Break;
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'ERROR: ' + E.Message);
        Break;
      end;
    end;
  end;
end;

end.
