unit mx.Auth;

interface

uses
  System.SysUtils, System.Hash, System.Generics.Collections,
  FireDAC.Comp.Client,
  mx.Types, mx.Data.Pool;

type
  TMxAuthManager = class
  private
    FPool: TMxConnectionPool;
    // Server logger: AcquireContext hands out a TMxNullLogger, so Ctx.Logger
    // would swallow every auth log line.
    FLogger: IMxLogger;
    // Old proxies poll every few seconds: device warnings are logged at most
    // once per hour per (key, reason, seen device). Guarded by TMonitor.
    FLastWarn: TDictionary<string, TDateTime>;
    function Logger(const ACtx: IMxDbContext): IMxLogger;
    function ShouldWarn(const AKey: string): Boolean;
    class function ComputeSHA256(const AKey: string): string; static;
    procedure UpgradeKeyHash(const ACtx: IMxDbContext; AKeyId: Integer;
      const ARawKey: string);
    procedure CheckDeviceBinding(const ACtx: IMxDbContext;
      var AResult: TMxAuthResult; const AHost: string);
  public
    constructor Create(APool: TMxConnectionPool; ALogger: IMxLogger = nil);
    destructor Destroy; override;
    function ValidateKey(const ABearerToken: string;
      const ADeviceId: string = ''; const AProxyVersion: string = '';
      const AHost: string = ''): TMxAuthResult;
  end;

implementation

uses
  mx.Crypto;

