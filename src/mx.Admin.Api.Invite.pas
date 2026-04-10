unit mx.Admin.Api.Invite;

// v2.4.0 Phase 3.3: REST handlers for invite links (Spec #1755, ADR#1767).
//
// Admin endpoints (auth required):
//   GET    /api/invites[?status=active|expired|revoked|all]
//   POST   /api/invites
//   DELETE /api/invites/{id}
//
// Public endpoints (no auth, rate-limited via TMxRateLimit, CSRF-exempt):
//   GET    /api/invite/{token}           — resolves invite, returns credentials
//   POST   /api/invite/{token}/confirm   — consumer-initiated key-nulling

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Logic.Settings, mx.Logic.RateLimit;

// --- Admin ---

procedure HandleListInvites(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleCreateInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ASettings: TMxSettingsCache;
  ACreatedBy: Integer; ALogger: IMxLogger);

procedure HandleDeleteInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; AInviteId, ARevokedBy: Integer;
  ALogger: IMxLogger);

// DELETE /api/invites/cleanup — hard-delete all revoked+expired
procedure HandleCleanupInvites(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

// --- Public ---

procedure HandleResolveInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ARateLimit: TMxRateLimit;
  ASettings: TMxSettingsCache; const AToken: string;
  ALogger: IMxLogger);

procedure HandleConfirmInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ARateLimit: TMxRateLimit;
  ASettings: TMxSettingsCache; const AToken: string; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, System.DateUtils,
  Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server,    // MxSendJson/Error, MxParseBody, MxGetClientIp, MxDateStr
  mx.Data.Invite, mx.Logic.Invite;

// --- helpers ------------------------------------------------------------

function InviteToJson(const ARec: TMxInviteRecord;
  AIncludeToken: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(ARec.Id));
  if AIncludeToken then
    Result.AddPair('token', ARec.Token);
  Result.AddPair('developer_id', TJSONNumber.Create(ARec.DeveloperId));
  Result.AddPair('client_key_id', TJSONNumber.Create(ARec.ClientKeyId));
  Result.AddPair('mode', ARec.Mode);
  Result.AddPair('expires_at', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ARec.ExpiresAt));
  if ARec.FirstViewedAt > 0 then
    Result.AddPair('first_viewed_at',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ARec.FirstViewedAt))
  else
    Result.AddPair('first_viewed_at', TJSONNull.Create);
  if ARec.ConfirmedAt > 0 then
    Result.AddPair('confirmed_at',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ARec.ConfirmedAt))
  else
    Result.AddPair('confirmed_at', TJSONNull.Create);
  if ARec.RevokedAt > 0 then
    Result.AddPair('revoked_at',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ARec.RevokedAt))
  else
    Result.AddPair('revoked_at', TJSONNull.Create);
  if ARec.ConsumerIp <> '' then
    Result.AddPair('consumer_ip', ARec.ConsumerIp)
  else
    Result.AddPair('consumer_ip', TJSONNull.Create);
  Result.AddPair('created_by', TJSONNumber.Create(ARec.CreatedBy));
  Result.AddPair('created_at',
    FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ARec.CreatedAt));
  Result.AddPair('status', TMxInviteLogic.RecordStatusString(ARec));
end;

function GetJsonString(AObj: TJSONObject; const AKey: string;
  const ADefault: string = ''): string;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  V := AObj.GetValue(AKey);
  if (V <> nil) and (V is TJSONString) then
    Result := TJSONString(V).Value;
end;

function GetJsonInt(AObj: TJSONObject; const AKey: string;
  ADefault: Integer = 0): Integer;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  V := AObj.GetValue(AKey);
  if (V <> nil) and (V is TJSONNumber) then
    Result := TJSONNumber(V).AsInt;
end;

// --- Admin: GET /api/invites --------------------------------------------

