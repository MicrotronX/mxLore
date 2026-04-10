unit mx.Logic.Invite;

// v2.4.0: Business logic for team invite links (Spec #1755, Plan #1756 Phase 3.2).
// Wraps mx.Data.Invite with token generation, expiry + revocation + key-active
// checks, and audit semantics (first_viewed_at via idempotent write).
//
// Error codes exposed via TInviteResolveResult are stable public API —
// the /api/invite/{token} endpoint maps them 1:1 to JSON error codes.

interface

uses
  System.SysUtils, System.Classes,
  mx.Types, mx.Data.Invite;

type
  // Status derived from invite_links row + client_keys.is_active join.
  // 'key_inactive' is never exposed externally — mapped to 'revoked' to
  // avoid leaking key state to unauthenticated callers.
  TInviteStatus = (isActive, isExpired, isRevoked, isKeyInactive, isNotFound);

  // Full resolve result for /api/invite/{token} endpoint.
  TInviteResolveResult = record
    Status: TInviteStatus;
    Invite: TMxInviteRecord;
    DeveloperName: string;
    ApiKey: string;          // raw key — only populated when Status = isActive
    McpUrl: string;
    AdminUrl: string;
    FirstViewNow: Boolean;   // True if THIS resolve was the first view ever
  end;

  TMxInviteLogic = class
  public
    /// <summary>
    ///   Generates a new invite token. Format: 'inv_' + 64 lowercase hex chars
    ///   (32 bytes = 256 bits entropy via BCryptGenRandom CSPRNG, per ADR#1767).
    /// </summary>
    class function GenerateToken: string; static;

    /// <summary>
    ///   Creates a new invite AND a new client_key in one go. Generates:
    ///    1. a fresh raw API key via `MxGenerateRandomHex(16)` (prefix 'mxk_')
    ///    2. a fresh invite token
    ///   Inserts the hashed key into client_keys, stores the raw key
    ///   XOR-obfuscated in invite_links.raw_api_key_obfuscated. Returns
    ///   the raw key (for the admin UI "Copy link" flow) and the token.
    /// </summary>
    class function CreateInviteWithNewKey(ACtx: IMxDbContext;
      ADeveloperId: Integer; const AKeyName, AKeyPermissions, AMode: string;
      AExpiresHours, ACreatedBy: Integer;
      out ANewInviteId, ANewKeyId: Integer;
      out AToken, ARawApiKey: string): Boolean; static;

    /// <summary>
    ///   Resolves an invite token. Sets first_viewed_at idempotently on first
    ///   call. Decrypts the raw API key via mxDecryptStaticString. Returns
    ///   the raw key only when Status = isActive AND raw_api_key is still
    ///   in the DB (not nulled by Confirm or 1h-cleanup). For all other
    ///   statuses ApiKey is empty.
    /// </summary>
    class function ResolveInvite(ACtx: IMxDbContext;
      const AToken: string; const AConsumerIp: string;
      const AExternalMcpUrl, AExternalAdminUrl: string): TInviteResolveResult; static;

    /// <summary>
    ///   Consumer-initiated confirmation. Sets confirmed_at + nulls
    ///   raw_api_key_obfuscated. Called from POST /api/invite/{token}/confirm.
    ///   Returns False if token not found, expired, revoked, or already confirmed.
    /// </summary>
    class function ConfirmInvite(ACtx: IMxDbContext;
      const AToken: string): Boolean; static;

    /// <summary>
    ///   Admin-initiated revoke. Sets revoked_at + revoked_by + nulls raw key.
    ///   Returns False if already revoked (replay-safe audit trail).
    /// </summary>
    class function RevokeInvite(ACtx: IMxDbContext;
      AId, ARevokedBy: Integer): Boolean; static;

    /// <summary>
    ///   Converts internal status to the error code returned by the public
    ///   /api/invite/{token} endpoint. 'key_inactive' is intentionally
    ///   mapped to 'invite_revoked' to not leak key-activation state.
    /// </summary>
    class function StatusToErrorCode(AStatus: TInviteStatus): string; static;

    /// <summary>
    ///   Derives the public status string ('active'/'expired'/'revoked')
    ///   from a TMxInviteRecord. Used by the admin list endpoint.
    /// </summary>
    class function RecordStatusString(const ARec: TMxInviteRecord): string; static;
  end;

