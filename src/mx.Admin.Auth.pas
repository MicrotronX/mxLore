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
    Qry.ParamByName('prefix').AsString := Prefix;
    Qry.Open;
    while not Qry.Eof do
    begin
      if MxVerifyKey(RawKey, Qry.FieldByName('key_hash').AsString) then
      begin
        Found := True;
        FoundKeyId := Qry.FieldByName('key_id').AsInteger;
        if not SameText(Qry.FieldByName('permissions').AsString, 'admin') then
          Exit(lrNotAdmin);
        if not Qry.FieldByName('ui_login_enabled').AsBoolean then
          Exit(lrUiLoginDisabled);
        ASession.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
        ASession.DeveloperName := Qry.FieldByName('dev_name').AsString;
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
      Qry.ParamByName('hash').AsString := KeyHash;
      Qry.Open;
      if Qry.IsEmpty then
        Exit(lrInvalidKey);

      Found := True;
      IsLegacy := True;
      FoundKeyId := Qry.FieldByName('key_id').AsInteger;
      if not SameText(Qry.FieldByName('permissions').AsString, 'admin') then
        Exit(lrNotAdmin);
      if not Qry.FieldByName('ui_login_enabled').AsBoolean then
        Exit(lrUiLoginDisabled);
      ASession.DeveloperId := Qry.FieldByName('dev_id').AsInteger;
      ASession.DeveloperName := Qry.FieldByName('dev_name').AsString;
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
        Qry.ParamByName('hash').AsString := UpgHash;
        Qry.ParamByName('prefix').AsString := Prefix;
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
    Qry.ParamByName('token').AsString :=
      THashSHA2.GetHashString(ASession.Token, THashSHA2.TSHA2Version.SHA256);
    Qry.ParamByName('dev_id').AsInteger := ASession.DeveloperId;
    Qry.ParamByName('csrf').AsString := ASession.CsrfToken;
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
  if AToken = '' then Exit;

  Ctx := FPool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT s.token, s.developer_id, d.name AS dev_name, ' +
    '  s.csrf_token, s.expires_at ' +
    'FROM admin_sessions s ' +
    'JOIN developers d ON s.developer_id = d.id ' +
    'WHERE s.token = :token AND s.expires_at > NOW()');
  try
    Qry.ParamByName('token').AsString :=
      THashSHA2.GetHashString(AToken, THashSHA2.TSHA2Version.SHA256);
    Qry.Open;
    if Qry.IsEmpty then Exit;

    Result.Token := Qry.FieldByName('token').AsString;
    Result.DeveloperId := Qry.FieldByName('developer_id').AsInteger;
    Result.DeveloperName := Qry.FieldByName('dev_name').AsString;
    Result.CsrfToken := Qry.FieldByName('csrf_token').AsString;
    Result.ExpiresAt := Qry.FieldByName('expires_at').AsDateTime;
    Result.Valid := True;
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
    Qry.ParamByName('token').AsString :=
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