procedure HandleListInvites(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Arr: TJSONArray;
  Json: TJSONObject;
  Invites: TArray<TMxInviteRecord>;
  I: Integer;
  StatusFilter, RawQuery: string;
begin
  // Parse ?status=active|expired|revoked (default: all).
  // Anchor match with & delimiters to avoid false positives like ?xstatus=active_foo.
  StatusFilter := '';
  RawQuery := LowerCase(C.Request.Uri.Query);
  if (Length(RawQuery) > 0) and (RawQuery[1] = '?') then
    RawQuery := Copy(RawQuery, 2);
  RawQuery := '&' + RawQuery + '&';
  if Pos('&status=active&', RawQuery) > 0 then
    StatusFilter := 'active'
  else if Pos('&status=expired&', RawQuery) > 0 then
    StatusFilter := 'expired'
  else if Pos('&status=revoked&', RawQuery) > 0 then
    StatusFilter := 'revoked'
  else if Pos('&status=confirmed&', RawQuery) > 0 then
    StatusFilter := 'confirmed';

  Ctx := APool.AcquireContext;
  Invites := TMxInviteData.ListAll(Ctx, StatusFilter);

  // Build JSON tree; free Arr on exception before ownership transfer to Json.
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Invites) do
      Arr.AddElement(InviteToJson(Invites[I], False));  // token excluded
  except
    Arr.Free;
    raise;
  end;

  Json := TJSONObject.Create;
  try
    Json.AddPair('invites', Arr);  // ownership transferred
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// --- Admin: POST /api/invites -------------------------------------------

