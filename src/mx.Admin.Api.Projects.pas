unit mx.Admin.Api.Projects;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool;

procedure HandleGetProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
procedure HandleCreateProject(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
procedure HandleUpdateProject(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);
procedure HandleDeleteProject(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; AHard: Boolean; ALogger: IMxLogger);
procedure HandleMergeProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandleGetDevProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
procedure HandleUpdateDevProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);

procedure HandleGetDashboard(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server, mx.Logic.Projects;

procedure HandleGetProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
  LastAct: string;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT id, slug, name, is_active, doc_count, developer_count, ' +
    '  last_activity, created_at, deleted_at, created_by_developer_id, created_by_name ' +
    'FROM v_admin_project_overview ORDER BY name');
  try
    Qry.Open;
    Arr := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Obj.AddPair('slug', Qry.FieldByName('slug').AsString);
      Obj.AddPair('name', Qry.FieldByName('name').AsString);
      Obj.AddPair('is_active', TJSONBool.Create(Qry.FieldByName('is_active').AsBoolean));
      Obj.AddPair('doc_count', TJSONNumber.Create(Qry.FieldByName('doc_count').AsInteger));
      Obj.AddPair('developer_count', TJSONNumber.Create(Qry.FieldByName('developer_count').AsInteger));
      if Qry.FieldByName('last_activity').IsNull then
        Obj.AddPair('last_activity', TJSONNull.Create)
      else
        Obj.AddPair('last_activity', MxDateStr(Qry.FieldByName('last_activity')));
      Obj.AddPair('created_at', MxDateStr(Qry.FieldByName('created_at')));
      if Qry.FieldByName('deleted_at').IsNull then
        Obj.AddPair('deleted_at', TJSONNull.Create)
      else
        Obj.AddPair('deleted_at', MxDateStr(Qry.FieldByName('deleted_at')));
      Obj.AddPair('created_by_name', Qry.FieldByName('created_by_name').AsString);
      if Qry.FieldByName('created_by_developer_id').IsNull then
        Obj.AddPair('created_by_developer_id', TJSONNull.Create)
      else
        Obj.AddPair('created_by_developer_id',
          TJSONNumber.Create(Qry.FieldByName('created_by_developer_id').AsInteger));
      Arr.AddElement(Obj);
      Qry.Next;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('projects', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Qry.Free;
  end;
end;

procedure HandleCreateProject(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Mgr: TMxProjectManager;
  Name, Slug: string;
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
    Slug := Body.GetValue<string>('slug', '');

    if Name.Trim.IsEmpty or Slug.Trim.IsEmpty then
    begin
      MxSendError(C, 400, 'name_and_slug_required');
      Exit;
    end;

    Mgr := TMxProjectManager.Create(APool, ALogger);
    try
      try
        NewId := Mgr.CreateProject(Name, Slug);
      except
        on E: Exception do
        begin
          if E.Message = 'slug_exists' then
            MxSendError(C, 409, 'slug_exists')
          else
            MxSendError(C, 500, 'internal_error');
          Exit;
        end;
      end;
    finally
      Mgr.Free;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('project', TJSONObject.Create
        .AddPair('id', TJSONNumber.Create(NewId))
        .AddPair('slug', Slug));
      MxSendJson(C, 201, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleUpdateProject(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Mgr: TMxProjectManager;
  Name: string;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    Name := Body.GetValue<string>('name', '');
    if Name.Trim.IsEmpty then
    begin
      MxSendError(C, 400, 'name_required');
      Exit;
    end;

    Mgr := TMxProjectManager.Create(APool, ALogger);
    try
      try
        Mgr.UpdateProject(AProjId, Name,
          Body.GetValue<Integer>('created_by_developer_id', -1));
      except
        on E: Exception do
        begin
          if E.Message = 'project_not_found' then
            MxSendError(C, 404, 'project_not_found')
          else
            MxSendError(C, 500, 'internal_error');
          Exit;
        end;
      end;
    finally
      Mgr.Free;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('project', TJSONObject.Create
        .AddPair('id', TJSONNumber.Create(AProjId)));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleDeleteProject(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; AHard: Boolean; ALogger: IMxLogger);
var
  Mgr: TMxProjectManager;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  // Prevent deletion of _global sentinel project
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery('SELECT slug FROM projects WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := AProjId;
    Qry.Open;
    if (not Qry.IsEmpty) and (Qry.FieldByName('slug').AsString = '_global') then
    begin
      MxSendError(C, 400, 'cannot_delete_global_project');
      Exit;
    end;
  finally
    Qry.Free;
  end;

  if AHard then
  begin
    Ctx.StartTransaction;
    try
      // Delete all dependent data
      Qry := Ctx.CreateQuery('DELETE FROM doc_relations WHERE source_doc_id IN ' +
        '(SELECT id FROM documents WHERE project_id = :id) OR target_doc_id IN ' +
        '(SELECT id FROM documents WHERE project_id = :id)');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM doc_tags WHERE doc_id IN ' +
        '(SELECT id FROM documents WHERE project_id = :id)');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM doc_revisions WHERE doc_id IN ' +
        '(SELECT id FROM documents WHERE project_id = :id)');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM sessions WHERE project_id = :id');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM documents WHERE project_id = :id');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM developer_project_access WHERE project_id = :id');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM developer_environments WHERE project_id = :id');
      try Qry.ParamByName('id').AsInteger := AProjId; Qry.ExecSQL; finally Qry.Free; end;

      Qry := Ctx.CreateQuery('DELETE FROM projects WHERE id = :id');
      try
        Qry.ParamByName('id').AsInteger := AProjId;
        Qry.ExecSQL;
        if Qry.RowsAffected = 0 then
        begin
          Ctx.Rollback;
          MxSendError(C, 404, 'project_not_found');
          Exit;
        end;
      finally
        Qry.Free;
      end;

      Ctx.Commit;
      ALogger.Log(mlInfo, 'Project hard-deleted: ID ' + IntToStr(AProjId));
    except
      Ctx.Rollback;
      raise;
    end;
  end
  else
  begin
    Mgr := TMxProjectManager.Create(APool, ALogger);
    try
      try
        Mgr.SoftDelete(AProjId);
      except
        on E: Exception do
        begin
          if E.Message = 'project_not_found' then
            MxSendError(C, 404, 'project_not_found')
          else
            MxSendError(C, 500, 'internal_error');
          Exit;
        end;
      end;
    finally
      Mgr.Free;
    end;
  end;

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

procedure HandleMergeProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Body, Json, ConflictObj: TJSONObject;
  Mgr: TMxProjectManager;
  SourceIds: TJSONArray;
  SourceVal: TJSONValue;
  TargetId, I, MovedDocs: Integer;
  Ids: TArray<Integer>;
  Conflicts: TArray<TMxMergeConflict>;
  ConflictArr: TJSONArray;
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

    // Build source ID array (skip non-numeric and zero entries)
    SetLength(Ids, 0);
    for I := 0 to SourceIds.Count - 1 do
    begin
      if (SourceIds.Items[I] is TJSONNumber) and
         (TJSONNumber(SourceIds.Items[I]).AsInt > 0) then
      begin
        SetLength(Ids, Length(Ids) + 1);
        Ids[High(Ids)] := TJSONNumber(SourceIds.Items[I]).AsInt;
      end;
    end;

    if Length(Ids) = 0 then
    begin
      MxSendError(C, 400, 'no_valid_source_ids');
      Exit;
    end;

    Mgr := TMxProjectManager.Create(APool, ALogger);
    try
      // Check for conflicts first
      Conflicts := Mgr.CheckMergeConflicts(Ids, TargetId);
      if Length(Conflicts) > 0 then
      begin
        Json := TJSONObject.Create;
        try
          Json.AddPair('error', 'merge_conflict');
          ConflictArr := TJSONArray.Create;
          for I := 0 to High(Conflicts) do
          begin
            ConflictObj := TJSONObject.Create;
            ConflictObj.AddPair('doc_type', Conflicts[I].DocType);
            ConflictObj.AddPair('slug', Conflicts[I].Slug);
            ConflictObj.AddPair('source_project_id',
              TJSONNumber.Create(Conflicts[I].SourceProjectId));
            ConflictObj.AddPair('source_project_name',
              Conflicts[I].SourceProjectName);
            ConflictArr.AddElement(ConflictObj);
          end;
          Json.AddPair('conflicts', ConflictArr);
          MxSendJson(C, 409, Json);
        finally
          Json.Free;
        end;
        Exit;
      end;

      // No conflicts — merge
      Mgr.MergeTo(Ids, TargetId, MovedDocs);
    finally
      Mgr.Free;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('moved_docs', TJSONNumber.Create(MovedDocs));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

// === Developer-Project Assignments (unchanged) ===

procedure HandleGetDevProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT dpa.project_id, p.name, p.slug, dpa.access_level ' +
    'FROM developer_project_access dpa ' +
    'JOIN projects p ON dpa.project_id = p.id ' +
    'WHERE dpa.developer_id = :dev_id ORDER BY p.name');
  try
    Qry.ParamByName('dev_id').AsInteger := ADevId;
    Qry.Open;

    Arr := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('project_id', TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
      Obj.AddPair('name', Qry.FieldByName('name').AsString);
      Obj.AddPair('slug', Qry.FieldByName('slug').AsString);
      Obj.AddPair('access_level', Qry.FieldByName('access_level').AsString);
      Arr.AddElement(Obj);
      Qry.Next;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('projects', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Qry.Free;
  end;
end;

procedure HandleUpdateDevProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; ADevId: Integer; ALogger: IMxLogger);
var
  Body, Json, ProjObj: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ProjectsArr: TJSONArray;
  ProjectsVal: TJSONValue;
  I, ProjId: Integer;
  Level: string;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    ProjectsVal := Body.FindValue('projects');
    if (ProjectsVal <> nil) and (ProjectsVal is TJSONArray) then
      ProjectsArr := TJSONArray(ProjectsVal)
    else
      ProjectsArr := nil;
    if ProjectsArr = nil then
    begin
      MxSendError(C, 400, 'missing_projects');
      Exit;
    end;

    Ctx := APool.AcquireContext;
    Ctx.StartTransaction;
    try
      // Delete old assignments
      Qry := Ctx.CreateQuery(
        'DELETE FROM developer_project_access WHERE developer_id = :dev_id');
      try
        Qry.ParamByName('dev_id').AsInteger := ADevId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      // Insert new assignments
      for I := 0 to ProjectsArr.Count - 1 do
      begin
        if not (ProjectsArr.Items[I] is TJSONObject) then
          Continue;
        ProjObj := TJSONObject(ProjectsArr.Items[I]);
        ProjId := ProjObj.GetValue<Integer>('project_id', 0);
        Level := ProjObj.GetValue<string>('access_level', 'read');

        if ProjId = 0 then Continue;

        // Whitelist access_level
        if not SameText(Level, 'read') and not SameText(Level, 'write') then
          Level := 'read';

        Qry := Ctx.CreateQuery(
          'INSERT INTO developer_project_access ' +
          '  (developer_id, project_id, access_level) ' +
          'VALUES (:dev_id, :proj_id, :level)');
        try
          Qry.ParamByName('dev_id').AsInteger := ADevId;
          Qry.ParamByName('proj_id').AsInteger := ProjId;
          Qry.ParamByName('level').AsString := Level;
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

    ALogger.Log(mlInfo, 'Project access updated for dev ' + IntToStr(ADevId));

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

procedure HandleGetDashboard(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, DocTypes: TJSONObject;
  Changes, Devs, Rels: TJSONArray;
begin
  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // Doc counts by type
    DocTypes := TJSONObject.Create;
    Qry := Ctx.CreateQuery(
      'SELECT doc_type, COUNT(*) AS cnt FROM documents ' +
      'WHERE project_id = :pid AND status != ''deleted'' GROUP BY doc_type');
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      Qry.Open;
      while not Qry.Eof do
      begin
        DocTypes.AddPair(Qry.FieldByName('doc_type').AsString,
          TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('doc_types', DocTypes);

    // Recent changes (last 10)
    Changes := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT d.title, d.doc_type, dr.changed_by, dr.change_reason, dr.changed_at ' +
      'FROM doc_revisions dr ' +
      'JOIN documents d ON dr.doc_id = d.id ' +
      'WHERE d.project_id = :pid ' +
      'ORDER BY dr.changed_at DESC LIMIT 10');
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Item := TJSONObject.Create;
        Item.AddPair('title', Qry.FieldByName('title').AsString);
        Item.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Item.AddPair('changed_by', Qry.FieldByName('changed_by').AsString);
        Item.AddPair('reason', Qry.FieldByName('change_reason').AsString);
        Item.AddPair('changed_at', MxDateStr(Qry.FieldByName('changed_at')));
        Changes.Add(Item);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('recent_changes', Changes);

    // Developers with access
    Devs := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.name, dpa.access_level ' +
      'FROM developer_project_access dpa ' +
      'JOIN developers d ON dpa.developer_id = d.id ' +
      'WHERE dpa.project_id = :pid AND d.is_active = TRUE ' +
      'ORDER BY d.name');
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Dev := TJSONObject.Create;
        Dev.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Dev.AddPair('name', Qry.FieldByName('name').AsString);
        Dev.AddPair('access_level', Qry.FieldByName('access_level').AsString);
        Devs.Add(Dev);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('developers', Devs);

    // Related projects
    Rels := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT p.id, p.slug, p.name, pr.relation_type, ''outgoing'' AS direction ' +
      'FROM project_relations pr ' +
      'JOIN projects p ON pr.target_project_id = p.id ' +
      'WHERE pr.source_project_id = :pid ' +
      'UNION ALL ' +
      'SELECT p.id, p.slug, p.name, pr.relation_type, ' +
      'CASE WHEN pr.relation_type = ''related_to'' THEN ''outgoing'' ELSE ''incoming'' END AS direction ' +
      'FROM project_relations pr ' +
      'JOIN projects p ON pr.source_project_id = p.id ' +
      'WHERE pr.target_project_id = :pid2 ' +
      'ORDER BY direction, name');
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      Qry.ParamByName('pid2').AsInteger := AProjId;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Rel := TJSONObject.Create;
        Rel.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Rel.AddPair('slug', Qry.FieldByName('slug').AsString);
        Rel.AddPair('name', Qry.FieldByName('name').AsString);
        Rel.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
        Rel.AddPair('direction', Qry.FieldByName('direction').AsString);
        Rels.Add(Rel);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('related_projects', Rels);

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Dashboard error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

end.