constructor TMxAuthManager.Create(APool: TMxConnectionPool; ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
  FLastWarn := TDictionary<string, TDateTime>.Create;
end;

destructor TMxAuthManager.Destroy;
begin
  FLastWarn.Free;
  inherited;
end;

function TMxAuthManager.ShouldWarn(const AKey: string): Boolean;
const
  WARN_INTERVAL = 1 / 24; // 1 hour
var
  Last: TDateTime;
begin
  TMonitor.Enter(FLastWarn);
  try
    Result := not FLastWarn.TryGetValue(AKey, Last) or (Now - Last >= WARN_INTERVAL);
    if Result then
      FLastWarn.AddOrSetValue(AKey, Now);
  finally
    TMonitor.Exit(FLastWarn);
  end;
end;

function TMxAuthManager.Logger(const ACtx: IMxDbContext): IMxLogger;
begin
  if FLogger <> nil then
    Result := FLogger
  else
    Result := ACtx.Logger;
end;

class function TMxAuthManager.ComputeSHA256(const AKey: string): string;
begin
  Result := THashSHA2.GetHashString(AKey, THashSHA2.TSHA2Version.SHA256);
end;

procedure TMxAuthManager.UpgradeKeyHash(const ACtx: IMxDbContext;
  AKeyId: Integer; const ARawKey: string);
var
  Qry: TFDQuery;
  NewHash, Prefix: string;
begin
  // Auto-upgrade legacy SHA256 hash to PBKDF2
  NewHash := MxHashKey(ARawKey);
  Prefix := Copy(ARawKey, 1, 12);
  Qry := ACtx.CreateQuery(
    'UPDATE client_keys SET key_hash = :hash, key_prefix = :prefix WHERE id = :id');
  try
    Qry.ParamByName('hash').AsWideString :=NewHash;
    Qry.ParamByName('prefix').AsWideString :=Prefix;
    Qry.ParamByName('id').AsInteger := AKeyId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

// Plan#17121 M1 (Build N, log-only, AC7): binds an unbound key to the first
// device id it sees, logs mismatches. NEVER rejects and NEVER sets
// key_kind='cloud' (admin-only, Spec#17110 Req3). M2 adds enforcement here.
procedure TMxAuthManager.CheckDeviceBinding(const ACtx: IMxDbContext;
  var AResult: TMxAuthResult; const AHost: string);
var
  Qry: TFDQuery;
begin
  if SameText(AResult.KeyKind, 'cloud') then
    Exit;

  if AResult.DeviceId = '' then
  begin
    if SameText(AResult.KeyKind, 'device')
       and ShouldWarn(Format('%d|noheader', [AResult.KeyId])) then
      Logger(ACtx).Log(mlWarning, Format(
        '[Auth] device-bound key %d without X-Device-Id (proxy=%s) - log-only, next in 1h',
        [AResult.KeyId, AResult.ProxyVersion]));
    Exit;
  end;

  if (AResult.BoundDeviceId = '') then
  begin
    // Atomic first bind: concurrent first requests race on device_id IS NULL,
    // exactly one wins (RowsAffected=1), the loser sees the bound row next request.
    try
      Qry := ACtx.CreateQuery(
        'UPDATE client_keys SET key_kind = ''device'', device_id = :dev, ' +
        '  bound_at = NOW(), bound_host = :host ' +
        'WHERE id = :id AND device_id IS NULL AND key_kind = ''unbound''');
      try
        Qry.ParamByName('dev').AsWideString := AResult.DeviceId;
        Qry.ParamByName('host').AsWideString := Copy(AHost, 1, 255);
        Qry.ParamByName('id').AsInteger := AResult.KeyId;
        Qry.ExecSQL;
        if Qry.RowsAffected = 1 then
        begin
          AResult.KeyKind := 'device';
          AResult.BoundDeviceId := AResult.DeviceId;
          Logger(ACtx).Log(mlInfo, Format(
            '[Auth] key %d bound to device %s (host=%s, proxy=%s)',
            [AResult.KeyId, AResult.DeviceId, AHost, AResult.ProxyVersion]));
        end;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        Logger(ACtx).Log(mlWarning, '[Auth] device bind skipped: ' + E.Message);
    end;
    Exit;
  end;

  if not SameText(AResult.BoundDeviceId, AResult.DeviceId)
     and ShouldWarn(Format('%d|mismatch|%s', [AResult.KeyId, AResult.DeviceId])) then
    Logger(ACtx).Log(mlWarning, Format(
      '[Auth] device mismatch key %d: bound=%s seen=%s (host=%s, proxy=%s) - log-only, next in 1h',
      [AResult.KeyId, AResult.BoundDeviceId, AResult.DeviceId, AHost,
       AResult.ProxyVersion]));
end;

function TMxAuthManager.ValidateKey(const ABearerToken: string;
  const ADeviceId: string; const AProxyVersion: string;
  const AHost: string): TMxAuthResult;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  RawKey, Prefix, StoredHash: string;
  Found, IsLegacy: Boolean;
begin
  Result.Valid := False;
  Result.KeyId := 0;
  Result.KeyName := '';
  Result.Permissions := mpRead;
  Result.DeveloperId := 0;
  Result.DeveloperName := '';
  Result.IsAdmin := False;
  // M3.11 writer default: AR_KEY_INVALID covers empty-bearer + prefix-miss +
  // verify-fail + beyond-grace expiry (all return Valid=False). Pre-auth
  // distinction of key_expired vs key_revoked is DEFERRED to M3.11b (requires
  // a second diagnostic query without widening the hot path).
  Result.AuthReason := AR_KEY_INVALID;
  Result.RemoteIp := '';
  Result.UserAgent := '';
  // M3.4b: explicit zero so X-Key-Expires-In header never surfaces garbage
  // on any valid=false path. 0 = no expiry (unlimited key).
  Result.ExpiresAt := 0;
  Result.DeviceId := Copy(Trim(ADeviceId), 1, 64);
  Result.ProxyVersion := Copy(Trim(AProxyVersion), 1, 32);
  Result.KeyKind := '';
  Result.BoundDeviceId := '';

  RawKey := ABearerToken;
  if RawKey.StartsWith('Bearer ', True) then
    RawKey := RawKey.Substring(7).Trim;

  if RawKey = '' then
    Exit;

  Ctx := FPool.AcquireContext;
  Found := False;
  IsLegacy := False;
  Prefix := Copy(RawKey, 1, 12);

  // Step 1: Try PBKDF2 lookup via key_prefix.
  // M3.4 Grace-Period: accept keys that expired up to 24h ago (auth layer
  // downgrades to read-only after Found — see post-loop block). M3.6+M3.8:
  // exclude revoked keys (revoked_at IS NOT NULL) so prefix-collisions with
  // a revoked row don't shadow the valid active key.
  Qry := Ctx.CreateQuery(
    'SELECT ck.id AS key_id, ck.name AS key_name, ck.permissions, ' +
    '       ck.key_hash, ck.expires_at, ck.key_kind, ck.device_id, d.id AS dev_id, d.name AS dev_name ' +
    'FROM client_keys ck ' +
    'JOIN developers d ON ck.developer_id = d.id ' +
    'WHERE ck.key_prefix = :prefix ' +
    '  AND ck.is_active = TRUE ' +
    '  AND d.is_active = TRUE ' +
    '  AND ck.revoked_at IS NULL ' +
    '  AND (ck.expires_at IS NULL OR ck.expires_at > DATE_SUB(NOW(), INTERVAL 24 HOUR))');
  try
    Qry.ParamByName('prefix').AsWideString :=Prefix;
    Qry.Open;

    while not Qry.Eof do
    begin
      StoredHash := Qry.FieldByName('key_hash').AsString;
      if MxVerifyKey(RawKey, StoredHash) then
      begin
        Found := True;
        Result.Valid := True;
        Result.KeyId := Qry.FieldByName('key_id').AsInteger;
        Result.KeyName := Qry.FieldByName('key_name').AsString;
        Result.Permissions := TMxPermission.FromString(
          Qry.FieldByName('permissions').AsString);
        Result.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
        Result.DeveloperName := Qry.FieldByName('dev_name').AsString;
        Result.IsAdmin := (Result.Permissions = mpAdmin);
        Result.KeyKind := Qry.FieldByName('key_kind').AsString;
        Result.BoundDeviceId := Qry.FieldByName('device_id').AsString;
        // M3.4b: surface expiry horizon for X-Key-Expires-In header.
        if not Qry.FieldByName('expires_at').IsNull then
          Result.ExpiresAt := Qry.FieldByName('expires_at').AsDateTime;
        // M3.4 Grace-Period: if the key is past its hard expiry but within 24h,
        // downgrade to read-only so the holder can rotate without lock-out.
        if (not Qry.FieldByName('expires_at').IsNull)
           and (Qry.FieldByName('expires_at').AsDateTime < Now) then
        begin
          Result.Permissions := mpRead;
          Result.IsAdmin := False;
          Result.AuthReason := AR_KEY_EXPIRED_GRACE;
        end
        else
          Result.AuthReason := AR_OK;
        Break;
      end;
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  // Step 2: Fallback to legacy SHA256 lookup (keys without key_prefix)
  if not Found then
  begin
    Qry := Ctx.CreateQuery(
      'SELECT ck.id AS key_id, ck.name AS key_name, ck.permissions, ' +
      '       ck.expires_at, ck.key_kind, ck.device_id, d.id AS dev_id, d.name AS dev_name ' +
      'FROM client_keys ck ' +
      'JOIN developers d ON ck.developer_id = d.id ' +
      'WHERE ck.key_hash = :hash ' +
      '  AND ck.key_prefix IS NULL ' +
      '  AND ck.is_active = TRUE ' +
      '  AND d.is_active = TRUE ' +
      '  AND ck.revoked_at IS NULL ' +
      '  AND (ck.expires_at IS NULL OR ck.expires_at > DATE_SUB(NOW(), INTERVAL 24 HOUR))');
    try
      Qry.ParamByName('hash').AsWideString :=ComputeSHA256(RawKey);
      Qry.Open;

      if not Qry.IsEmpty then
      begin
        Found := True;
        IsLegacy := True;
        Result.Valid := True;
        Result.KeyId := Qry.FieldByName('key_id').AsInteger;
        Result.KeyName := Qry.FieldByName('key_name').AsString;
        Result.Permissions := TMxPermission.FromString(
          Qry.FieldByName('permissions').AsString);
        Result.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
        Result.DeveloperName := Qry.FieldByName('dev_name').AsString;
        Result.IsAdmin := (Result.Permissions = mpAdmin);
        Result.KeyKind := Qry.FieldByName('key_kind').AsString;
        Result.BoundDeviceId := Qry.FieldByName('device_id').AsString;
        // M3.4b: surface expiry horizon (same as PBKDF2 path above).
        if not Qry.FieldByName('expires_at').IsNull then
          Result.ExpiresAt := Qry.FieldByName('expires_at').AsDateTime;
        // M3.4 Grace-Period (legacy path): same downgrade as PBKDF2 path above.
        if (not Qry.FieldByName('expires_at').IsNull)
           and (Qry.FieldByName('expires_at').AsDateTime < Now) then
        begin
          Result.Permissions := mpRead;
          Result.IsAdmin := False;
          Result.AuthReason := AR_KEY_EXPIRED_GRACE;
        end
        else
          Result.AuthReason := AR_OK;
      end;
    finally
      Qry.Free;
    end;
  end;

  if not Found then
    Exit;

  // Auto-upgrade legacy keys to PBKDF2
  if IsLegacy then
  begin
    try
      UpgradeKeyHash(Ctx, Result.KeyId, RawKey);
    except
      on E: Exception do
        Logger(Ctx).Log(mlDebug, '[Auth] Key upgrade deferred: ' + E.Message);
    end;
  end;

  // Update last_used + last_seen identity (fire-and-forget). Empty header
  // keeps the previous last_seen value (Plan#17121 M1).
  try
    Qry := Ctx.CreateQuery(
      'UPDATE client_keys SET last_used_at = NOW(), ' +
      '  last_seen_device_id = COALESCE(NULLIF(:dev, ''''), last_seen_device_id), ' +
      '  last_seen_proxy_version = COALESCE(NULLIF(:ver, ''''), last_seen_proxy_version) ' +
      'WHERE id = :id');
    try
      Qry.ParamByName('dev').AsWideString := Result.DeviceId;
      Qry.ParamByName('ver').AsWideString := Result.ProxyVersion;
      Qry.ParamByName('id').AsInteger := Result.KeyId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      Logger(Ctx).Log(mlDebug, '[Auth] last_used update skipped: ' + E.Message);
  end;

  CheckDeviceBinding(Ctx, Result, AHost);
end;

end.
