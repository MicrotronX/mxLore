unit mx.Admin.Api.Projects;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Admin.Auth;

// FR#4006 / Plan#4007 M2: non-admin callers see only projects they hold
// developer_project_access rows for. Admin (ASession.IsAdmin) bypasses
// the filter. Session passed by server-router.
procedure HandleGetProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
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
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3353 Phase A Gap#2: PUT /projects/:id/access { developer_id, access_level }
procedure HandleSetProjectAccess(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);

// FR#3353 Phase C: GET /projects/:id/documents?type=&q=&status=&limit=&offset=
// FR#4006 / Plan#4007 M2: non-admin callers need project-ACL read (row presence).
procedure HandleListProjectDocs(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3353 Phase C: GET /docs/:id — full document detail (view-only)
// FR#4006 / Plan#4007 M2: non-admin callers get 403 when the doc's project
// is outside their ACL.
procedure HandleGetDocDetail(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3353 Phase C: DELETE /docs/:id — soft-delete (status='deleted')
// FR#4006 / Plan#4007 M2: non-admin callers need project-ACL read-write
// (ACL row presence; granular level-check out-of-scope for this milestone).
procedure HandleDeleteDoc(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3353 Phase C: PUT /docs/:id — admin-side content/title/summary/status edit
// FR#4006 / Plan#4007 M2: non-admin callers need project-ACL (row presence).
procedure HandleUpdateDocAdmin(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3353 Phase C: DELETE /relations/:id — remove single doc_relations row
procedure HandleDeleteRelation(const C: THttpServerContext;
  APool: TMxConnectionPool; ARelId: Integer; ALogger: IMxLogger);

// FR#3353 Phase C: DELETE /project-relations/:id — remove project_relations row
procedure HandleDeleteProjectRelation(const C: THttpServerContext;
  APool: TMxConnectionPool; ARelId: Integer; ALogger: IMxLogger);

// FR#3472 A (SPEC#3583): GET /docs/:id/thread — hierarchischer Review-Thread
// ausgehend von Doc :id, via WITH RECURSIVE CTE ueber doc_relations.review-on.
// depth<10 cap + LIMIT 200 rows.
// FR#4006 / Plan#4007 M2: non-admin callers get 403 when the root doc's
// project is outside their ACL (404->403 info-leak collapse like GetDocDetail).
procedure HandleGetDocThread(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

// FR#3472 C (SPEC#3583): GET /projects/:id/reviews — Root-Aggregate aller
// Review-Threads im Projekt (Docs mit review-Kindern), 1-Query GROUP BY
// root_parent_doc_id, ORDER BY last_activity DESC, LIMIT 100.
// FR#4006 / Plan#4007 M2: non-admin callers need project-ACL read.
procedure HandleListProjectReviews(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.StrUtils, System.JSON, System.Math,
  System.Net.URLClient,
  Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server, mx.Logic.Projects;

procedure HandleGetProjects(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
  LastAct, SQL: string;
begin
  Ctx := APool.AcquireContext;
  // FR#4006 / Plan#4007 M2: admin sees all projects; non-admin filtered by
  // developer_project_access membership (row-presence, any level).
  SQL :=
    'SELECT id, slug, name, is_active, doc_count, developer_count, ' +
    '  last_activity, created_at, deleted_at, created_by_developer_id, created_by_name ' +
    'FROM v_admin_project_overview ';
  if not ASession.IsAdmin then
    SQL := SQL +
      'WHERE id IN (SELECT project_id FROM developer_project_access ' +
      '             WHERE developer_id = :dev_id) ';
  SQL := SQL + 'ORDER BY name';
  Qry := Ctx.CreateQuery(SQL);
  try
    if not ASession.IsAdmin then
      Qry.ParamByName('dev_id').AsInteger := ASession.DeveloperId;
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

        // Whitelist access_level (Bug#3356 M1 4-level ACL per ADR#3264)
        if not SameText(Level, 'none') and
           not SameText(Level, 'comment') and
           not SameText(Level, 'read') and
           not SameText(Level, 'read-write') then
          Level := 'read';
        // 'none' = skip insert (= no access row)
        if SameText(Level, 'none') then Continue;

        Qry := Ctx.CreateQuery(
          'INSERT INTO developer_project_access ' +
          '  (developer_id, project_id, access_level) ' +
          'VALUES (:dev_id, :proj_id, :level)');
        try
          Qry.ParamByName('dev_id').AsInteger := ADevId;
          Qry.ParamByName('proj_id').AsInteger := ProjId;
          Qry.ParamByName('level').AsWideString :=Level;
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

procedure HandleSetProjectAccess(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer; ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  DevId: Integer;
  Level: string;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;
  try
    DevId := Body.GetValue<Integer>('developer_id', 0);
    Level := Body.GetValue<string>('access_level', '');
    if (DevId = 0) or (AProjId = 0) then
    begin
      MxSendError(C, 400, 'missing_ids');
      Exit;
    end;

    // Whitelist per ADR#3264 — 'none' = delete row
    if not SameText(Level, 'none') and
       not SameText(Level, 'comment') and
       not SameText(Level, 'read') and
       not SameText(Level, 'read-write') then
    begin
      MxSendError(C, 400, 'invalid_access_level');
      Exit;
    end;

    Ctx := APool.AcquireContext;
    if SameText(Level, 'none') then
    begin
      // Remove access
      Qry := Ctx.CreateQuery(
        'DELETE FROM developer_project_access ' +
        'WHERE developer_id = :dev_id AND project_id = :proj_id');
      try
        Qry.ParamByName('dev_id').AsInteger := DevId;
        Qry.ParamByName('proj_id').AsInteger := AProjId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    end
    else
    begin
      // Upsert
      Qry := Ctx.CreateQuery(
        'INSERT INTO developer_project_access ' +
        '  (developer_id, project_id, access_level) ' +
        'VALUES (:dev_id, :proj_id, :level) ' +
        'ON DUPLICATE KEY UPDATE access_level = VALUES(access_level)');
      try
        Qry.ParamByName('dev_id').AsInteger := DevId;
        Qry.ParamByName('proj_id').AsInteger := AProjId;
        Qry.ParamByName('level').AsWideString :=LowerCase(Level);
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    end;

    ALogger.Log(mlInfo, Format(
      'Project access set: proj=%d dev=%d level=%s',
      [AProjId, DevId, Level]));

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('access_level', LowerCase(Level));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleGetDashboard(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, DocTypes: TJSONObject;
  Changes, Devs, Rels: TJSONArray;
begin
  // FR#4006 / Plan#4007 M2: non-admin must hold an ACL row for this
  // project, else 403. Admin bypasses.
  if (not ASession.IsAdmin) and
     (not DeveloperHasProjectAccess(APool, ASession.DeveloperId, AProjId)) then
  begin
    MxSendError(C, 403, 'forbidden');
    Exit;
  end;

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

    // Developers with access (FR#3353 Phase A: enrich with UI-Login + Key-Stats)
    Devs := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.name, dpa.access_level, ' +
      '       d.ui_login_enabled, d.accept_agent_messages, ' +
      '       COALESCE(ks.active_keys, 0) AS active_keys, ' +
      '       ks.next_expiry, ' +
      '       COALESCE(ks.revoked_keys, 0) AS revoked_keys ' +
      'FROM developer_project_access dpa ' +
      'JOIN developers d ON dpa.developer_id = d.id ' +
      'LEFT JOIN ( ' +
      '  SELECT developer_id, ' +
      '    SUM(CASE WHEN revoked_at IS NULL THEN 1 ELSE 0 END) AS active_keys, ' +
      '    MIN(CASE WHEN revoked_at IS NULL THEN expires_at END) AS next_expiry, ' +
      '    SUM(CASE WHEN revoked_at IS NOT NULL THEN 1 ELSE 0 END) AS revoked_keys ' +
      '  FROM client_keys GROUP BY developer_id ' +
      ') ks ON ks.developer_id = d.id ' +
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
        Dev.AddPair('ui_login_enabled',
          TJSONBool.Create(Qry.FieldByName('ui_login_enabled').AsBoolean));
        Dev.AddPair('accept_agent_messages',
          TJSONBool.Create(Qry.FieldByName('accept_agent_messages').AsBoolean));
        Dev.AddPair('active_keys',
          TJSONNumber.Create(Qry.FieldByName('active_keys').AsInteger));
        Dev.AddPair('revoked_keys',
          TJSONNumber.Create(Qry.FieldByName('revoked_keys').AsInteger));
        if Qry.FieldByName('next_expiry').IsNull then
          Dev.AddPair('next_expiry', TJSONNull.Create)
        else
          Dev.AddPair('next_expiry',
            MxDateStr(Qry.FieldByName('next_expiry')));
        Devs.Add(Dev);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('developers', Devs);

    // Related projects (incl. pr.id for delete)
    Rels := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT pr.id AS rel_id, p.id, p.slug, p.name, pr.relation_type, ''outgoing'' AS direction ' +
      'FROM project_relations pr ' +
      'JOIN projects p ON pr.target_project_id = p.id ' +
      'WHERE pr.source_project_id = :pid ' +
      'UNION ALL ' +
      'SELECT pr.id AS rel_id, p.id, p.slug, p.name, pr.relation_type, ' +
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
        Rel.AddPair('rel_id', TJSONNumber.Create(Qry.FieldByName('rel_id').AsInteger));
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

// Local helper: URL-decode + param extraction from a query string like
//   'type=spec&q=Hello%20World&limit=50'
function QGet(const AQuery, AName: string): string;
var
  Q: string;
  Parts: TArray<string>;
  I, EqPos: Integer;
  Key: string;
begin
  Result := '';
  if AQuery = '' then Exit;
  // Sparkle Uri.Query may include the leading '?' — strip it so the first
  // param-name (e.g. "status" in "?status=deleted") isn't misread as "?status".
  Q := AQuery;
  if (Length(Q) > 0) and (Q[1] = '?') then
    Q := Copy(Q, 2, MaxInt);
  Parts := Q.Split(['&']);
  for I := 0 to High(Parts) do
  begin
    EqPos := Pos('=', Parts[I]);
    if EqPos <= 0 then Continue;
    Key := Copy(Parts[I], 1, EqPos - 1);
    if SameText(Key, AName) then
    begin
      Result := Copy(Parts[I], EqPos + 1, MaxInt);
      // Minimal URL-decode: + → space, %XX → char
      Result := StringReplace(Result, '+', ' ', [rfReplaceAll]);
      Result := System.Net.URLClient.TURI.URLDecode(Result);
      Exit;
    end;
  end;
end;

// ===========================================================================
// FR#3353 Phase C — Project-scoped document list (filterable)
// GET /projects/:id/documents?type=X&q=Y&status=Z&limit=N&offset=N
// ===========================================================================
procedure HandleListProjectDocs(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Items: TJSONArray;
  SQL, FilterType, FilterQ, FilterStatus, FilterDocIdStr, Qstr: string;
  FilterDocId, Lim, Off: Integer;
begin
  // FR#4006 / Plan#4007 M2: non-admin ACL gate (read-level suffices — listing).
  if (not ASession.IsAdmin) and
     (not DeveloperHasProjectAccess(APool, ASession.DeveloperId, AProjId)) then
  begin
    MxSendError(C, 403, 'forbidden');
    Exit;
  end;

  Qstr := C.Request.Uri.Query;
  FilterType   := Trim(QGet(Qstr, 'type'));
  FilterQ      := Trim(QGet(Qstr, 'q'));
  FilterStatus := Trim(QGet(Qstr, 'status'));
  // FR#3472 B: explicit doc-id lookup short-path. Accepts `123` or `#123`.
  // When set AND numeric -> ignores type/q/status/limit/offset and returns
  // the single matching row (or empty array for cross-project / not-found).
  FilterDocIdStr := Trim(QGet(Qstr, 'doc_id'));
  if (Length(FilterDocIdStr) > 0) and (FilterDocIdStr[1] = '#') then
    FilterDocIdStr := Copy(FilterDocIdStr, 2, Length(FilterDocIdStr) - 1);
  FilterDocId := StrToIntDef(FilterDocIdStr, 0);
  Lim := StrToIntDef(QGet(Qstr, 'limit'), 100);
  Off := StrToIntDef(QGet(Qstr, 'offset'), 0);
  if Lim < 1  then Lim := 1;
  if Lim > 500 then Lim := 500;
  if Off < 0  then Off := 0;

  SQL :=
    'SELECT d.id, d.doc_type, d.slug, d.title, d.status, ' +
    '       d.summary_l1, d.created_by, d.created_by_developer_id, ' +
    '       dev.name AS author_name, ' +
    '       d.created_at, d.updated_at, d.token_estimate ' +
    'FROM documents d ' +
    'LEFT JOIN developers dev ON d.created_by_developer_id = dev.id ' +
    'WHERE d.project_id = :pid';
  if FilterDocId > 0 then
  begin
    // Exact-id short-path: scope to project_id prevents cross-project leaks
    // (unknown/foreign id returns empty set, not 404 — same as q-filter misses).
    SQL := SQL + ' AND d.id = :did';
    // Intentional: skip status, type, q filters when doing id-lookup.
    SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT 1';
  end
  else
  begin
    // Hide deleted docs by default; show them when explicitly requested via filter.
    if FilterStatus = '' then
      SQL := SQL + ' AND d.status <> ''deleted''';
    if FilterType <> '' then
      SQL := SQL + ' AND d.doc_type = :ftype';
    if FilterStatus <> '' then
      SQL := SQL + ' AND d.status = :fstatus';
    if FilterQ <> '' then
      SQL := SQL + ' AND (d.title LIKE :fq OR d.summary_l1 LIKE :fq)';
    SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT :lim OFFSET :off';
  end;

  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    Items := TJSONArray.Create;
    Qry := Ctx.CreateQuery(SQL);
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      if FilterDocId > 0 then
      begin
        Qry.ParamByName('did').AsInteger := FilterDocId;
      end
      else
      begin
        if FilterType <> '' then
          Qry.ParamByName('ftype').AsWideString :=LowerCase(FilterType);
        if FilterStatus <> '' then
          Qry.ParamByName('fstatus').AsWideString :=LowerCase(FilterStatus);
        if FilterQ <> '' then
          Qry.ParamByName('fq').AsWideString :='%' + FilterQ + '%';
        Qry.ParamByName('lim').AsInteger := Lim;
        Qry.ParamByName('off').AsInteger := Off;
      end;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Row := TJSONObject.Create;
        Row.AddPair('id',
          TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Row.AddPair('slug', Qry.FieldByName('slug').AsString);
        Row.AddPair('title', Qry.FieldByName('title').AsString);
        Row.AddPair('status', Qry.FieldByName('status').AsString);
        Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
        Row.AddPair('created_by', Qry.FieldByName('created_by').AsString);
        if Qry.FieldByName('created_by_developer_id').IsNull then
          Row.AddPair('author_name', TJSONNull.Create)
        else
          Row.AddPair('author_name',
            Qry.FieldByName('author_name').AsString);
        Row.AddPair('created_at',
          MxDateStr(Qry.FieldByName('created_at')));
        Row.AddPair('updated_at',
          MxDateStr(Qry.FieldByName('updated_at')));
        Row.AddPair('token_estimate',
          TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
        Items.Add(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('documents', Items);
    Json.AddPair('limit', TJSONNumber.Create(Lim));
    Json.AddPair('offset', TJSONNumber.Create(Off));
    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, '[ListProjectDocs] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ===========================================================================
// FR#3353 Phase C — Full document detail (view-only)
// GET /docs/:id
// ===========================================================================
procedure HandleGetDocDetail(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Tags, Rels: TJSONArray;
  DocProjId: Integer;
begin
  if ADocId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;

  // FR#4006 / Plan#4007 M2: non-admin callers require project-ACL. We
  // resolve project_id via a cheap lookup first, then 403 on foreign. This
  // keeps admin-path unchanged (no extra round-trip).
  // Security: for non-admin callers we collapse 404 (not-exists) to 403 so
  // attackers cannot probe for document existence via response-code delta.
  // Admins still get legitimate 404 to debug input errors.
  if not ASession.IsAdmin then
  begin
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT project_id FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        MxSendError(C, 403, 'forbidden');
        Exit;
      end;
      DocProjId := Qry.FieldByName('project_id').AsInteger;
    finally
      Qry.Free;
    end;
    if not DeveloperHasProjectAccess(APool, ASession.DeveloperId, DocProjId) then
    begin
      MxSendError(C, 403, 'forbidden');
      Exit;
    end;
  end;

  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // Main doc + project (include deleted so admin can see + restore)
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug, p.name AS project_name, ' +
      '       d.doc_type, d.slug, d.title, d.status, ' +
      '       d.summary_l1, d.summary_l2, d.content, ' +
      '       d.confidence, d.token_estimate, ' +
      '       d.created_by, d.created_by_developer_id, dev.name AS author_name, ' +
      '       d.created_at, d.updated_at ' +
      'FROM documents d ' +
      'JOIN projects p ON d.project_id = p.id ' +
      'LEFT JOIN developers dev ON d.created_by_developer_id = dev.id ' +
      'WHERE d.id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        // Info-leak guard: non-admin sees 403 even on race-condition 404.
        if ASession.IsAdmin then
          MxSendError(C, 404, 'not_found')
        else
          MxSendError(C, 403, 'forbidden');
        Exit;  // finally frees Qry; outer finally frees Json (no double-free)
      end;
      Json.AddPair('id',
        TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Json.AddPair('project_id',
        TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
      Json.AddPair('project_slug', Qry.FieldByName('project_slug').AsString);
      Json.AddPair('project_name', Qry.FieldByName('project_name').AsString);
      Json.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
      Json.AddPair('slug', Qry.FieldByName('slug').AsString);
      Json.AddPair('title', Qry.FieldByName('title').AsString);
      Json.AddPair('status', Qry.FieldByName('status').AsString);
      Json.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
      Json.AddPair('summary_l2', Qry.FieldByName('summary_l2').AsString);
      Json.AddPair('content', Qry.FieldByName('content').AsString);
      Json.AddPair('confidence',
        TJSONNumber.Create(Qry.FieldByName('confidence').AsFloat));
      Json.AddPair('token_estimate',
        TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
      Json.AddPair('created_by', Qry.FieldByName('created_by').AsString);
      if Qry.FieldByName('created_by_developer_id').IsNull then
        Json.AddPair('author_name', TJSONNull.Create)
      else
        Json.AddPair('author_name',
          Qry.FieldByName('author_name').AsString);
      Json.AddPair('created_at',
        MxDateStr(Qry.FieldByName('created_at')));
      Json.AddPair('updated_at',
        MxDateStr(Qry.FieldByName('updated_at')));
    finally
      Qry.Free;
    end;

    // Tags (doc_tags has direct 'tag' string column, no separate tags table)
    Tags := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT tag FROM doc_tags WHERE doc_id = :id ORDER BY tag');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      while not Qry.Eof do
      begin
        Tags.Add(Qry.FieldByName('tag').AsString);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('tags', Tags);

    // Relations (bidirectional, include rel_id for delete)
    Rels := TJSONArray.Create;
    Qry := Ctx.CreateQuery(
      'SELECT r.id AS rel_id, r.relation_type, ''outbound'' AS direction, ' +
      '       d2.id AS target_id, d2.title AS target_title, d2.doc_type AS target_type ' +
      'FROM doc_relations r ' +
      'JOIN documents d2 ON r.target_doc_id = d2.id ' +
      'WHERE r.source_doc_id = :id ' +
      'UNION ALL ' +
      'SELECT r.id AS rel_id, r.relation_type, ''inbound'' AS direction, ' +
      '       d2.id AS target_id, d2.title AS target_title, d2.doc_type AS target_type ' +
      'FROM doc_relations r ' +
      'JOIN documents d2 ON r.source_doc_id = d2.id ' +
      'WHERE r.target_doc_id = :id2 ' +
      'ORDER BY direction, target_title');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.ParamByName('id2').AsInteger := ADocId;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Rel := TJSONObject.Create;
        Rel.AddPair('rel_id',
          TJSONNumber.Create(Qry.FieldByName('rel_id').AsInteger));
        Rel.AddPair('relation_type',
          Qry.FieldByName('relation_type').AsString);
        Rel.AddPair('direction', Qry.FieldByName('direction').AsString);
        Rel.AddPair('target_id',
          TJSONNumber.Create(Qry.FieldByName('target_id').AsInteger));
        Rel.AddPair('target_title', Qry.FieldByName('target_title').AsString);
        Rel.AddPair('target_type', Qry.FieldByName('target_type').AsString);
        Rels.Add(Rel);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Json.AddPair('relations', Rels);

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, '[GetDocDetail] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;


// ===========================================================================
// FR#3353 Phase C — Soft-delete document
// DELETE /docs/:id
// ===========================================================================
procedure HandleDeleteDoc(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  DocProjId: Integer;
begin
  if ADocId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;
  // FR#4006 / Plan#4007 M2: non-admin ACL gate (row-presence). Resolve
  // project_id first, then 403 for foreign or non-existent (info-leak
  // guard — do not reveal existence to non-admin). Admin path returns 404
  // on non-existent for legitimate input-error debugging.
  if not ASession.IsAdmin then
  begin
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT project_id FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        MxSendError(C, 403, 'forbidden');
        Exit;
      end;
      DocProjId := Qry.FieldByName('project_id').AsInteger;
    finally
      Qry.Free;
    end;
    // FR#3360 — write-level gate (was DeveloperHasProjectAccess which
    // returned TRUE for read/comment access too, letting a read-only dev
    // wipe docs via the Admin-UI Save/Delete button — data-loss bug).
    if not DeveloperHasProjectWriteAccess(APool, ASession.DeveloperId, DocProjId) then
    begin
      MxSendError(C, 403, 'forbidden');
      Exit;
    end;
  end;
  try
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'UPDATE documents SET status = ''deleted'', updated_at = NOW() ' +
      'WHERE id = :id AND status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.ExecSQL;
      if Qry.RowsAffected = 0 then
      begin
        // Info-leak guard: collapse to 403 for non-admin.
        if ASession.IsAdmin then
          MxSendError(C, 404, 'not_found_or_already_deleted')
        else
          MxSendError(C, 403, 'forbidden');
        Exit;
      end;
    finally
      Qry.Free;
    end;
    ALogger.Log(mlInfo, 'Doc soft-deleted: id=' + IntToStr(ADocId));
    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('id', TJSONNumber.Create(ADocId));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  except
    on E: Exception do
    begin
      ALogger.Log(mlError, '[DeleteDoc] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ===========================================================================
// FR#3353 Phase C — Admin-side document edit
// PUT /docs/:id  body: {title?, summary_l1?, content?, status?, change_reason?}
// Notes (doc_type='note') MUST use mx_update_note (M2.5 edit-window enforcement).
// ===========================================================================
procedure HandleUpdateDocAdmin(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Body, Json: TJSONObject;
  NewTitle, NewSummary, NewContent, NewStatus, ChangeReason, DocType: string;
  HasTitle, HasSummary, HasContent, HasStatus: Boolean;
  SetClauses: string;
  DocProjId: Integer;
begin
  if ADocId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;
  // FR#4006 / Plan#4007 M2: non-admin ACL gate. Resolve project_id pre-
  // parse so we 403 before we bother parsing the body.
  // Info-leak guard: non-admin sees 403 even for non-existent docs so the
  // response-code delta cannot be used to probe existence.
  if not ASession.IsAdmin then
  begin
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT project_id FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        MxSendError(C, 403, 'forbidden');
        Exit;
      end;
      DocProjId := Qry.FieldByName('project_id').AsInteger;
    finally
      Qry.Free;
    end;
    // FR#3360 — write-level gate (was DeveloperHasProjectAccess which
    // returned TRUE for read/comment access too, letting a read-only dev
    // overwrite docs via the Admin-UI Save button — data-loss bug).
    if not DeveloperHasProjectWriteAccess(APool, ASession.DeveloperId, DocProjId) then
    begin
      MxSendError(C, 403, 'forbidden');
      Exit;
    end;
  end;
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;
  try
    HasTitle   := Body.FindValue('title')      <> nil;
    HasSummary := Body.FindValue('summary_l1') <> nil;
    HasContent := Body.FindValue('content')    <> nil;
    HasStatus  := Body.FindValue('status')     <> nil;
    NewTitle      := Body.GetValue<string>('title',        '');
    NewSummary    := Body.GetValue<string>('summary_l1',   '');
    NewContent    := Body.GetValue<string>('content',      '');
    NewStatus     := Body.GetValue<string>('status',       '');
    ChangeReason  := Body.GetValue<string>('change_reason',
                      'Admin-UI edit');

    if not (HasTitle or HasSummary or HasContent or HasStatus) then
    begin
      MxSendError(C, 400, 'nothing_to_update');
      Exit;
    end;
    // Whitelist status (prevent arbitrary values reaching DB)
    if HasStatus and not MatchStr(LowerCase(NewStatus),
         ['active', 'draft', 'archived', 'superseded', 'deleted']) then
    begin
      MxSendError(C, 400, 'invalid_status');
      Exit;
    end;

    Ctx := APool.AcquireContext;

    // Block notes — M2.5 enforces edit-window via mx_update_note only
    Qry := Ctx.CreateQuery(
      'SELECT doc_type FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        // Info-leak guard: non-admin gets 403 even on race-condition 404.
        if ASession.IsAdmin then
          MxSendError(C, 404, 'not_found')
        else
          MxSendError(C, 403, 'forbidden');
        Exit;  // finally frees Qry (no double-free)
      end;
      DocType := Qry.FieldByName('doc_type').AsString;
    finally
      Qry.Free;
    end;
    // Notes have an edit-window enforced via mx_update_note — block content
    // edits here. Status-only changes (restore, archive, etc.) are safe and
    // must pass through so admin can un-delete a note.
    if SameText(DocType, 'note') and (HasTitle or HasSummary or HasContent) then
    begin
      MxSendError(C, 409, 'notes_require_mx_update_note');
      Exit;
    end;

    // Build dynamic SET clause
    SetClauses := '';
    if HasTitle   then SetClauses := SetClauses + ', title = :t';
    if HasSummary then SetClauses := SetClauses + ', summary_l1 = :s';
    if HasContent then SetClauses := SetClauses + ', content = :c';
    if HasStatus  then SetClauses := SetClauses + ', status = :st';
    // Strip leading ", "
    if (Length(SetClauses) >= 2) and (Copy(SetClauses, 1, 2) = ', ') then
      SetClauses := Copy(SetClauses, 3, MaxInt);

    Ctx.StartTransaction;
    try
      // Archive new revision (schema: doc_id, revision, content, summary_l2,
      // changed_by, change_reason). Revision auto-increments per doc.
      Qry := Ctx.CreateQuery(
        'INSERT INTO doc_revisions ' +
        '  (doc_id, revision, content, summary_l2, changed_by, change_reason) ' +
        'SELECT :id, ' +
        '       COALESCE((SELECT MAX(revision) FROM doc_revisions dr2 WHERE dr2.doc_id = :id2), 0) + 1, ' +
        '       content, summary_l2, ''admin'', :reason ' +
        'FROM documents WHERE id = :id3');
      try
        Qry.ParamByName('id').AsInteger  := ADocId;
        Qry.ParamByName('id2').AsInteger := ADocId;
        Qry.ParamByName('id3').AsInteger := ADocId;
        Qry.ParamByName('reason').AsWideString :=Copy(ChangeReason, 1, 500);
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      // Update documents
      Qry := Ctx.CreateQuery(
        'UPDATE documents SET ' + SetClauses +
        ', updated_at = NOW() WHERE id = :id');
      try
        if HasTitle   then Qry.ParamByName('t').AsWideString := NewTitle;
        if HasSummary then Qry.ParamByName('s').AsWideString := NewSummary;
        if HasContent then
        begin
          // Bug#3345 + Lesson#2727: ftWideMemo + explicit Size avoids cp1252
          // triple-hop AND 32767-cap. Admin edits can exceed 32 KB on long specs.
          Qry.ParamByName('c').DataType := ftWideMemo;
          Qry.ParamByName('c').Size := Max(Length(NewContent) + 1024, 1048576);
          Qry.ParamByName('c').AsWideString := NewContent;
        end;
        if HasStatus  then Qry.ParamByName('st').AsWideString :=NewStatus;
        Qry.ParamByName('id').AsInteger := ADocId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Ctx.Commit;
    except
      Ctx.Rollback;
      raise;
    end;

    var FieldTag := '';
    if HasTitle   then FieldTag := FieldTag + 'T';
    if HasSummary then FieldTag := FieldTag + 'S';
    if HasContent then FieldTag := FieldTag + 'C';
    if HasStatus  then FieldTag := FieldTag + 'St';
    ALogger.Log(mlInfo, Format(
      'Doc admin-edit: id=%d fields=[%s] reason=%s',
      [ADocId, FieldTag, ChangeReason]));

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('id', TJSONNumber.Create(ADocId));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

// ===========================================================================
// FR#3353 Phase C — Delete single relation row
// DELETE /relations/:id
// ===========================================================================
procedure HandleDeleteRelation(const C: THttpServerContext;
  APool: TMxConnectionPool; ARelId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  if ARelId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;
  try
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'DELETE FROM doc_relations WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ARelId;
      Qry.ExecSQL;
      if Qry.RowsAffected = 0 then
      begin
        MxSendError(C, 404, 'not_found');
        Exit;
      end;
    finally
      Qry.Free;
    end;
    ALogger.Log(mlInfo, 'Relation deleted: id=' + IntToStr(ARelId));
    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('id', TJSONNumber.Create(ARelId));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  except
    on E: Exception do
    begin
      ALogger.Log(mlError, '[DeleteRelation] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ===========================================================================
// FR#3353 Phase C — Delete single project-relation row
// DELETE /project-relations/:id
// ===========================================================================
procedure HandleDeleteProjectRelation(const C: THttpServerContext;
  APool: TMxConnectionPool; ARelId: Integer; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
begin
  if ARelId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;
  try
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'DELETE FROM project_relations WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ARelId;
      Qry.ExecSQL;
      if Qry.RowsAffected = 0 then
      begin
        MxSendError(C, 404, 'not_found');
        Exit;
      end;
    finally
      Qry.Free;
    end;
    ALogger.Log(mlInfo, 'Project-relation deleted: id=' + IntToStr(ARelId));
    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('id', TJSONNumber.Create(ARelId));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  except
    on E: Exception do
    begin
      ALogger.Log(mlError, '[DeleteProjectRelation] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// FR#3472 A — GET /docs/:id/thread
// Hierarchischer Review-Thread via WITH RECURSIVE CTE über
// doc_relations.review-on (Edge source=child, target=parent).
// ---------------------------------------------------------------------------
procedure HandleGetDocThread(const C: THttpServerContext;
  APool: TMxConnectionPool; ADocId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
const
  DEPTH_CAP = 10;
  ROW_CAP   = 200;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Thread: TJSONArray;
  Item: TJSONObject;
  RowCount, MaxDepth: Integer;
  RootFound: Boolean;
  DocProjId: Integer;
begin
  if ADocId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;

  // FR#4006 / Plan#4007 M2: ACL pre-check — non-admin callers collapse
  // 404 (not-exists) to 403 so attackers cannot probe doc existence via
  // response-code delta. Same pattern as HandleGetDocDetail.
  if not ASession.IsAdmin then
  begin
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT project_id FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        MxSendError(C, 403, 'forbidden');
        Exit;
      end;
      DocProjId := Qry.FieldByName('project_id').AsInteger;
    finally
      Qry.Free;
    end;
    if not DeveloperHasProjectAccess(APool, ASession.DeveloperId, DocProjId) then
    begin
      MxSendError(C, 403, 'forbidden');
      Exit;
    end;
  end;

  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    // Existence pre-check: 404 wenn Root-Doc gar nicht existiert (oder deleted).
    RootFound := False;
    Qry := Ctx.CreateQuery(
      'SELECT 1 FROM documents WHERE id = :id AND status <> ''deleted'' LIMIT 1');
    try
      Qry.ParamByName('id').AsInteger := ADocId;
      Qry.Open;
      RootFound := not Qry.IsEmpty;
    finally
      Qry.Free;
    end;
    if not RootFound then
    begin
      MxSendError(C, 404, 'not_found');
      Exit;
    end;

    Qry := Ctx.CreateQuery(
      'WITH RECURSIVE thread AS (' +
      '  SELECT d.id, d.doc_type, d.title, d.summary_l1, d.status, ' +
      '         d.created_at, d.created_by_developer_id, ' +
      '         0 AS depth, CAST(NULL AS SIGNED) AS parent_doc_id ' +
      '  FROM documents d WHERE d.id = :root_id AND d.status <> ''deleted'' ' +
      '  UNION ALL ' +
      '  SELECT d.id, d.doc_type, d.title, d.summary_l1, d.status, ' +
      '         d.created_at, d.created_by_developer_id, ' +
      '         t.depth + 1 AS depth, r.target_doc_id AS parent_doc_id ' +
      '  FROM documents d ' +
      '  JOIN doc_relations r ON r.source_doc_id = d.id ' +
      '                      AND r.relation_type = ''review-on'' ' +
      '  JOIN thread t ON r.target_doc_id = t.id ' +
      '  WHERE t.depth < :depth_cap AND d.status <> ''deleted'' ' +
      ') ' +
      'SELECT t.id, t.doc_type, t.title, t.summary_l1, t.status, ' +
      '       t.created_at, t.created_by_developer_id, ' +
      '       dev.name AS author_name, ' +
      '       t.depth, t.parent_doc_id ' +
      'FROM thread t ' +
      'LEFT JOIN developers dev ON dev.id = t.created_by_developer_id ' +
      'ORDER BY t.depth, t.created_at ' +
      'LIMIT :lim');
    try
      Qry.ParamByName('root_id').AsInteger    := ADocId;
      Qry.ParamByName('depth_cap').AsInteger  := DEPTH_CAP;
      Qry.ParamByName('lim').AsInteger        := ROW_CAP;
      Qry.Open;

      Thread := TJSONArray.Create;
      try
        RowCount := 0;
        MaxDepth := 0;
        while not Qry.Eof do
        begin
          Item := TJSONObject.Create;
          try
            Item.AddPair('id',
              TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
            Item.AddPair('doc_type',   Qry.FieldByName('doc_type').AsString);
            Item.AddPair('title',      Qry.FieldByName('title').AsString);
            Item.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
            Item.AddPair('status',     Qry.FieldByName('status').AsString);
            Item.AddPair('created_at',
              FormatDateTime('yyyy-mm-dd"T"hh:nn:ss',
                Qry.FieldByName('created_at').AsDateTime));
            if Qry.FieldByName('created_by_developer_id').IsNull then
            begin
              Item.AddPair('created_by_developer_id', TJSONNull.Create);
              Item.AddPair('author_name', TJSONNull.Create);
            end
            else
            begin
              Item.AddPair('created_by_developer_id',
                TJSONNumber.Create(
                  Qry.FieldByName('created_by_developer_id').AsInteger));
              Item.AddPair('author_name',
                Qry.FieldByName('author_name').AsString);
            end;
            Item.AddPair('depth',
              TJSONNumber.Create(Qry.FieldByName('depth').AsInteger));
            if Qry.FieldByName('parent_doc_id').IsNull then
              Item.AddPair('parent_doc_id', TJSONNull.Create)
            else
              Item.AddPair('parent_doc_id',
                TJSONNumber.Create(
                  Qry.FieldByName('parent_doc_id').AsInteger));
            Thread.AddElement(Item);
          except
            Item.Free;
            raise;
          end;
          if Qry.FieldByName('depth').AsInteger > MaxDepth then
            MaxDepth := Qry.FieldByName('depth').AsInteger;
          Inc(RowCount);
          Qry.Next;
        end;

        Json.AddPair('root_id', TJSONNumber.Create(ADocId));
        Json.AddPair('thread', Thread);
        Thread := nil;  // ownership transferred to Json
        Json.AddPair('max_depth_reached', TJSONBool.Create(MaxDepth >= DEPTH_CAP));
        Json.AddPair('truncated',         TJSONBool.Create(RowCount >= ROW_CAP));
      except
        Thread.Free;
        raise;
      end;
    finally
      Qry.Free;
    end;

    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// ---------------------------------------------------------------------------
// FR#3472 C — GET /projects/:id/reviews
// Root-Aggregate aller Review-Threads im Projekt. 1-Query GROUP BY, kein N+1.
// ---------------------------------------------------------------------------
procedure HandleListProjectReviews(const C: THttpServerContext;
  APool: TMxConnectionPool; AProjId: Integer;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
const
  LIMIT_ROWS = 100;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Reviews: TJSONArray;
  Item: TJSONObject;
  RowCount: Integer;
begin
  if AProjId <= 0 then
  begin
    MxSendError(C, 400, 'invalid_id');
    Exit;
  end;

  // FR#4006 / Plan#4007 M2: non-admin ACL gate (read-level suffices).
  if (not ASession.IsAdmin) and
     (not DeveloperHasProjectAccess(APool, ASession.DeveloperId, AProjId)) then
  begin
    MxSendError(C, 403, 'forbidden');
    Exit;
  end;

  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;

    Qry := Ctx.CreateQuery(
      'SELECT r.id AS root_id, r.doc_type, r.title, r.status, ' +
      '  COUNT(c.id) AS reply_count, ' +
      '  MAX(c.depth) AS max_depth, ' +
      '  MAX(c.created_at) AS last_activity ' +
      'FROM documents r ' +
      'JOIN documents c ON c.root_parent_doc_id = r.id ' +
      'WHERE r.project_id = :pid ' +
      '  AND c.project_id = :pid ' +
      '  AND c.status <> ''deleted'' ' +
      '  AND r.status <> ''deleted'' ' +
      'GROUP BY r.id, r.doc_type, r.title, r.status ' +
      'ORDER BY MAX(c.created_at) DESC ' +
      'LIMIT :lim');
    try
      Qry.ParamByName('pid').AsInteger := AProjId;
      Qry.ParamByName('lim').AsInteger := LIMIT_ROWS;
      Qry.Open;

      Reviews := TJSONArray.Create;
      try
        RowCount := 0;
        while not Qry.Eof do
        begin
          Item := TJSONObject.Create;
          try
            Item.AddPair('root_id',
              TJSONNumber.Create(Qry.FieldByName('root_id').AsInteger));
            Item.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
            Item.AddPair('title',    Qry.FieldByName('title').AsString);
            Item.AddPair('status',   Qry.FieldByName('status').AsString);
            Item.AddPair('reply_count',
              TJSONNumber.Create(Qry.FieldByName('reply_count').AsInteger));
            Item.AddPair('max_depth',
              TJSONNumber.Create(Qry.FieldByName('max_depth').AsInteger));
            Item.AddPair('last_activity',
              FormatDateTime('yyyy-mm-dd"T"hh:nn:ss',
                Qry.FieldByName('last_activity').AsDateTime));
            Reviews.AddElement(Item);
          except
            Item.Free;
            raise;
          end;
          Inc(RowCount);
          Qry.Next;
        end;

        Json.AddPair('reviews', Reviews);
        Reviews := nil;  // ownership transferred to Json
        Json.AddPair('total', TJSONNumber.Create(RowCount));
        Json.AddPair('truncated',
          TJSONBool.Create(RowCount >= LIMIT_ROWS));
      except
        Reviews.Free;
        raise;
      end;
    finally
      Qry.Free;
    end;

    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
