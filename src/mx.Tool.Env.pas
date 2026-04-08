unit mx.Tool.Env;

interface

uses
  System.SysUtils, System.JSON, Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool;

function HandleSetEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleGetEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleDeleteEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// Helper: Resolve _global project ID
// ---------------------------------------------------------------------------
function GetGlobalProjectId(AContext: IMxDbContext): Integer;
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = ''_global'' LIMIT 1');
  try
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('global_project_missing', '_global project not found');
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Resolve project by slug
// ---------------------------------------------------------------------------
function ResolveProjectId(AContext: IMxDbContext; const ASlug: string): Integer;
var
  Qry: TFDQuery;
begin
  if (ASlug = '') or (ASlug = '_global') then
    Exit(GetGlobalProjectId(AContext));
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ASlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('project_not_found', 'Project not found: ' + ASlug);
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Validate env key (alphanumeric + underscore, starts with letter/_)
// ---------------------------------------------------------------------------
function IsValidEnvKey(const AKey: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  if AKey = '' then
    Exit(False);
  C := AKey[1];
  if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or (C = '_')) then
    Exit(False);
  for I := 2 to Length(AKey) do
  begin
    C := AKey[I];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z'))
        or ((C >= '0') and (C <= '9')) or (C = '_')) then
      Exit(False);
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// HandleSetEnv
// ---------------------------------------------------------------------------
function HandleSetEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  EnvKey, EnvValue, ProjectSlug: string;
  KeyId, ProjectId: Integer;
  Auth: TMxAuthResult;
  Qry: TFDQuery;
begin
  EnvKey := '';
  EnvValue := '';
  ProjectSlug := '_global';

  if AParams.GetValue('key') <> nil then
    EnvKey := AParams.GetValue<string>('key', '');
  if AParams.GetValue('env_value') <> nil then
    EnvValue := AParams.GetValue<string>('env_value', '');
  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '_global');

  // Validate
  if EnvKey.Trim = '' then
    raise EMxError.Create('missing_key', 'key is required');
  if Length(EnvKey) > 100 then
    raise EMxError.Create('key_too_long', 'key must be <= 100 characters');
  if not IsValidEnvKey(EnvKey) then
    raise EMxError.Create('invalid_key', 'key must be alphanumeric with underscores');
  if EnvValue.Trim = '' then
    raise EMxError.Create('missing_value', 'value is required');
  if Length(EnvValue) > 500 then
    raise EMxError.Create('value_too_long', 'value must be <= 500 characters');

  // Get client key ID from auth context
  Auth := MxGetThreadAuth;
  KeyId := Auth.KeyId;
  if KeyId = 0 then
    raise EMxError.Create('no_key_id', 'Could not determine client key');

  // Resolve project
  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  // Upsert
  Qry := AContext.CreateQuery(
    'INSERT INTO developer_environments (client_key_id, project_id, env_key, env_value) ' +
    'VALUES (:key_id, :proj_id, :env_key, :val) ' +
    'ON DUPLICATE KEY UPDATE env_value = :upd_val, updated_at = NOW()');
  try
    Qry.ParamByName('key_id').AsInteger := KeyId;
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    Qry.ParamByName('env_key').AsString := EnvKey;
    Qry.ParamByName('val').AsString := EnvValue;
    Qry.ParamByName('upd_val').AsString := EnvValue;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONBool.Create(True));
  Result.AddPair('key', EnvKey);
  Result.AddPair('project', ProjectSlug);
end;

