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
  mx.MCP.Schema, mx.MCP.Protocol, mx.Logic.AccessControl;

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
  ProjectId: Integer;
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

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);

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

    // Fetch pending messages (compact: only essential fields)
    Qry := Ctx.CreateQuery(
      'SELECT am.id, am.message_type, am.payload, am.ref_doc_id, ' +
      '  am.priority, am.created_at, p.slug AS sender_project ' +
      'FROM agent_messages am ' +
      'JOIN projects p ON am.sender_project_id = p.id ' +
      'WHERE am.target_project_id = :pid AND am.status = ''pending'' ' +
      'ORDER BY am.created_at ASC LIMIT 20');
    try
      Qry.ParamByName('pid').AsInteger := ProjectId;
      Qry.Open;

      Arr := TJSONArray.Create;
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('type', Qry.FieldByName('message_type').AsString);
        Row.AddPair('payload', Qry.FieldByName('payload').AsString);
        Row.AddPair('from', Qry.FieldByName('sender_project').AsString);
        Row.AddPair('priority', Qry.FieldByName('priority').AsString);
        if not Qry.FieldByName('ref_doc_id').IsNull then
          Row.AddPair('ref', TJSONNumber.Create(Qry.FieldByName('ref_doc_id').AsInteger));
        Arr.Add(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // Note: messages stay 'pending' until proxy confirms delivery via
    // GET ?agent_ack=<id,id,...> — prevents data loss if proxy crashes

    Resp := TJSONObject.Create;
    try
      Resp.AddPair('count', TJSONNumber.Create(Arr.Count));
      Resp.AddPair('messages', Arr);
      C.Response.StatusCode := 200;
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      ResponseBytes := TEncoding.UTF8.GetBytes(Resp.ToJSON);
      C.Response.Close(ResponseBytes);
    finally
      Resp.Free;
    end;
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, '[agent_inbox_get] ' + E.Message);
      C.Response.StatusCode := 500;
      C.Response.Close;
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
  Qry: TFDQuery;
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

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);

    // Validate: only allow comma-separated integers (prevent SQL injection)
    var SafeIds := '';
    var Parts := AIds.Split([',']);
    for var Part in Parts do
    begin
      var IdVal := StrToIntDef(Trim(Part), -1);
      if IdVal > 0 then
      begin
        if SafeIds <> '' then SafeIds := SafeIds + ',';
        SafeIds := SafeIds + IntToStr(IdVal);
      end;
    end;
    if SafeIds = '' then
    begin
      C.Response.StatusCode := 400;
      C.Response.Close;
      Exit;
    end;

    Qry := Ctx.CreateQuery(
      'UPDATE agent_messages SET status = ''read'', read_at = NOW() ' +
      'WHERE id IN (' + SafeIds + ') AND status = ''pending''');
    try
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    C.Response.StatusCode := 200;
    ResponseBytes := TEncoding.UTF8.GetBytes('{"ok":true}');
    C.Response.Headers.SetValue('Content-Type', 'application/json');
    C.Response.Close(ResponseBytes);
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, '[agent_ack_get] ' + E.Message);
      C.Response.StatusCode := 500;
      C.Response.Close;
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
