unit mx.MCP.Server;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math,
  Sparkle.HttpSys.Server,
  Sparkle.HttpServer.Module,
  Sparkle.HttpServer.Context,
  Sparkle.Middleware.Cors,
  Data.DB, FireDAC.Comp.Client,
  mx.Types, mx.Config, mx.Log, mx.Data.Pool, mx.Auth, mx.Errors,
  mx.MCP.Schema, mx.MCP.Protocol, mx.Logic.AccessControl,
  mx.Logic.AgentMessaging;

type
  TMxMcpApiModule = class(THttpServerModule)
  private
    FPool: TMxConnectionPool;
    FAuth: TMxAuthManager;
    FLogger: IMxLogger;
    FProtocol: TMxMcpProtocol;
    FAllowUrlApiKey: Boolean;
    procedure HandleAgentInboxGet(const C: THttpServerContext;
      const AProject: string);
    procedure HandleAgentAckGet(const C: THttpServerContext;
      const AIds: string);
  protected
    procedure ProcessRequest(const C: THttpServerContext); override;
  public
    constructor Create(const ABaseUri: string; APool: TMxConnectionPool;
      AAuth: TMxAuthManager; ARegistry: TMxMcpRegistry;
      ALogger: IMxLogger; AAllowUrlApiKey: Boolean); reintroduce;
    destructor Destroy; override;
  end;

  TMxMcpServer = class
  private
    FServer: THttpSysServer;
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
    FPort: Integer;
    FBindAddress: string;
  public
    constructor Create(APool: TMxConnectionPool; AAuth: TMxAuthManager;
      ARegistry: TMxMcpRegistry; AConfig: TMxConfig; ALogger: IMxLogger);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

{ TMxMcpApiModule }

constructor TMxMcpApiModule.Create(const ABaseUri: string;
  APool: TMxConnectionPool; AAuth: TMxAuthManager;
  ARegistry: TMxMcpRegistry; ALogger: IMxLogger; AAllowUrlApiKey: Boolean);
begin
  inherited Create(ABaseUri);
  FPool := APool;
  FAuth := AAuth;
  FLogger := ALogger;
  FAllowUrlApiKey := AAllowUrlApiKey;
  FProtocol := TMxMcpProtocol.Create(ARegistry, APool, ALogger);
end;

destructor TMxMcpApiModule.Destroy;
begin
  FreeAndNil(FProtocol);
  inherited;
end;

function ExtractQueryApiKey(const AQuery: string): string;
var
  KeyIdx, AmpIdx: Integer;
begin
  Result := '';
  KeyIdx := Pos('api_key=', LowerCase(AQuery));
  if KeyIdx > 0 then
  begin
    Result := Copy(AQuery, KeyIdx + 8, Length(AQuery));
    AmpIdx := Pos('&', Result);
    if AmpIdx > 0 then
      Result := Copy(Result, 1, AmpIdx - 1);
  end;
end;

// FR#2936/Plan#3266 M3.9+M3.10 — RFC7807 auth-failure responder with
// OAuth2-conformant WWW-Authenticate header on 401. Centralises the
// pattern so HandleMcpRequest (POST /mcp) and HandleAgentInboxGet
// (GET /mcp?agent_inbox=...) emit identical shapes. Keeps the 401 vs
// 403 semantics per RFC 6750: 401 = no/malformed credentials, 403 =
// credentials present but invalid/expired/revoked.
//
// Session 267 mxDesignChecker WARN#1 split: AReason is the Spec §I9
// domain-code (AR_* from mx.Types, drives `type` URI + `mxlore.reason`).
// The OAuth2 RFC6750 §3.1 challenge-code is DERIVED from AReason via
// MapReasonToOAuth2Challenge — clients get a spec-compliant body AND
// a spec-compliant Bearer challenge without the caller conflating them.
function MapReasonToOAuth2Challenge(const AReason: string): string;
begin
  // RFC 6750 §3.1 registers exactly three codes. Map domain-reasons into
  // this narrow set; unknown reasons omit the challenge-code entirely
  // (realm-only challenge — fail-closed).
  if (AReason = AR_KEY_INVALID)
     or (AReason = AR_KEY_EXPIRED)
     or (AReason = AR_KEY_REVOKED)
     or (AReason = AR_KEY_EXPIRED_GRACE) then
    Result := 'invalid_token'
  else if (AReason = AR_ROLE_INSUFFICIENT)
          or (AReason = AR_PROJECT_NOT_ASSIGNED)
          or (AReason = AR_WRITE_SCOPE_VIOLATION)
          or (AReason = AR_TOOL_NOT_WHITELISTED) then
    Result := 'insufficient_scope'
  else
    Result := '';  // realm-only challenge (no `error=` field)
