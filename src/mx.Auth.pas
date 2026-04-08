unit mx.Auth;

interface

uses
  System.SysUtils, System.Hash,
  FireDAC.Comp.Client,
  mx.Types, mx.Data.Pool;

type
  TMxAuthManager = class
  private
    FPool: TMxConnectionPool;
    class function ComputeSHA256(const AKey: string): string; static;
    procedure UpgradeKeyHash(const ACtx: IMxDbContext; AKeyId: Integer;
      const ARawKey: string);
  public
    constructor Create(APool: TMxConnectionPool);
    function ValidateKey(const ABearerToken: string): TMxAuthResult;
  end;

implementation

uses
  mx.Crypto;

constructor TMxAuthManager.Create(APool: TMxConnectionPool);
begin
  inherited Create;
  FPool := APool;
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
    Qry.ParamByName('hash').AsString := NewHash;
    Qry.ParamByName('prefix').AsString := Prefix;
    Qry.ParamByName('id').AsInteger := AKeyId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

function TMxAuthManager.ValidateKey(const ABearerToken: string): TMxAuthResult;
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

  RawKey := ABearerToken;
  if RawKey.StartsWith('Bearer ', True) then
    RawKey := RawKey.Substring(7).Trim;

  if RawKey = '' then
    Exit;

  Ctx := FPool.AcquireContext;
  Found := False;
  IsLegacy := False;
  Prefix := Copy(RawKey, 1, 12);

  // Step 1: Try PBKDF2 lookup via key_prefix
  Qry := Ctx.CreateQuery(
    'SELECT ck.id AS key_id, ck.name AS key_name, ck.permissions, ' +
    '       ck.key_hash, d.id AS dev_id, d.name AS dev_name ' +
    'FROM client_keys ck ' +
    'JOIN developers d ON ck.developer_id = d.id ' +
    'WHERE ck.key_prefix = :prefix ' +
    '  AND ck.is_active = TRUE ' +
    '  AND d.is_active = TRUE ' +
    '  AND (ck.expires_at IS NULL OR ck.expires_at > NOW())');
  try
    Qry.ParamByName('prefix').AsString := Prefix;
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
      '       d.id AS dev_id, d.name AS dev_name ' +
      'FROM client_keys ck ' +
      'JOIN developers d ON ck.developer_id = d.id ' +
      'WHERE ck.key_hash = :hash ' +
      '  AND ck.key_prefix IS NULL ' +
      '  AND ck.is_active = TRUE ' +
      '  AND d.is_active = TRUE ' +
      '  AND (ck.expires_at IS NULL OR ck.expires_at > NOW())');
    try
      Qry.ParamByName('hash').AsString := ComputeSHA256(RawKey);
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
        Ctx.Logger.Log(mlDebug, '[Auth] Key upgrade deferred: ' + E.Message);
    end;
  end;

  // Update last_used (fire-and-forget)
  try
    Qry := Ctx.CreateQuery(
      'UPDATE client_keys SET last_used_at = NOW() WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := Result.KeyId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      Ctx.Logger.Log(mlDebug, '[Auth] last_used update skipped: ' + E.Message);
  end;
end;

end.
