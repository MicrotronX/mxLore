unit mx.Proxy.Core;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.SyncObjs, System.IOUtils, System.Net.HttpClient, System.Net.URLClient,
  Winapi.Windows,
  mx.Proxy.Log, mx.Proxy.Config, mx.Proxy.Http;

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
    function GetKnownIdsFilePath: string;
    procedure WriteInboxFile(const AJson: string; const AIds: string);
    procedure CheckAndAck;
    procedure LoadKnownIds;
    procedure SaveKnownIds;
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
  LogDebug('[poll] Thread.Create entry. project=' + AProject + ' inbox=' + AInboxDir
      + ' interval=' + IntToStr(AInterval));
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
  LogDebug('[poll] Creating inbox dir: ' + FInboxDir);
  try
    ForceDirectories(FInboxDir);
    LogDebug('[poll] Inbox dir ready. exists=' + BoolToStr(DirectoryExists(FInboxDir), True));
  except
    on E: Exception do
      Log('[poll] ForceDirectories FAILED: ' + E.ClassName + ': ' + E.Message);
  end;

  // Restore known-IDs from disk — survives Proxy restarts, prevents the
  // accumulation-gap where un-acked messages get rewritten to JSON on every
  // Proxy startup (Bug observed 2026-04-20: mx-erp.json grew to 12 IDs
  // across multiple restarts before the Hook could ack them cleanly).
  LoadKnownIds;

  LogDebug('[poll] Thread.Create done');
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

function TMxAgentPollThread.GetKnownIdsFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(FInboxDir) +
    'known_ids_' + FProject + '.txt';
end;

procedure TMxAgentPollThread.LoadKnownIds;
var
  Lines: TArray<string>;
  Line: string;
  Id: Integer;
begin
  if not FileExists(GetKnownIdsFilePath) then Exit;
  try
    // Match the writer: TFile.WriteAllText(..., TEncoding.UTF8) emits a BOM.
    // Reading without an encoding hint falls back to TEncoding.Default
    // (Windows ANSI) which surfaces the BOM as a garbage first line and
    // silently drops it via TryStrToInt. Explicit UTF-8 read strips the BOM
    // cleanly and matches the writer end-to-end.
    Lines := TFile.ReadAllLines(GetKnownIdsFilePath, TEncoding.UTF8);
    for Line in Lines do
      if TryStrToInt(Trim(Line), Id) and (Id > 0) then
        FKnownIds.Add(Id);
    LogDebug('[poll] Loaded ' + IntToStr(FKnownIds.Count) +
      ' known IDs from disk');
  except
    on E: Exception do
      Log('[poll] LoadKnownIds failed (starting fresh): ' + E.Message);
  end;
end;

procedure TMxAgentPollThread.SaveKnownIds;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to FKnownIds.Count - 1 do
      SB.AppendLine(IntToStr(FKnownIds[I]));
    try
      TFile.WriteAllText(GetKnownIdsFilePath, SB.ToString, TEncoding.UTF8);
    except
      on E: Exception do
        Log('[poll] SaveKnownIds failed: ' + E.Message);
    end;
  finally
    SB.Free;
  end;
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
  Log('[mxProxy] Failed to write inbox file after 3 retries');
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
      Log('[mxProxy] ACK failed: ' + E.Message);
  end;

  // Clear regardless of ACK success (prevent infinite retry)
  FWrittenIds := '';
  FKnownIds.Clear;
  // Persist the cleared state so a Proxy restart does not reload a stale
  // on-disk known_ids_<project>.txt that would swallow newly pending messages.
  try
    if FileExists(GetKnownIdsFilePath) then
      TFile.Delete(GetKnownIdsFilePath);
  except
    on E: Exception do
      Log('[poll] known_ids delete failed: ' + E.Message);
  end;
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
  LogDebug('[poll] Execute entry. project=' + FProject);
  try
  Url := FServerUrl + '?agent_inbox=' + FProject;
  LogDebug('[poll] URL=' + Url);

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
                      // Persist FKnownIds so a Proxy restart does not re-
                      // consider these IDs "new" and re-write the same rows.
                      SaveKnownIds;
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
        Log('[mxProxy] Agent poll error: ' + E.Message);
    end;

    // Wait for interval or shutdown
    if FShutdownEvent.WaitFor(Cardinal(FInterval * 1000)) = wrSignaled then
      Break;
  end;
  LogDebug('[poll] Execute loop exit (Terminated=' + BoolToStr(Terminated, True) + ')');
  except
    on E: Exception do
      Log('[poll] FATAL in Execute: ' + E.ClassName + ': ' + E.Message);
  end;
  LogDebug('[poll] Execute return');
end;