// ---------------------------------------------------------------------------
// HandleGetEnv
// ---------------------------------------------------------------------------
function HandleGetEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  EnvKey, ProjectSlug: string;
  KeyId, DeveloperId, ProjectId, GlobalId: Integer;
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj: TJSONObject;
begin
  EnvKey := '';
  ProjectSlug := '';

  if AParams.GetValue('key') <> nil then
    EnvKey := AParams.GetValue<string>('key', '');
  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '');

  Auth := MxGetThreadAuth;
  KeyId := Auth.KeyId;
  DeveloperId := Auth.DeveloperId;
  if KeyId = 0 then
    raise EMxError.Create('no_key_id', 'Could not determine client key');

  GlobalId := GetGlobalProjectId(AContext);

  if EnvKey <> '' then
  begin
    // Single key lookup with fallback chain: Key → Developer → _global
    if ProjectSlug <> '' then
      ProjectId := ResolveProjectId(AContext, ProjectSlug)
    else
      ProjectId := GlobalId;

    // Fallback chain: 1) this key+project, 2) this key+global,
    // 3) other key of same dev+project, 4) other key of same dev+global
    Qry := AContext.CreateQuery(
      'SELECT env_value, ' +
      '  CASE ' +
      '    WHEN client_key_id = :key_id AND project_id = :proj_id THEN ''key'' ' +
      '    WHEN client_key_id = :key_id2 THEN ''key'' ' +
      '    WHEN project_id = :proj_id2 THEN ''developer'' ' +
      '    ELSE ''global'' ' +
      '  END AS source ' +
      'FROM developer_environments ' +
      'WHERE client_key_id IN ' +
      '  (SELECT id FROM client_keys WHERE developer_id = :dev_id AND is_active = TRUE) ' +
      '  AND env_key = :env_key ' +
      '  AND project_id IN (:proj_id3, :global_id) ' +
      'ORDER BY ' +
      '  CASE WHEN client_key_id = :key_id3 THEN 0 ELSE 1 END, ' +
      '  CASE WHEN project_id = :proj_id4 THEN 0 ELSE 1 END ' +
      'LIMIT 1');
    try
      Qry.ParamByName('key_id').AsInteger := KeyId;
      Qry.ParamByName('key_id2').AsInteger := KeyId;
      Qry.ParamByName('key_id3').AsInteger := KeyId;
      Qry.ParamByName('dev_id').AsInteger := DeveloperId;
      Qry.ParamByName('env_key').AsString := EnvKey;
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ParamByName('proj_id2').AsInteger := ProjectId;
      Qry.ParamByName('proj_id3').AsInteger := ProjectId;
      Qry.ParamByName('proj_id4').AsInteger := ProjectId;
      Qry.ParamByName('global_id').AsInteger := GlobalId;
      Qry.Open;

      Result := TJSONObject.Create;
      if Qry.IsEmpty then
      begin
        Result.AddPair('found', TJSONBool.Create(False));
        Result.AddPair('key', EnvKey);
      end
      else
      begin
        Result.AddPair('found', TJSONBool.Create(True));
        Result.AddPair('key', EnvKey);
        Result.AddPair('value', Qry.FieldByName('env_value').AsString);
        Result.AddPair('source', Qry.FieldByName('source').AsString);
      end;
    finally
      Qry.Free;
    end;
  end
  else
  begin
    // All keys for this client
    Arr := TJSONArray.Create;
    try
      Qry := AContext.CreateQuery(
        'SELECT de.env_key, de.env_value, p.slug AS project_slug, ' +
        '  CASE WHEN de.project_id = :global_id THEN ''global'' ELSE ''project'' END AS source ' +
        'FROM developer_environments de ' +
        'JOIN projects p ON de.project_id = p.id ' +
        'WHERE de.client_key_id = :key_id ' +
        'ORDER BY de.env_key, source');
      try
        Qry.ParamByName('key_id').AsInteger := KeyId;
        Qry.ParamByName('global_id').AsInteger := GlobalId;
        Qry.Open;

        while not Qry.Eof do
        begin
          Obj := TJSONObject.Create;
          Obj.AddPair('key', Qry.FieldByName('env_key').AsString);
          Obj.AddPair('value', Qry.FieldByName('env_value').AsString);
          Obj.AddPair('project', Qry.FieldByName('project_slug').AsString);
          Obj.AddPair('source', Qry.FieldByName('source').AsString);
          Arr.AddElement(Obj);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      Result := TJSONObject.Create;
      Result.AddPair('environments', Arr);
    except
      Arr.Free;
      raise;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// HandleDeleteEnv
// ---------------------------------------------------------------------------
function HandleDeleteEnv(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  EnvKey, ProjectSlug: string;
  KeyId, ProjectId: Integer;
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  Deleted: Boolean;
begin
  EnvKey := '';
  ProjectSlug := '_global';

  if AParams.GetValue('key') <> nil then
    EnvKey := AParams.GetValue<string>('key', '');
  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '_global');

  if EnvKey.Trim = '' then
    raise EMxError.Create('missing_key', 'key is required');

  Auth := MxGetThreadAuth;
  KeyId := Auth.KeyId;
  if KeyId = 0 then
    raise EMxError.Create('no_key_id', 'Could not determine client key');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  Qry := AContext.CreateQuery(
    'DELETE FROM developer_environments ' +
    'WHERE client_key_id = :key_id AND project_id = :proj_id AND env_key = :env_key');
  try
    Qry.ParamByName('key_id').AsInteger := KeyId;
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    Qry.ParamByName('env_key').AsString := EnvKey;
    Qry.ExecSQL;
    Deleted := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONBool.Create(True));
  Result.AddPair('deleted', TJSONBool.Create(Deleted));
end;

end.
