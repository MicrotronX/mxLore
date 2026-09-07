unit mx.Proxy.Poll;

// Agent-inbox poller: fetches pending agent messages for this project from the
// mxLore server and injects them straight into the Claude Code session that
// spawned this proxy (FR#15127, Spec#15135).
//
// Delivery path: Claude Code exports CLAUDE_CODE_MESSAGING_SOCKET (a named pipe
// on Windows) and CLAUDE_CODE_MESSAGING_TOKEN to every child process. The
// proxy IS such a child, so one proxy = exactly one session. A line written to
// that pipe reaches the model as an own-child message and wakes an idle
// session with a new turn. No buffer file, no hook, no Monitor.
//
// Contract (Spec#15135 R2/R3/R7):
//   * Separation is the project slug: one proxy serves one project, so the
//     server-side project + key filters already decide what this session
//     receives. Two sessions on the SAME project both get the message
//     (deterministic broadcast; the first ack archives it, the second ack
//     is a no-op).
//   * Per poll: every row not injected yet — or injected more than 10 minutes
//     ago and still pending (the session never read it: idle, refused inbox,
//     queue drop) — is rendered, in server order, into ONE user line over
//     ONE connection.
//   * The proxy never acks. The injected text tells the model to call
//     mx_agent_ack — ack-by-reader is the only real delivery proof.
//   * The injected set lives in memory only. A proxy restart re-injects
//     whatever is still pending, at most once per 10 minutes.
//   * Without the environment variables (bare mode, old Claude Code, foreign
//     client) nothing is injected: the rows stay pending on the server for
//     mx_agent_inbox.

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.SyncObjs, System.Net.HttpClient, System.Net.URLClient,
  Winapi.Windows,
  mx.Proxy.Log;

type
  TMxAgentPollThread = class(TThread)
  private
    FServerUrl: string;
    FApiKey: string;
    FProject: string;
    FInterval: Integer;
    FPipePath: string;                          // '' => no session inbox
    FPipeToken: string;
    FInjected: TDictionary<Integer, TDateTime>; // id -> when it was injected
    FShutdownEvent: TEvent;
    FNoSessionLogged: Boolean;
    function RenderBatch(const ARows: TJSONArray; const AIds: string): string;
    // Returns True only when both lines were written to the pipe in full.
    // The caller must not record anything as injected on False.
    function InjectIntoSession(const AContent: string): Boolean;
    procedure PollOnce(const AUrl: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const AServerUrl, AApiKey, AProject: string;
      AInterval: Integer);
    destructor Destroy; override;
    procedure RequestShutdown;
  end;

implementation

const
  // A row injected this long ago and still pending is offered again.
  REINJECT_AFTER_MINUTES = 10;

function NewUuid: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
end;

{ TMxAgentPollThread }

