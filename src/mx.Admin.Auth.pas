unit mx.Admin.Auth;

interface

uses
  System.SysUtils, System.Hash,
  FireDAC.Comp.Client,
  mx.Types, mx.Data.Pool;

type
  TMxAdminSession = record
    Token: string;
    DeveloperId: Integer;
    DeveloperName: string;
    CsrfToken: string;
    ExpiresAt: TDateTime;
    Valid: Boolean;
    // FR#4006 / Plan#4007 M1: admin-flag on session so handlers can cheaply
    // branch admin-bypass vs ACL-filter without a per-request client_keys
    // lookup. Populated on Login + ValidateSession. HasNoDevelopers setup
    // mode sets this True so bootstrap works before any admin key exists.
    IsAdmin: Boolean;
  end;

  TMxLoginResult = (lrSuccess, lrInvalidKey, lrNotAdmin, lrUiLoginDisabled);

  TMxAdminAuth = class
  private
    FPool: TMxConnectionPool;
    FSessionTTLMinutes: Integer;
    class function GenerateToken: string; static;
  public
    constructor Create(APool: TMxConnectionPool; ASessionTTLMinutes: Integer = 480);
    function Login(const AApiKey: string; out ASession: TMxAdminSession): TMxLoginResult;
    function ValidateSession(const AToken: string): TMxAdminSession;
    function ValidateCsrf(const ASession: TMxAdminSession;
      const ACsrfToken: string): Boolean;
    procedure Logout(const AToken: string);
    procedure CleanupExpired;
  end;

// FR#4006 / Plan#4007 M1 helpers. Public so non-admin API handlers can
// gate per-request without duplicating the SELECT.
function DeveloperIsAdmin(APool: TMxConnectionPool; ADevId: Integer): Boolean;
function DeveloperHasAnyProjectAccess(APool: TMxConnectionPool;
  ADevId: Integer): Boolean;
function DeveloperHasProjectAccess(APool: TMxConnectionPool;
  ADevId, AProjId: Integer): Boolean;
// FR#3360 — write-level gate. DeveloperHasProjectAccess returns TRUE for any
// access-level (read/comment/read-write/write). For destructive ops (doc
// update/delete) the handler must gate on this write-only variant instead,
// otherwise a read-only dev can wipe docs via the Admin-UI Save-Button.
function DeveloperHasProjectWriteAccess(APool: TMxConnectionPool;
  ADevId, AProjId: Integer): Boolean;

// Cookie helpers
function GetCookieValue(const ACookieHeader, AName: string): string;

implementation

uses
  mx.Crypto;

{ Cookie helpers }

function GetCookieValue(const ACookieHeader, AName: string): string;
var
  Parts: TArray<string>;
  Part, Prefix: string;
begin
  Result := '';
  Prefix := AName + '=';
  Parts := ACookieHeader.Split([';']);
  for Part in Parts do
    if Part.Trim.StartsWith(Prefix) then
      Exit(Part.Trim.Substring(Length(Prefix)));
end;

{ TMxAdminAuth }

constructor TMxAdminAuth.Create(APool: TMxConnectionPool;
  ASessionTTLMinutes: Integer);
begin
  inherited Create;
  FPool := APool;
  FSessionTTLMinutes := ASessionTTLMinutes;
end;

class function TMxAdminAuth.GenerateToken: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := GUIDToString(G);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

function TMxAdminAuth.Login(const AApiKey: string;
  out ASession: TMxAdminSession): TMxLoginResult;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  KeyHash, RawKey, Prefix: string;
  Found, IsLegacy: Boolean;
  FoundKeyId: Integer;
