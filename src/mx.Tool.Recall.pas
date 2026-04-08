unit mx.Tool.Recall;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils, System.StrUtils, System.Math,
  System.Diagnostics,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors;

function HandleRecall(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleRecallOutcome(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  mx.Logic.AccessControl,
  mx.Data.Graph;

type
  TRecallItem = record
    DocId: Integer;
    Title: string;
    Summary: string;
    LessonType: string;   // rule, pitfall, solution, decision_note, integration_fact
    Scope: string;        // project, shared-domain, global
    Severity: string;     // low, medium, high, critical
    AppliesTo: string;    // comma-sep patterns
    RecommendedAction: string;
    AvoidAction: string;
    Tags: string;         // comma-sep from doc_tags
    Confidence: Double;
    ViolationCount: Integer;
    SuccessCount: Integer;
    CreatedAt: TDateTime;
    Score: Double;
  end;

  TGateResult = record
    Level: string;        // INFO, WARN, BLOCK
    Reason: string;
    LessonIds: string;    // comma-sep doc_ids that triggered
    Patterns: string;     // comma-sep applies_to patterns
    Action: string;       // recommended_action from top lesson
    AvoidAction: string;  // avoid_action from top lesson
  end;

// ---------------------------------------------------------------------------
// Scoring: Calculate relevance score for a lesson
// ---------------------------------------------------------------------------
function CalculateScore(const AItem: TRecallItem; const AQuery: string;
  const AIntent: string): Double;
var
  Score: Double;
  DaysSinceCreated: Double;
  SeverityWeight: Double;
begin
  Score := 0;

  // --- File/Pattern match (highest weight) ---
  if (AQuery <> '') and (Pos(LowerCase(AQuery), LowerCase(AItem.AppliesTo)) > 0) then
    Score := Score + 50;
  if (AQuery <> '') and (Pos(LowerCase(AQuery), LowerCase(AItem.Title)) > 0) then
    Score := Score + 20;

  // --- Severity weight ---
  if AItem.Severity = 'critical' then SeverityWeight := 40
  else if AItem.Severity = 'high' then SeverityWeight := 25
  else if AItem.Severity = 'medium' then SeverityWeight := 10
  else SeverityWeight := 3;
  Score := Score + SeverityWeight;

  // --- Recency (newer = higher, decay over 30 days) ---
  DaysSinceCreated := Max(1, DaysBetween(Now, AItem.CreatedAt));
  if DaysSinceCreated <= 7 then
    Score := Score + 15
  else if DaysSinceCreated <= 30 then
    Score := Score + 8
  else
    Score := Score + Max(1, 8 - (DaysSinceCreated / 10));

  // --- Violation count (more violations = more important) ---
  Score := Score + Min(20, AItem.ViolationCount * 5);

  // --- Confidence boost ---
  Score := Score + (AItem.Confidence * 10);

  // --- Lesson type relevance per intent ---
  if (AIntent = 'implement') and (AItem.LessonType = 'pitfall') then
    Score := Score + 10;
  if (AIntent = 'debug') and (AItem.LessonType = 'solution') then
    Score := Score + 10;
  if (AIntent = 'review') and (AItem.LessonType = 'rule') then
    Score := Score + 10;
  if (AIntent = 'design') and (AItem.LessonType = 'decision_note') then
    Score := Score + 10;

  // --- Negative: low confirmation rate ---
  if (AItem.ViolationCount + AItem.SuccessCount > 5) then
  begin
    if AItem.SuccessCount = 0 then
      Score := Score - 10;
  end;

  Result := Score;
end;

// ---------------------------------------------------------------------------
// Budget class: determine response size based on top severity
// ---------------------------------------------------------------------------
function DetermineBudgetClass(const ATopSeverity: string;
  ATopScore: Double): string;
begin
  // High score (direct match) + high severity = critical
  if (ATopScore >= 80) and ((ATopSeverity = 'critical') or (ATopSeverity = 'high')) then
    Result := 'critical'
  // Medium score or medium severity = standard
  else if (ATopScore >= 40) and (ATopSeverity <> 'low') then
    Result := 'standard'
  else
    Result := 'tiny';
end;

// ---------------------------------------------------------------------------
// Gate: Severity x Confidence → INFO/WARN/BLOCK (B2)
// ---------------------------------------------------------------------------
function HasBlockTag(const ATags: string): Boolean;
begin
  Result := (Pos('production-bug', ATags) > 0) or
            (Pos('security', ATags) > 0) or
            (Pos('data-integrity', ATags) > 0);
end;

function DetermineGate(const AItems: array of TRecallItem;
  ACount: Integer): TGateResult;
var
  I: Integer;
  Ids: string;
  Pats: string;
begin
  Result.Level := 'INFO';
  Result.Reason := '';
  Result.LessonIds := '';
  Result.Patterns := '';
  Result.Action := '';
  Result.AvoidAction := '';

  if ACount = 0 then Exit;

  Ids := '';
  Pats := '';

  for I := 0 to Min(ACount, 10) - 1 do
  begin
    // BLOCK: critical + (rule|integration_fact) + violation_count>=2 + block-tag
    if (AItems[I].Severity = 'critical') and
       ((AItems[I].LessonType = 'rule') or (AItems[I].LessonType = 'integration_fact')) and
       (AItems[I].ViolationCount >= 2) and
       HasBlockTag(AItems[I].Tags) then
    begin
      Result.Level := 'BLOCK';
      Result.Reason := Format('Critical %s (doc_id=%d) with %d violations: %s',
        [AItems[I].LessonType, AItems[I].DocId, AItems[I].ViolationCount,
         AItems[I].Title]);
      if Result.Action = '' then
        Result.Action := AItems[I].RecommendedAction;
      if Result.AvoidAction = '' then
        Result.AvoidAction := AItems[I].AvoidAction;
      if Ids <> '' then Ids := Ids + ',';
      Ids := Ids + IntToStr(AItems[I].DocId);
      if (AItems[I].AppliesTo <> '') then
      begin
        if Pats <> '' then Pats := Pats + ',';
        Pats := Pats + AItems[I].AppliesTo;
      end;
    end
    // WARN: high/critical severity OR confirmed violation
    else if (Result.Level <> 'BLOCK') and
            ((AItems[I].Severity = 'critical') or (AItems[I].Severity = 'high') or
             (AItems[I].ViolationCount >= 1)) then
    begin
      if Result.Level <> 'WARN' then
      begin
        Result.Level := 'WARN';
        Result.Reason := Format('%s severity %s (doc_id=%d): %s',
          [AItems[I].Severity, AItems[I].LessonType, AItems[I].DocId,
           AItems[I].Title]);
      end;
      if Result.Action = '' then
        Result.Action := AItems[I].RecommendedAction;
      if Result.AvoidAction = '' then
        Result.AvoidAction := AItems[I].AvoidAction;
      if Ids <> '' then Ids := Ids + ',';
      Ids := Ids + IntToStr(AItems[I].DocId);
      if (AItems[I].AppliesTo <> '') then
      begin
        if Pats <> '' then Pats := Pats + ',';
        Pats := Pats + AItems[I].AppliesTo;
      end;
    end;
  end;

  // INFO: fill action from top item if not set
  if (Result.Level = 'INFO') and (ACount > 0) then
  begin
    Result.Action := AItems[0].RecommendedAction;
    Result.AvoidAction := AItems[0].AvoidAction;
    if AItems[0].DocId > 0 then
      Ids := IntToStr(AItems[0].DocId);
    Pats := AItems[0].AppliesTo;
  end;

  Result.LessonIds := Ids;
  Result.Patterns := Pats;
end;

// ---------------------------------------------------------------------------
// mx_recall — Central recall for relevant project knowledge
// ---------------------------------------------------------------------------
function HandleRecall(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  Query, ProjectSlug, Scope, Intent: string;
  ProjectId: Integer;
  Items: array of TRecallItem;
  ItemCount, I, J: Integer;
  Temp: TRecallItem;
  HardRules, Pitfalls, Solutions, RelatedDocs: TJSONArray;
  ItemObj: TJSONObject;
  Data: TJSONObject;
  TopSeverity, BudgetClass: string;
  LessonData: TJSONObject;
  LessonStr: string;
  MaxItems: Integer;
  SW: TStopwatch;
  LatencyMs: Integer;
  TopScore: Double;
  RecallId: Int64;
  SessionId: Integer;
  TargetFile: string;
  Gate: TGateResult;
  GateObj: TJSONObject;
begin
  SW := TStopwatch.StartNew;
  Query := AParams.GetValue<string>('query', '');
  ProjectSlug := AParams.GetValue<string>('project', '');
  Scope := AParams.GetValue<string>('scope', 'project');
  Intent := AParams.GetValue<string>('intent', 'general');

  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  if not MatchStr(Scope, ['project', 'shared-domain', 'global']) then
    Scope := 'project';
  if not MatchStr(Intent, ['implement', 'debug', 'review', 'design', 'migrate', 'general']) then
    Intent := 'general';

  // Resolve project
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  // ACL
  if not AContext.AccessControl.CheckProject(ProjectId, alRead) then
    raise EMxAccessDenied.Create(ProjectSlug, alRead);

  // --- Query lessons ---
  // Phase 1: Always includes project lessons + _global lessons (env/key conventions)
  // Scope param is accepted but reserved for future filtering
  Qry := AContext.CreateQuery(
    'SELECT d.id, d.title, d.summary_l1, d.lesson_data, d.confidence, ' +
    '  d.violation_count, d.success_count, d.created_at, ' +
    '  p.slug AS project_slug, ' +
    '  (SELECT GROUP_CONCAT(dt.tag ORDER BY dt.tag SEPARATOR '','') ' +
    '   FROM doc_tags dt WHERE dt.doc_id = d.id) AS tag_names ' +
    'FROM documents d ' +
    'JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.doc_type = ''lesson'' AND d.status <> ''deleted'' ' +
    '  AND (d.project_id = :pid OR p.slug = ''_global'') ' +
    'ORDER BY d.created_at DESC ' +
    'LIMIT 50');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.Open;

    ItemCount := 0;
    SetLength(Items, 50);

    while not Qry.Eof do
    begin
      if ItemCount >= 50 then Break;

      Items[ItemCount].DocId := Qry.FieldByName('id').AsInteger;
      Items[ItemCount].Title := Qry.FieldByName('title').AsString;
      Items[ItemCount].Summary := Qry.FieldByName('summary_l1').AsString;
      Items[ItemCount].Confidence := Qry.FieldByName('confidence').AsFloat;
      Items[ItemCount].ViolationCount := Qry.FieldByName('violation_count').AsInteger;
      Items[ItemCount].SuccessCount := Qry.FieldByName('success_count').AsInteger;
      Items[ItemCount].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Items[ItemCount].Tags := Qry.FieldByName('tag_names').AsString;

      // Parse lesson_data JSON
      LessonStr := Qry.FieldByName('lesson_data').AsString;
      if LessonStr <> '' then
      begin
        LessonData := nil;
        try
          LessonData := TJSONObject.ParseJSONValue(LessonStr) as TJSONObject;
          if LessonData <> nil then
          begin
            Items[ItemCount].LessonType := LessonData.GetValue<string>('type', 'pitfall');
            Items[ItemCount].Scope := LessonData.GetValue<string>('scope', 'project');
            Items[ItemCount].Severity := LessonData.GetValue<string>('severity', 'medium');
            Items[ItemCount].AppliesTo := LessonData.GetValue<string>('applies_to', '');
            Items[ItemCount].RecommendedAction := LessonData.GetValue<string>('recommended_action', '');
            Items[ItemCount].AvoidAction := LessonData.GetValue<string>('avoid_action', '');
          end;
        finally
          LessonData.Free;
        end;
      end
      else
      begin
        Items[ItemCount].LessonType := 'pitfall';
        Items[ItemCount].Scope := 'project';
        Items[ItemCount].Severity := 'medium';
        Items[ItemCount].AppliesTo := '';
        Items[ItemCount].RecommendedAction := '';
        Items[ItemCount].AvoidAction := '';
      end;

      // Calculate score
      Items[ItemCount].Score := CalculateScore(Items[ItemCount], Query, Intent);

      Inc(ItemCount);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  // Also search skill_findings for relevant findings
  if Query <> '' then
  begin
    Qry := AContext.CreateQuery(
      'SELECT sf.id, sf.title, sf.details, sf.severity, sf.rule_id, sf.created_at ' +
      'FROM skill_findings sf ' +
      'WHERE sf.project_id = :pid AND sf.user_reaction = ''confirmed'' ' +
      '  AND (sf.title LIKE :q OR sf.details LIKE :q2 OR sf.file_path LIKE :q3) ' +
      'ORDER BY sf.created_at DESC LIMIT 10');
    try
      Qry.ParamByName('pid').AsInteger := ProjectId;
      Qry.ParamByName('q').AsString := '%' + Query + '%';
      Qry.ParamByName('q2').AsString := '%' + Query + '%';
      Qry.ParamByName('q3').AsString := '%' + Query + '%';
      Qry.Open;

      while not Qry.Eof do
      begin
        if ItemCount >= Length(Items) then
          SetLength(Items, ItemCount + 10);

        Items[ItemCount].DocId := -Qry.FieldByName('id').AsInteger; // negative = finding
        Items[ItemCount].Title := '[Finding] ' + Qry.FieldByName('title').AsString;
        Items[ItemCount].Summary := Qry.FieldByName('details').AsString;
        Items[ItemCount].LessonType := 'pitfall';
        Items[ItemCount].Scope := 'project';
        Items[ItemCount].Severity := Qry.FieldByName('severity').AsString;
        Items[ItemCount].AppliesTo := Qry.FieldByName('rule_id').AsString;
        Items[ItemCount].RecommendedAction := '';
        Items[ItemCount].Confidence := 0.8;
        Items[ItemCount].ViolationCount := 0;
        Items[ItemCount].SuccessCount := 0;
        Items[ItemCount].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
        Items[ItemCount].Score := CalculateScore(Items[ItemCount], Query, Intent);

        Inc(ItemCount);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  end;

  // --- Sort by score descending (simple bubble sort, max 60 items) ---
  for I := 0 to ItemCount - 2 do
    for J := I + 1 to ItemCount - 1 do
      if Items[J].Score > Items[I].Score then
      begin
        Temp := Items[I];
        Items[I] := Items[J];
        Items[J] := Temp;
      end;

  // --- Lazy Graph-Population (Phase 2: populate nodes+edges on recall) ---
  TargetFile := AParams.GetValue<string>('target_file', '');
  if (TargetFile <> '') and (ItemCount > 0) then
  begin
    try
      // Create file node for the queried file
      var FileNodeId := TMxGraphData.FindOrCreateNode(AContext,
        'file', TargetFile, ProjectId);
      // Link top lessons to this file via applies_to edges (max 5)
      for I := 0 to Min(5, ItemCount) - 1 do
      begin
        if Items[I].DocId > 0 then
        begin
          var LessonNodeId := TMxGraphData.FindOrCreateNode(AContext,
            'lesson', Items[I].Title, ProjectId, Items[I].DocId);
          TMxGraphData.FindOrCreateEdge(AContext,
            LessonNodeId, FileNodeId, 'applies_to',
            Items[I].Score / 100);
        end;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlDebug, 'Graph population skipped: ' + E.Message);
    end;
  end;

  // --- Graph-boosted scoring (Phase 2: neighbors boost) ---
  if (TargetFile <> '') and (ItemCount > 0) then
  begin
    try
      var FileNodeId := TMxGraphData.FindNode(AContext, 'file', TargetFile, ProjectId);
      if FileNodeId > 0 then
      begin
        var Neighbors := TMxGraphData.GetNeighbors(AContext, FileNodeId, 1, 'applies_to');
        for I := 0 to ItemCount - 1 do
        begin
          for J := 0 to High(Neighbors) do
          begin
            if (Neighbors[J].DocId > 0) and (Neighbors[J].DocId = Items[I].DocId) then
            begin
              Items[I].Score := Items[I].Score + 15; // graph-neighbor bonus
              Break;
            end;
          end;
        end;
        // Re-sort after graph boost
        for I := 0 to ItemCount - 2 do
          for J := I + 1 to ItemCount - 1 do
            if Items[J].Score > Items[I].Score then
            begin
              Temp := Items[I];
              Items[I] := Items[J];
              Items[J] := Temp;
            end;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlDebug, 'Graph scoring skipped: ' + E.Message);
    end;
  end;

  // --- Determine budget class from top severity + score ---
  TopSeverity := 'low';
  if ItemCount > 0 then
    TopSeverity := Items[0].Severity;
  if ItemCount > 0 then
    BudgetClass := DetermineBudgetClass(TopSeverity, Items[0].Score)
  else
    BudgetClass := 'tiny';

  // Max items per budget class
  if BudgetClass = 'tiny' then MaxItems := 3
  else if BudgetClass = 'standard' then MaxItems := 6
  else MaxItems := 10;
  if MaxItems > ItemCount then MaxItems := ItemCount;

  // --- Build response ---
  Result := TJSONObject.Create;
  try
    HardRules := TJSONArray.Create;
    Pitfalls := TJSONArray.Create;
    Solutions := TJSONArray.Create;
    RelatedDocs := TJSONArray.Create;

    for I := 0 to MaxItems - 1 do
    begin
      ItemObj := TJSONObject.Create;
      ItemObj.AddPair('doc_id', TJSONNumber.Create(Items[I].DocId));
      ItemObj.AddPair('title', Items[I].Title);
      if Items[I].Summary <> '' then
        ItemObj.AddPair('summary', Copy(Items[I].Summary, 1, 200));
      if Items[I].RecommendedAction <> '' then
        ItemObj.AddPair('action', Copy(Items[I].RecommendedAction, 1, 200));
      ItemObj.AddPair('severity', Items[I].Severity);
      ItemObj.AddPair('score', TJSONNumber.Create(Round(Items[I].Score)));

      // Route to appropriate section
      if Items[I].LessonType = 'rule' then
      begin
        if HardRules.Count < 3 then
          HardRules.AddElement(ItemObj)
        else
          ItemObj.Free;
      end
      else if Items[I].LessonType = 'pitfall' then
      begin
        if Pitfalls.Count < 3 then
          Pitfalls.AddElement(ItemObj)
        else
          ItemObj.Free;
      end
      else if Items[I].LessonType = 'solution' then
      begin
        if Solutions.Count < 2 then
          Solutions.AddElement(ItemObj)
        else
          ItemObj.Free;
      end
      else
      begin
        if RelatedDocs.Count < 2 then
          RelatedDocs.AddElement(ItemObj)
        else
          ItemObj.Free;
      end;
    end;

    Data := TJSONObject.Create;
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('query', Query);
    Data.AddPair('budget_class', BudgetClass);
    Data.AddPair('total_lessons', TJSONNumber.Create(ItemCount));
    Data.AddPair('hard_rules', HardRules);
    Data.AddPair('pitfalls', Pitfalls);
    Data.AddPair('solutions', Solutions);
    Data.AddPair('related_docs', RelatedDocs);

    if ItemCount = 0 then
      Data.AddPair('summary', 'No relevant lessons found for this query.')
    else
      Data.AddPair('summary', Format('%d lessons found (%s budget). Top: %s',
        [ItemCount, BudgetClass, Items[0].Title]));

    // --- Gate-Level (B2) ---
    Gate := DetermineGate(Items, ItemCount);
    GateObj := TJSONObject.Create;
    GateObj.AddPair('gate_level', Gate.Level);
    if Gate.Reason <> '' then
      GateObj.AddPair('gate_reason', Gate.Reason);
    if Gate.LessonIds <> '' then
      GateObj.AddPair('triggered_by_lesson_ids', Gate.LessonIds);
    if Gate.Patterns <> '' then
      GateObj.AddPair('triggered_by_patterns', Gate.Patterns);
    if Gate.Action <> '' then
      GateObj.AddPair('recommended_action', Gate.Action);
    if Gate.AvoidAction <> '' then
      GateObj.AddPair('avoid_action', Gate.AvoidAction);
    Data.AddPair('gate', GateObj);

    // --- Log to recall_log ---
    SW.Stop;
    LatencyMs := SW.ElapsedMilliseconds;
    TopScore := 0;
    if ItemCount > 0 then
      TopScore := Items[0].Score;
    SessionId := AParams.GetValue<Integer>('session_id', 0);
    TargetFile := AParams.GetValue<string>('target_file', '');
    RecallId := 0;

    // --- Cooldown: skip INSERT if identical query within 5 min (Bug#1288) ---
    try
      Qry := AContext.CreateQuery(
        'SELECT id FROM recall_log ' +
        'WHERE project_id = :pid AND query = :q AND intent = :intent ' +
        '  AND created_at > NOW() - INTERVAL 5 MINUTE ' +
        'ORDER BY created_at DESC LIMIT 1');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('q').AsString := Copy(Query, 1, 500);
        Qry.ParamByName('intent').AsString := Intent;
        Qry.Open;
        if not Qry.IsEmpty then
        begin
          RecallId := Qry.FieldByName('id').AsLargeInt;
          Data.AddPair('recall_id', TJSONNumber.Create(RecallId));
          Data.AddPair('latency_ms', TJSONNumber.Create(LatencyMs));
          Data.AddPair('cached', TJSONBool.Create(True));
          Result := MxSuccessResponse(Data);
          Exit;
        end;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlWarning, 'recall cooldown check failed: ' + E.Message);
    end;

    try
      Qry := AContext.CreateQuery(
        'INSERT INTO recall_log (session_id, project_id, query, intent, ' +
        '  target_file, treffer_count, top_score, budget_class, latency_ms, ' +
        '  outcome, gate_level, gate_reason, triggered_lesson_ids) ' +
        'VALUES (:sid, :pid, :q, :intent, :tf, :tc, :ts, :bc, :lms, ' +
        '  ''shown'', :gl, :gr, :tli)');
      try
        if SessionId > 0 then
          Qry.ParamByName('sid').AsInteger := SessionId
        else
        begin
          Qry.ParamByName('sid').DataType := ftInteger;
          Qry.ParamByName('sid').Clear;
        end;
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('q').AsString := Copy(Query, 1, 500);
        Qry.ParamByName('intent').AsString := Intent;
        Qry.ParamByName('tf').AsString := Copy(TargetFile, 1, 500);
        Qry.ParamByName('tc').AsInteger := ItemCount;
        Qry.ParamByName('ts').AsFloat := TopScore;
        Qry.ParamByName('bc').AsString := BudgetClass;
        Qry.ParamByName('lms').AsInteger := LatencyMs;
        Qry.ParamByName('gl').AsString := Gate.Level;
        if Gate.Reason <> '' then
          Qry.ParamByName('gr').AsString := Copy(Gate.Reason, 1, 500)
        else
        begin
          Qry.ParamByName('gr').DataType := ftString;
          Qry.ParamByName('gr').Clear;
        end;
        if Gate.LessonIds <> '' then
          Qry.ParamByName('tli').AsString := Copy(Gate.LessonIds, 1, 500)
        else
        begin
          Qry.ParamByName('tli').DataType := ftString;
          Qry.ParamByName('tli').Clear;
        end;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS recall_id');
      try
        Qry.Open;
        RecallId := Qry.FieldByName('recall_id').AsLargeInt;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlWarning, 'recall_log INSERT failed: ' + E.Message);
    end;

    Data.AddPair('recall_id', TJSONNumber.Create(RecallId));
    Data.AddPair('latency_ms', TJSONNumber.Create(LatencyMs));

    Result := MxSuccessResponse(Data);
  except
    Result.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_recall_outcome — Update outcome of a recall invocation (B6.7)