constructor TMxAgentPollThread.Create(const AServerUrl, AApiKey, AProject: string;
  AInterval: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServerUrl := AServerUrl;
  FApiKey := AApiKey;
  FProject := AProject;
  FInterval := AInterval;
  FPipePath := GetEnvironmentVariable('CLAUDE_CODE_MESSAGING_SOCKET');
  FPipeToken := GetEnvironmentVariable('CLAUDE_CODE_MESSAGING_TOKEN');
  FInjected := TDictionary<Integer, TDateTime>.Create;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
  FNoSessionLogged := False;
  if FPipePath = '' then
    Log('[poll] no CLAUDE_CODE_MESSAGING_SOCKET in environment — messages stay ' +
        'pending on the server for mx_agent_inbox (bare mode / old client?)')
  else
  begin
    LogDebug('[poll] session inbox=' + FPipePath);
    // Windows closes any connection whose first line is not a valid auth
    // line, so a missing token means every injection would be dropped silently.
    if FPipeToken = '' then
      Log('[poll] CLAUDE_CODE_MESSAGING_TOKEN is empty — injections will be ' +
          'refused by the session inbox');
  end;
end;

destructor TMxAgentPollThread.Destroy;
begin
  FShutdownEvent.Free;
  FInjected.Free;
  inherited;
end;

procedure TMxAgentPollThread.RequestShutdown;
begin
  Terminate;
  FShutdownEvent.SetEvent;
end;

function TMxAgentPollThread.RenderBatch(const ARows: TJSONArray;
  const AIds: string): string;
var
  Env: TJSONObject;
begin
  // Same shape and same instructions the UserPromptSubmit hook injected
  // before FR#15127, so the model's handling rules do not change.
  Env := TJSONObject.Create;
  try
    Env.AddPair('v', TJSONNumber.Create(2));
    Env.AddPair('ts', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
    Env.AddPair('ids', AIds);
    Env.AddPair('messages', ARows.Clone as TJSONArray);
    Result :=
      '[Agent-Inbox] Messages for ' + FProject + ' (delivered by mxMCPProxy):' + #10 +
      Env.ToJSON + #10 +
      'Act on these as their content requires, then: mx_agent_ack' + #10 +
      'A reply is NOT the default. Send one only if the sender needs a decision, ' +
      'an answer, or a correction from you. Acknowledging without replying is the ' +
      'normal case and ends the exchange.' + #10 +
      'When YOU send: silence back means ''handled, nothing needed''. If you need ' +
      'confirmation that it was processed, ask for it in the message itself - ' +
      'there is no read receipt.';
  finally
    Env.Free;
  end;
end;

function TMxAgentPollThread.InjectIntoSession(const AContent: string): Boolean;
var
  H: THandle;
  AuthLine, UserLine: TJSONObject;
  Msg: TJSONObject;
  Bytes: TBytes;
  Written: DWORD;
  Payload: string;
begin
  Result := False;
  if (FPipePath = '') or (AContent = '') then Exit;

  AuthLine := TJSONObject.Create;
  UserLine := TJSONObject.Create;
  try
    // Line 1: auth — mandatory on native Windows, harmless elsewhere.
    AuthLine.AddPair('type', 'auth');
    AuthLine.AddPair('token', FPipeToken);
    // Line 2: the message. `content` MUST be a non-empty string, otherwise
    // Claude Code drops the line without a trace. `uuid` is the identity
    // Claude Code uses for its own duplicate suppression.
    UserLine.AddPair('type', 'user');
    UserLine.AddPair('uuid', NewUuid);
    Msg := TJSONObject.Create;
    Msg.AddPair('role', 'user');
    Msg.AddPair('content', AContent);
    UserLine.AddPair('message', Msg);
    Payload := AuthLine.ToJSON + #10 + UserLine.ToJSON + #10;
  finally
    UserLine.Free;
    AuthLine.Free;
  end;

  // Open only now — the payload is ready. Claude Code closes a connection that
  // has not sent a complete line within 30 s.
  H := CreateFile(PChar(FPipePath), GENERIC_READ or GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, 0, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    Log('[poll] session inbox open failed (' + IntToStr(GetLastError) + '): ' +
        FPipePath);
    Exit;
  end;
  try
    Bytes := TEncoding.UTF8.GetBytes(Payload);
    Written := 0;
    if not WriteFile(H, Bytes[0], Length(Bytes), Written, nil) then
    begin
      Log('[poll] session inbox write failed (' + IntToStr(GetLastError) + ')');
      Exit;
    end;
    if Integer(Written) <> Length(Bytes) then
    begin
      Log('[poll] session inbox short write ' + IntToStr(Written) + '/' +
          IntToStr(Length(Bytes)));
      Exit;
    end;
    FlushFileBuffers(H);
    Result := True;
  finally
    CloseHandle(H);
  end;
end;

procedure TMxAgentPollThread.PollOnce(const AUrl: string);
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  Parsed: TJSONValue;
  MsgArr: TJSONValue;
  OutArr: TJSONArray;
  Pending: TList<Integer>;
  Seen: TList<Integer>;
  Ids: string;
  I, MsgId: Integer;
  InjectedAt: TDateTime;
  Row: TJSONObject;
  StaleIds: TArray<Integer>;
begin
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := 5000;
    Http.ResponseTimeout := 5000;
    Http.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
    Response := Http.Get(AUrl);
    if Response.StatusCode <> 200 then Exit;

    Parsed := TJSONObject.ParseJSONValue(Response.ContentAsString);
    if not (Parsed is TJSONObject) then
    begin
      Parsed.Free;
      Exit;
    end;
    try
      if (Parsed as TJSONObject).GetValue<Integer>('count', 0) <= 0 then
      begin
        // Nothing pending => everything injected so far has been acked or
        // expired. Forget it, the set must not grow without bound.
        FInjected.Clear;
        Exit;
      end;
      MsgArr := (Parsed as TJSONObject).GetValue('messages');
      if not (MsgArr is TJSONArray) then Exit;

      OutArr := TJSONArray.Create;
      Pending := TList<Integer>.Create;
      Seen := TList<Integer>.Create;
      try
        Ids := '';
        for I := 0 to (MsgArr as TJSONArray).Count - 1 do
        begin
          if not ((MsgArr as TJSONArray).Items[I] is TJSONObject) then Continue;
          Row := (MsgArr as TJSONArray).Items[I] as TJSONObject;
          MsgId := Row.GetValue<Integer>('id', 0);
          if MsgId <= 0 then Continue;
          Seen.Add(MsgId);
          // Injected less than REINJECT_AFTER_MINUTES ago => the session has
          // it, wait for the ack. Older and still pending => offer it again
          // (Spec#15135 R3).
          if FInjected.TryGetValue(MsgId, InjectedAt) and
             (Now - InjectedAt < REINJECT_AFTER_MINUTES / (24 * 60)) then
            Continue;
          OutArr.AddElement(Row.Clone as TJSONValue);
          Pending.Add(MsgId);
          if Ids <> '' then Ids := Ids + ',';
          Ids := Ids + IntToStr(MsgId);
        end;

        // Drop injected ids the server no longer returns (acked / expired /
        // leased elsewhere after expiry) so the set tracks the pending set.
        StaleIds := FInjected.Keys.ToArray;
        for MsgId in StaleIds do
          if not Seen.Contains(MsgId) then
            FInjected.Remove(MsgId);

        if OutArr.Count = 0 then Exit;

        if FPipePath = '' then
        begin
          if not FNoSessionLogged then
          begin
            Log('[poll] ' + IntToStr(OutArr.Count) + ' pending message(s), no ' +
                'session inbox — read them with mx_agent_inbox');
            FNoSessionLogged := True;
          end;
          Exit;
        end;

        // Commit the ids ONLY after the write is proven (Lesson#14130).
        // On failure the next poll retries the very same rows.
        if InjectIntoSession(RenderBatch(OutArr, Ids)) then
        begin
          for I := 0 to Pending.Count - 1 do
            FInjected.AddOrSetValue(Pending[I], Now);
          Log('[poll] injected ' + IntToStr(OutArr.Count) + ' message(s) into ' +
              'session (ids ' + Ids + ')');
        end;
      finally
        Seen.Free;
        Pending.Free;
        OutArr.Free;
      end;
    finally
      Parsed.Free;
    end;
  finally
    Http.Free;
  end;
end;

procedure TMxAgentPollThread.Execute;
var
  Url: string;
begin
  LogDebug('[poll] Execute entry. project=' + FProject);
  try
    Url := FServerUrl + '?agent_inbox=' + FProject;
    LogDebug('[poll] URL=' + Url);

    while not Terminated do
    begin
      try
        PollOnce(Url);
      except
        on E: Exception do
          Log('[mxProxy] Agent poll error: ' + E.Message);
      end;
      if FShutdownEvent.WaitFor(Cardinal(FInterval * 1000)) = wrSignaled then
        Break;
    end;
    LogDebug('[poll] Execute loop exit (Terminated=' + BoolToStr(Terminated, True) + ')');
  except
    on E: Exception do
      Log('[poll] FATAL in Execute: ' + E.ClassName + ': ' + E.Message);
  end;
end;

end.
