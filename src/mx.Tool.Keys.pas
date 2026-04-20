// ============================================================================
// mx.Tool.Keys — FR#2936/Plan#3266 M3.6b Self-Revoke MCP Endpoint
// ----------------------------------------------------------------------------
// Self-revocation path complementing the admin-UI HandleRevokeKey shipped in
// Build 101. Dev-as-user can revoke their OWN keys via MCP; admins still use
// the admin-UI endpoint (/admin/api/keys/:id/revoke) for cross-dev revocation.
// Forensik-Trio populated: revoke_actor_type='self' (Spec#3194 §I3b enum —
// channel-differentiation via tool_call_log JOIN ON tool_name='mx_key_revoke'),
// revoked_by=caller, revoke_ip + revoke_user_agent from TMxAuthResult (mx.MCP.
// Server captures X-Forwarded-For + User-Agent post-ValidateKey; Session 267
// mxDesignChecker WARN#1+#2 fixes).
// ============================================================================

unit mx.Tool.Keys;

interface

uses
  System.JSON,
  mx.Types, mx.Data.Pool;

// Self-revoke an API key owned by the caller. Params:
//   key_id (optional) — if omitted or <=0, uses the caller's current auth key
//   reason (optional) — free-text, capped at 255 chars, stored in revoked_reason
// Returns success with revoked_at + key_id + key_prefix + actor_type.
// Errors: NOT_FOUND (key_id missing in DB), ACCESS_DENIED (key not owned by
// caller), VALIDATION_ERROR (already_revoked / no key_id available).
function HandleKeyRevoke(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  System.SysUtils,
  FireDAC.Comp.Client, Data.DB,
  mx.Errors, mx.Logic.AccessControl;

function HandleKeyRevoke(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  TargetKeyId, TargetOwnerDevId: Integer;
  Reason, KeyPrefix, NowStr: string;
  Data: TJSONObject;
  AlreadyRevoked: Boolean;
begin
  Auth := MxGetThreadAuth;
  if Auth.DeveloperId <= 0 then
    // EMxAccessDenied expects (slug, level) — use sentinel slug '_auth' for
    // no-session case. SafeExecute logs the message via E.Message anyway.
    raise EMxAccessDenied.Create('_auth', alReadOnly);

  // Default to current session key when key_id not passed.
  TargetKeyId := AParams.GetValue<Integer>('key_id', 0);
  if TargetKeyId <= 0 then
    TargetKeyId := Auth.KeyId;
  if TargetKeyId <= 0 then
    raise EMxValidation.Create(
      'No key_id provided and no current key in auth context');

  Reason := AParams.GetValue<string>('reason', '');
  if Length(Reason) > 255 then
    Reason := Copy(Reason, 1, 255);

  // Look up ownership + current revoke state.
  Qry := AContext.CreateQuery(
    'SELECT developer_id, revoked_at, key_prefix ' +
    'FROM client_keys WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := TargetKeyId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Key not found: ' + IntToStr(TargetKeyId));
    TargetOwnerDevId := Qry.FieldByName('developer_id').AsInteger;
    AlreadyRevoked := not Qry.FieldByName('revoked_at').IsNull;
    KeyPrefix := Qry.FieldByName('key_prefix').AsString;
  finally
    Qry.Free;
  end;

  // Self-only gate. Admin cross-dev revocation stays on the admin-UI path
  // where IP + UA capture is available and the audit-trail differentiates
  // revoke_actor_type='admin' vs 'self'. EMxAccessDenied(slug, level) — use
  // the key's own scope marker '_key' and the strongest level to reflect
  // "you have no permission over this resource at all".
  if TargetOwnerDevId <> Auth.DeveloperId then
    raise EMxAccessDenied.Create('_key', alReadWrite);

  if AlreadyRevoked then
    raise EMxValidation.Create('already_revoked');

  // Atomic UPDATE with revoked_at IS NULL guard (Bug#3350 TOCTOU pattern).
  // Forensik-Trio: revoke_ip + revoke_user_agent from TMxAuthResult (M3.6b
  // WARN#1 fix — mx.MCP.Server captures X-Forwarded-For + User-Agent post-
  // ValidateKey). revoke_actor_type='self' matches Spec §I3b enum; channel
  // differentiation (MCP vs admin-UI) via tool_call_log.tool_name JOIN.
  Qry := AContext.CreateQuery(
    'UPDATE client_keys SET ' +
    '  revoked_at = NOW(), ' +
    '  revoked_by = :actor, ' +
    '  revoked_reason = :reason, ' +
    '  revoke_ip = :ip, ' +
    '  revoke_user_agent = :ua, ' +
    '  revoke_actor_type = ''self'', ' +
    '  is_active = FALSE ' +
    'WHERE id = :id AND revoked_at IS NULL');
  try
    Qry.ParamByName('actor').AsInteger := Auth.DeveloperId;
    if Reason <> '' then
      Qry.ParamByName('reason').AsWideString :=Reason
    else
    begin
      Qry.ParamByName('reason').DataType := ftString;
      Qry.ParamByName('reason').Clear;
    end;
    if Auth.RemoteIp <> '' then
      Qry.ParamByName('ip').AsWideString :=Auth.RemoteIp
    else
    begin
      Qry.ParamByName('ip').DataType := ftString;
      Qry.ParamByName('ip').Clear;
    end;
    if Auth.UserAgent <> '' then
      Qry.ParamByName('ua').AsWideString :=Auth.UserAgent
    else
    begin
      Qry.ParamByName('ua').DataType := ftString;
      Qry.ParamByName('ua').Clear;
    end;
    Qry.ParamByName('id').AsInteger := TargetKeyId;
    Qry.ExecSQL;
    // TOCTOU: another actor revoked between SELECT and UPDATE.
    if Qry.RowsAffected = 0 then
      raise EMxValidation.Create('already_revoked');
  finally
    Qry.Free;
  end;

  NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);

  Data := TJSONObject.Create;
  Data.AddPair('revoked', TJSONBool.Create(True));
  Data.AddPair('key_id', TJSONNumber.Create(TargetKeyId));
  Data.AddPair('key_prefix', KeyPrefix);
  Data.AddPair('revoked_at', NowStr);
  Data.AddPair('actor_type', 'self');
  Data.AddPair('channel', 'mcp');  // non-persisted response hint
  Result := MxSuccessResponse(Data);
end;

end.