// ---------------------------------------------------------------------------
function HandleRecallOutcome(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  RecallId: Int64;
  Outcome, Reason: string;
  Data: TJSONObject;
begin
  RecallId := AParams.GetValue<Int64>('recall_id', 0);
  Outcome := AParams.GetValue<string>('outcome', '');
  Reason := AParams.GetValue<string>('reason', '');

  if RecallId < 1 then
    raise EMxValidation.Create('Parameter "recall_id" is required');
  if not MatchStr(Outcome, ['shown', 'acknowledged', 'edited_after_recall',
      'applied', 'candidate_success', 'no_edit_followed', 'overridden',
      'potential_violation', 'violation']) then
    raise EMxValidation.CreateFmt('Invalid outcome "%s"', [Outcome]);

  Qry := AContext.CreateQuery(
    'UPDATE recall_log SET outcome = :outcome, override_reason = :reason ' +
    'WHERE id = :rid');
  try
    Qry.ParamByName('outcome').AsString := Outcome;
    if Reason <> '' then
      Qry.ParamByName('reason').AsString := Copy(Reason, 1, 500)
    else
    begin
      Qry.ParamByName('reason').DataType := ftString;
      Qry.ParamByName('reason').Clear;
    end;
    Qry.ParamByName('rid').AsLargeInt := RecallId;
    Qry.ExecSQL;

    if Qry.RowsAffected = 0 then
      raise EMxNotFound.Create('Recall log entry not found: ' + IntToStr(RecallId));
  finally
    Qry.Free;
  end;

  // Update last_confirmed_at on positive outcomes (AnsatzC)
  if MatchStr(Outcome, ['applied', 'edited_after_recall', 'candidate_success']) then
  begin
    try
      Qry := AContext.CreateQuery(
        'UPDATE documents SET lesson_data = JSON_SET(COALESCE(lesson_data, ''{}''), ' +
        '  ''$.last_confirmed_at'', :now) ' +
        'WHERE FIND_IN_SET(CAST(id AS CHAR), ' +
        '  (SELECT triggered_lesson_ids FROM recall_log WHERE id = :rid)) > 0 ' +
        'AND doc_type = ''lesson''');
      try
        Qry.ParamByName('now').AsString :=
          FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
        Qry.ParamByName('rid').AsLargeInt := RecallId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlWarning,
          'last_confirmed_at update failed: ' + E.Message);
    end;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('recall_id', TJSONNumber.Create(RecallId));
    Data.AddPair('outcome', Outcome);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

end.