end;

procedure SendAuthProblem(const C: THttpServerContext; AStatus: Integer;
  const AReason, ATitle, ADetail, ASuggestedAction: string);
var
  Body: TJSONObject;
  Bytes: TBytes;
  Challenge, ChallengeCode: string;
begin
  Body := MxRfc7807Response(AReason, ATitle, ADetail, AStatus,
    ASuggestedAction, '' {decision_basis reserved per AC-27});
  try
    Bytes := TEncoding.UTF8.GetBytes(Body.ToJSON);
  finally
    Body.Free;
  end;
  C.Response.StatusCode := AStatus;
  C.Response.Headers.SetValue('Content-Type', 'application/problem+json');
  if AStatus = 401 then
  begin
    // OAuth2 Bearer challenge (RFC 6750 §3.1). ChallengeCode is derived
    // from AReason — never from a caller-supplied string — so unknown
    // reasons produce a realm-only challenge (fail-closed).
    ChallengeCode := MapReasonToOAuth2Challenge(AReason);
    Challenge := 'Bearer realm="mxLore"';
    if ChallengeCode <> '' then
      Challenge := Challenge + ', error="' + ChallengeCode + '"';
    C.Response.Headers.SetValue('WWW-Authenticate', Challenge);
  end;
  C.Response.Close(Bytes);
end;

// FR#3835 — emit RFC7807 problem+json body on 5xx error paths so proxy + admin-
// UI consumers can distinguish causes (auth_state_invalid, server_error, ...)
// programmatically instead of seeing bare HTTP-500 with empty body. Mirrors
// SendAuthProblem shape without the WWW-Authenticate Bearer challenge (5xx
// responses do not advertise auth schemes per RFC 6750).
procedure SendInternalProblem(const C: THttpServerContext;
  const AReason, ATitle, ADetail: string);
var
  Body: TJSONObject;
  Bytes: TBytes;
begin
  Body := MxRfc7807Response(AReason, ATitle, ADetail, 500,
    '' {suggested_action}, '' {decision_basis});
  try
    Bytes := TEncoding.UTF8.GetBytes(Body.ToJSON);
  finally
    Body.Free;
  end;
  C.Response.StatusCode := 500;
  C.Response.Headers.SetValue('Content-Type', 'application/problem+json');
  C.Response.Close(Bytes);
end;

// FR#2936/Plan#3266 M3.4b — set X-Key-Expires-In header when the authenticated
// key has a finite expiry. Value = integer seconds remaining (analogous to
// HTTP Retry-After). Skipped when ExpiresAt=0 (unlimited key).
//
// FR#3517-#1 — during the 24h grace-period, emit X-Key-Grace-Expires-In with
// seconds until end-of-grace instead (the primary header would be negative
// and misleading). Clients that honour either header know to rotate urgently.
procedure SetKeyExpiryHeader(const C: THttpServerContext;
  const AAuth: TMxAuthResult);
var
  Secs, GraceSecs: Int64;
begin
  if AAuth.ExpiresAt <= 0 then
    Exit;
  // Trunc (not Round) so clients get a conservative "at most N seconds left"
  // reading — never one second past actual expiry due to banker's rounding.
  Secs := Trunc((AAuth.ExpiresAt - Now) * 86400);
  if Secs > 0 then
  begin
    C.Response.Headers.SetValue('X-Key-Expires-In', IntToStr(Secs));
    Exit;
  end;
  // Grace-period branch: ExpiresAt < Now, key is valid read-only for 24h
  // past expiry (see mx.Auth.ValidateKey M3.4 grace-downgrade). Seconds until
  // end-of-grace = (ExpiresAt + 24h - Now).
  if AAuth.AuthReason = AR_KEY_EXPIRED_GRACE then
  begin
    GraceSecs := Trunc((AAuth.ExpiresAt + 1.0 - Now) * 86400);
    // >= 0: auth layer admitted the request as grace, emit header even at
    // the exact 0-second boundary so the client knows "0s left" vs absent.
    if GraceSecs >= 0 then
      C.Response.Headers.SetValue('X-Key-Grace-Expires-In', IntToStr(GraceSecs));
  end;