{ TMxStdioProxy }

constructor TMxStdioProxy.Create(AConfig: TMxProxyConfig);
begin
  LogDebug('[stdio] TMxStdioProxy.Create entry');
  inherited Create;
  FConfig := AConfig;
  FLock := TCriticalSection.Create;
  FShutdownRequested := False;
  FSessionId := '';
  FProjectSlug := '';
  FAgentThread := nil;

  GProxyInstance := Self;
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
  LogDebug('[stdio] ConsoleCtrlHandler installed');

  // Debug: log working directory and CLAUDE.md detection
  LogDebug('[mxProxy] CWD: ' + GetCurrentDir);
  LogDebug('[mxProxy] ExeDir (ParamStr(0)): ' + ExtractFilePath(ParamStr(0)));
  LogDebug('[mxProxy] CLAUDE.md exists in CWD: ' + BoolToStr(FileExists('CLAUDE.md'), True));

  // WorkDir: override CWD if configured (for deployments where EXE is not in project dir)
  if FConfig.WorkDir <> '' then
  begin
    if DirectoryExists(FConfig.WorkDir) then
    begin
      SetCurrentDir(FConfig.WorkDir);
      Log('[mxProxy] WorkDir changed to: ' + FConfig.WorkDir);
    end
    else
      Log('[mxProxy] WorkDir not found: ' + FConfig.WorkDir);
  end;

  // Try to detect project slug from CLAUDE.md in working directory
  LogDebug('[stdio] AgentPolling=' + BoolToStr(FConfig.AgentPolling, True));
  if FConfig.AgentPolling and FileExists('CLAUDE.md') then
  begin
    LogDebug('[stdio] Starting CLAUDE.md slug parse');
    try
      var ClaudeMd := TFile.ReadAllText('CLAUDE.md', TEncoding.UTF8);
      LogDebug('[stdio] CLAUDE.md read. length=' + IntToStr(Length(ClaudeMd)));
      var SlugPos := Pos('**Slug:**', ClaudeMd);
      LogDebug('[stdio] SlugPos=' + IntToStr(SlugPos));
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
          Log('[mxProxy] Slug from CLAUDE.md: ' + FProjectSlug);

          // Auto-start polling thread
          LogDebug('[stdio] About to call TMxAgentPollThread.Create');
          FAgentThread := TMxAgentPollThread.Create(
            FConfig.ServerUrl, FConfig.ApiKey,
            FProjectSlug, FConfig.InboxDir,
            FConfig.AgentPollInterval);
          LogDebug('[stdio] TMxAgentPollThread.Create OK, about to Start');
          FAgentThread.Start;
          Log('[mxProxy] Agent polling auto-started for ' + FProjectSlug);
        end
        else
          LogDebug('[stdio] AfterSlug empty after parse, no thread started');
      end;
    except
      on E: Exception do
        Log('[mxProxy] CLAUDE.md read failed: ' + E.ClassName + ': ' + E.Message);
    end;
  end
  else
    LogDebug('[stdio] Skip CLAUDE.md parse (AgentPolling off or CLAUDE.md missing)');
  LogDebug('[stdio] TMxStdioProxy.Create done');
end;

destructor TMxStdioProxy.Destroy;
begin
  LogDebug('[stdio] TMxStdioProxy.Destroy entry');
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
  GProxyInstance := nil;
  if FAgentThread <> nil then
  begin
    LogDebug('[stdio] Shutting down poll thread');
    FAgentThread.RequestShutdown;
    FAgentThread.WaitFor;
    FAgentThread.Free;
    LogDebug('[stdio] Poll thread freed');
  end;
  FLock.Free;
  inherited;
  LogDebug('[stdio] TMxStdioProxy.Destroy done');
end;

procedure TMxStdioProxy.WriteOutput(const ALine: string);
var
  SafeLine: string;
  Bytes: TBytes;
  BytesWritten: DWORD;
  H: THandle;