begin
  ASession.Valid := False;

  RawKey := AApiKey.Trim;
  if RawKey = '' then
    Exit(lrInvalidKey);

  Ctx := FPool.AcquireContext;
  Found := False;
  IsLegacy := False;
  FoundKeyId := 0;
  Prefix := Copy(RawKey, 1, 12);

  // Step 1: Try PBKDF2 lookup via key_prefix
  Qry := Ctx.CreateQuery(
    'SELECT ck.id AS key_id, ck.permissions, ck.key_hash, ' +
    '       d.id AS dev_id, d.name AS dev_name, d.ui_login_enabled ' +
    'FROM client_keys ck ' +
    'JOIN developers d ON ck.developer_id = d.id ' +
    'WHERE ck.key_prefix = :prefix AND ck.is_active = TRUE AND d.is_active = TRUE ' +
    '  AND ck.revoked_at IS NULL ' +
    '  AND (ck.expires_at IS NULL OR ck.expires_at > NOW())');
  try
    Qry.ParamByName('prefix').AsWideString :=Prefix;
    Qry.Open;
    while not Qry.Eof do
    begin
      if MxVerifyKey(RawKey, Qry.FieldByName('key_hash').AsString) then
      begin
        Found := True;
        FoundKeyId := Qry.FieldByName('key_id').AsInteger;
        // FR#4006 / Plan#4007 M1: lift admin-only gate. Admins still
        // hard-bypass; non-admins may log in iff ui_login_enabled AND they
        // hold at least one developer_project_access row (→ handlers will
        // scope by ACL). Zero-access non-admins have nothing to show.
        ASession.IsAdmin :=
          SameText(Qry.FieldByName('permissions').AsString, 'admin');
        ASession.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
        ASession.DeveloperName := Qry.FieldByName('dev_name').AsString;
        if not ASession.IsAdmin then
        begin
          if not Qry.FieldByName('ui_login_enabled').AsBoolean then
            Exit(lrUiLoginDisabled);
          if not DeveloperHasAnyProjectAccess(FPool, ASession.DeveloperId) then
            Exit(lrNotAdmin);
        end;
        Break;
      end;
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  // Step 2: Fallback to legacy SHA256 lookup
  if not Found then
  begin
    KeyHash := THashSHA2.GetHashString(RawKey, THashSHA2.TSHA2Version.SHA256);
    Qry := Ctx.CreateQuery(
      'SELECT ck.id AS key_id, ck.permissions, d.id AS dev_id, d.name AS dev_name, ' +
      '       d.ui_login_enabled ' +
      'FROM client_keys ck ' +
      'JOIN developers d ON ck.developer_id = d.id ' +
      'WHERE ck.key_hash = :hash AND ck.key_prefix IS NULL ' +
      '  AND ck.is_active = TRUE AND d.is_active = TRUE ' +
      '  AND ck.revoked_at IS NULL ' +
      '  AND (ck.expires_at IS NULL OR ck.expires_at > NOW())');
    try
      Qry.ParamByName('hash').AsWideString :=KeyHash;
      Qry.Open;
      if Qry.IsEmpty then
        Exit(lrInvalidKey);

      Found := True;
      IsLegacy := True;
      FoundKeyId := Qry.FieldByName('key_id').AsInteger;
      // FR#4006 / Plan#4007 M1: identical guard-lift as PBKDF2 path above —
      // admin hard-bypass, else ui_login_enabled + ACL-presence required.
      ASession.IsAdmin :=
        SameText(Qry.FieldByName('permissions').AsString, 'admin');
      ASession.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
      ASession.DeveloperName := Qry.FieldByName('dev_name').AsString;
      if not ASession.IsAdmin then
      begin
        if not Qry.FieldByName('ui_login_enabled').AsBoolean then
          Exit(lrUiLoginDisabled);
        if not DeveloperHasAnyProjectAccess(FPool, ASession.DeveloperId) then
          Exit(lrNotAdmin);
      end;
    finally
      Qry.Free;
    end;
  end;

  if not Found then
    Exit(lrInvalidKey);

  // Auto-upgrade legacy key to PBKDF2
  if IsLegacy then
  begin
    try
      var UpgHash := MxHashKey(RawKey);
      Qry := Ctx.CreateQuery(
        'UPDATE client_keys SET key_hash = :hash, key_prefix = :prefix WHERE id = :id');
      try
        Qry.ParamByName('hash').AsWideString :=UpgHash;
        Qry.ParamByName('prefix').AsWideString :=Prefix;
        Qry.ParamByName('id').AsInteger := FoundKeyId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        Ctx.Logger.Log(mlWarning, 'PBKDF2 auto-upgrade failed for key ' +
          IntToStr(FoundKeyId) + ': ' + E.Message);
    end;
  end;

  // Create session in DB (store hashed token, return plain token in cookie)
  ASession.Token := GenerateToken;
  ASession.CsrfToken := GenerateToken;
  ASession.ExpiresAt := Now + (FSessionTTLMinutes / 1440);

  Qry := Ctx.CreateQuery(
    'INSERT INTO admin_sessions (token, developer_id, csrf_token, expires_at) ' +
    'VALUES (:token, :dev_id, :csrf, :expires)');
  try
    Qry.ParamByName('token').AsWideString :=
      THashSHA2.GetHashString(ASession.Token, THashSHA2.TSHA2Version.SHA256);
    Qry.ParamByName('dev_id').AsInteger := ASession.DeveloperId;
    Qry.ParamByName('csrf').AsWideString :=ASession.CsrfToken;
    Qry.ParamByName('expires').AsDateTime := ASession.ExpiresAt;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  // Piggyback cleanup of expired sessions
  CleanupExpired;

  ASession.Valid := True;
  Result := lrSuccess;
end;

