unit mx.Admin.Api.Keys;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool;

procedure HandleGetKeys(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
procedure HandleCreateKey(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
procedure HandleDeleteKey(const C: THttpServerContext;
  APool: TMxConnectionPool; AKeyId: Integer; AHardDelete: Boolean;
  ALogger: IMxLogger);
procedure HandleUpdateKey(const C: THttpServerContext;
  APool: TMxConnectionPool; AKeyId: Integer; ALogger: IMxLogger);
procedure HandleGetEnvironments(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
procedure HandleDeleteEnvironment(const C: THttpServerContext;
  APool: TMxConnectionPool; AEnvId: Integer; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, System.Hash, Data.DB,
  FireDAC.Comp.Client,
  mx.Admin.Server, mx.Crypto;

procedure HandleGetKeys(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT id, name, key_prefix, permissions, is_active, created_at, expires_at, ' +
    'last_used_at, last_used_ip ' +
    'FROM client_keys WHERE developer_id = :dev_id ORDER BY COALESCE(last_used_at, ''1970-01-01'') DESC, created_at DESC');
  try
    Qry.ParamByName('dev_id').AsInteger := ADevId;
    Qry.Open;

    Arr := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Obj.AddPair('name', Qry.FieldByName('name').AsString);
      if not Qry.FieldByName('key_prefix').IsNull then
        Obj.AddPair('key_prefix', Qry.FieldByName('key_prefix').AsString);
      Obj.AddPair('permissions', Qry.FieldByName('permissions').AsString);
      Obj.AddPair('is_active', TJSONBool.Create(Qry.FieldByName('is_active').AsBoolean));
      Obj.AddPair('created_at', MxDateStr(Qry.FieldByName('created_at')));
      if not Qry.FieldByName('expires_at').IsNull then
        Obj.AddPair('expires_at', MxDateStr(Qry.FieldByName('expires_at')))
      else
        Obj.AddPair('expires_at', TJSONNull.Create);
      if not Qry.FieldByName('last_used_at').IsNull then
        Obj.AddPair('last_used_at', MxDateStr(Qry.FieldByName('last_used_at')))
      else
        Obj.AddPair('last_used_at', TJSONNull.Create);
      if not Qry.FieldByName('last_used_ip').IsNull then
        Obj.AddPair('last_used_ip', Qry.FieldByName('last_used_ip').AsString)
      else
        Obj.AddPair('last_used_ip', TJSONNull.Create);
      Arr.AddElement(Obj);
      Qry.Next;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('keys', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Qry.Free;
  end;
end;

procedure HandleCreateKey(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Name, Permissions, ExpiresAt: string;
  RawKey, KeyHash, GuidStr: string;
  G: TGUID;
  NewId: Integer;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    Name := Body.GetValue<string>('name', '');
    Permissions := Body.GetValue<string>('permissions', 'read');
    ExpiresAt := Body.GetValue<string>('expires_at', '');

    if Name = '' then
    begin
      MxSendError(C, 400, 'missing_name');
      Exit;
    end;

    // Whitelist permissions (must match DB ENUM: read, readwrite, admin)
    if not SameText(Permissions, 'read') and
       not SameText(Permissions, 'readwrite') and
       not SameText(Permissions, 'admin') then
      Permissions := 'read';

    // Generate key: mxk_ + 32 hex chars from GUID
    CreateGUID(G);
    GuidStr := GUIDToString(G);
    GuidStr := StringReplace(GuidStr, '{', '', [rfReplaceAll]);
    GuidStr := StringReplace(GuidStr, '}', '', [rfReplaceAll]);
    GuidStr := StringReplace(GuidStr, '-', '', [rfReplaceAll]);
    RawKey := 'mxk_' + LowerCase(GuidStr);

    // PBKDF2-HMAC-SHA256 hash for storage
    KeyHash := MxHashKey(RawKey);

    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'INSERT INTO client_keys (developer_id, name, key_hash, key_prefix, permissions, expires_at) ' +
      'VALUES (:dev_id, :name, :hash, :prefix, :perms, :expires)');
    try
      Qry.ParamByName('dev_id').AsInteger := ADevId;
      Qry.ParamByName('name').AsString := Name;
      Qry.ParamByName('hash').AsString := KeyHash;
      Qry.ParamByName('prefix').AsString := Copy(RawKey, 1, 12);
      Qry.ParamByName('perms').AsString := Permissions;
      if ExpiresAt <> '' then
        Qry.ParamByName('expires').AsString := ExpiresAt
      else
      begin
        Qry.ParamByName('expires').DataType := ftDateTime;
        Qry.ParamByName('expires').Clear;
      end;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    Qry := Ctx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
    try
      Qry.Open;
      NewId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;

    ALogger.Log(mlInfo, 'Key created: ' + Name + ' for dev ' + IntToStr(ADevId));

    // Return plaintext key (shown ONCE only)
    Json := TJSONObject.Create;
    try
      Json.AddPair('id', TJSONNumber.Create(NewId));
      Json.AddPair('key', RawKey);
      Json.AddPair('name', Name);
      MxSendJson(C, 201, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleDeleteKey(const C: THttpServerContext;
  APool: TMxConnectionPool; AKeyId: Integer; AHardDelete: Boolean;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;

  if AHardDelete then
  begin
    // Kaskadierend: Environments loeschen die an Keys dieses IDs haengen
    Qry := Ctx.CreateQuery(
      'DELETE FROM developer_environments WHERE client_key_id = :id');
    try
      Qry.ParamByName('id').AsInteger := AKeyId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    Qry := Ctx.CreateQuery('DELETE FROM client_keys WHERE id = :id');
  end
  else
    Qry := Ctx.CreateQuery(
      'UPDATE client_keys SET is_active = FALSE WHERE id = :id');

  try
    Qry.ParamByName('id').AsInteger := AKeyId;
    Qry.ExecSQL;

    if Qry.RowsAffected = 0 then
    begin
      MxSendError(C, 404, 'key_not_found');
      Exit;
    end;
  finally
    Qry.Free;
  end;

  if AHardDelete then
    ALogger.Log(mlInfo, 'Key hard-deleted: ID ' + IntToStr(AKeyId))
  else
    ALogger.Log(mlInfo, 'Key deactivated: ID ' + IntToStr(AKeyId));

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

procedure HandleUpdateKey(const C: THttpServerContext;
  APool: TMxConnectionPool; AKeyId: Integer; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Permissions: string;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    Permissions := Body.GetValue<string>('permissions', '');
    if (Permissions = '') or
       (not SameText(Permissions, 'read') and
        not SameText(Permissions, 'readwrite') and
        not SameText(Permissions, 'admin')) then
    begin
      MxSendError(C, 400, 'invalid_permissions');
      Exit;
    end;

    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'UPDATE client_keys SET permissions = :perms WHERE id = :id');
    try
      Qry.ParamByName('perms').AsString := Permissions;
      Qry.ParamByName('id').AsInteger := AKeyId;
      Qry.ExecSQL;

      if Qry.RowsAffected = 0 then
      begin
        MxSendError(C, 404, 'key_not_found');
        Exit;
      end;
    finally
      Qry.Free;
    end;

    ALogger.Log(mlInfo, 'Key role changed: ID ' + IntToStr(AKeyId) +
      ' -> ' + Permissions);

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleGetEnvironments(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT de.id, de.env_key, de.env_value, ' +
    '  ck.name AS key_name, ' +
    '  COALESCE(p.slug, ''_global'') AS project_slug ' +
    'FROM developer_environments de ' +
    'JOIN client_keys ck ON ck.id = de.client_key_id ' +
    'LEFT JOIN projects p ON p.id = de.project_id ' +
    'WHERE ck.developer_id = :dev_id ' +
    'ORDER BY de.env_key, project_slug');
  try
    Qry.ParamByName('dev_id').AsInteger := ADevId;
    Qry.Open;

    Arr := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Obj.AddPair('env_key', Qry.FieldByName('env_key').AsString);
      Obj.AddPair('env_value', Qry.FieldByName('env_value').AsString);
      Obj.AddPair('key_name', Qry.FieldByName('key_name').AsString);
      Obj.AddPair('project', Qry.FieldByName('project_slug').AsString);
      Arr.AddElement(Obj);
      Qry.Next;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('environments', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Qry.Free;
  end;
end;

procedure HandleDeleteEnvironment(const C: THttpServerContext;
  APool: TMxConnectionPool; AEnvId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'DELETE FROM developer_environments WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := AEnvId;
    Qry.ExecSQL;

    if Qry.RowsAffected = 0 then
    begin
      MxSendError(C, 404, 'env_not_found');
      Exit;
    end;
  finally
    Qry.Free;
  end;

  ALogger.Log(mlInfo, 'Environment deleted: ID ' + IntToStr(AEnvId));

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