procedure HandleCreateInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ASettings: TMxSettingsCache;
  ACreatedBy: Integer; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  DeveloperId, ExpiresHours: Integer;
  NewInviteId, NewKeyId: Integer;
  KeyName, KeyPerms, Mode, Token, RawKey: string;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;
  try
    DeveloperId := GetJsonInt(Body, 'developer_id');
    if DeveloperId <= 0 then
    begin
      MxSendError(C, 400, 'missing_developer_id');
      Exit;
    end;
    ExpiresHours := GetJsonInt(Body, 'expires_hours', 48);
    if (ExpiresHours < 1) or (ExpiresHours > 24 * 30) then
    begin
      MxSendError(C, 400, 'invalid_expires_hours');
      Exit;
    end;
    KeyName := GetJsonString(Body, 'key_name', 'invite-' + FormatDateTime('yyyymmdd-hhnn', Now));
    KeyPerms := LowerCase(GetJsonString(Body, 'permissions', 'read'));
    if (KeyPerms <> 'read') and (KeyPerms <> 'readwrite') and (KeyPerms <> 'admin') then
      KeyPerms := 'read';
    Mode := LowerCase(GetJsonString(Body, 'mode', 'external'));
    if (Mode <> 'external') and (Mode <> 'internal') then
      Mode := 'external';

    Ctx := APool.AcquireContext;
    try
      if not TMxInviteLogic.CreateInviteWithNewKey(Ctx, DeveloperId, KeyName,
        KeyPerms, Mode, ExpiresHours, ACreatedBy,
        NewInviteId, NewKeyId, Token, RawKey) then
      begin
        // CreateInviteWithNewKey only returns False on bad input (validated
        // above); any DB failure raises an exception caught below.
        ALogger.Log(mlError,
          'Invite creation returned False with validated inputs — unexpected');
        MxSendError(C, 500, 'create_failed');
        Exit;
      end;
    except
      on E: Exception do
      begin
        ALogger.Log(mlError, Format(
          'Invite creation failed: dev=%d key=%s mode=%s err=%s: %s',
          [DeveloperId, KeyName, Mode, E.ClassName, E.Message]));
        MxSendError(C, 500, 'create_failed');
        Exit;
      end;
    end;

    ALogger.Log(mlInfo, Format(
      'Invite created: id=%d token=inv_... developer=%d key=%d by=%d expires=%dh mode=%s',
      [NewInviteId, DeveloperId, NewKeyId, ACreatedBy, ExpiresHours, Mode]));

    // --- Build the invite_url that the admin will share ---
    // For mode=external: use connect.external_admin_url (the reverse-proxy URL).
    // For mode=internal OR external URL not configured: fall back to the host
    // the admin is currently connected to (C.Request.Uri.Host + scheme + port).
    var InviteBase: string := '';
    var InviteUrlWarning: string := '';
    if Assigned(ASettings) and SameText(Mode, 'external') then
      InviteBase := ASettings.Get('connect.external_admin_url');

    if InviteBase = '' then
    begin
      // Fallback: rebuild the base URL from the request the admin is using
      var Scheme := C.Request.Uri.Scheme;
      if Scheme = '' then Scheme := 'http';
      var Host := C.Request.Uri.Host;
      if Host = '' then Host := '127.0.0.1';
      var Port := C.Request.Uri.Port;
      InviteBase := Scheme + '://' + Host;
      if (Port > 0) and
         (not ((SameText(Scheme, 'http') and (Port = 80)) or
               (SameText(Scheme, 'https') and (Port = 443)))) then
        InviteBase := InviteBase + ':' + IntToStr(Port);
      if SameText(Mode, 'external') then
        InviteUrlWarning :=
          'connect.external_admin_url is not configured — using local admin host. ' +
          'The recipient may not be able to reach this URL from outside.';
    end;

    // Strip trailing slash then append /connect?token=
    if InviteBase.EndsWith('/') then
      InviteBase := Copy(InviteBase, 1, Length(InviteBase) - 1);
    var InviteUrl: string := InviteBase + '/connect?token=' + Token;

    // Return token + raw key ONCE — admin UI must display + copy immediately.
    Json := TJSONObject.Create;
    try
      Json.AddPair('id', TJSONNumber.Create(NewInviteId));
      Json.AddPair('token', Token);
      Json.AddPair('api_key', RawKey);
      Json.AddPair('invite_url', InviteUrl);
      Json.AddPair('client_key_id', TJSONNumber.Create(NewKeyId));
      Json.AddPair('expires_hours', TJSONNumber.Create(ExpiresHours));
      Json.AddPair('mode', Mode);
      if InviteUrlWarning <> '' then
        Json.AddPair('url_warning', InviteUrlWarning);
      MxSendJson(C, 201, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

// --- Admin: DELETE /api/invites/{id} ------------------------------------
// Smart behavior: active invite → revoke, revoked/expired invite → hard delete.

procedure HandleDeleteInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; AInviteId, ARevokedBy: Integer;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Json: TJSONObject;
  Revoked, Deleted: Boolean;
begin
  Ctx := APool.AcquireContext;

  // Try hard-delete first (only succeeds for revoked/expired)
  Deleted := TMxInviteData.DeleteById(Ctx, AInviteId);
  if Deleted then
  begin
    ALogger.Log(mlInfo, Format('Invite hard-deleted: id=%d by=%d', [AInviteId, ARevokedBy]));
    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('deleted', TJSONBool.Create(True));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
    Exit;
  end;

  // Not inactive — try revoke (active invite)
  Revoked := TMxInviteLogic.RevokeInvite(Ctx, AInviteId, ARevokedBy);
  if Revoked then
    ALogger.Log(mlInfo, Format('Invite revoked: id=%d by=%d', [AInviteId, ARevokedBy]))
  else
    ALogger.Log(mlInfo, Format('Invite delete/revoke noop: id=%d', [AInviteId]));

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    Json.AddPair('revoked_now', TJSONBool.Create(Revoked));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// --- Admin: DELETE /api/invites/cleanup ----------------------------------

procedure HandleCleanupInvites(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Json: TJSONObject;
  Count: Integer;
begin
  Ctx := APool.AcquireContext;
  Count := TMxInviteData.DeleteAllInactive(Ctx);
  ALogger.Log(mlInfo, Format('Invite cleanup: %d inactive invites deleted', [Count]));

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    Json.AddPair('deleted_count', TJSONNumber.Create(Count));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// --- Public: GET /api/invite/{token} ------------------------------------

procedure HandleResolveInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ARateLimit: TMxRateLimit;
  ASettings: TMxSettingsCache; const AToken: string;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Result: TInviteResolveResult;
  Json: TJSONObject;
  ClientIp, TrustedProxies, ExtMcpUrl, ExtAdminUrl, ErrCode: string;
begin
  // Rate-limit guard — IP-based, before DB touch
  TrustedProxies := '';
  if Assigned(ASettings) then
    TrustedProxies := ASettings.Get('connect.trusted_proxies');
  ClientIp := MxGetClientIp(C, TrustedProxies);
  if (ARateLimit <> nil) and (not ARateLimit.TryAcquire(ClientIp)) then
  begin
    C.Response.Headers.SetValue('Retry-After', '300');
    MxSendError(C, 429, 'rate_limited');
    Exit;
  end;

  // Resolve URLs from settings cache
  if Assigned(ASettings) then
  begin
    ExtMcpUrl := ASettings.Get('connect.external_mcp_url');
    ExtAdminUrl := ASettings.Get('connect.external_admin_url');
  end;

  Ctx := APool.AcquireContext;
  Result := TMxInviteLogic.ResolveInvite(Ctx, AToken, ClientIp,
    ExtMcpUrl, ExtAdminUrl);

  if Result.Status <> isActive then
  begin
    ErrCode := TMxInviteLogic.StatusToErrorCode(Result.Status);
    ALogger.Log(mlInfo, Format('Invite resolve failed: token=inv_... ip=%s code=%s',
      [ClientIp, ErrCode]));
    Json := TJSONObject.Create;
    try
      Json.AddPair('status', 'error');
      Json.AddPair('code', ErrCode);
      MxSendJson(C, 200, Json);  // 200 OK with error in body — landing page handles UX
    finally
      Json.Free;
    end;
    Exit;
  end;

  if Result.FirstViewNow then
    ALogger.Log(mlInfo, Format('Invite first-view: id=%d ip=%s developer=%s',
      [Result.Invite.Id, ClientIp, Result.DeveloperName]));

  Json := TJSONObject.Create;
  try
    Json.AddPair('status', 'valid');
    Json.AddPair('developer_name', Result.DeveloperName);
    Json.AddPair('mode', Result.Invite.Mode);
    if Result.McpUrl <> '' then
      Json.AddPair('mcp_url', Result.McpUrl);
    if Result.AdminUrl <> '' then
      Json.AddPair('admin_url', Result.AdminUrl);
    if Result.ApiKey <> '' then
      Json.AddPair('api_key', Result.ApiKey)
    else
      Json.AddPair('api_key_cleared', TJSONBool.Create(True));  // post-confirm state
    Json.AddPair('expires_at',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Result.Invite.ExpiresAt));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// --- Public: POST /api/invite/{token}/confirm ---------------------------

procedure HandleConfirmInvite(const C: THttpServerContext;
  APool: TMxConnectionPool; ARateLimit: TMxRateLimit;
  ASettings: TMxSettingsCache; const AToken: string; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Json: TJSONObject;
  Confirmed: Boolean;
  ClientIp, TrustedProxies: string;
begin
  // Rate-limit (same bucket as resolve — same public surface).
  // IMPORTANT: use MxGetClientIp with TrustedProxies so the bucket key is the
  // real client behind a reverse proxy, consistent with HandleResolveInvite.
  TrustedProxies := '';
  if Assigned(ASettings) then
    TrustedProxies := ASettings.Get('connect.trusted_proxies');
  ClientIp := MxGetClientIp(C, TrustedProxies);
  if (ARateLimit <> nil) and (not ARateLimit.TryAcquire(ClientIp)) then
  begin
    C.Response.Headers.SetValue('Retry-After', '300');
    MxSendError(C, 429, 'rate_limited');
    Exit;
  end;

  Ctx := APool.AcquireContext;
  Confirmed := TMxInviteLogic.ConfirmInvite(Ctx, AToken);
  if Confirmed then
    ALogger.Log(mlInfo, Format('Invite confirmed: token=inv_... ip=%s', [ClientIp]));

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    Json.AddPair('confirmed_now', TJSONBool.Create(Confirmed));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