implementation

uses
  System.DateUtils,
  FireDAC.Comp.Client,
  Data.DB,
  mx.Crypto,    // MxGenerateRandomHex, MxHashKey
  mx.Config;    // mxEncryptStaticString / mxDecryptStaticString (XOR helper)

{ TMxInviteLogic }

class function TMxInviteLogic.GenerateToken: string;
begin
  // 32 bytes = 256 bits via Windows BCryptGenRandom (CSPRNG).
  // Per ADR#1767 — replaces weaker CreateGUID approach.
  Result := 'inv_' + MxGenerateRandomHex(32);
end;

class function TMxInviteLogic.CreateInviteWithNewKey(ACtx: IMxDbContext;
  ADeveloperId: Integer; const AKeyName, AKeyPermissions, AMode: string;
  AExpiresHours, ACreatedBy: Integer;
  out ANewInviteId, ANewKeyId: Integer;
  out AToken, ARawApiKey: string): Boolean;
var
  Qry: TFDQuery;
  KeyHash, RawKeyObfuscated: string;
  ExpiresAt: TDateTime;
begin
  ANewInviteId := 0;
  ANewKeyId := 0;
  AToken := '';
  ARawApiKey := '';
  Result := False;

  if AExpiresHours <= 0 then Exit;
  if ADeveloperId <= 0 then Exit;

  // All-or-nothing: client_keys INSERT + invite_links INSERT wrapped in one
  // transaction so that a half-created invite cannot leave an orphan active
  // client_key with a hashed-but-undelivered raw key (ADR#1767 / mxBugChecker).
  ACtx.StartTransaction;
  try
    // Step 1: generate raw key (16 bytes = 32 hex chars)
    ARawApiKey := 'mxk_' + MxGenerateRandomHex(16);

    // Step 2: insert into client_keys with PBKDF2 hash
    KeyHash := MxHashKey(ARawApiKey);
    Qry := ACtx.CreateQuery(
      'INSERT INTO client_keys (developer_id, name, key_hash, key_prefix, ' +
      '  permissions, is_active, created_at) ' +
      'VALUES (:d, :n, :h, :p, :perms, TRUE, NOW())');
    try
      Qry.ParamByName('d').AsInteger := ADeveloperId;
      Qry.ParamByName('n').AsString := AKeyName;
      Qry.ParamByName('h').AsString := KeyHash;
      Qry.ParamByName('p').AsString := Copy(ARawApiKey, 1, 12);
      Qry.ParamByName('perms').AsString := AKeyPermissions;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    Qry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
    try
      Qry.Open;
      if not Qry.IsEmpty then
        ANewKeyId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;
    if ANewKeyId = 0 then
      raise Exception.Create('client_keys insert returned no id');

    // Step 3: generate invite token + XOR-obfuscate raw key
    AToken := GenerateToken;
    RawKeyObfuscated := mxEncryptStaticString(ARawApiKey);
    ExpiresAt := IncHour(Now, AExpiresHours);

    // Step 4: insert invite row
    ANewInviteId := TMxInviteData.CreateInvite(ACtx, AToken, ADeveloperId,
      ANewKeyId, AMode, ExpiresAt, ACreatedBy, RawKeyObfuscated);
    if ANewInviteId = 0 then
      raise Exception.Create('invite_links insert returned no id');

    ACtx.Commit;
    Result := True;
  except
    on E: Exception do
    begin
      try ACtx.Rollback; except end;
      ARawApiKey := '';
      AToken := '';
      ANewInviteId := 0;
      ANewKeyId := 0;
      // Re-raise so the handler can log via its guaranteed-non-nil ALogger
      // and return a descriptive error to the UI. The previous approach
      // of swallowing the exception + returning False made failures
      // invisible in the log (ACtx.Logger can be nil at runtime).
      raise;
    end;
  end;
end;

class function TMxInviteLogic.ResolveInvite(ACtx: IMxDbContext;
  const AToken: string; const AConsumerIp: string;
  const AExternalMcpUrl, AExternalAdminUrl: string): TInviteResolveResult;