begin
  // MCP stdio transport requires ONE JSON-RPC message per line.
  // If the server ever returns pretty-printed JSON with embedded LF/CR,
  // CC will see a truncated object and throw "Unexpected EOF". Collapse
  // all CR/LF into single spaces so exactly one terminator is written.
  SafeLine := StringReplace(ALine, #13#10, ' ', [rfReplaceAll]);
  SafeLine := StringReplace(SafeLine, #10, ' ', [rfReplaceAll]);
  SafeLine := StringReplace(SafeLine, #13, ' ', [rfReplaceAll]);

  FLock.Enter;
  try
    // Bypass Delphi's text-file RTL entirely for stdout. Delphi's WriteLn
    // on a redirected Output can ignore the requested CodePage and may
    // emit CRLF which some parsers accept and some don't. Win32 WriteFile
    // on the raw handle gives exact bytes with exact LF terminator.
    H := GetStdHandle(STD_OUTPUT_HANDLE);
    Bytes := TEncoding.UTF8.GetBytes(SafeLine + #10);
    if Length(Bytes) > 0 then
    begin
      if not WriteFile(H, Bytes[0], Length(Bytes), BytesWritten, nil) then
        Log('[run] WriteFile(stdout) FAILED err=' + IntToStr(GetLastError))
      else
        LogDebug('[run] WriteFile(stdout) ok len=' + IntToStr(Length(Bytes)));
    end;
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
  Log('[mxProxy] Agent polling started for ' +
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
    begin
      // Skip empty responses. Per MCP spec, notifications (requests without
      // an "id" field) must NOT produce any response on stdout. The mxLore
      // server correctly returns HTTP 202 with empty body for notifications;
      // forwarding that as an empty line would corrupt CC's JSON-RPC framing
      // (it reads the blank line as "Unexpected EOF" and drops the transport).
      if Trim(Responses[I]) = '' then
      begin
        LogDebug('[run] Skipping empty response (notification ACK, no stdout write)');
        Continue;
      end;
      WriteOutput(Responses[I]);
    end;
  finally
    HttpClient.Free;
  end;
end;

// Win32-based line reader for stdin. Delphi's Text-file RTL is unreliable on
// piped stdin (returns empty strings in a hot-loop after a certain internal
// state is reached). ReadFile on a blocking pipe handle blocks correctly and
// only returns 0 bytes when the peer actually closes the pipe.
function ReadStdinLine(AHandle: THandle; out ALine: string): Boolean;
var
  Chunk: array[0..4095] of Byte;
  LineBytes: TBytes;
  LineLen: Integer;
  I: Integer;
  BytesRead: DWORD;

  // Small per-call static scratch: we don't need leftover buffering across
  // calls because Claude Code sends one JSON-RPC line then waits for the
  // response; each line fits comfortably in 4 KB in practice.

  procedure AppendByte(B: Byte);
  begin
    if LineLen >= Length(LineBytes) then
      SetLength(LineBytes, Length(LineBytes) * 2);
    LineBytes[LineLen] := B;
    Inc(LineLen);
  end;

begin
  SetLength(LineBytes, 4096);
  LineLen := 0;
  ALine := '';
  while True do
  begin
    if not ReadFile(AHandle, Chunk[0], SizeOf(Chunk), BytesRead, nil) then
    begin
      Log('[run] ReadFile FAILED: err=' + IntToStr(GetLastError));
      Exit(False);
    end;
    if BytesRead = 0 then
    begin
      // True EOF — peer closed the pipe
      Log('[run] ReadFile returned 0 bytes (stdin closed cleanly)');
      Exit(False);
    end;
    for I := 0 to Integer(BytesRead) - 1 do
    begin
      case Chunk[I] of
        10: // LF — end of line
          begin
            SetLength(LineBytes, LineLen);
            ALine := TEncoding.UTF8.GetString(LineBytes);
            Exit(True);
          end;
        13: ; // CR — skip (LF will follow in CRLF)
      else
        AppendByte(Chunk[I]);
      end;
    end;
  end;
end;

procedure TMxStdioProxy.Run;
var
  Line: string;
  Iter: Integer;
  StdinH: THandle;
begin
  Log('[run] Enter Run loop (Win32 ReadFile mode)');
  StdinH := GetStdHandle(STD_INPUT_HANDLE);
  LogDebug('[run] stdin handle=' + IntToStr(StdinH));
  Iter := 0;
  while not FShutdownRequested do
  begin
    Inc(Iter);
    LogDebug('[run] Iter=' + IntToStr(Iter) + ' ReadFile...');
    if not ReadStdinLine(StdinH, Line) then
    begin
      Log('[run] ReadStdinLine returned False — exiting Run loop');
      Break;
    end;
    LogDebug('[run] Iter=' + IntToStr(Iter) + ' line OK, len=' + IntToStr(Length(Line)));

    if Line = '' then
    begin
      // Genuine blank line between JSON-RPC messages — skip, don't forward
      Continue;
    end;

    try
      HandleLine(Line);
      LogDebug('[run] Iter=' + IntToStr(Iter) + ' HandleLine done');
    except
      on E: Exception do
      begin
        Log('[run] EXCEPTION in HandleLine: ' + E.ClassName + ': ' + E.Message);
        Break;
      end;
    end;
  end;
  Log('[run] Exit Run loop (FShutdownRequested=' + BoolToStr(FShutdownRequested, True) + ')');
end;

end.
