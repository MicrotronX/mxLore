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
    // Returns True only when the buffer file is actually on disk under its
    // final name. The caller must not record anything as "rendered" on False.
    function WriteInboxFile(const AJson: string; const AIds: string): Boolean;
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

function TMxAgentPollThread.WriteInboxFile(const AJson: string;
  const AIds: string): Boolean;
var
  TmpPath, JsonPath: string;
  Retry: Integer;
begin
  Result := False;
  TmpPath := GetTmpFilePath;
  JsonPath := GetInboxFilePath;

  // Write to .tmp first (no BOM — bash scripts can't handle it).
  // Swallowing the I/O error here is deliberate: this routine reports failure
  // through its result, so the poll loop stays alive and retries next round.
  try
    var Bytes := TEncoding.UTF8.GetBytes(AJson);
    TFile.WriteAllBytes(TmpPath, Bytes);
  except
    on E: Exception do
    begin
      // Same best-effort cleanup as the rename-failure path below: a partially
      // written .tmp must not be left lying in the user-visible inbox dir just
      // because the failure happened one step earlier.
      try
        TFile.Delete(TmpPath);
      except
        // ignore
      end;
      Log('[mxProxy] Failed to write inbox tmp file: ' + E.Message);
      Exit(False);
    end;
  end;

  // Atomic rename .tmp -> .json (retry on sharing violation)
  for Retry := 1 to 3 do
  begin
    if MoveFileEx(PChar(TmpPath), PChar(JsonPath),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      FWrittenIds := AIds;
      Exit(True);
    end;
    if Retry < 3 then
      Sleep(50);
  end;

  // Rename failed after retries — clean up tmp (best effort; a stale .tmp is
  // harmless, the next round overwrites it)
  try
    TFile.Delete(TmpPath);
  except
    // ignore
  end;
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
                  // The buffer file is a MIRROR of the pending set, not a delta
                  // feed. Rendering only the FKnownIds-new rows was wrong,
                  // because WriteInboxFile REPLACES the file: a still-unconsumed
                  // buffer lost the rows already sitting in it. Observed live —
                  // an older message dropped out of the buffer, was therefore
                  // never acked, and reappeared only after CheckAndAck had
                  // cleared FKnownIds, i.e. it was delivered AFTER the newer
                  // message that retracted it. That is both the ordering defect
                  // and a delivery gap; the server side was never at fault (its
                  // query already sorts by created_at ASC).
                  //
                  // So: while an unconsumed buffer exists, re-render the FULL
                  // pending set in server order. Once the hook has consumed the
                  // file, fall back to new-rows-only — that is what keeps the
                  // accumulation-gap guard (FKnownIds) meaningful.
                  var HasUnconsumed := FileExists(GetInboxFilePath);
                  var NewCount := 0;
                  var OutArr := TJSONArray.Create;
                  // Staging area for the "already rendered" claim. It is only
                  // merged into FKnownIds once the write is proven — see the
                  // commit block below.
                  var PendingNew := TList<Integer>.Create;
                  NewIds := '';
                  try
                    for var I := 0 to (MsgArr as TJSONArray).Count - 1 do
                    begin
                      var MsgId := ((MsgArr as TJSONArray).Items[I] as TJSONObject)
                        .GetValue<Integer>('id', 0);
                      if MsgId <= 0 then Continue;

                      var IsNew := not FKnownIds.Contains(MsgId);
                      if IsNew then
                      begin
                        PendingNew.Add(MsgId);
                        Inc(NewCount);
                      end;

                      if IsNew or HasUnconsumed then
                      begin
                        OutArr.AddElement(
                          (MsgArr as TJSONArray).Items[I].Clone as TJSONValue);
                        if NewIds <> '' then NewIds := NewIds + ',';
                        NewIds := NewIds + IntToStr(MsgId);
                      end;
                    end;

                    // Write when something new arrived, OR when an unconsumed
                    // buffer on disk no longer matches what the pending set says
                    // it should hold (repairs a stale file across a Proxy
                    // restart, where FKnownIds is reloaded but FWrittenIds is not).
                    //
                    // ⚡ Compare the ROW COUNT, never the id string. The server
                    // orders by created_at, which is second-granular; messages
                    // tied on the same second can come back in a different order
                    // on each poll. A string compare would then differ every 5s
                    // and rewrite the buffer forever — and since the wakeup
                    // watcher keys on the file signature, that is a notification
                    // every 5 seconds. The count is order-insensitive and still
                    // sufficient: any set change that keeps the count equal also
                    // brings a new row in, which NewCount already catches.
                    // (The server-side query now adds `am.id` as a tie-break,
                    // but this proxy must not assume it has been rebuilt.)
                    var WrittenCount := 0;
                    if FWrittenIds <> '' then
                    begin
                      WrittenCount := 1;
                      for var Ch in FWrittenIds do
                        if Ch = ',' then Inc(WrittenCount);
                    end;

                    if (NewIds <> '') and
                       ((NewCount > 0) or
                        (HasUnconsumed and (OutArr.Count <> WrittenCount))) then
                    begin
                      var Written := False;
                      FileJson := TJSONObject.Create;
                      try
                        FileJson.AddPair('v', TJSONNumber.Create(1));
                        FileJson.AddPair('ts',
                          FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
                        FileJson.AddPair('ids', NewIds);
                        FileJson.AddPair('messages', OutArr.Clone as TJSONArray);
                        // FWrittenIds now covers EVERY row in the file, so
                        // CheckAndAck acks all of them instead of just the last
                        // delta — the other half of the ordering fix.
                        Written := WriteInboxFile(FileJson.ToJSON, NewIds);
                      finally
                        FileJson.Free;
                      end;

                      // ⚡ Record the IDs as "rendered" ONLY after the write is
                      // proven. Committing first was a closed trap: a failed
                      // write leaves no buffer and no FWrittenIds, so CheckAndAck
                      // exits at once and never acks — while FKnownIds already
                      // claims the row was handled. The next poll then computes
                      // IsNew=False and HasUnconsumed=False, so the row enters
                      // neither OutArr nor NewIds, NewIds stays empty and the
                      // write condition is never true again. SaveKnownIds had
                      // meanwhile persisted that dead state, so a restart did not
                      // heal it either: the message stayed pending server-side,
                      // undeliverable and unackable, forever. Reported for the Go
                      // twin from the macOS host 2026-08-26 (msg#2030, r3971) and
                      // confirmed identical here.
                      //
                      // Leaving FKnownIds untouched on failure is what makes the
                      // next poll retry the very same rows.
                      if Written then
                      begin
                        for var PendingId in PendingNew do
                          FKnownIds.Add(PendingId);
                        // Persist FKnownIds so a Proxy restart does not re-
                        // consider these IDs "new" and re-write the same rows.
                        if NewCount > 0 then
                          SaveKnownIds;
                      end;
                    end;
                  finally
                    PendingNew.Free;
                    OutArr.Free;
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
          FProjectSlug, FConfig.InboxDir,
          FConfig.AgentPollInterval);
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