var
  Qry: TFDQuery;
  KeyActive: Boolean;
  DevName: string;
begin
  Result := Default(TInviteResolveResult);
  Result.Status := isNotFound;

  // Step 1: Lookup invite by token
  if not TMxInviteData.GetByToken(ACtx, AToken, Result.Invite) then
    Exit;

  // Step 2: Check revoke state
  if Result.Invite.RevokedAt > 0 then
  begin
    Result.Status := isRevoked;
    Exit;
  end;

  // Step 3: Check expiry
  if Result.Invite.ExpiresAt <= Now then
  begin
    Result.Status := isExpired;
    Exit;
  end;

  // Step 4: Fetch client_key.is_active + developer name (one JOIN query)
  Qry := ACtx.CreateQuery(
    'SELECT ck.is_active, d.name ' +
    'FROM client_keys ck ' +
    'INNER JOIN developers d ON d.id = ck.developer_id ' +
    'WHERE ck.id = :k');
  try
    Qry.ParamByName('k').AsInteger := Result.Invite.ClientKeyId;
    Qry.Open;
    if Qry.IsEmpty then
    begin
      // Underlying key was hard-deleted — externally mapped to 'revoked'
      Result.Status := isKeyInactive;
      Exit;
    end;
    // Note: client_keys.is_active is TINYINT(1), which FireDAC maps to a
    // Boolean field — `AsInteger` raises "Field cannot be accessed as Integer".
    // Use `AsBoolean` instead.
    KeyActive := Qry.FieldByName('is_active').AsBoolean;
    DevName := Qry.FieldByName('name').AsString;
  finally
    Qry.Free;
  end;
  if not KeyActive then
  begin
    Result.Status := isKeyInactive;
    Exit;
  end;

  // Step 5: Mark first_viewed_at idempotently (first click wins)
  Result.FirstViewNow := TMxInviteData.MarkFirstViewed(ACtx,
    Result.Invite.Id, AConsumerIp);

  // Step 6: Populate result. Raw key is only present if not yet confirmed
  // / not yet cleaned up (ADR#1767 TTL policy).
  Result.Status := isActive;
  Result.DeveloperName := DevName;
  Result.McpUrl := AExternalMcpUrl;
  Result.AdminUrl := AExternalAdminUrl;
  if Result.Invite.RawApiKeyObfuscated <> '' then
    Result.ApiKey := mxDecryptStaticString(Result.Invite.RawApiKeyObfuscated)
  else
    Result.ApiKey := '';  // already confirmed / cleaned up — consumer must revisit via admin
end;

class function TMxInviteLogic.ConfirmInvite(ACtx: IMxDbContext;
  const AToken: string): Boolean;
var
  Invite: TMxInviteRecord;
begin
  Result := False;
  if not TMxInviteData.GetByToken(ACtx, AToken, Invite) then Exit;
  if Invite.RevokedAt > 0 then Exit;
  if Invite.ExpiresAt <= Now then Exit;
  Result := TMxInviteData.ConfirmInvite(ACtx, Invite.Id);
end;

class function TMxInviteLogic.RevokeInvite(ACtx: IMxDbContext;
  AId, ARevokedBy: Integer): Boolean;
begin
  Result := TMxInviteData.Revoke(ACtx, AId, ARevokedBy);
end;

class function TMxInviteLogic.StatusToErrorCode(AStatus: TInviteStatus): string;
begin
  case AStatus of
    isActive:       Result := '';  // no error
    isExpired:      Result := 'invite_expired';
    isRevoked:      Result := 'invite_revoked';
    isKeyInactive:  Result := 'invite_revoked';  // intentional: don't leak key state
    isNotFound:     Result := 'invite_not_found';
  else
    Result := 'invite_not_found';
  end;
end;

class function TMxInviteLogic.RecordStatusString(const ARec: TMxInviteRecord): string;
begin
  if ARec.RevokedAt > 0 then
    Exit('revoked');
  if ARec.ExpiresAt <= Now then
    Exit('expired');
  if ARec.ConfirmedAt > 0 then
    Exit('confirmed');
  Result := 'active';
end;

end.
