unit mx.Proxy.Core;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.SyncObjs, System.IOUtils, System.Net.HttpClient, System.Net.URLClient,
  Winapi.Windows,
  mx.Proxy.Log, mx.Proxy.Config, mx.Proxy.Http, mx.Proxy.Poll;

type
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

// Extract the project slug from a CLAUDE.md body.
//
// The marker must be ANCHORED to the start of a line. A plain substring scan
// over the whole file also matches the marker inside prose or a code span: a
// CLAUDE.md carrying the note "Kein `**Slug:**` hier" yielded the slug "hier,"
// and the proxy then polled an agent inbox for a project that does not exist —
// silently, for the whole process lifetime, because the slug is latched once.
// Observed live on the macOS build host 2026-08-26 (BR#14128); the Go port had
// the identical defect and was fixed in r3971.
//
// A leading list bullet MUST be tolerated. The canonical CLAUDE.md template
// writes `- **Slug:** <slug>`, and 4 of the 5 real project files on the author
// machine use that form. Anchoring on the bare marker alone therefore trades a
// wrong slug for no slug at all — the same silent failure one step further
// along. A leading `>` is deliberately NOT stripped: a blockquote is the prose
// case this fix exists to reject.
//
// A bare marker line carrying no value does not abort the scan; it keeps
// looking, so a template placeholder cannot mask the real entry below it.
function ParseSlugFromClaudeMd(const AContent: string): string;
const
  Marker = '**Slug:**';
var
  Line, Rest: string;
begin
  Result := '';
  for Line in AContent.Split([#10]) do
  begin
    Rest := Trim(Line);

    // optional markdown list bullet ("- ", "* ", "+ ")
    if (Length(Rest) >= 2) and CharInSet(Rest[1], ['-', '*', '+']) and
       CharInSet(Rest[2], [' ', #9]) then
      Rest := Trim(Copy(Rest, 3, MaxInt));

    if not Rest.StartsWith(Marker) then
      Continue;

    Rest := Trim(Copy(Rest, Length(Marker) + 1, MaxInt));
    Rest := StringReplace(Rest, '`', '', [rfReplaceAll]);
    Rest := Trim(Rest);

    // first whitespace-delimited token
    for var I := 1 to Length(Rest) do
      if CharInSet(Rest[I], [' ', #9, #13]) then
      begin
        Rest := Copy(Rest, 1, I - 1);
        Break;
      end;

    if Rest <> '' then
      Exit(Rest);
  end;
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
      var AfterSlug := ParseSlugFromClaudeMd(ClaudeMd);
      LogDebug('[stdio] Parsed slug=' + AfterSlug);
      if AfterSlug <> '' then
      begin
        FProjectSlug := AfterSlug;
        Log('[mxProxy] Slug from CLAUDE.md: ' + FProjectSlug);

        // Auto-start polling thread
        LogDebug('[stdio] About to call TMxAgentPollThread.Create');
        FAgentThread := TMxAgentPollThread.Create(
          FConfig.ServerUrl, FConfig.ApiKey,
          FProjectSlug, FConfig.AgentPollInterval);
        LogDebug('[stdio] TMxAgentPollThread.Create OK, about to Start');
        FAgentThread.Start;
        Log('[mxProxy] Agent polling auto-started for ' + FProjectSlug);
      end
      else
        // ⚡ Log, NOT LogDebug: LogDebug returns immediately unless the level is
        // llDebug, and llInfo is the default — so this branch was silent in
        // normal operation while the success path above logs unconditionally.
        // Success loud, failure quiet is the worst pairing for diagnosis, and it
        // is why the original prose-match defect sat undetected for six weeks.
        Log('[mxProxy] No usable **Slug:** line in CLAUDE.md — agent polling disabled');
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
    FProjectSlug, FConfig.AgentPollInterval);
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