end;

procedure TMxMcpApiModule.ProcessRequest(const C: THttpServerContext);
var
  AuthHeader, Body, ResponseJson: string;
  AuthResult: TMxAuthResult;
  Bytes: TBytes;
  Request: TMxJsonRpcRequest;
  OwnedJson: TJSONObject;
  ResponseBytes: TBytes;
begin
  try
    // GET /mcp?agent_inbox=<project> — lightweight polling for proxy
    if C.Request.MethodType = THttpMethod.Get then
    begin
      var QS := C.Request.Uri.Query;
      var InboxIdx := Pos('agent_inbox=', LowerCase(QS));
      if InboxIdx > 0 then
      begin
        var InboxProject := Copy(QS, InboxIdx + 12, Length(QS));
        var AmpIdx := Pos('&', InboxProject);
        if AmpIdx > 0 then
          InboxProject := Copy(InboxProject, 1, AmpIdx - 1);
        if InboxProject <> '' then
        begin
          HandleAgentInboxGet(C, InboxProject);
          Exit;
        end;
      end;
      // GET /mcp?agent_ack=<id,id,...> — proxy confirms delivery
      var AckIdx := Pos('agent_ack=', LowerCase(QS));
      if AckIdx > 0 then
      begin
        var AckIds := Copy(QS, AckIdx + 10, Length(QS));
        var AmpIdx2 := Pos('&', AckIds);
        if AmpIdx2 > 0 then
          AckIds := Copy(AckIds, 1, AmpIdx2 - 1);
        if AckIds <> '' then
        begin
          HandleAgentAckGet(C, AckIds);
          Exit;
        end;
      end;

      C.Response.StatusCode := 405;
      C.Response.Close;
      Exit;
    end;

    // Only POST allowed for MCP
    if C.Request.MethodType <> THttpMethod.Post then
    begin
      C.Response.StatusCode := 405;
      C.Response.Close;
      Exit;
    end;

    // Auth: Bearer token or ?api_key= query parameter
    AuthHeader := '';
    C.Request.Headers.GetIfExists('Authorization', AuthHeader);
    if (AuthHeader = '') and FAllowUrlApiKey then
      AuthHeader := ExtractQueryApiKey(C.Request.Uri.Query);
    if AuthHeader = '' then
    begin
      SendAuthProblem(C, 401, AR_KEY_INVALID,
        'Missing credentials',
        'Bearer token or api_key parameter required.',
        'request_access');
      FLogger.Log(mlWarning, 'MCP auth failed: no Authorization header');
      Exit;
    end;

    AuthResult := FAuth.ValidateKey(AuthHeader);
    if not AuthResult.Valid then
    begin
      // M3.11b forward-proof: pass AuthResult.AuthReason so future-
      // distinguished codes (key_revoked / key_expired) surface without
      // a second edit-pass. Today ValidateKey collapses all fails to
      // AR_KEY_INVALID — behaviour identical, just future-ready.
      SendAuthProblem(C, 403, AuthResult.AuthReason,
        'Invalid or expired API key',
        'The provided key is unknown, revoked, or expired beyond the 24h grace window.',
        'rotate');
      FLogger.Log(mlWarning, 'MCP auth failed: invalid key');
      Exit;
    end;

    // FR#2936/Plan#3266 M3.6b — capture request-context for forensic trio.
    // Consumed by mx_key_revoke (self-revoke) to populate revoke_ip +
    // revoke_user_agent. Same column sizes as admin path (VARCHAR 45/255).
    C.Request.Headers.GetIfExists('X-Forwarded-For', AuthResult.RemoteIp);
    if AuthResult.RemoteIp = '' then
      AuthResult.RemoteIp := C.Request.RemoteIp;
    if Length(AuthResult.RemoteIp) > 45 then
      AuthResult.RemoteIp := Copy(AuthResult.RemoteIp, 1, 45);
    C.Request.Headers.GetIfExists('User-Agent', AuthResult.UserAgent);
    if Length(AuthResult.UserAgent) > 255 then
      AuthResult.UserAgent := Copy(AuthResult.UserAgent, 1, 255);

    // Store auth for tool handlers (threadvar)
    MxSetThreadAuth(AuthResult);

    // M3.4b — publish remaining key lifetime to the client (secs)
    SetKeyExpiryHeader(C, AuthResult);

    // Read request body
    Body := TEncoding.UTF8.GetString(C.Request.Content);

    // Bug#3345 diagnostic (Session 267) — log raw request-body metrics to
    // distinguish transport-loss vs parse-loss. BytesLen = on-wire, BodyLen =
    // UTF-8 decoded chars. First 200 chars + last 200 chars help spot
    // truncation-points in large bodies. REMOVE after root-cause found.
    FLogger.Log(mlInfo, Format(
      '[Bug3345] body: bytes=%d chars=%d head=%s | tail=%s',
      [Length(C.Request.Content),
       Length(Body),
       Copy(Body, 1, 200).Replace(#10, '\n').Replace(#13, '\r'),
       Copy(Body, Max(1, Length(Body) - 199), 200).Replace(#10, '\n').Replace(#13, '\r')]));

    if Body = '' then
    begin
      C.Response.StatusCode := 400;
      ResponseBytes := TEncoding.UTF8.GetBytes('{"error":"Empty request body"}');
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
      Exit;
    end;

    // Parse and process JSON-RPC request
    OwnedJson := nil;
    try
      Request := TMxMcpProtocol.ParseRequest(Body, OwnedJson);
      ResponseJson := FProtocol.ProcessRequest(Request);
    finally
      OwnedJson.Free;
    end;

    // Notifications get no response
    if ResponseJson = '' then
    begin
      C.Response.StatusCode := 202;
      C.Response.Close;
      Exit;
    end;

    // Send JSON-RPC response
    C.Response.StatusCode := 200;
    C.Response.Headers.SetValue('Content-Type', 'application/json');
    ResponseBytes := TEncoding.UTF8.GetBytes(ResponseJson);
    C.Response.Close(ResponseBytes);

  except
    on E: Exception do
    begin
      // Scope-out from FR#3835: this 500 path emits a JSON-RPC 2.0 error
      // envelope (application/json), NOT RFC7807 problem+json. MCP transport
      // is JSON-RPC at the protocol layer, so clients expect the RPC error
      // shape here. Do NOT replace with SendInternalProblem in future sweeps.
      FLogger.Log(mlError, 'MCP request error: ' + E.Message);
      C.Response.StatusCode := 500;
      ResponseJson := TMxMcpProtocol.FormatError(nil, -32700, 'Parse error');
      ResponseBytes := TEncoding.UTF8.GetBytes(ResponseJson);
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
    end;
  end;
end;

// GET ?agent_inbox=<project> — lightweight polling for proxy background thread
procedure TMxMcpApiModule.HandleAgentInboxGet(const C: THttpServerContext;
  const AProject: string);
var
  AuthHeader: string;
  AuthResult: TMxAuthResult;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ProjectId, I: Integer;
  Opts: TAgentInboxOptions;
  Rows: TArray<TAgentInboxRow>;
  Arr: TJSONArray;
  Row, Resp: TJSONObject;
  ResponseBytes: TBytes;
begin
  // Auth: Bearer token or ?api_key= query parameter
  AuthHeader := '';
  C.Request.Headers.GetIfExists('Authorization', AuthHeader);
  if (AuthHeader = '') and FAllowUrlApiKey then
    AuthHeader := ExtractQueryApiKey(C.Request.Uri.Query);
  if AuthHeader = '' then
  begin
    SendAuthProblem(C, 401, AR_KEY_INVALID,
      'Missing credentials',
      'Bearer token or api_key parameter required.',
      'request_access');
    Exit;
  end;

  AuthResult := FAuth.ValidateKey(AuthHeader);
  if not AuthResult.Valid then
  begin
    SendAuthProblem(C, 403, AuthResult.AuthReason,
      'Invalid or expired API key',
      'The provided key is unknown, revoked, or expired beyond the 24h grace window.',
      'rotate');
    Exit;
  end;

  // M3.4b — publish remaining key lifetime (before Ctx acquisition so the
  // header is set even if the handler exits early on an error).
  SetKeyExpiryHeader(C, AuthResult);

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);
    if Ctx = nil then
    begin
      FLogger.Log(mlError,
        '[agent_inbox_get] AcquireAuthContext returned nil');
      SendInternalProblem(C, AR_AUTH_STATE_INVALID,
        'Context acquisition failed',
        'Failed to acquire an authenticated DB context. Retry; if it persists, rotate the API key and contact the project owner.');
      Exit;
    end;

    // Resolve project
    Qry := Ctx.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
    try
      Qry.ParamByName('slug').AsWideString :=AProject;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        C.Response.StatusCode := 404;
        C.Response.Close;
        Exit;
      end;
      ProjectId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;

    // ACL: check read access
    if not Ctx.AccessControl.CheckProject(ProjectId, alReadOnly) then
    begin
      SendAuthProblem(C, 403, AR_PROJECT_NOT_ASSIGNED,
        'Insufficient project access',
        'Read access to the target project is required to list the agent inbox.',
        'request_access');
      Exit;
    end;

    // FR#3836: delegate fetch to Logic-layer. REST path does not filter by
    // target_developer (proxy poller has no dev identity) and does not apply
    // the self-echo guard (proxy is not an agent). Archive-expired runs
    // inside FetchAgentInbox — fixes the pre-FR#3836 asymmetry where the
    // REST path left expired messages as 'pending' forever (CC2050 review).
    Opts.ProjectId := ProjectId;
    Opts.MyDeveloperId := 0;
    Opts.LimitCount := 20;
    Opts.FilterTargetDeveloper := False;
    Opts.FilterSelfEcho := False;
    Rows := FetchAgentInbox(Ctx, Opts);

    // Compact REST response shape: {id, type, payload, from, priority, ref}
    Arr := TJSONArray.Create;
    try
      for I := Low(Rows) to High(Rows) do
      begin
        Row := TJSONObject.Create;
        try
          Row.AddPair('id', TJSONNumber.Create(Rows[I].Id));
          Row.AddPair('type', Rows[I].MessageType);
          Row.AddPair('payload', Rows[I].Payload);
          Row.AddPair('from', Rows[I].SenderProject);
          Row.AddPair('priority', Rows[I].Priority);
          if Rows[I].HasRefDocId then
            Row.AddPair('ref', TJSONNumber.Create(Rows[I].RefDocId));
          Arr.Add(Row);
          Row := nil; // ownership transferred to Arr
        except
          Row.Free;
          raise;
        end;
      end;
    except
      Arr.Free;
      raise;
    end;

    // Note: messages stay 'pending' until proxy confirms delivery via
    // GET ?agent_ack=<id,id,...> — prevents data loss if proxy crashes

    Resp := TJSONObject.Create;
    try
      Resp.AddPair('count', TJSONNumber.Create(Arr.Count));
      Resp.AddPair('messages', Arr);
      Arr := nil; // ownership transferred to Resp
      C.Response.StatusCode := 200;
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      ResponseBytes := TEncoding.UTF8.GetBytes(Resp.ToJSON);
      C.Response.Close(ResponseBytes);
    finally
      Arr.Free; // no-op if nil (ownership transferred)
      Resp.Free;
    end;
  except
    on E: Exception do
    begin
      FLogger.Log(mlError,
        '[agent_inbox_get] ' + E.ClassName + ': ' + E.Message);
      try
        SendInternalProblem(C, AR_SERVER_ERROR,
          'Internal server error',
          'An unexpected error occurred while fetching the agent inbox. Retry; the server log carries the exception class and message for diagnosis.');
      except
        on E2: Exception do
          FLogger.Log(mlWarning,
            '[agent_inbox_get] response close after error failed: ' +
            E2.ClassName + ': ' + E2.Message);
      end;
    end;
  end;
end;

// GET ?agent_ack=<id,id,...> — proxy confirms delivery, mark as read
procedure TMxMcpApiModule.HandleAgentAckGet(const C: THttpServerContext;
  const AIds: string);
var
  AuthHeader: string;
  AuthResult: TMxAuthResult;
  Ctx: IMxDbContext;
  Ids: TArray<Integer>;
  AckOpts: TAgentAckOptions;
  IdCount, IdVal: Integer;
  ResponseBytes: TBytes;
begin
  AuthHeader := '';
  C.Request.Headers.GetIfExists('Authorization', AuthHeader);
  if (AuthHeader = '') and FAllowUrlApiKey then
    AuthHeader := ExtractQueryApiKey(C.Request.Uri.Query);
  if AuthHeader = '' then
  begin
    SendAuthProblem(C, 401, AR_KEY_INVALID,
      'Missing credentials',
      'Bearer token or api_key parameter required.',
      'request_access');
    Exit;
  end;

  AuthResult := FAuth.ValidateKey(AuthHeader);
  if not AuthResult.Valid then
  begin
    SendAuthProblem(C, 403, AuthResult.AuthReason,
      'Invalid or expired API key',
      'The provided key is unknown, revoked, or expired beyond the 24h grace window.',
      'rotate');
    Exit;
  end;

  // M3.4b — publish remaining key lifetime
  SetKeyExpiryHeader(C, AuthResult);

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);
    if Ctx = nil then
    begin
      FLogger.Log(mlError,
        '[agent_ack_get] AcquireAuthContext returned nil');
      SendInternalProblem(C, AR_AUTH_STATE_INVALID,
        'Context acquisition failed',
        'Failed to acquire an authenticated DB context. Retry; if it persists, rotate the API key and contact the project owner.');
      Exit;
    end;

    // Validate: only allow positive integers (prevent SQL injection via
    // explicit parse + type-check before the Logic-layer handles the list).
    var Parts := AIds.Split([',']);
    SetLength(Ids, Length(Parts));
    IdCount := 0;
    for var Part in Parts do
    begin
      IdVal := StrToIntDef(Trim(Part), -1);
      if IdVal > 0 then
      begin
        Ids[IdCount] := IdVal;
        Inc(IdCount);
      end;
    end;
    SetLength(Ids, IdCount);
    if IdCount = 0 then
    begin
      C.Response.StatusCode := 400;
      C.Response.Close;
      Exit;
    end;

    // FR#3836: delegate to Logic-layer. REST path does NOT enforce project-
    // ownership today (proxy polls one project per session; ProjectId=0 skips
    // the target_project_id filter). Preserves pre-FR#3836 semantics exactly.
    AckOpts.ProjectId := 0;
    AckOpts.NewStatus := 'read';
    AckAgentMessages(Ctx, Ids, AckOpts);

    C.Response.StatusCode := 200;
    ResponseBytes := TEncoding.UTF8.GetBytes('{"ok":true}');
    C.Response.Headers.SetValue('Content-Type', 'application/json');
    C.Response.Close(ResponseBytes);
  except
    on E: Exception do
    begin
      FLogger.Log(mlError,
        '[agent_ack_get] ' + E.ClassName + ': ' + E.Message);
      try
        SendInternalProblem(C, AR_SERVER_ERROR,
          'Internal server error',
          'An unexpected error occurred while acknowledging agent messages. Retry; the server log carries the exception class and message for diagnosis.');
      except
        on E2: Exception do
          FLogger.Log(mlWarning,
            '[agent_ack_get] response close after error failed: ' +
            E2.ClassName + ': ' + E2.Message);
      end;
    end;
  end;
end;

{ TMxMcpServer }

constructor TMxMcpServer.Create(APool: TMxConnectionPool;
  AAuth: TMxAuthManager; ARegistry: TMxMcpRegistry;
  AConfig: TMxConfig; ALogger: IMxLogger);
var
  BaseUrl: string;
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
  FPort := AConfig.ServerPort;
  FBindAddress := AConfig.BindAddress;

  if (FBindAddress = '') or (FBindAddress = '0.0.0.0') then
    BaseUrl := Format('http://+:%d/', [FPort])
  else
    BaseUrl := Format('http://%s:%d/', [FBindAddress, FPort]);

  FServer := THttpSysServer.Create;
  var Module := TMxMcpApiModule.Create(BaseUrl, APool, AAuth, ARegistry, ALogger, AConfig.AllowUrlApiKey);
  Module.AddMiddleware(TCorsMiddleware.Create('*', 'POST'));
  FServer.AddModule(Module);

  FLogger.Log(mlDebug, 'MCP server configured on port ' + IntToStr(FPort));
end;

destructor TMxMcpServer.Destroy;
begin
  Stop;
  FreeAndNil(FServer);
  inherited;
end;

procedure TMxMcpServer.Start;
begin
  FServer.Start;
  FLogger.Log(mlInfo, 'MCP server started on port ' + IntToStr(FPort));
end;

procedure TMxMcpServer.Stop;
begin
  if Assigned(FServer) then
  begin
    FServer.Stop;
    FLogger.Log(mlInfo, 'MCP server stopped');
  end;
end;

end.
