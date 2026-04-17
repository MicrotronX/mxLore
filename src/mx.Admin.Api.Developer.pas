unit mx.Admin.Api.Developer;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool;

procedure HandleGetDevelopers(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
procedure HandleCreateDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
procedure HandleUpdateDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
procedure HandleDeleteDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; AHard: Boolean; ALogger: IMxLogger);
procedure HandleMergeDevelopers(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server;

procedure HandleGetDevelopers(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT d.id, d.name, d.email, d.role, d.is_active, d.ui_login_enabled, ' +
    '  (SELECT COUNT(*) FROM client_keys ck ' +
    '   WHERE ck.developer_id = d.id AND ck.is_active = TRUE) AS key_count, ' +
    '  (SELECT COUNT(*) FROM developer_project_access dpa ' +
    '   WHERE dpa.developer_id = d.id) AS project_count, ' +
    '  CASE ' +
    '    WHEN d.role = ''admin'' THEN ''admin'' ' +
    '    WHEN EXISTS (SELECT 1 FROM client_keys ck ' +
    '      WHERE ck.developer_id = d.id AND ck.permissions = ''admin'' ' +
    '      AND ck.is_active = TRUE) THEN ''admin'' ' +
    '    WHEN EXISTS (SELECT 1 FROM developer_project_access dpa ' +
    '      WHERE dpa.developer_id = d.id AND dpa.access_level = ''read-write'') ' +
    '      THEN ''read-write'' ' +
    '    WHEN EXISTS (SELECT 1 FROM developer_project_access dpa ' +
    '      WHERE dpa.developer_id = d.id AND dpa.access_level = ''read'') ' +
    '      THEN ''read'' ' +
    '    WHEN EXISTS (SELECT 1 FROM developer_project_access dpa ' +
    '      WHERE dpa.developer_id = d.id AND dpa.access_level = ''comment'') ' +
    '      THEN ''comment'' ' +
    '    ELSE ''none'' ' +
    '  END AS effective_level ' +
    'FROM developers d ORDER BY d.name');
  try
    Qry.Open;
    Arr := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Obj.AddPair('name', Qry.FieldByName('name').AsString);
      if not Qry.FieldByName('email').IsNull then
        Obj.AddPair('email', Qry.FieldByName('email').AsString)
      else
        Obj.AddPair('email', TJSONNull.Create);
      if not Qry.FieldByName('role').IsNull then
        Obj.AddPair('role', Qry.FieldByName('role').AsString)
      else
        Obj.AddPair('role', TJSONNull.Create);
      Obj.AddPair('is_active', TJSONBool.Create(Qry.FieldByName('is_active').AsBoolean));
      Obj.AddPair('ui_login_enabled', TJSONBool.Create(Qry.FieldByName('ui_login_enabled').AsBoolean));
      Obj.AddPair('effective_level', Qry.FieldByName('effective_level').AsString);
      Obj.AddPair('key_count', TJSONNumber.Create(Qry.FieldByName('key_count').AsInteger));
      Obj.AddPair('project_count', TJSONNumber.Create(Qry.FieldByName('project_count').AsInteger));
      Arr.AddElement(Obj);
      Qry.Next;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('developers', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Qry.Free;
  end;
end;

procedure HandleCreateDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Name, Email, Role: string;
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
    if Name = '' then
    begin
      MxSendError(C, 400, 'missing_name');
      Exit;
    end;

    Email := Body.GetValue<string>('email', '');
    Role := Body.GetValue<string>('role', '');

    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'INSERT INTO developers (name, email, role) VALUES (:name, :email, :role)');
    try
      Qry.ParamByName('name').AsString := Name;
      if Email <> '' then
        Qry.ParamByName('email').AsString := Email
      else
      begin
        Qry.ParamByName('email').DataType := ftString;
        Qry.ParamByName('email').Clear;
      end;
      if Role <> '' then
        Qry.ParamByName('role').AsString := Role
      else
      begin
        Qry.ParamByName('role').DataType := ftString;
        Qry.ParamByName('role').Clear;
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

    ALogger.Log(mlInfo, 'Developer created: ' + Name + ' (ID ' + IntToStr(NewId) + ')');

    Json := TJSONObject.Create;
    try
      Json.AddPair('id', TJSONNumber.Create(NewId));
      Json.AddPair('name', Name);
      MxSendJson(C, 201, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleUpdateDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Body: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Name, Email, Role, SQL, Sep, EffLvl: string;
  IsActive, UiLoginEnabled: Boolean;
  HasName, HasEmail, HasActive, HasRole, HasUiLogin: Boolean;
  EmailVal, RoleVal: TJSONValue;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    HasName := Body.TryGetValue<string>('name', Name);
    EmailVal := Body.FindValue('email');
    HasEmail := EmailVal <> nil;
    if HasEmail then
    begin
      if EmailVal is TJSONNull then
        Email := ''
      else
        Email := EmailVal.Value;
    end;
    RoleVal := Body.FindValue('role');
    HasRole := RoleVal <> nil;
    if HasRole then
    begin
      if RoleVal is TJSONNull then
        Role := ''
      else
        Role := RoleVal.Value;
    end;
    HasActive := Body.TryGetValue<Boolean>('is_active', IsActive);
    HasUiLogin := Body.TryGetValue<Boolean>('ui_login_enabled', UiLoginEnabled);

    if not (HasName or HasEmail or HasActive or HasRole or HasUiLogin) then
    begin
      MxSendError(C, 400, 'no_fields');
      Exit;
    end;

    Ctx := APool.AcquireContext;

    // Lock-Matrix server-side enforce (FR#2936 M2.1): admin / read-write force TRUE.
    if HasUiLogin then
    begin
      Qry := Ctx.CreateQuery(
        'SELECT CASE ' +
        '  WHEN d.role = ''admin'' THEN ''admin'' ' +
        '  WHEN EXISTS (SELECT 1 FROM client_keys ck ' +
        '    WHERE ck.developer_id = d.id AND ck.permissions = ''admin'' ' +
        '    AND ck.is_active = TRUE) THEN ''admin'' ' +
        '  WHEN EXISTS (SELECT 1 FROM developer_project_access dpa ' +
        '    WHERE dpa.developer_id = d.id AND dpa.access_level = ''read-write'') ' +
        '    THEN ''read-write'' ' +
        '  ELSE '''' ' +
        'END AS lvl FROM developers d WHERE d.id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.Open;
        if not Qry.Eof then
        begin
          EffLvl := Qry.FieldByName('lvl').AsString;
          if (EffLvl = 'admin') or (EffLvl = 'read-write') then
            UiLoginEnabled := True;
        end;
      finally
        Qry.Free;
      end;
    end;

    // Build dynamic UPDATE
    SQL := 'UPDATE developers SET ';
    Sep := '';
    if HasName then    begin SQL := SQL + Sep + 'name = :name';                   Sep := ', '; end;
    if HasEmail then   begin SQL := SQL + Sep + 'email = :email';                 Sep := ', '; end;
    if HasRole then    begin SQL := SQL + Sep + 'role = :role';                   Sep := ', '; end;
    if HasActive then  begin SQL := SQL + Sep + 'is_active = :active';            Sep := ', '; end;
    if HasUiLogin then begin SQL := SQL + Sep + 'ui_login_enabled = :uilogin';    Sep := ', '; end;
    SQL := SQL + ' WHERE id = :id';

    Ctx.StartTransaction;
    try
      Qry := Ctx.CreateQuery(SQL);
      try
        if HasName then
          Qry.ParamByName('name').AsString := Name;
        if HasEmail then
        begin
          if Email <> '' then
            Qry.ParamByName('email').AsString := Email
          else
          begin
            Qry.ParamByName('email').DataType := ftString;
            Qry.ParamByName('email').Clear;
          end;
        end;
        if HasRole then
        begin
          if Role <> '' then
            Qry.ParamByName('role').AsString := Role
          else
          begin
            Qry.ParamByName('role').DataType := ftString;
            Qry.ParamByName('role').Clear;
          end;
        end;
        if HasActive then
          Qry.ParamByName('active').AsBoolean := IsActive;
        if HasUiLogin then
          Qry.ParamByName('uilogin').AsBoolean := UiLoginEnabled;
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;

        if Qry.RowsAffected = 0 then
        begin
          Ctx.Rollback;
          MxSendError(C, 404, 'developer_not_found');
          Exit;
        end;
      finally
        Qry.Free;
      end;

      // Deactivating developer -> also deactivate all keys
      if HasActive and not IsActive then
      begin
        Qry := Ctx.CreateQuery(
          'UPDATE client_keys SET is_active = FALSE WHERE developer_id = :id');
        try
          Qry.ParamByName('id').AsInteger := ADevId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      end;

      Ctx.Commit;
    except
      Ctx.Rollback;
      raise;
    end;

    ALogger.Log(mlInfo, 'Developer updated: ID ' + IntToStr(ADevId));

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

procedure HandleDeleteDeveloper(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; AHard: Boolean; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Ctx.StartTransaction;
  try
    if AHard then
    begin
      // Hard-delete: remove all dependent data, then the developer
      Qry := Ctx.CreateQuery(
        'DELETE FROM admin_sessions WHERE developer_id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'DELETE FROM developer_project_access WHERE developer_id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'DELETE FROM invite_links WHERE developer_id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'DELETE FROM developer_environments WHERE client_key_id IN ' +
        '(SELECT id FROM client_keys WHERE developer_id = :id)');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'DELETE FROM client_keys WHERE developer_id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'DELETE FROM developers WHERE id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;

        if Qry.RowsAffected = 0 then
        begin
          Ctx.Rollback;
          MxSendError(C, 404, 'developer_not_found');
          Exit;
        end;
      finally
        Qry.Free;
      end;

      Ctx.Commit;
      ALogger.Log(mlInfo, 'Developer hard-deleted: ID ' + IntToStr(ADevId));
    end
    else
    begin
      // Soft-delete: deactivate keys + developer
      Qry := Ctx.CreateQuery(
        'UPDATE client_keys SET is_active = FALSE WHERE developer_id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := Ctx.CreateQuery(
        'UPDATE developers SET is_active = FALSE WHERE id = :id');
      try
        Qry.ParamByName('id').AsInteger := ADevId;
        Qry.ExecSQL;

        if Qry.RowsAffected = 0 then
        begin
          Ctx.Rollback;
          MxSendError(C, 404, 'developer_not_found');
          Exit;
        end;
      finally
        Qry.Free;
      end;

      Ctx.Commit;
      ALogger.Log(mlInfo, 'Developer deactivated: ID ' + IntToStr(ADevId));
    end;
  except
    Ctx.Rollback;
    raise;
  end;

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

procedure HandleMergeDevelopers(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  SourceIds: TJSONArray;
  SourceVal: TJSONValue;
  TargetId, SourceId, I: Integer;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    SourceVal := Body.FindValue('source_ids');
    if (SourceVal <> nil) and (SourceVal is TJSONArray) then
      SourceIds := TJSONArray(SourceVal)
    else
      SourceIds := nil;
    TargetId := Body.GetValue<Integer>('target_id', 0);

    if (SourceIds = nil) or (SourceIds.Count = 0) or (TargetId = 0) then
    begin
      MxSendError(C, 400, 'missing_fields');
      Exit;
    end;

    Ctx := APool.AcquireContext;

    // Validate target developer exists
    Qry := Ctx.CreateQuery(
      'SELECT id FROM developers WHERE id = :id AND is_active = TRUE');
    try
      Qry.ParamByName('id').AsInteger := TargetId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        MxSendError(C, 404, 'target_not_found');
        Exit;
      end;
    finally
      Qry.Free;
    end;

    Ctx.StartTransaction;
    try
      for I := 0 to SourceIds.Count - 1 do
      begin
        if not (SourceIds.Items[I] is TJSONNumber) then
          Continue;
        SourceId := TJSONNumber(SourceIds.Items[I]).AsInt;
        if (SourceId = TargetId) or (SourceId = 0) then
          Continue;

        // Move keys to target developer
        Qry := Ctx.CreateQuery(
          'UPDATE client_keys SET developer_id = :target ' +
          'WHERE developer_id = :source');
        try
          Qry.ParamByName('target').AsInteger := TargetId;
          Qry.ParamByName('source').AsInteger := SourceId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;

        // Merge project access (highest level wins)
        Qry := Ctx.CreateQuery(
          'INSERT INTO developer_project_access ' +
          '  (developer_id, project_id, access_level) ' +
          'SELECT :target, project_id, access_level ' +
          'FROM developer_project_access WHERE developer_id = :source ' +
          'ON DUPLICATE KEY UPDATE access_level = ' +
          '  CASE WHEN VALUES(access_level) = ''write'' ' +
          '    OR developer_project_access.access_level = ''write'' ' +
          '  THEN ''write'' ELSE developer_project_access.access_level END');
        try
          Qry.ParamByName('target').AsInteger := TargetId;
          Qry.ParamByName('source').AsInteger := SourceId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;

        // Remove old project access
        Qry := Ctx.CreateQuery(
          'DELETE FROM developer_project_access WHERE developer_id = :source');
        try
          Qry.ParamByName('source').AsInteger := SourceId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;

        // Move admin sessions
        Qry := Ctx.CreateQuery(
          'UPDATE admin_sessions SET developer_id = :target ' +
          'WHERE developer_id = :source');
        try
          Qry.ParamByName('target').AsInteger := TargetId;
          Qry.ParamByName('source').AsInteger := SourceId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;

        // Deactivate source developer
        Qry := Ctx.CreateQuery(
          'UPDATE developers SET is_active = FALSE WHERE id = :source');
        try
          Qry.ParamByName('source').AsInteger := SourceId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      end;

      Ctx.Commit;
    except
      Ctx.Rollback;
      raise;
    end;

    ALogger.Log(mlInfo, 'Developers merged into target ID ' + IntToStr(TargetId));

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

end.