function TMxAdminAuth.ValidateSession(const AToken: string): TMxAdminSession;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result.Valid := False;
  Result.IsAdmin := False;
  if AToken = '' then Exit;

  Ctx := FPool.AcquireContext;
  // FR#4006 / Plan#4007 M1: surface is_admin per session so handlers can
  // branch admin-bypass vs ACL-filter without a second round-trip. Derived
  // from "developer owns >=1 active admin client_key" (same definition as
  // Login + mx.Admin.Api.ProjectBundle.IsAdminDeveloper).
  Qry := Ctx.CreateQuery(
    'SELECT s.token, s.developer_id, d.name AS dev_name, ' +
    '  s.csrf_token, s.expires_at, ' +
    '  EXISTS(SELECT 1 FROM client_keys ck ' +
    '         WHERE ck.developer_id = d.id AND ck.is_active = TRUE ' +
    '           AND ck.permissions = ''admin'' ' +
    '           AND ck.revoked_at IS NULL ' +
    '           AND (ck.expires_at IS NULL OR ck.expires_at > NOW())) ' +
    '  AS is_admin ' +
    'FROM admin_sessions s ' +
    'JOIN developers d ON s.developer_id = d.id ' +
    'WHERE s.token = :token AND s.expires_at > NOW()');
  try
    Qry.ParamByName('token').AsWideString :=
      THashSHA2.GetHashString(AToken, THashSHA2.TSHA2Version.SHA256);
    Qry.Open;
    if Qry.IsEmpty then Exit;

    Result.Token := Qry.FieldByName('token').AsString;
    Result.DeveloperId := Qry.FieldByName('developer_id').AsInteger;
    Result.DeveloperName := Qry.FieldByName('dev_name').AsString;
    Result.CsrfToken := Qry.FieldByName('csrf_token').AsString;
    Result.ExpiresAt := Qry.FieldByName('expires_at').AsDateTime;
    // MariaDB EXISTS returns BIGINT(1), not BOOLEAN — FireDAC refuses .AsBoolean.
    Result.IsAdmin := Qry.FieldByName('is_admin').AsLargeInt <> 0;
    Result.Valid := True;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// FR#4006 / Plan#4007 M1 — ACL helpers (public, used by API handlers)
// ---------------------------------------------------------------------------

function DeveloperIsAdmin(APool: TMxConnectionPool;
  ADevId: Integer): Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := False;
  if ADevId <= 0 then Exit;
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT 1 FROM client_keys ' +
    'WHERE developer_id = :id AND is_active = TRUE ' +
    '  AND permissions = ''admin'' AND revoked_at IS NULL LIMIT 1');
  try
    Qry.ParamByName('id').AsInteger := ADevId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function DeveloperHasAnyProjectAccess(APool: TMxConnectionPool;
  ADevId: Integer): Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := False;
  if ADevId <= 0 then Exit;
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT 1 FROM developer_project_access ' +
    'WHERE developer_id = :id LIMIT 1');
  try
    Qry.ParamByName('id').AsInteger := ADevId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function DeveloperHasProjectAccess(APool: TMxConnectionPool;
  ADevId, AProjId: Integer): Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := False;
  if (ADevId <= 0) or (AProjId <= 0) then Exit;
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT 1 FROM developer_project_access ' +
    'WHERE developer_id = :dev AND project_id = :pid LIMIT 1');
  try
    Qry.ParamByName('dev').AsInteger := ADevId;
    Qry.ParamByName('pid').AsInteger := AProjId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function DeveloperHasProjectWriteAccess(APool: TMxConnectionPool;
  ADevId, AProjId: Integer): Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := False;
  if (ADevId <= 0) or (AProjId <= 0) then Exit;
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT 1 FROM developer_project_access ' +
    'WHERE developer_id = :dev AND project_id = :pid ' +
    '  AND access_level IN (''read-write'', ''write'') LIMIT 1');
  try
    Qry.ParamByName('dev').AsInteger := ADevId;
    Qry.ParamByName('pid').AsInteger := AProjId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function TMxAdminAuth.ValidateCsrf(const ASession: TMxAdminSession;
  const ACsrfToken: string): Boolean;
var
  I, Diff: Integer;
begin
  Result := False;
  if not ASession.Valid then Exit;
  if Length(ASession.CsrfToken) <> Length(ACsrfToken) then Exit;

  // Constant-time comparison to prevent timing attacks
  Diff := 0;
  for I := 1 to Length(ASession.CsrfToken) do
    Diff := Diff or (Ord(ASession.CsrfToken[I]) xor Ord(ACsrfToken[I]));
  Result := (Diff = 0);
end;

procedure TMxAdminAuth.Logout(const AToken: string);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  if AToken = '' then Exit;
  Ctx := FPool.AcquireContext;
  Qry := Ctx.CreateQuery('DELETE FROM admin_sessions WHERE token = :token');
  try
    Qry.ParamByName('token').AsWideString :=
      THashSHA2.GetHashString(AToken, THashSHA2.TSHA2Version.SHA256);
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

procedure TMxAdminAuth.CleanupExpired;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Ctx := FPool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'DELETE FROM admin_sessions WHERE expires_at < NOW()');
  try
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

end.
