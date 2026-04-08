unit mx.Tool.Session;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils, System.Variants,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function HandleSessionStart(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSessionSave(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSessionDelta(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// mx_session_start — Start a new session for a project
// ---------------------------------------------------------------------------
function HandleSessionStart(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug, InstanceId, SQL, Since: string;
  ProjectId, SessionId: Integer;
  Data, Stats: TJSONObject;
  Recent, Workflows, Notes, TagArr: TJSONArray;
  Row: TJSONObject;
  Guid: TGUID;
  IncludeBriefing, IncludeNotes: Boolean;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  IncludeBriefing := AParams.GetValue<Boolean>('include_briefing', True);
  IncludeNotes := AParams.GetValue<Boolean>('include_notes', False);
  Since := AParams.GetValue<string>('since', '');
  var SetupVersion := AParams.GetValue<string>('setup_version', '');

  // Generate UUID (without braces)
  CreateGUID(Guid);
  InstanceId := GUIDToString(Guid);
  InstanceId := Copy(InstanceId, 2, Length(InstanceId) - 2);

  // Insert session (project lookup inside TX for TOCTOU safety)
  AContext.StartTransaction;
  try
    // Look up project
    Qry := AContext.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug');
    try
      Qry.ParamByName('slug').AsString := ProjectSlug;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
      ProjectId := Qry.FieldByName('id').AsInteger;

      // ACL: check read access to start a session
      if not AContext.AccessControl.CheckProject(ProjectId, alRead) then
        raise EMxAccessDenied.Create(ProjectSlug, alRead);
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery(
      'INSERT INTO sessions (project_id, instance_id, developer_id, client_key_id, setup_version, started_at) ' +
      'VALUES (:proj_id, :inst_id, :dev_id, :key_id, :setup_ver, NOW())');
    try
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ParamByName('inst_id').AsString := InstanceId;
      Qry.ParamByName('dev_id').AsInteger := MxGetThreadAuth.DeveloperId;
      Qry.ParamByName('key_id').DataType := ftInteger;
      if MxGetThreadAuth.KeyId > 0 then
        Qry.ParamByName('key_id').AsInteger := MxGetThreadAuth.KeyId
      else
        Qry.ParamByName('key_id').Clear;
      if SetupVersion <> '' then
        Qry.ParamByName('setup_ver').AsString := SetupVersion
      else
      begin
        Qry.ParamByName('setup_ver').DataType := ftString;
        Qry.ParamByName('setup_ver').Clear;
      end;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // Get generated session ID
    Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS session_id');
    try
      Qry.Open;
      SessionId := Qry.FieldByName('session_id').AsInteger;
      if SessionId < 1 then
        raise EMxInternal.Create('LAST_INSERT_ID returned invalid value');
    finally
      Qry.Free;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('session_id', TJSONNumber.Create(SessionId));
    Data.AddPair('instance_id', InstanceId);
    Data.AddPair('project', ProjectSlug);

    // #12: Compound — include briefing + active workflows (saves 2-3 calls)
    if IncludeBriefing then
    begin
      // doc_type_counts
      Qry := AContext.CreateQuery(
        'SELECT doc_type, COUNT(*) AS cnt FROM documents ' +
        'WHERE project_id = :proj_id AND status <> ''deleted'' ' +
        'GROUP BY doc_type ORDER BY cnt DESC');
      try
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
        Qry.Open;
        Stats := TJSONObject.Create;
        while not Qry.Eof do
        begin
          Stats.AddPair(Qry.FieldByName('doc_type').AsString,
            TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
          Qry.Next;
        end;
        Data.AddPair('doc_type_counts', Stats);
      finally
        Qry.Free;
      end;

      // recent_changes (last 10, or filtered by since)
      if Since <> '' then
      begin
        SQL := 'SELECT d.id, d.doc_type, d.title, d.updated_at FROM documents d ' +
          'WHERE d.project_id = :proj_id AND d.status <> ''deleted'' ' +
          'AND d.updated_at > :since ORDER BY d.updated_at DESC LIMIT 20';
        Qry := AContext.CreateQuery(SQL);
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
        Qry.ParamByName('since').AsString := Since;
      end
      else
      begin
        Qry := AContext.CreateQuery(
          'SELECT d.id, d.doc_type, d.title, d.updated_at FROM documents d ' +
          'WHERE d.project_id = :proj_id AND d.status <> ''deleted'' ' +
          'ORDER BY d.updated_at DESC LIMIT 10');
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
      end;
      try
        Qry.Open;
        Recent := TJSONArray.Create;
        while not Qry.Eof do
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          Row.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);
          Recent.Add(Row);
          Qry.Next;
        end;
        Data.AddPair('recent_changes', Recent);
      finally
        Qry.Free;
      end;

      // unchanged_count (only when since is provided)
      if Since <> '' then
      begin
        Qry := AContext.CreateQuery(
          'SELECT COUNT(*) AS cnt FROM documents ' +
          'WHERE project_id = :proj_id AND status <> ''deleted'' ' +
          'AND updated_at <= :since');
        try
          Qry.ParamByName('proj_id').AsInteger := ProjectId;
          Qry.ParamByName('since').AsString := Since;
          Qry.Open;
          Data.AddPair('unchanged_count',
            TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        finally
          Qry.Free;
        end;
      end;

      // active_workflows
      Qry := AContext.CreateQuery(
        'SELECT d.id, d.title, d.summary_l1 FROM documents d ' +
        'WHERE d.project_id = :proj_id AND d.doc_type = ''workflow_log'' ' +
        'AND d.status <> ''deleted'' AND d.content LIKE ''%Status:** active%'' ' +
        'ORDER BY d.updated_at DESC LIMIT 5');
      try
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
        Qry.Open;
        Workflows := TJSONArray.Create;
        while not Qry.Eof do
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
          Workflows.Add(Row);
          Qry.Next;
        end;
        Data.AddPair('active_workflows', Workflows);
      finally
        Qry.Free;
      end;

      // Lesson Injection (Spec#1198): Top lessons for session briefing
      Qry := AContext.CreateQuery(
        'SELECT d.id, d.title, d.summary_l1, d.lesson_data, d.confidence, ' +
        '  d.violation_count, d.success_count ' +
        'FROM documents d ' +
        'WHERE d.doc_type = ''lesson'' AND d.status <> ''deleted'' ' +
        '  AND (d.project_id = :pid OR d.project_id = ' +
        '    (SELECT id FROM projects WHERE slug = ''_global'' LIMIT 1)) ' +
        'ORDER BY ' +
        '  CASE WHEN JSON_UNQUOTE(JSON_EXTRACT(d.lesson_data, ''$.severity'')) = ''critical'' THEN 0 ' +
        '       WHEN JSON_UNQUOTE(JSON_EXTRACT(d.lesson_data, ''$.severity'')) = ''high'' THEN 1 ' +
        '       WHEN JSON_UNQUOTE(JSON_EXTRACT(d.lesson_data, ''$.severity'')) = ''medium'' THEN 2 ' +
        '       ELSE 3 END, ' +
        '  d.violation_count DESC, d.created_at DESC ' +
        'LIMIT 10');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.Open;
        var Lessons := TJSONArray.Create;
        while not Qry.Eof do
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          if Qry.FieldByName('summary_l1').AsString <> '' then
            Row.AddPair('summary', Qry.FieldByName('summary_l1').AsString);
          if Qry.FieldByName('lesson_data').AsString <> '' then
            Row.AddPair('lesson_data', Qry.FieldByName('lesson_data').AsString);
          Row.AddPair('violation_count',
            TJSONNumber.Create(Qry.FieldByName('violation_count').AsInteger));
          Lessons.Add(Row);
          Qry.Next;
        end;
        Data.AddPair('lessons', Lessons);
      finally
        Qry.Free;
      end;
    end;

    // #12 Compound: include_notes (note, bugreport, feature_request with tags)
    if IncludeNotes then
    begin
      SQL := 'SELECT d.id, d.doc_type, d.title, d.slug, d.status, d.updated_at ' +
        'FROM documents d ' +
        'WHERE d.project_id = :proj_id ' +
        'AND d.doc_type IN (''note'', ''bugreport'', ''feature_request'') ' +
        'AND d.status <> ''deleted''';
      if Since <> '' then
        SQL := SQL + ' AND d.updated_at > :since';
      SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT 50';
      Qry := AContext.CreateQuery(SQL);
      try
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
        if Since <> '' then
          Qry.ParamByName('since').AsString := Since;
        Qry.Open;
        Notes := TJSONArray.Create;
        while not Qry.Eof do
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          Row.AddPair('slug', Qry.FieldByName('slug').AsString);
          Row.AddPair('status', Qry.FieldByName('status').AsString);
          Row.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);
          // Inline tags
          TagArr := TJSONArray.Create;
          var TagQry := AContext.CreateQuery(
            'SELECT tag FROM doc_tags WHERE doc_id = :did ORDER BY tag');
          try
            TagQry.ParamByName('did').AsInteger :=
              Qry.FieldByName('id').AsInteger;
            TagQry.Open;
            while not TagQry.Eof do
            begin
              TagArr.Add(TagQry.FieldByName('tag').AsString);
              TagQry.Next;
            end;
          finally
            TagQry.Free;
          end;
          Row.AddPair('tags', TagArr);
          Notes.Add(Row);
          Qry.Next;
        end;
        Data.AddPair('notes', Notes);
      finally
        Qry.Free;
      end;
    end;

    // Multi-Agent: active_peers on related projects + auto-join
    try
      Qry := AContext.CreateQuery(
        'SELECT DISTINCT p.id AS peer_project_id, p.slug AS project_slug, ' +
        '  p.name AS project_name, ' +
        '  s.id AS peer_session_id, s.started_at, pr.relation_type ' +
        'FROM sessions s ' +
        'JOIN projects p ON s.project_id = p.id ' +
        'JOIN project_relations pr ON ' +
        '  (pr.source_project_id = :pid AND pr.target_project_id = s.project_id) ' +
        '  OR (pr.target_project_id = :pid2 AND pr.source_project_id = s.project_id) ' +
        'WHERE s.ended_at IS NULL ' +
        '  AND (s.last_heartbeat IS NULL OR s.last_heartbeat > DATE_SUB(NOW(), INTERVAL 5 MINUTE)) ' +
        '  AND s.project_id != :pid3 ' +
        'ORDER BY s.started_at DESC');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('pid2').AsInteger := ProjectId;
        Qry.ParamByName('pid3').AsInteger := ProjectId;
        Qry.Open;

        var Peers := TJSONArray.Create;
        while not Qry.Eof do
        begin
          Row := TJSONObject.Create;
          Row.AddPair('project', Qry.FieldByName('project_slug').AsString);
          Row.AddPair('project_name', Qry.FieldByName('project_name').AsString);
          Row.AddPair('session_id',
            TJSONNumber.Create(Qry.FieldByName('peer_session_id').AsInteger));
          Row.AddPair('started_at', Qry.FieldByName('started_at').AsString);
          Row.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
          Peers.Add(Row);

          // Auto-join: notify each active peer
          try
            var JoinQry := AContext.CreateQuery(
              'INSERT INTO agent_messages ' +
              '(sender_session_id, sender_project_id, sender_developer_id, ' +
              ' target_project_id, message_type, payload, priority, expires_at) ' +
              'VALUES (:sid, :spid, :did, :tpid, ''join'', :payload, ' +
              ' ''normal'', DATE_ADD(NOW(), INTERVAL 1 HOUR))');
            try
              JoinQry.ParamByName('sid').AsInteger := SessionId;
              JoinQry.ParamByName('spid').AsInteger := ProjectId;
              JoinQry.ParamByName('did').AsInteger := MxGetThreadAuth.DeveloperId;
              JoinQry.ParamByName('tpid').AsInteger :=
                Qry.FieldByName('peer_project_id').AsInteger;
              JoinQry.ParamByName('payload').AsString :=
                '{"project":"' + ProjectSlug + '","session_id":' +
                IntToStr(SessionId) + '}';
              JoinQry.ExecSQL;
            finally
              JoinQry.Free;
            end;
          except
            // Non-critical: don't fail session_start if join fails
          end;

          Qry.Next;
        end;
        Data.AddPair('active_peers', Peers);
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
      begin
        // Non-critical: don't fail session_start if peers query fails
        Data.AddPair('active_peers', TJSONArray.Create);
        AContext.Logger.Log(mlWarning,
          '[mx_session_start] active_peers query failed: ' + E.Message);
      end;
    end;

    // Heartbeat: set initial heartbeat for this session
    try
      Qry := AContext.CreateQuery(
        'UPDATE sessions SET last_heartbeat = NOW() WHERE id = :sid');
      try
        Qry.ParamByName('sid').AsInteger := SessionId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    except
      // Non-critical
    end;

    // Prefetch candidates (pre-calculated at boot time)
    if IncludeBriefing then
    begin
      try
        Qry := AContext.CreateQuery(
          'SELECT ap.doc_id, d.title, d.doc_type, ap.score, ap.reason, ' +
          '  d.summary_l2 ' +
          'FROM access_patterns ap ' +
          'JOIN documents d ON d.id = ap.doc_id ' +
          'WHERE ap.project_id = :pid AND d.status <> ''deleted'' ' +
          'ORDER BY ap.score DESC LIMIT 15');
        try
          Qry.ParamByName('pid').AsInteger := ProjectId;
          Qry.Open;
          var Prefetch := TJSONArray.Create;
          while not Qry.Eof do
          begin
            Row := TJSONObject.Create;
            Row.AddPair('doc_id',
              TJSONNumber.Create(Qry.FieldByName('doc_id').AsInteger));
            Row.AddPair('title', Qry.FieldByName('title').AsString);
            Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
            Row.AddPair('score',
              TJSONNumber.Create(Qry.FieldByName('score').AsFloat));
            Row.AddPair('reason', Qry.FieldByName('reason').AsString);
            Row.AddPair('summary_l2', Qry.FieldByName('summary_l2').AsString);
            Prefetch.Add(Row);
            Qry.Next;
          end;
          Data.AddPair('prefetch_candidates', Prefetch);
        finally
          Qry.Free;
        end;
      except
        on E: Exception do
        begin
          Data.AddPair('prefetch_candidates', TJSONArray.Create);
          AContext.Logger.Log(mlWarning,
            '[mx_session_start] prefetch query failed: ' + E.Message);
        end;
      end;
    end;

    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_session_save — End and persist a session with summary
// ---------------------------------------------------------------------------
function HandleSessionSave(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  SessionId, ProjectId: Integer;
  Summary, ProjectSlug: string;
  Data: TJSONObject;
begin
  SessionId := AParams.GetValue<Integer>('session_id', 0);
  Summary := AParams.GetValue<string>('summary', '');
  ProjectId := 0;
  ProjectSlug := '';

  if SessionId < 1 then
    raise EMxValidation.Create('Parameter "session_id" is required');
  if Summary = '' then
    raise EMxValidation.Create('Parameter "summary" is required');

  // Verify + update in single transaction (race condition protection)
  AContext.StartTransaction;
  try
    Qry := AContext.CreateQuery(
      'SELECT s.id, s.project_id, p.slug AS project_slug, s.ended_at ' +
      'FROM sessions s JOIN projects p ON s.project_id = p.id ' +
      'WHERE s.id = :sid FOR UPDATE');
    try
      Qry.ParamByName('sid').AsInteger := SessionId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Session not found: ' + IntToStr(SessionId));
      if not Qry.FieldByName('ended_at').IsNull then
        raise EMxConflict.Create('Session already ended: ' + IntToStr(SessionId));

      ProjectId := Qry.FieldByName('project_id').AsInteger;
      ProjectSlug := Qry.FieldByName('project_slug').AsString;

      // ACL: check write access (saving a session modifies project data)
      if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
        raise EMxAccessDenied.Create(ProjectSlug, alWrite);
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery(
      'UPDATE sessions SET ended_at = NOW(), summary = :summary ' +
      'WHERE id = :sid AND ended_at IS NULL');
    try
      Qry.ParamByName('summary').AsString := Summary;
      Qry.ParamByName('sid').AsInteger := SessionId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  // Multi-Agent: auto-leave to active peers + archive own pending messages
  if ProjectId > 0 then
  begin
    try
      // Send leave to all related projects with active sessions
      Qry := AContext.CreateQuery(
        'INSERT INTO agent_messages ' +
        '(sender_session_id, sender_project_id, sender_developer_id, ' +
        ' target_project_id, message_type, payload, priority, expires_at) ' +
        'SELECT :sid, :spid, :did, p.id, ''leave'', ' +
        '  :payload, ''normal'', DATE_ADD(NOW(), INTERVAL 1 HOUR) ' +
        'FROM sessions s ' +
        'JOIN projects p ON s.project_id = p.id ' +
        'JOIN project_relations pr ON ' +
        '  (pr.source_project_id = :pid AND pr.target_project_id = s.project_id) ' +
        '  OR (pr.target_project_id = :pid2 AND pr.source_project_id = s.project_id) ' +
        'WHERE s.ended_at IS NULL AND s.project_id != :pid3 ' +
        '  AND (s.last_heartbeat IS NULL OR s.last_heartbeat > DATE_SUB(NOW(), INTERVAL 5 MINUTE))');
      try
        Qry.ParamByName('sid').AsInteger := SessionId;
        Qry.ParamByName('spid').AsInteger := ProjectId;
        Qry.ParamByName('did').AsInteger := MxGetThreadAuth.DeveloperId;
        Qry.ParamByName('payload').AsString :=
          '{"project":"' + ProjectSlug + '","session_id":' +
          IntToStr(SessionId) + '}';
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('pid2').AsInteger := ProjectId;
        Qry.ParamByName('pid3').AsInteger := ProjectId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      // Archive own unread incoming messages
      Qry := AContext.CreateQuery(
        'UPDATE agent_messages SET status = ''archived'' ' +
        'WHERE target_project_id = :pid AND status = ''pending''');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlWarning,
          '[mx_session_save] auto-leave failed: ' + E.Message);
    end;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('session_id', TJSONNumber.Create(SessionId));
    Data.AddPair('status', 'closed');
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_session_delta — Changes since last completed session for a project
// ---------------------------------------------------------------------------
function HandleSessionDelta(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug: string;
  ProjectId: Integer;
  LastEnded: TDateTime;
  HasPrior: Boolean;
  Data: TJSONObject;
  Changes: TJSONArray;
  Row: TJSONObject;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  // Look up project
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  // ACL: check read access
  if not AContext.AccessControl.CheckProject(ProjectId, alRead) then
    raise EMxAccessDenied.Create(ProjectSlug, alRead);

  // Find last completed session for this project
  HasPrior := False;
  LastEnded := 0;
  Qry := AContext.CreateQuery(
    'SELECT ended_at FROM sessions ' +
    'WHERE project_id = :proj_id AND ended_at IS NOT NULL ' +
    'ORDER BY ended_at DESC LIMIT 1');
  try
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    Qry.Open;
    if not Qry.IsEmpty then
    begin
      HasPrior := True;
      LastEnded := Qry.FieldByName('ended_at').AsDateTime;
    end;
  finally
    Qry.Free;
  end;

  // Get documents changed since last session (or all if no prior session)
  if HasPrior then
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.doc_type, d.slug, d.title, d.status, ' +
      '  d.summary_l1, d.updated_at ' +
      'FROM documents d ' +
      'WHERE d.project_id = :proj_id ' +
      '  AND d.status <> ''deleted'' ' +
      '  AND d.updated_at > :since ' +
      'ORDER BY d.updated_at DESC')
  else
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.doc_type, d.slug, d.title, d.status, ' +
      '  d.summary_l1, d.updated_at ' +
      'FROM documents d ' +
      'WHERE d.project_id = :proj_id ' +
      '  AND d.status <> ''deleted'' ' +
      'ORDER BY d.updated_at DESC');
  try
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    if HasPrior then
      Qry.ParamByName('since').AsDateTime := LastEnded;
    Qry.Open;

    Data := TJSONObject.Create;
    try
      Data.AddPair('project', ProjectSlug);
      if HasPrior then
        Data.AddPair('since',
          FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', LastEnded))
      else
        Data.AddPair('since', TJSONNull.Create);
      Data.AddPair('total_changes',
        TJSONNumber.Create(Qry.RecordCount));

      Changes := TJSONArray.Create;
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Row.AddPair('slug', Qry.FieldByName('slug').AsString);
        Row.AddPair('title', Qry.FieldByName('title').AsString);
        Row.AddPair('status', Qry.FieldByName('status').AsString);
        Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
        Row.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);
        Changes.Add(Row);
        Qry.Next;
      end;
      Data.AddPair('changes', Changes);

      Result := MxSuccessResponse(Data);
    except
      Data.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;
end;

end.
