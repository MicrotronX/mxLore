unit mx.Tool.Read;

interface

uses
  System.SysUtils, System.StrUtils, System.JSON, System.DateUtils, System.Variants,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl,
  mx.Intelligence.HybridSearch;

function HandlePing(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleBriefing(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSearch(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleDetail(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleBatchDetail(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleDocRevisions(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleGetRevision(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// mx_ping — Health-Check
// ---------------------------------------------------------------------------
function HandlePing(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  Data: TJSONObject;
  DBOk: Boolean;
  SchemaVersion: string;
begin
  DBOk := False;
  SchemaVersion := 'unknown';

  Qry := AContext.CreateQuery(
    'SELECT value FROM schema_meta WHERE key_name = ''schema_version''');
  try
    Qry.Open;
    if not Qry.IsEmpty then
    begin
      DBOk := True;
      SchemaVersion := Qry.FieldByName('value').AsString;
    end;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('server', 'mxLore');
    Data.AddPair('version', MXAI_VERSION);
    Data.AddPair('build', TJSONNumber.Create(MXAI_BUILD));
    Data.AddPair('protocol', MXAI_PROTOCOL);
    Data.AddPair('db_connected', TJSONBool.Create(DBOk));
    Data.AddPair('schema_version', SchemaVersion);
    if MXAI_SETUP_VERSION <> '' then
      Data.AddPair('setup_version', MXAI_SETUP_VERSION);
    if MXAI_ADMIN_PORT > 0 then
    begin
      Data.AddPair('admin_port', TJSONNumber.Create(MXAI_ADMIN_PORT));
      Data.AddPair('proxy_download_path', '/api/download/proxy');
      // Build full proxy_download_url from settings (external) or localhost (fallback)
      var ExtAdminUrl := '';
      try
        var SQry := AContext.CreateQuery(
          'SELECT setting_value FROM app_settings ' +
          'WHERE setting_key = ''connect.external_admin_url''');
        try
          SQry.Open;
          if not SQry.IsEmpty then
            ExtAdminUrl := Trim(SQry.FieldByName('setting_value').AsString);
        finally
          SQry.Free;
        end;
      except
        // app_settings may not exist on old schema — ignore
      end;
      // Always provide internal URL (works for local installs)
      var InternalUrl := 'http://localhost:' + IntToStr(MXAI_ADMIN_PORT) + '/api/download/proxy';
      Data.AddPair('proxy_download_url_internal', InternalUrl);
      // External URL from settings (for remote devs behind reverse proxy)
      if ExtAdminUrl <> '' then
      begin
        if ExtAdminUrl.EndsWith('/') then
          ExtAdminUrl := Copy(ExtAdminUrl, 1, Length(ExtAdminUrl) - 1);
        Data.AddPair('proxy_download_url', ExtAdminUrl + '/api/download/proxy');
      end
      else
        Data.AddPair('proxy_download_url', InternalUrl);
    end;
    Data.AddPair('timestamp', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));

    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_briefing — Projekt-Briefing via sp_briefing
// ---------------------------------------------------------------------------
function HandleBriefing(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug, FilterDocType, FilterStatus, Since, SQL: string;
  TokenBudget, ProjectId: Integer;
  Data, ProjectInfo, Stats: TJSONObject;
  Docs, Recent: TJSONArray;
  Row: TJSONObject;
  HasSince: Boolean;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  TokenBudget := AParams.GetValue<Integer>('token_budget', 1500);
  FilterDocType := AParams.GetValue<string>('doc_type', '');
  FilterStatus := AParams.GetValue<string>('status', '');
  Since := AParams.GetValue<string>('since', '');
  HasSince := Since <> '';

  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  // Query 1: Project info
  Qry := AContext.CreateQuery(
    'SELECT p.id, p.slug, p.name, p.path, p.briefing ' +
    'FROM projects p WHERE p.slug = :slug AND p.is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);

    ProjectId := Qry.FieldByName('id').AsInteger;

    if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
      raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

    Data := TJSONObject.Create;
    try
      ProjectInfo := TJSONObject.Create;
      ProjectInfo.AddPair('slug', Qry.FieldByName('slug').AsString);
      ProjectInfo.AddPair('name', Qry.FieldByName('name').AsString);
      ProjectInfo.AddPair('path', Qry.FieldByName('path').AsString);
      ProjectInfo.AddPair('briefing', Qry.FieldByName('briefing').AsString);
      Data.AddPair('project', ProjectInfo);
    except
      Data.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;

  // Query 2: Scored documents under token budget (#550 Relevanz-Scoring)
  // score = type_weight*40 + recency_weight*35 + access_weight*25
  SQL :=
    'SELECT d.id, d.doc_type, d.slug, d.title, d.status, ' +
    '  d.summary_l1, d.relevance_score, d.token_estimate ' +
    'FROM ( ' +
    '  SELECT scored.*, SUM(IFNULL(scored.token_estimate, 0)) ' +
    '    OVER (ORDER BY scored.relevance_score DESC ' +
    '          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_tokens ' +
    '  FROM ( ' +
    '    SELECT d2.id, d2.doc_type, d2.slug, d2.title, d2.status, ' +
    '      d2.summary_l1, d2.token_estimate, d2.updated_at, d2.confidence, ' +
    '      ROUND(' +
    '        CASE ' +
    '          WHEN d2.doc_type = ''decision'' THEN 1.0 ' +
    '          WHEN d2.doc_type = ''plan'' AND d2.status = ''draft'' THEN 0.9 ' +
    '          WHEN d2.doc_type = ''bugreport'' AND d2.status IN (''reported'',''confirmed'') THEN 0.8 ' +
    '          WHEN d2.doc_type = ''todo'' AND d2.status = ''open'' THEN 0.8 ' +
    '          WHEN d2.doc_type = ''feature_request'' AND d2.status IN (''reported'',''confirmed'') THEN 0.7 ' +
    '          WHEN d2.doc_type = ''assumption'' THEN 0.7 ' +
    '          WHEN d2.doc_type = ''reference'' THEN 0.6 ' +
    '          WHEN d2.doc_type = ''spec'' THEN 0.5 ' +
    '          WHEN d2.doc_type = ''plan'' THEN 0.5 ' +
    '          WHEN d2.doc_type = ''skill'' THEN 0.55 ' +
    '          WHEN d2.doc_type = ''note'' THEN 0.4 ' +
    '          WHEN d2.doc_type = ''session_note'' THEN 0.3 ' +
    '          WHEN d2.doc_type = ''workflow_log'' THEN 0.3 ' +
    '          ELSE 0.4 ' +
    '        END * 40 + ' +
    '        (1.0 / (1 + DATEDIFF(NOW(), d2.updated_at) * 0.1)) * 35 + ' +
    '        IFNULL(d2.access_count / NULLIF(' +
    '          (SELECT MAX(access_count) FROM documents WHERE project_id = d2.project_id AND status <> ''deleted''), 0' +
    '        ), 0) * 25 ' +
    '      , 2) * GREATEST(0.10, d2.confidence - (DATEDIFF(NOW(), d2.updated_at) / 180.0) * 0.5) AS relevance_score ' +
    '    FROM documents d2 ' +
    '    WHERE d2.project_id = :proj_id ' +
    '      AND d2.status NOT IN (''deleted'', ''archived'', ''superseded'')';

  // Optional filters
  if FilterDocType <> '' then
    SQL := SQL + '      AND d2.doc_type = :filter_doc_type';
  if FilterStatus <> '' then
    SQL := SQL + '      AND d2.status = :filter_status';

  SQL := SQL +
    '  ) scored ' +
    ') d ' +
    'WHERE d.cumulative_tokens - d.token_estimate < :budget ' +
    'ORDER BY d.relevance_score DESC LIMIT 50';

  Qry := AContext.CreateQuery(SQL);
  try
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    Qry.ParamByName('budget').AsInteger := TokenBudget;
    if FilterDocType <> '' then
      Qry.ParamByName('filter_doc_type').AsString := FilterDocType;
    if FilterStatus <> '' then
      Qry.ParamByName('filter_status').AsString := FilterStatus;
    Qry.Open;

    Docs := TJSONArray.Create;
    try
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Row.AddPair('slug', Qry.FieldByName('slug').AsString);
        Row.AddPair('title', Qry.FieldByName('title').AsString);
        Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
        Row.AddPair('relevance_score',
          TJSONNumber.Create(Qry.FieldByName('relevance_score').AsFloat));
        Docs.Add(Row);
        Qry.Next;
      end;
      Data.AddPair('documents', Docs);
    except
      Docs.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;

  // Query 3: Document count per doc_type (all non-deleted, optionally since)
  SQL := 'SELECT doc_type, COUNT(*) AS cnt ' +
    'FROM documents ' +
    'WHERE project_id = :proj_id AND status <> ''deleted''';
  if HasSince then
    SQL := SQL + ' AND updated_at > :since';
  SQL := SQL + ' GROUP BY doc_type ORDER BY cnt DESC';
  Qry := AContext.CreateQuery(SQL);
  try
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    if HasSince then
      Qry.ParamByName('since').AsString := Since;
    Qry.Open;
    Stats := TJSONObject.Create;
    try
      while not Qry.Eof do
      begin
        Stats.AddPair(Qry.FieldByName('doc_type').AsString,
          TJSONNumber.Create(Qry.FieldByName('cnt').AsInteger));
        Qry.Next;
      end;
      Data.AddPair('doc_type_counts', Stats);
    except
      Stats.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;

  // Query 4: Last 3 changed documents (all non-deleted, optionally since)
  SQL := 'SELECT d.id, d.doc_type, d.title, d.updated_at ' +
    'FROM documents d ' +
    'WHERE d.project_id = :proj_id AND d.status <> ''deleted''';
  if HasSince then
    SQL := SQL + ' AND d.updated_at > :since';
  SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT 3';
  Qry := AContext.CreateQuery(SQL);
  try
    Qry.ParamByName('proj_id').AsInteger := ProjectId;
    if HasSince then
      Qry.ParamByName('since').AsString := Since;
    Qry.Open;
    Recent := TJSONArray.Create;
    try
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
    except
      Recent.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;

  // Project relations (depends_on, related_to)
  try
    Qry := AContext.CreateQuery(
      'SELECT p.slug, p.name, pr.relation_type, ''outgoing'' AS direction ' +
      'FROM project_relations pr ' +
      'JOIN projects p ON pr.target_project_id = p.id ' +
      'WHERE pr.source_project_id = :proj_id ' +
      'UNION ALL ' +
      'SELECT p.slug, p.name, pr.relation_type, ' +
      '  CASE WHEN pr.relation_type = ''related_to'' THEN ''outgoing'' ' +
      '       ELSE ''incoming'' END AS direction ' +
      'FROM project_relations pr ' +
      'JOIN projects p ON pr.source_project_id = p.id ' +
      'WHERE pr.target_project_id = :proj_id2');
    try
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ParamByName('proj_id2').AsInteger := ProjectId;
      Qry.Open;
      if not Qry.IsEmpty then
      begin
        Recent := TJSONArray.Create;
        try
          while not Qry.Eof do
          begin
            Row := TJSONObject.Create;
            Row.AddPair('slug', Qry.FieldByName('slug').AsString);
            Row.AddPair('name', Qry.FieldByName('name').AsString);
            Row.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
            Row.AddPair('direction', Qry.FieldByName('direction').AsString);
            Recent.Add(Row);
            Qry.Next;
          end;
          Data.AddPair('related_projects', Recent);
        except
          Recent.Free;
          raise;
        end;
      end;
    finally
      Qry.Free;
    end;
  except
    // Non-critical — don't fail briefing if project_relations table missing
    on E: Exception do
      if Assigned(AContext.Logger) then
        AContext.Logger.Log(mlWarning, '[mx_briefing] project_relations query failed: ' + E.Message);
  end;

  // Log access for predictive prefetch
  try
    Qry := AContext.CreateQuery(
      'INSERT INTO access_log (session_id, developer_id, tool_name, doc_id, project_id, context_tool) ' +
      'VALUES (:session_id, :dev_id, ''mx_briefing'', 0, :proj_id, NULL)');
    try
      Qry.ParamByName('session_id').DataType := ftInteger;
      if AParams.GetValue<Integer>('session_id', 0) > 0 then
        Qry.ParamByName('session_id').AsInteger := AParams.GetValue<Integer>('session_id', 0)
      else
        Qry.ParamByName('session_id').Clear;
      Qry.ParamByName('dev_id').AsInteger := MxGetThreadAuth.DeveloperId;
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      AContext.Logger.Log(mlWarning, '[mx_briefing] access_log INSERT failed: ' + E.Message);
  end;

  // Query 5: Invalidated assumption warnings (Decision Replay)
  var WarningsArr := TJSONArray.Create;
  try
    Qry := AContext.CreateQuery(
      'SELECT d.id as decision_id, d.title as decision_title, ' +
      '  a.id as assumption_id, a.title as assumption_title ' +
      'FROM doc_relations r ' +
      'INNER JOIN documents d ON d.id = r.source_doc_id ' +
      'INNER JOIN documents a ON a.id = r.target_doc_id ' +
      'WHERE r.relation_type = ''assumes'' ' +
      '  AND a.doc_type = ''assumption'' ' +
      '  AND a.status = ''rejected'' ' +
      '  AND d.project_id = :proj_id');
    try
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.Open;
      while not Qry.Eof do
      begin
        WarningsArr.Add(Format('%s (doc_id=%d) basiert auf invalidierter Annahme #%d: ''%s''',
          [Qry.FieldByName('decision_title').AsString,
           Qry.FieldByName('decision_id').AsInteger,
           Qry.FieldByName('assumption_id').AsInteger,
           Qry.FieldByName('assumption_title').AsString]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // B7.3: Warn about stale_candidate and stub_candidate docs
    Qry := AContext.CreateQuery(
      'SELECT ' +
      '  SUM(CASE WHEN status = ''stale_candidate'' THEN 1 ELSE 0 END) AS stale_count, ' +
      '  SUM(CASE WHEN status = ''stub_candidate'' THEN 1 ELSE 0 END) AS stub_count ' +
      'FROM documents ' +
      'WHERE project_id = :proj_id ' +
      '  AND status IN (''stale_candidate'', ''stub_candidate'')');
    try
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.Open;
      if not Qry.IsEmpty then
      begin
        var StaleCount := Qry.FieldByName('stale_count').AsInteger;
        var StubCount := Qry.FieldByName('stub_count').AsInteger;
        if (StaleCount > 0) or (StubCount > 0) then
          WarningsArr.Add(Format('%d stale_candidate docs, %d stub_candidate docs found - review recommended',
            [StaleCount, StubCount]));
      end;
    finally
      Qry.Free;
    end;

    Data.AddPair('warnings', WarningsArr);
  except
    WarningsArr.Free;
    raise;
  end;

  try
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_search — Volltext-Suche via sp_search
// ---------------------------------------------------------------------------
function HandleSearch(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry, SubQry: TFDQuery;
  Query, Scope, ProjectSlug, DocType, Tag, StatusFilter, SinceStr, NormSinceStr, RowProjSlug, IdList, SQL: string;
  SinceDT: TDateTime;
  DocParts: TArray<string>;
  TokenBudget, ProjId, I, MaxLimit: Integer;
  Data: TJSONArray;
  Row: TJSONObject;
  ACL: IAccessControl;
  NeedFilter, IncludeContent, IncludeDetails: Boolean;
  ProjIdCache: TDictionary<string, Integer>;
  IdMap: TDictionary<Integer, TJSONObject>;
begin
  Query := AParams.GetValue<string>('query', '');
  Scope := AParams.GetValue<string>('scope', 'all');
  ProjectSlug := AParams.GetValue<string>('project', '');
  // Auto-scope: if project is given, force scope=project
  if (ProjectSlug <> '') and (Scope = 'all') then
    Scope := 'project';
  DocType := AParams.GetValue<string>('doc_type', '');
  Tag := AParams.GetValue<string>('tag', '');
  StatusFilter := LowerCase(Trim(AParams.GetValue<string>('status', '')));
  if (StatusFilter <> '') and not MatchStr(StatusFilter,
      ['draft', 'active', 'completed', 'superseded', 'deprecated', 'archived',
       'reported', 'confirmed', 'fixed', 'rejected', 'resolved',
       'accepted', 'proposed', 'approved', 'implemented',
       'open', 'in_progress', 'done', 'deferred']) then
    raise EMxValidation.CreateFmt('Invalid status "%s"', [StatusFilter]);
  TokenBudget := AParams.GetValue<Integer>('token_budget', 1500);
  IncludeContent := AParams.GetValue<Boolean>('include_content', False);
  MaxLimit := AParams.GetValue<Integer>('limit', 10);
  if MaxLimit < 1 then MaxLimit := 1;
  if MaxLimit > 50 then MaxLimit := 50;
  IncludeDetails := AParams.GetValue<Boolean>('include_details', False);
  // Bug#3033: since filter — ISO 8601 cutoff, matches mx_session_delta pattern
  SinceStr := Trim(AParams.GetValue<string>('since', ''));
  SinceDT := 0;
  if SinceStr <> '' then
  begin
    // Accept date-only form (YYYY-MM-DD) by normalizing to midnight, because
    // Delphi's ISO8601ToDate requires a 'T'-datetime component. Parse once
    // and bind as TDateTime (AsDateTime), mirroring mx_session_delta:697-702.
    if Length(SinceStr) = 10 then
      NormSinceStr := SinceStr + 'T00:00:00'
    else
      NormSinceStr := SinceStr;
    try
      SinceDT := ISO8601ToDate(NormSinceStr, False);
    except
      raise EMxValidation.Create('Invalid "since" timestamp (expected ISO 8601)');
    end;
  end;

  Query := Trim(Query);
  // B6.2: query is now optional when using doc_type/tag/status/since filters
  if (Query = '') and (DocType = '') and (Tag = '') and (StatusFilter = '') and (SinceStr = '') then
    raise EMxValidation.Create('At least one of query, doc_type, tag, status, or since is required');

  // Bug #549: Pure wildcard queries ('*', '**') are not valid for MySQL FTS.
  if Query <> '' then
    Query := Query.Replace('*', '').Trim;

  // Validate doc_type (single or comma-separated, e.g. 'plan,spec')
  if DocType <> '' then
  begin
    DocParts := DocType.Split([',']);
    DocType := '';
    for I := 0 to High(DocParts) do
    begin
      DocParts[I] := Trim(DocParts[I]);
      if not IsAllowedDocType(DocParts[I]) then
        raise EMxValidation.CreateFmt('Invalid doc_type "%s"', [DocParts[I]]);
      if I > 0 then DocType := DocType + ',';
      DocType := DocType + DocParts[I];
    end;
  end;

  ACL := AContext.AccessControl;

  // ACL: if specific project given, check read access before calling SP
  if ProjectSlug <> '' then
  begin
    SubQry := AContext.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
    try
      SubQry.ParamByName('slug').AsString := ProjectSlug;
      SubQry.Open;
      if SubQry.IsEmpty then
        raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
      ProjId := SubQry.FieldByName('id').AsInteger;
      if not ACL.CheckProject(ProjId, alReadOnly) then
        raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);
    finally
      SubQry.Free;
    end;
  end;

  // For scope=all with non-admin, post-filter results by allowed projects
  NeedFilter := (ProjectSlug = '') and (not ACL.IsAdmin);

  ProjIdCache := TDictionary<string, Integer>.Create;
  try
    // Inline SELECT replaces CALL sp_search (Bug #554: CALL via DirectExecute
    // leaves unconsumed OK packet on pooled connections -> "Commands out of sync")
    // Bug #549: When query is empty after wildcard stripping, browse-all without FTS
    if Query <> '' then
    begin
      SQL := 'SELECT d.id, p.slug AS project, d.doc_type, d.title, ' +
        'd.summary_l1, d.summary_l2, ' +
        'ROUND(MATCH(d.title, d.summary_l2, d.content) ' +
        'AGAINST(:query IN NATURAL LANGUAGE MODE), 2) AS relevance_score, ' +
        'd.token_estimate ' +
        'FROM documents d ' +
        'JOIN projects p ON d.project_id = p.id ' +
        'WHERE d.status != ''deleted'' ' +
        'AND p.is_active = TRUE';
      if (Scope = 'project') and (ProjectSlug <> '') then
        SQL := SQL + ' AND p.slug = :project';
      if DocType <> '' then
        SQL := SQL + ' AND FIND_IN_SET(d.doc_type, :doc_type) > 0';
      // B6.2: tag filter (replaces mx_list_notes), supports comma-separated (OR)
      if Tag <> '' then
        SQL := SQL + ' AND EXISTS (SELECT 1 FROM doc_tags dt WHERE dt.doc_id = d.id AND FIND_IN_SET(dt.tag, :tag) > 0)';
      if StatusFilter <> '' then
        SQL := SQL + ' AND d.status = :status';
      // Bug#3033: since filter — updated_at cutoff (inclusive)
      if SinceStr <> '' then
        SQL := SQL + ' AND d.updated_at >= :since';
      SQL := SQL +
        ' AND MATCH(d.title, d.summary_l2, d.content) ' +
        'AGAINST(:query IN NATURAL LANGUAGE MODE) ' +
        'ORDER BY relevance_score DESC LIMIT ' + IntToStr(MaxLimit);
    end
    else
    begin
      // Browse-all: no FTS, order by most recently updated
      SQL := 'SELECT d.id, p.slug AS project, d.doc_type, d.title, ' +
        'd.summary_l1, d.summary_l2, ' +
        '0.0 AS relevance_score, d.token_estimate ' +
        'FROM documents d ' +
        'JOIN projects p ON d.project_id = p.id ' +
        'WHERE d.status != ''deleted'' ' +
        'AND p.is_active = TRUE';
      if (Scope = 'project') and (ProjectSlug <> '') then
        SQL := SQL + ' AND p.slug = :project';
      if DocType <> '' then
        SQL := SQL + ' AND FIND_IN_SET(d.doc_type, :doc_type) > 0';
      // B6.2: tag filter, supports comma-separated (OR)
      if Tag <> '' then
        SQL := SQL + ' AND EXISTS (SELECT 1 FROM doc_tags dt WHERE dt.doc_id = d.id AND FIND_IN_SET(dt.tag, :tag) > 0)';
      if StatusFilter <> '' then
        SQL := SQL + ' AND d.status = :status';
      // Bug#3033: since filter — updated_at cutoff (inclusive)
      if SinceStr <> '' then
        SQL := SQL + ' AND d.updated_at >= :since';
      SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT ' + IntToStr(MaxLimit);
    end;

    Qry := AContext.CreateQuery(SQL);
    try
      if Query <> '' then
        Qry.ParamByName('query').AsString := Query;
      if (Scope = 'project') and (ProjectSlug <> '') then
        Qry.ParamByName('project').AsString := ProjectSlug;
      if DocType <> '' then
        Qry.ParamByName('doc_type').AsString := DocType;
      if Tag <> '' then
        Qry.ParamByName('tag').AsString := LowerCase(Trim(Tag));
      if StatusFilter <> '' then
        Qry.ParamByName('status').AsString := StatusFilter;
      // Bug#3033: since binding — TDateTime bind, matches mx_session_delta pattern (Session.pas:697-702)
      if SinceStr <> '' then
        Qry.ParamByName('since').AsDateTime := SinceDT;
      Qry.Open;

      Data := TJSONArray.Create;
      try
        while not Qry.Eof do
        begin
          // ACL post-filter for scope=all
          if NeedFilter then
          begin
            RowProjSlug := Qry.FieldByName('project').AsString;
            if not ProjIdCache.TryGetValue(RowProjSlug, ProjId) then
            begin
              SubQry := AContext.CreateQuery(
                'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
              try
                SubQry.ParamByName('slug').AsString := RowProjSlug;
                SubQry.Open;
                if not SubQry.IsEmpty then
                  ProjId := SubQry.FieldByName('id').AsInteger
                else
                  ProjId := -1;
              finally
                SubQry.Free;
              end;
              ProjIdCache.AddOrSetValue(RowProjSlug, ProjId);
            end;
            if (ProjId < 0) or (not ACL.CheckProject(ProjId, alReadOnly)) then
            begin
              Qry.Next;
              Continue;
            end;
          end;

          Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('project', Qry.FieldByName('project').AsString);
          Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
          Row.AddPair('summary_l2', Qry.FieldByName('summary_l2').AsString);
          Row.AddPair('relevance_score',
            TJSONNumber.Create(Qry.FieldByName('relevance_score').AsFloat));
          Row.AddPair('token_estimate',
            TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
          Data.Add(Row);
          Qry.Next;
        end;

        // Hybrid Search: enrich with vector-only results if available
        if Assigned(GHybridSearch) and (Query <> '') and (Data.Count > 0) then
        begin
          var KwIds: TArray<Integer>;
          var KwScores: TArray<Double>;
          SetLength(KwIds, Data.Count);
          SetLength(KwScores, Data.Count);
          for I := 0 to Data.Count - 1 do
          begin
            KwIds[I] := (Data.Items[I] as TJSONObject).GetValue<Integer>('id');
            KwScores[I] := (Data.Items[I] as TJSONObject).GetValue<Double>('relevance_score');
          end;
          var HybridResults := GHybridSearch.MergeResults(
            Qry.Connection, KwIds, KwScores, Query, MaxLimit, ProjectSlug);
          // Add vector-only docs (not in keyword results)
          var ExistingIds := TDictionary<Integer, Boolean>.Create;
          try
            for I := 0 to High(KwIds) do
              ExistingIds.AddOrSetValue(KwIds[I], True);
            var Added := 0;
            for I := 0 to High(HybridResults) do
            begin
              if Data.Count >= MaxLimit then Break;
              if not ExistingIds.ContainsKey(HybridResults[I].DocId) then
              begin
                SubQry := AContext.CreateQuery(
                  'SELECT d.id, p.slug AS project, d.doc_type, d.title, ' +
                  'd.summary_l1, d.summary_l2, d.token_estimate ' +
                  'FROM documents d JOIN projects p ON d.project_id = p.id ' +
                  'WHERE d.id = :did');
                try
                  SubQry.ParamByName('did').AsInteger := HybridResults[I].DocId;
                  SubQry.Open;
                  if not SubQry.IsEmpty then
                  begin
                    Row := TJSONObject.Create;
                    Row.AddPair('id', TJSONNumber.Create(SubQry.FieldByName('id').AsInteger));
                    Row.AddPair('project', SubQry.FieldByName('project').AsString);
                    Row.AddPair('doc_type', SubQry.FieldByName('doc_type').AsString);
                    Row.AddPair('title', SubQry.FieldByName('title').AsString);
                    Row.AddPair('summary_l1', SubQry.FieldByName('summary_l1').AsString);
                    Row.AddPair('summary_l2', SubQry.FieldByName('summary_l2').AsString);
                    Row.AddPair('relevance_score',
                      TJSONNumber.Create(HybridResults[I].FinalScore));
                    Row.AddPair('token_estimate',
                      TJSONNumber.Create(SubQry.FieldByName('token_estimate').AsInteger));
                    Data.Add(Row);
                  end;
                finally
                  SubQry.Free;
                end;
              end;
            end;
          finally
            ExistingIds.Free;
          end;
        end;

        // include_content: load content for <=3 results
        if IncludeContent and (Data.Count > 0) and (Data.Count <= 3) then
        begin
          // Build ID->JSONObject map and ID list for SQL
          IdMap := TDictionary<Integer, TJSONObject>.Create;
          try
            IdList := '';
            for I := 0 to Data.Count - 1 do
            begin
              Row := Data.Items[I] as TJSONObject;
              ProjId := Row.GetValue<Integer>('id');
              IdMap.Add(ProjId, Row);
              if IdList <> '' then IdList := IdList + ',';
              IdList := IdList + IntToStr(ProjId);
            end;
            // Safe: IdList contains only integers, no SQL injection
            SubQry := AContext.CreateQuery(
              'SELECT id, content FROM documents WHERE id IN (' + IdList + ')');
            try
              SubQry.Open;
              while not SubQry.Eof do
              begin
                ProjId := SubQry.FieldByName('id').AsInteger;
                if IdMap.TryGetValue(ProjId, Row) then
                  Row.AddPair('content', SubQry.FieldByName('content').AsString);
                SubQry.Next;
              end;
            finally
              SubQry.Free;
            end;
          finally
            IdMap.Free;
          end;
        end
        else if IncludeContent and (Data.Count > 3) then
        begin
          // Mark each result as content_omitted
          for I := 0 to Data.Count - 1 do
          begin
            Row := Data.Items[I] as TJSONObject;
            Row.AddPair('content_omitted', TJSONBool.Create(True));
          end;
        end;

        // include_details: load content + relations for <=5 results
        if IncludeDetails and (Data.Count > 0) and (Data.Count <= 5) then
        begin
          IdMap := TDictionary<Integer, TJSONObject>.Create;
          try
            IdList := '';
            for I := 0 to Data.Count - 1 do
            begin
              Row := Data.Items[I] as TJSONObject;
              ProjId := Row.GetValue<Integer>('id');
              IdMap.Add(ProjId, Row);
              if IdList <> '' then IdList := IdList + ',';
              IdList := IdList + IntToStr(ProjId);
            end;
            // Load content (if not already loaded by include_content)
            if not IncludeContent then
            begin
              SubQry := AContext.CreateQuery(
                'SELECT id, content FROM documents WHERE id IN (' + IdList + ')');
              try
                SubQry.Open;
                while not SubQry.Eof do
                begin
                  ProjId := SubQry.FieldByName('id').AsInteger;
                  if IdMap.TryGetValue(ProjId, Row) then
                    Row.AddPair('content', SubQry.FieldByName('content').AsString);
                  SubQry.Next;
                end;
              finally
                SubQry.Free;
              end;
            end;
            // Load relations for all result docs
            SubQry := AContext.CreateQuery(
              'SELECT dr.source_doc_id, dr.target_doc_id, dr.relation_type, ' +
              'ds.title AS source_title, dt.title AS target_title ' +
              'FROM doc_relations dr ' +
              'JOIN documents ds ON ds.id = dr.source_doc_id ' +
              'JOIN documents dt ON dt.id = dr.target_doc_id ' +
              'WHERE dr.source_doc_id IN (' + IdList + ') ' +
              'OR dr.target_doc_id IN (' + IdList + ')');
            try
              SubQry.Open;
              // Init relations arrays
              for I := 0 to Data.Count - 1 do
              begin
                Row := Data.Items[I] as TJSONObject;
                Row.AddPair('relations', TJSONArray.Create);
              end;
              while not SubQry.Eof do
              begin
                Row := nil;
                ProjId := SubQry.FieldByName('source_doc_id').AsInteger;
                if not IdMap.TryGetValue(ProjId, Row) then
                begin
                  ProjId := SubQry.FieldByName('target_doc_id').AsInteger;
                  IdMap.TryGetValue(ProjId, Row);
                end;
                if Row <> nil then
                begin
                  var RelObj := TJSONObject.Create;
                  RelObj.AddPair('relation_type', SubQry.FieldByName('relation_type').AsString);
                  RelObj.AddPair('source_doc_id', TJSONNumber.Create(SubQry.FieldByName('source_doc_id').AsInteger));
                  RelObj.AddPair('source_title', SubQry.FieldByName('source_title').AsString);
                  RelObj.AddPair('target_doc_id', TJSONNumber.Create(SubQry.FieldByName('target_doc_id').AsInteger));
                  RelObj.AddPair('target_title', SubQry.FieldByName('target_title').AsString);
                  (Row.GetValue('relations') as TJSONArray).Add(RelObj);
                end;
                SubQry.Next;
              end;
            finally
              SubQry.Free;
            end;
          finally
            IdMap.Free;
          end;
        end
        else if IncludeDetails and (Data.Count > 5) then
        begin
          for I := 0 to Data.Count - 1 do
          begin
            Row := Data.Items[I] as TJSONObject;
            Row.AddPair('details_omitted', TJSONBool.Create(True));
          end;
        end;

        Result := MxSuccessResponse(Data);
      except
        Data.Free;
        raise;
      end;
    finally
      Qry.Free;
    end;
  finally
    ProjIdCache.Free;
  end;

  // Log access for predictive prefetch
  try
    Qry := AContext.CreateQuery(
      'INSERT INTO access_log (session_id, developer_id, tool_name, doc_id, project_id, context_tool) ' +
      'VALUES (:session_id, :dev_id, ''mx_search'', 0, :proj_id, NULL)');
    try
      Qry.ParamByName('session_id').DataType := ftInteger;
      if AParams.GetValue<Integer>('session_id', 0) > 0 then
        Qry.ParamByName('session_id').AsInteger := AParams.GetValue<Integer>('session_id', 0)
      else
        Qry.ParamByName('session_id').Clear;
      Qry.ParamByName('dev_id').AsInteger := MxGetThreadAuth.DeveloperId;
      Qry.ParamByName('proj_id').DataType := ftInteger;
      if ProjectSlug <> '' then
        Qry.ParamByName('proj_id').AsInteger := ProjId
      else
        Qry.ParamByName('proj_id').Clear;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      AContext.Logger.Log(mlWarning, '[mx_search] access_log INSERT failed: ' + E.Message);
  end;
end;

// ---------------------------------------------------------------------------
// mx_detail — Dokument-Volltext (3 separate Queries statt CALL sp_detail,
// weil FireDAC DirectExecute=True + NextRecordSet nicht kompatibel sind
// und MariaDB CALL ohne DirectExecute ablehnt)
// ---------------------------------------------------------------------------
function HandleDetail(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, ProjectId, MaxContentTokens, CharLimit: Integer;
  ProjectSlug, Content: string;
  Data: TJSONObject;
  Tags: TJSONArray;
  Relations: TJSONArray;
  Row: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');
  MaxContentTokens := AParams.GetValue<Integer>('max_content_tokens', 600);

  // Query 1: Document
  Qry := AContext.CreateQuery(
    'SELECT d.id, d.project_id, p.slug AS project, d.doc_type, d.slug, d.title, ' +
    '  d.status, d.summary_l1, d.summary_l2, d.content, d.token_estimate, ' +
    '  d.confidence, d.created_by, DATEDIFF(NOW(), d.updated_at) AS days_since_update, ' +
    '  d.created_at, d.updated_at ' +
    'FROM documents d ' +
    'JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.id = :doc_id AND p.is_active = TRUE');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));

    // ACL: check read access to the document's project
    ProjectId := Qry.FieldByName('project_id').AsInteger;
    ProjectSlug := Qry.FieldByName('project').AsString;
    if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
      raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

    Data := TJSONObject.Create;
    try
      Data.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Data.AddPair('project', Qry.FieldByName('project').AsString);
      Data.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
      Data.AddPair('slug', Qry.FieldByName('slug').AsString);
      Data.AddPair('title', Qry.FieldByName('title').AsString);
      Data.AddPair('status', Qry.FieldByName('status').AsString);
      Data.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
      Data.AddPair('summary_l2', Qry.FieldByName('summary_l2').AsString);
      Content := Qry.FieldByName('content').AsString;
      if (MaxContentTokens > 0) and (Length(Content) > MaxContentTokens * 4) then
      begin
        CharLimit := MaxContentTokens * 4;  // ~1 token = 4 chars
        Content := Copy(Content, 1, CharLimit) + #13#10 + '... [truncated at ' + IntToStr(MaxContentTokens) + ' tokens]';
        Data.AddPair('content_truncated', TJSONBool.Create(True));
      end;
      Data.AddPair('content', Content);
      Data.AddPair('token_estimate',
        TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
      // Confidence: base score + effective (with time decay)
      var BaseConf := Qry.FieldByName('confidence').AsFloat;
      var DaysSince := Qry.FieldByName('days_since_update').AsInteger;
      var EffConf := BaseConf - (DaysSince / 180) * 0.5;
      if EffConf < 0.10 then EffConf := 0.10;
      Data.AddPair('confidence', TJSONNumber.Create(Round(BaseConf * 100) / 100));
      Data.AddPair('effective_confidence', TJSONNumber.Create(Round(EffConf * 100) / 100));
      Data.AddPair('days_since_update', TJSONNumber.Create(DaysSince));
      Data.AddPair('created_by', Qry.FieldByName('created_by').AsString);
      Data.AddPair('created_at', Qry.FieldByName('created_at').AsString);
      Data.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);
    except
      Data.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;

  // Query 2: Tags
  Tags := TJSONArray.Create;
  Qry := AContext.CreateQuery(
    'SELECT tag FROM doc_tags WHERE doc_id = :doc_id ORDER BY tag');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.Open;
    while not Qry.Eof do
    begin
      Tags.Add(Qry.FieldByName('tag').AsString);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  Data.AddPair('tags', Tags);

  // Query 3: Relations
  Relations := TJSONArray.Create;
  Qry := AContext.CreateQuery(
    'SELECT dr.id AS relation_id, dr.relation_type, ' +
    '  dr.source_doc_id, ds.title AS source_title, ' +
    '  dr.target_doc_id, dt.title AS target_title ' +
    'FROM doc_relations dr ' +
    'JOIN documents ds ON ds.id = dr.source_doc_id ' +
    'JOIN documents dt ON dt.id = dr.target_doc_id ' +
    'WHERE dr.source_doc_id = :doc_id OR dr.target_doc_id = :doc_id');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
      Row.AddPair('source_doc_id',
        TJSONNumber.Create(Qry.FieldByName('source_doc_id').AsInteger));
      Row.AddPair('source_title', Qry.FieldByName('source_title').AsString);
      Row.AddPair('target_doc_id',
        TJSONNumber.Create(Qry.FieldByName('target_doc_id').AsInteger));
      Row.AddPair('target_title', Qry.FieldByName('target_title').AsString);
      Relations.Add(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  Data.AddPair('relations', Relations);

  // Increment access_count (fire-and-forget, for briefing relevance scoring)
  try
    Qry := AContext.CreateQuery(
      'UPDATE documents SET access_count = access_count + 1 WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      AContext.Logger.Log(mlWarning, '[mx_detail] access_count UPDATE failed: ' + E.Message);
  end;

  // Log access for predictive prefetch
  try
    Qry := AContext.CreateQuery(
      'INSERT INTO access_log (session_id, developer_id, tool_name, doc_id, project_id, context_tool) ' +
      'VALUES (:session_id, :dev_id, ''mx_detail'', :doc_id, :proj_id, ' +
      '  (SELECT tool_name FROM access_log WHERE session_id = :session_id2 ' +
      '   ORDER BY id DESC LIMIT 1))');
    try
      Qry.ParamByName('session_id').DataType := ftInteger;
      Qry.ParamByName('session_id2').DataType := ftInteger;
      if AParams.GetValue<Integer>('session_id', 0) > 0 then
      begin
        Qry.ParamByName('session_id').AsInteger := AParams.GetValue<Integer>('session_id', 0);
        Qry.ParamByName('session_id2').AsInteger := AParams.GetValue<Integer>('session_id', 0);
      end
      else
      begin
        Qry.ParamByName('session_id').Clear;
        Qry.ParamByName('session_id2').Clear;
      end;
      Qry.ParamByName('dev_id').AsInteger := MxGetThreadAuth.DeveloperId;
      Qry.ParamByName('doc_id').AsInteger := DocId;
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      AContext.Logger.Log(mlWarning, '[mx_detail] access_log INSERT failed: ' + E.Message);
  end;

  try
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_batch_detail — Multiple documents in one call
// ---------------------------------------------------------------------------
function HandleBatchDetail(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocIds: TJSONArray;
  DocId, ProjectId, I: Integer;
  IdList, ProjectSlug, Level: string;
  IncludeContent: Boolean;
  Data: TJSONArray;
  Row, RelObj: TJSONObject;
  Tags: TJSONArray;
  Relations: TJSONArray;
  IdMap: TDictionary<Integer, TJSONObject>;
begin
  DocIds := AParams.GetValue<TJSONArray>('doc_ids', nil);
  if (DocIds = nil) or (DocIds.Count = 0) then
    raise EMxValidation.Create('Parameter "doc_ids" is required (array of integers)');
  if DocIds.Count > 10 then
    raise EMxValidation.Create('Maximum 10 doc_ids per batch_detail call');

  // Level: full (default) = all fields, summary = no content
  Level := AParams.GetValue<string>('level', 'full').ToLower;
  IncludeContent := (Level <> 'summary');

  // Build ID list (safe: only integers)
  IdList := '';
  for I := 0 to DocIds.Count - 1 do
  begin
    if IdList <> '' then IdList := IdList + ',';
    IdList := IdList + IntToStr(DocIds.Items[I].GetValue<Integer>);
  end;

  // Query 1: Load all documents
  Qry := AContext.CreateQuery(
    'SELECT d.id, d.project_id, p.slug AS project, d.doc_type, d.slug, d.title, ' +
    'd.status, d.summary_l1, d.summary_l2, d.content, d.token_estimate, ' +
    'd.confidence, DATEDIFF(NOW(), d.updated_at) AS days_since_update, ' +
    'd.created_at, d.updated_at ' +
    'FROM documents d ' +
    'JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.id IN (' + IdList + ') AND p.is_active = TRUE');
  try
    Qry.Open;
    Data := TJSONArray.Create;
    IdMap := TDictionary<Integer, TJSONObject>.Create;
    try
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;
        ProjectId := Qry.FieldByName('project_id').AsInteger;
        ProjectSlug := Qry.FieldByName('project').AsString;

        // ACL: skip docs from projects the user cannot access
        if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
        begin
          Qry.Next;
          Continue;
        end;

        Row := TJSONObject.Create;
        Row.AddPair('id', TJSONNumber.Create(DocId));
        Row.AddPair('project', ProjectSlug);
        Row.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
        Row.AddPair('slug', Qry.FieldByName('slug').AsString);
        Row.AddPair('title', Qry.FieldByName('title').AsString);
        Row.AddPair('status', Qry.FieldByName('status').AsString);
        Row.AddPair('summary_l1', Qry.FieldByName('summary_l1').AsString);
        Row.AddPair('summary_l2', Qry.FieldByName('summary_l2').AsString);
        if IncludeContent then
          Row.AddPair('content', Qry.FieldByName('content').AsString);
        Row.AddPair('token_estimate',
          TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
        Row.AddPair('confidence',
          TJSONNumber.Create(Qry.FieldByName('confidence').AsFloat));
        Row.AddPair('days_since_update',
          TJSONNumber.Create(Qry.FieldByName('days_since_update').AsInteger));
        Row.AddPair('created_at', Qry.FieldByName('created_at').AsString);
        Row.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);

        Data.Add(Row);
        IdMap.Add(DocId, Row);
        Qry.Next;
      end;

      // Query 2: Tags for all docs
      if IdMap.Count > 0 then
      begin
        // Init empty tags arrays
        for I := 0 to Data.Count - 1 do
          (Data.Items[I] as TJSONObject).AddPair('tags', TJSONArray.Create);

        Qry.Close;
        Qry.SQL.Text :=
          'SELECT doc_id, tag FROM doc_tags WHERE doc_id IN (' + IdList + ')';
        Qry.Open;
        while not Qry.Eof do
        begin
          DocId := Qry.FieldByName('doc_id').AsInteger;
          if IdMap.TryGetValue(DocId, Row) then
            (Row.GetValue('tags') as TJSONArray).Add(Qry.FieldByName('tag').AsString);
          Qry.Next;
        end;
      end;

      // Query 3: Relations for all docs
      if IdMap.Count > 0 then
      begin
        for I := 0 to Data.Count - 1 do
          (Data.Items[I] as TJSONObject).AddPair('relations', TJSONArray.Create);

        Qry.Close;
        Qry.SQL.Text :=
          'SELECT dr.source_doc_id, dr.target_doc_id, dr.relation_type, ' +
          'ds.title AS source_title, dt.title AS target_title ' +
          'FROM doc_relations dr ' +
          'JOIN documents ds ON ds.id = dr.source_doc_id ' +
          'JOIN documents dt ON dt.id = dr.target_doc_id ' +
          'WHERE dr.source_doc_id IN (' + IdList + ') ' +
          'OR dr.target_doc_id IN (' + IdList + ')';
        Qry.Open;
        while not Qry.Eof do
        begin
          Row := nil;
          DocId := Qry.FieldByName('source_doc_id').AsInteger;
          if not IdMap.TryGetValue(DocId, Row) then
          begin
            DocId := Qry.FieldByName('target_doc_id').AsInteger;
            IdMap.TryGetValue(DocId, Row);
          end;
          if Row <> nil then
          begin
            RelObj := TJSONObject.Create;
            RelObj.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
            RelObj.AddPair('source_doc_id', TJSONNumber.Create(Qry.FieldByName('source_doc_id').AsInteger));
            RelObj.AddPair('source_title', Qry.FieldByName('source_title').AsString);
            RelObj.AddPair('target_doc_id', TJSONNumber.Create(Qry.FieldByName('target_doc_id').AsInteger));
            RelObj.AddPair('target_title', Qry.FieldByName('target_title').AsString);
            (Row.GetValue('relations') as TJSONArray).Add(RelObj);
          end;
          Qry.Next;
        end;
      end;

      Result := MxSuccessResponse(Data);
    except
      Data.Free;
      IdMap.Free;
      raise;
    end;
    IdMap.Free;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_doc_revisions — List recent revisions of a document (Wave 2b, Bug#3018
// follow-up). Reads the doc_revisions table populated by mx_update_doc.
// ACL: same project-read check as mx_detail.
// ---------------------------------------------------------------------------
function HandleDocRevisions(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, ProjectId, MaxLimit: Integer;
  ProjectSlug: string;
  Data: TJSONObject;
  Revisions: TJSONArray;
  Row: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  MaxLimit := AParams.GetValue<Integer>('limit', 20);
  if MaxLimit < 1 then MaxLimit := 1;
  if MaxLimit > 100 then MaxLimit := 100;

  // Query 1: Resolve document + ACL on project (mirrors HandleDetail pattern)
  Qry := AContext.CreateQuery(
    'SELECT d.project_id, p.slug AS project ' +
    'FROM documents d ' +
    'JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.id = :doc_id AND p.is_active = TRUE');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));
    ProjectId := Qry.FieldByName('project_id').AsInteger;
    ProjectSlug := Qry.FieldByName('project').AsString;
  finally
    Qry.Free;
  end;

  if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

  // Query 2: List revisions (newest first)
  Revisions := TJSONArray.Create;
  Qry := AContext.CreateQuery(
    'SELECT id, revision, changed_at, changed_by, change_reason, ' +
    '  LENGTH(content) AS content_length, LEFT(content, 100) AS content_preview ' +
    'FROM doc_revisions ' +
    'WHERE doc_id = :doc_id ' +
    'ORDER BY revision DESC ' +
    'LIMIT :lim');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.ParamByName('lim').AsInteger := MaxLimit;
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('revision_id',
        TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Row.AddPair('revision',
        TJSONNumber.Create(Qry.FieldByName('revision').AsInteger));
      Row.AddPair('changed_at', Qry.FieldByName('changed_at').AsString);
      Row.AddPair('changed_by', Qry.FieldByName('changed_by').AsString);
      Row.AddPair('change_reason', Qry.FieldByName('change_reason').AsString);
      Row.AddPair('content_length',
        TJSONNumber.Create(Qry.FieldByName('content_length').AsInteger));
      Row.AddPair('content_preview', Qry.FieldByName('content_preview').AsString);
      Revisions.Add(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('doc_id', TJSONNumber.Create(DocId));
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('count', TJSONNumber.Create(Revisions.Count));
    Data.AddPair('limit', TJSONNumber.Create(MaxLimit));
    Data.AddPair('revisions', Revisions);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_get_revision — Fetch the full body of one revision (Wave 2b).
// ACL: same project-read check as mx_detail. Raises EMxNotFound when the
// (doc_id, revision) pair does not exist.
// ---------------------------------------------------------------------------
function HandleGetRevision(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, RevNum, ProjectId: Integer;
  ProjectSlug: string;
  Data: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');
  RevNum := AParams.GetValue<Integer>('revision', 0);
  if RevNum = 0 then
    raise EMxValidation.Create('Parameter "revision" is required');

  // Query 1: Resolve document + ACL on project
  Qry := AContext.CreateQuery(
    'SELECT d.project_id, p.slug AS project ' +
    'FROM documents d ' +
    'JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.id = :doc_id AND p.is_active = TRUE');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));
    ProjectId := Qry.FieldByName('project_id').AsInteger;
    ProjectSlug := Qry.FieldByName('project').AsString;
  finally
    Qry.Free;
  end;

  if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

  // Query 2: Load the revision row (full content)
  Qry := AContext.CreateQuery(
    'SELECT id, revision, changed_at, changed_by, change_reason, ' +
    '  content, LENGTH(content) AS content_length ' +
    'FROM doc_revisions ' +
    'WHERE doc_id = :doc_id AND revision = :rev ' +
    'LIMIT 1');
  try
    Qry.ParamByName('doc_id').AsInteger := DocId;
    Qry.ParamByName('rev').AsInteger := RevNum;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.CreateFmt(
        'Revision not found: doc_id=%d revision=%d', [DocId, RevNum]);

    Data := TJSONObject.Create;
    try
      Data.AddPair('doc_id', TJSONNumber.Create(DocId));
      Data.AddPair('project', ProjectSlug);
      Data.AddPair('revision_id',
        TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Data.AddPair('revision',
        TJSONNumber.Create(Qry.FieldByName('revision').AsInteger));
      Data.AddPair('changed_at', Qry.FieldByName('changed_at').AsString);
      Data.AddPair('changed_by', Qry.FieldByName('changed_by').AsString);
      Data.AddPair('change_reason', Qry.FieldByName('change_reason').AsString);
      Data.AddPair('content', Qry.FieldByName('content').AsString);
      Data.AddPair('content_length',
        TJSONNumber.Create(Qry.FieldByName('content_length').AsInteger));
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
