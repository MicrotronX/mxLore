unit mx.Intelligence.AIBatch;

interface

uses
  System.SysUtils, System.JSON, System.Classes, System.DateUtils, System.StrUtils,
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}
  Data.DB, FireDAC.Comp.Client,
  mx.Types, mx.Config, mx.Data.Pool;

type
  TMxAIJobType = (jtSummary, jtTagging, jtStaleDetection, jtStubWarning,
    jtRecallTimeout, jtViolationCounter, jtLessonDedupe,
    jtContradictionDetection, jtStaleCandidatePromotion,
    jtRecallEffectiveness, jtSkillPrecision, jtHealthAutoNotes);

  TMxAIBatchStats = record
    StaleDetected: Integer;
    StubsWarned: Integer;
    LessonDupes: Integer;
    Contradictions: Integer;
    StalePromoted: Integer;
    ClaudeExeStarted: Boolean;
    Errors: Integer;
  end;

  TMxAIBatchRunner = class
  private
    FPool: TMxConnectionPool;
    FConfig: TMxConfig;
    FLogger: IMxLogger;
    FStats: TMxAIBatchStats;
    FAIThread: TThread;

    // Audit logging (for SQL-only jobs)
    procedure LogBatchResult(ACtx: IMxDbContext; AJobType: TMxAIJobType;
      ADocId, AProjectId: Integer; const AFieldName, AOldValue, ANewValue: string;
      const AStatus: string; const AErrorMsg: string = '');

    // Summary log for jobs that don't log per-doc (uses doc_id=0, dedup per day)
    procedure LogBatchRun(AJobType: TMxAIJobType; ACount: Integer;
      const ADetail: string = '');

    // SQL-only jobs
    procedure RunStaleDetectionJob;
    procedure RunStubWarningJob;
    procedure RunRecallTimeoutJob;
    procedure RunViolationCounterJob;
    procedure RunLessonDedupeJob;
    procedure RunContradictionDetectionJob;
    procedure RunStaleCandidatePromotionJob;
    procedure RunRecallEffectivenessJob;
    procedure RunSkillPrecisionJob;
    procedure RunHealthAutoNotesJob;
    procedure RunFindingAutoDismissJob;

    // claude.exe subprocess
    procedure StartClaudeExeThread;

    class function JobTypeToStr(AJobType: TMxAIJobType): string; static;
  public
    constructor Create(APool: TMxConnectionPool; AConfig: TMxConfig;
      ALogger: IMxLogger);
    destructor Destroy; override;
    procedure RunAll;

    // MCP Tool: returns pending work items for claude.exe
    class function GetPendingWorkItems(ACtx: IMxDbContext): TJSONObject; static;

    property Stats: TMxAIBatchStats read FStats;
  end;

implementation

const
  AI_BATCH_PROMPT =
    'AUTONOMOUS BATCH JOB. NO QUESTIONS. Process ALL items without asking. ' +
    'Call mx_ai_batch_pending(). For each summary item: generate summary_l1 ' +
    '(1 sentence max 150 chars) and summary_l2 (2-3 sentences max 500 chars) ' +
    'from content_preview, then mx_update_doc(doc_id=X, summary_l1=..., summary_l2=...). ' +
    'For each tagging item: generate 3-7 lowercase tags, then ' +
    'mx_add_tags(doc_id=X, tags=''["tag1","tag2"]''). ' +
    'LOGGING: After EACH processed doc, call mx_ai_batch_log(job_type=''summary'' or ''tagging'', ' +
    'doc_id=X, project_id=Y, field_name=''summary_l1'' or ''tags'', status=''success'' or ''error''). ' +
    'Process max 20 items per run. No questions, no confirmations, just execute. ' +
    'When done: mx_search(project=''mxLore'', doc_type=''note'', query=''AI-Batch Last Run'', limit=1). ' +
    'If found: mx_update_doc(doc_id=FOUND_ID, content=''AI-Batch Last Run: X summaries Y tags generated at TIMESTAMP'', change_reason=''batch run''). ' +
    'If not found: mx_create_note(project=''mxLore'', title=''AI-Batch Last Run'', ' +
    'content=''AI-Batch Last Run: X summaries Y tags generated at TIMESTAMP'', tags=''["ai-batch-status"]'').';

{ TMxAIBatchRunner }

constructor TMxAIBatchRunner.Create(APool: TMxConnectionPool;
  AConfig: TMxConfig; ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FConfig := AConfig;
  FLogger := ALogger;
  FAIThread := nil;
  FStats := Default(TMxAIBatchStats);
end;

destructor TMxAIBatchRunner.Destroy;
begin
  // Wait for claude.exe thread if still running (max 30s)
  if Assigned(FAIThread) and not FAIThread.Finished then
  begin
    FLogger.Log(mlInfo, 'AI Batch: waiting for claude.exe to finish...');
    FAIThread.WaitFor;
  end;
  FAIThread.Free;
  inherited;
end;

class function TMxAIBatchRunner.JobTypeToStr(AJobType: TMxAIJobType): string;
const
  Names: array[TMxAIJobType] of string = (
    'summary', 'tagging', 'stale_detection', 'stub_warning',
    'recall_timeout', 'violation_counter', 'lesson_dedupe',
    'contradiction_detection', 'stale_candidate_promotion',
    'recall_effectiveness', 'skill_precision', 'health_auto_notes');
begin
  Result := Names[AJobType];
end;

{ --- Audit Logging --- }

procedure TMxAIBatchRunner.LogBatchResult(ACtx: IMxDbContext;
  AJobType: TMxAIJobType; ADocId, AProjectId: Integer;
  const AFieldName, AOldValue, ANewValue: string;
  const AStatus: string; const AErrorMsg: string);
var
  Qry: TFDQuery;
begin
  // Dedup: skip if same job_type+doc_id already logged today
  Qry := ACtx.CreateQuery(
    'SELECT 1 FROM ai_batch_log ' +
    'WHERE job_type = :jtype AND doc_id = :doc ' +
    '  AND created_at >= CURDATE() LIMIT 1');
  try
    Qry.ParamByName('jtype').AsString := JobTypeToStr(AJobType);
    Qry.ParamByName('doc').AsInteger := ADocId;
    Qry.Open;
    if not Qry.Eof then Exit; // Already logged today
  finally
    Qry.Free;
  end;

  Qry := ACtx.CreateQuery(
    'INSERT INTO ai_batch_log ' +
    '(job_type, doc_id, project_id, field_name, old_value, new_value, ' +
    ' model, tokens_input, tokens_output, status, error_message, duration_ms) ' +
    'VALUES (:jtype, :doc, :proj, :field, :old_val, :new_val, ' +
    ' ''claude-exe'', 0, 0, :status, :err, 0)');
  try
    Qry.ParamByName('jtype').AsString := JobTypeToStr(AJobType);
    Qry.ParamByName('doc').AsInteger := ADocId;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ParamByName('field').AsString := AFieldName;
    if AOldValue <> '' then
      Qry.ParamByName('old_val').AsString := AOldValue
    else begin
      Qry.ParamByName('old_val').DataType := ftString;
      Qry.ParamByName('old_val').Clear;
    end;
    if ANewValue <> '' then
      Qry.ParamByName('new_val').AsString := ANewValue
    else begin
      Qry.ParamByName('new_val').DataType := ftString;
      Qry.ParamByName('new_val').Clear;
    end;
    Qry.ParamByName('status').AsString := AStatus;
    if AErrorMsg <> '' then
      Qry.ParamByName('err').AsString := AErrorMsg
    else begin
      Qry.ParamByName('err').DataType := ftString;
      Qry.ParamByName('err').Clear;
    end;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

procedure TMxAIBatchRunner.LogBatchRun(AJobType: TMxAIJobType;
  ACount: Integer; const ADetail: string);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  if ACount = 0 then Exit; // Don't log no-op runs
  try
    Ctx := FPool.AcquireContext;
    // Dedup: one entry per job_type per day (doc_id=0 = summary)
    Qry := Ctx.CreateQuery(
      'SELECT 1 FROM ai_batch_log ' +
      'WHERE job_type = :jtype AND doc_id IS NULL ' +
      '  AND created_at >= CURDATE() LIMIT 1');
    try
      Qry.ParamByName('jtype').AsString := JobTypeToStr(AJobType);
      Qry.Open;
      if not Qry.Eof then Exit;
    finally
      Qry.Free;
    end;
    Qry := Ctx.CreateQuery(
      'INSERT INTO ai_batch_log ' +
      '(job_type, doc_id, project_id, field_name, old_value, new_value, ' +
      ' model, tokens_input, tokens_output, status, duration_ms) ' +
      'VALUES (:jtype, NULL, NULL, :field, NULL, :detail, ' +
      ' ''batch-runner'', 0, 0, ''success'', 0)');
    try
      Qry.ParamByName('jtype').AsString := JobTypeToStr(AJobType);
      Qry.ParamByName('field').AsString := IntToStr(ACount) + ' items';
      Qry.ParamByName('detail').AsString := ADetail;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, Format('LogBatchRun(%s) failed: %s',
        [JobTypeToStr(AJobType), E.Message]));
  end;
end;

{ --- MCP Tool: Get Pending Work Items --- }

class function TMxAIBatchRunner.GetPendingWorkItems(
  ACtx: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  Items: TJSONArray;
  Obj: TJSONObject;
  Content: string;
begin
  Result := TJSONObject.Create;
  try
    Items := TJSONArray.Create;
    Result.AddPair('items', Items);

    // 1. Docs without summaries
    begin
      Qry := ACtx.CreateQuery(
        'SELECT d.id, d.project_id, p.slug AS project_slug, d.title, ' +
        '  d.doc_type, SUBSTRING(d.content, 1, 2000) AS content_preview ' +
        'FROM documents d ' +
        'JOIN projects p ON p.id = d.project_id ' +
        'WHERE d.status NOT IN (''archived'', ''deleted'') ' +
        '  AND (d.summary_l1 IS NULL OR d.summary_l1 = '''' ' +
        '       OR d.summary_l2 IS NULL OR d.summary_l2 = '''') ' +
        '  AND d.content IS NOT NULL AND LENGTH(d.content) > 50 ' +
        'ORDER BY d.updated_at DESC ' +
        'LIMIT 50');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Obj := TJSONObject.Create;
          Obj.AddPair('doc_id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Obj.AddPair('project', Qry.FieldByName('project_slug').AsString);
          Obj.AddPair('type', 'summary');
          Obj.AddPair('title', Qry.FieldByName('title').AsString);
          Obj.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
          Content := Qry.FieldByName('content_preview').AsString;
          Obj.AddPair('content_preview', Content);
          Items.AddElement(Obj);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    end;

    // 2. Docs without tags
    begin
      Qry := ACtx.CreateQuery(
        'SELECT d.id, d.project_id, p.slug AS project_slug, d.title, ' +
        '  d.doc_type, SUBSTRING(d.content, 1, 1500) AS content_preview ' +
        'FROM documents d ' +
        'JOIN projects p ON p.id = d.project_id ' +
        'LEFT JOIN doc_tags dt ON dt.doc_id = d.id ' +
        'WHERE d.status NOT IN (''archived'', ''deleted'') ' +
        '  AND dt.doc_id IS NULL ' +
        '  AND d.content IS NOT NULL AND LENGTH(d.content) > 50 ' +
        'ORDER BY d.updated_at DESC ' +
        'LIMIT 30');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Obj := TJSONObject.Create;
          Obj.AddPair('doc_id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Obj.AddPair('project', Qry.FieldByName('project_slug').AsString);
          Obj.AddPair('type', 'tagging');
          Obj.AddPair('title', Qry.FieldByName('title').AsString);
          Obj.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
          Content := Qry.FieldByName('content_preview').AsString;
          Obj.AddPair('content_preview', Content);
          Items.AddElement(Obj);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    end;

    Result.AddPair('total', TJSONNumber.Create(Items.Count));
  except
    Result.Free;
    raise;
  end;
end;

{ --- Job: Stale Detection (pure SQL, no AI) --- }

procedure TMxAIBatchRunner.RunStaleDetectionJob;
var
  Ctx: IMxDbContext;
  Qry, UpdQry: TFDQuery;
  DocId, ProjectId: Integer;
  Title: string;
  Count: Integer;
begin
  if not FConfig.AIStaleDetectionEnabled then Exit;
  Count := 0;

  Ctx := FPool.AcquireContext;
  try
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.project_id, d.title ' +
      'FROM documents d ' +
      'JOIN projects p ON p.id = d.project_id AND p.is_active = TRUE ' +
      'WHERE d.doc_type = ''plan'' ' +
      '  AND d.status = ''active'' ' +
      '  AND d.updated_at < DATE_SUB(NOW(), INTERVAL 90 DAY) ' +
      'LIMIT 50');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;
        ProjectId := Qry.FieldByName('project_id').AsInteger;
        Title := Qry.FieldByName('title').AsString;

        // B7.1: Set status to stale_candidate
        UpdQry := Ctx.CreateQuery(
          'UPDATE documents SET status = ''stale_candidate'', ' +
          '  updated_at = NOW() WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := DocId;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;

        // B7.1: Create a note documenting the stale detection
        UpdQry := Ctx.CreateQuery(
          'INSERT INTO documents (project_id, doc_type, slug, title, content, status, ' +
          '  created_at, updated_at, confidence) ' +
          'VALUES (:proj_id, ''note'', :slug, :title, :content, ''active'', NOW(), NOW(), 1.0)');
        try
          UpdQry.ParamByName('proj_id').AsInteger := ProjectId;
          UpdQry.ParamByName('slug').AsString := Format('stale-%d', [DocId]);
          UpdQry.ParamByName('title').AsString := '[Stale] ' + Title;
          UpdQry.ParamByName('content').AsString :=
            Format('Plan doc_id=%d "%s" was marked as stale_candidate ' +
              '(>90 days without update). Review and either update or archive.',
              [DocId, Title]);
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;

        LogBatchResult(Ctx, jtStaleDetection, DocId, ProjectId, 'status',
          'active', 'stale_candidate', 'success');

        Inc(Count);
        FLogger.Log(mlDebug, Format('Stale plan detected+marked: doc %d (%s)', [DocId, Title]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  finally
    Ctx := nil;
  end;

  FStats.StaleDetected := Count;
end;

{ --- Job: Stub Warning (pure SQL, no AI) --- }

procedure TMxAIBatchRunner.RunStubWarningJob;
var
  Ctx: IMxDbContext;
  Qry, UpdQry: TFDQuery;
  DocId, ProjectId, TokenEst: Integer;
  Title: string;
  Count: Integer;
begin
  if not FConfig.AIStubWarningEnabled then Exit;
  Count := 0;

  Ctx := FPool.AcquireContext;
  try
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.project_id, d.title, d.token_estimate ' +
      'FROM documents d ' +
      'JOIN projects p ON p.id = d.project_id AND p.is_active = TRUE ' +
      'WHERE d.status NOT IN (''archived'', ''deleted'', ''stale_candidate'', ''stub_candidate'') ' +
      '  AND d.doc_type NOT IN (''session_note'', ''workflow_log'') ' +
      '  AND (d.token_estimate < 50 OR d.content IS NULL OR LENGTH(d.content) < 100) ' +
      'LIMIT 50');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;
        ProjectId := Qry.FieldByName('project_id').AsInteger;
        Title := Qry.FieldByName('title').AsString;
        TokenEst := Qry.FieldByName('token_estimate').AsInteger;

        // B7.2: Set status to stub_candidate
        UpdQry := Ctx.CreateQuery(
          'UPDATE documents SET status = ''stub_candidate'', ' +
          '  updated_at = NOW() WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := DocId;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;

        LogBatchResult(Ctx, jtStubWarning, DocId, ProjectId, 'status',
          '', 'stub_candidate', 'success');

        Inc(Count);
        FLogger.Log(mlDebug, Format('Stub doc marked: %d (%s, %d tokens)',
          [DocId, Title, TokenEst]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  finally
    Ctx := nil;
  end;

  FStats.StubsWarned := Count;
end;

// C1.3: Set 'no_edit_followed' for recall_log entries still 'shown' after timeout
procedure TMxAIBatchRunner.RunRecallTimeoutJob;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Count: Integer;
begin
  Ctx := FPool.AcquireContext;
  try
    Qry := Ctx.CreateQuery(
      'UPDATE recall_log SET outcome = ''no_edit_followed'' ' +
      'WHERE outcome = ''shown'' ' +
      '  AND created_at < NOW() - INTERVAL 15 MINUTE');
    try
      Qry.ExecSQL;
      Count := Qry.RowsAffected;
    finally
      Qry.Free;
    end;
    if Count > 0 then
      FLogger.Log(mlInfo, Format('Recall timeout: %d entries set to no_edit_followed', [Count]));
  finally
    Ctx := nil;
  end;
end;

// C2: Automatic violation/success counters from recall_log outcomes
procedure TMxAIBatchRunner.RunViolationCounterJob;
var
  Ctx: IMxDbContext;
  Qry, UpdQry: TFDQuery;
  DocId, Violations, Candidates: Integer;
begin
  Ctx := FPool.AcquireContext;
  try
    Violations := 0;
    Candidates := 0;

    // C2.1: violation_count++ for confirmed violations
    // 3 conditions: outcome='violation', lesson exists (doc_id>0), recall within 15min
    Qry := Ctx.CreateQuery(
      'SELECT rl.id AS recall_id, ' +
      '  CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(g.triggered_ids, '','', n.n), '','', -1) AS UNSIGNED) AS lesson_doc_id ' +
      'FROM recall_log rl ' +
      'CROSS JOIN (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) n ' +
      'JOIN ( ' +
      '  SELECT id, gate_reason AS triggered_ids ' +
      '  FROM recall_log WHERE outcome = ''violation'' ' +
      '    AND created_at > NOW() - INTERVAL 1 DAY ' +
      ') g ON g.id = rl.id ' +
      'WHERE rl.outcome = ''violation'' ' +
      '  AND rl.created_at > NOW() - INTERVAL 1 DAY');
    // Simpler approach: just scan violation outcomes and update linked lessons
    Qry.Free;

    // Simplified: Find recall_log entries with outcome='violation' not yet counted
    // We use gate_reason which contains doc_id references
    Qry := Ctx.CreateQuery(
      'SELECT id, gate_reason FROM recall_log ' +
      'WHERE outcome = ''violation'' ' +
      '  AND created_at > NOW() - INTERVAL 1 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        // Extract doc_ids from gate_reason (format: "Critical rule (doc_id=123)...")
        var Reason := Qry.FieldByName('gate_reason').AsString;
        var DocIdPos := Pos('doc_id=', Reason);
        if DocIdPos > 0 then
        begin
          var IdStr := Copy(Reason, DocIdPos + 7, 10);
          var EndPos := Pos(')', IdStr);
          if EndPos > 0 then
            IdStr := Copy(IdStr, 1, EndPos - 1);
          DocId := StrToIntDef(IdStr, 0);
          if DocId > 0 then
          begin
            UpdQry := Ctx.CreateQuery(
              'UPDATE documents SET violation_count = violation_count + 1 ' +
              'WHERE id = :id AND doc_type = ''lesson''');
            try
              UpdQry.ParamByName('id').AsInteger := DocId;
              UpdQry.ExecSQL;
              if UpdQry.RowsAffected > 0 then
                Inc(Violations);
            finally
              UpdQry.Free;
            end;
          end;
        end;
        // Mark as processed by changing outcome to prevent double-counting
        UpdQry := Ctx.CreateQuery(
          'UPDATE recall_log SET outcome = ''violation_counted'' WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := Qry.FieldByName('id').AsInteger;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // C2.2: potential_violation — same but for 'potential_violation' outcome
    Qry := Ctx.CreateQuery(
      'SELECT id, gate_reason FROM recall_log ' +
      'WHERE outcome = ''potential_violation'' ' +
      '  AND created_at > NOW() - INTERVAL 1 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        // Log but don't increment violation_count (only 1-2 conditions met)
        UpdQry := Ctx.CreateQuery(
          'UPDATE recall_log SET outcome = ''potential_violation_noted'' WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := Qry.FieldByName('id').AsInteger;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // C2.3: candidate_success — outcome='applied' or 'candidate_success'
    Qry := Ctx.CreateQuery(
      'SELECT id, gate_reason FROM recall_log ' +
      'WHERE outcome IN (''applied'', ''candidate_success'') ' +
      '  AND created_at > NOW() - INTERVAL 1 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var Reason := Qry.FieldByName('gate_reason').AsString;
        var DocIdPos := Pos('doc_id=', Reason);
        if DocIdPos > 0 then
        begin
          var IdStr := Copy(Reason, DocIdPos + 7, 10);
          var EndPos := Pos(')', IdStr);
          if EndPos > 0 then
            IdStr := Copy(IdStr, 1, EndPos - 1);
          DocId := StrToIntDef(IdStr, 0);
          // C2.3: Don't increment success_count directly — mark as candidate
          // C2.4: Promotion via Admin-UI later
          if DocId > 0 then
            Inc(Candidates);
        end;
        UpdQry := Ctx.CreateQuery(
          'UPDATE recall_log SET outcome = ''success_candidate_noted'' WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := Qry.FieldByName('id').AsInteger;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    if (Violations > 0) or (Candidates > 0) then
      FLogger.Log(mlInfo, Format('Violation counter: %d violations counted, %d success candidates noted',
        [Violations, Candidates]));
  finally
    Ctx := nil;
  end;
end;

{ --- Job: Lesson Dedupe (C4.1) --- }

procedure TMxAIBatchRunner.RunLessonDedupeJob;

  function SplitTitleWords(const S: string): TStringList;
  var
    W: string;
    C: Char;
  begin
    Result := TStringList.Create;
    Result.Duplicates := dupIgnore;
    Result.Sorted := True;
    W := '';
    for C in LowerCase(S) do
    begin
      if CharInSet(C, ['a'..'z', '0'..'9', '_', '.']) or (Ord(C) > 127) then
        W := W + C
      else
      begin
        if Length(W) > 2 then
          Result.Add(W);
        W := '';
      end;
    end;
    if Length(W) > 2 then
      Result.Add(W);
  end;

  function JaccardSimilarity(const A, B: string): Double;
  var
    WA, WB: TStringList;
    Intersection, Union, K: Integer;
  begin
    WA := SplitTitleWords(A);
    try
      WB := SplitTitleWords(B);
      try
        if (WA.Count = 0) or (WB.Count = 0) then
          Exit(0.0);
        Intersection := 0;
        for K := 0 to WA.Count - 1 do
          if WB.IndexOf(WA[K]) >= 0 then
            Inc(Intersection);
        Union := WA.Count + WB.Count - Intersection;
        if Union = 0 then
          Result := 0.0
        else
          Result := Intersection / Union;
      finally
        WB.Free;
      end;
    finally
      WA.Free;
    end;
  end;

  function IsSpecificAppliesTo(const Value: string): Boolean;
  begin
    Result := (Pos('.', Value) > 0) or    // filename: mx.Data.Context.pas
              (Pos('::', Value) > 0) or    // namespace
              (Pos('(', Value) > 0) or     // function signature
              (Length(Value) > 40);         // long = likely specific
  end;

var
  Ctx: IMxDbContext;
  Qry, ChkQry, InsQry, TagQry: TFDQuery;
  Count, I, J: Integer;
  Ids: array of Integer;
  ProjectIds: array of Integer;
  Titles: array of string;
  AppliesTo: array of string;
  NoteTitle, NoteContent, MatchReason, DedupeSlug: string;
  Score: Double;
begin
  Count := 0;
  Ctx := FPool.AcquireContext;
  try
    // Load active lessons from the last 30 days only
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title, d.project_id, ' +
      '  JSON_UNQUOTE(JSON_EXTRACT(d.lesson_data, ''$.applies_to'')) AS applies_to ' +
      'FROM documents d ' +
      'JOIN projects p ON p.id = d.project_id AND p.is_active = TRUE ' +
      'WHERE d.doc_type = ''lesson'' ' +
      '  AND d.status NOT IN (''deleted'', ''archived'') ' +
      '  AND d.created_at >= NOW() - INTERVAL 30 DAY ' +
      'ORDER BY d.id ' +
      'LIMIT 500');
    try
      Qry.Open;
      // Don't trust RecordCount (can be -1 with FireDAC+MariaDB)
      SetLength(Ids, 0);
      SetLength(ProjectIds, 0);
      SetLength(Titles, 0);
      SetLength(AppliesTo, 0);
      I := 0;
      while not Qry.Eof do
      begin
        SetLength(Ids, I + 1);
        SetLength(ProjectIds, I + 1);
        SetLength(Titles, I + 1);
        SetLength(AppliesTo, I + 1);
        Ids[I] := Qry.FieldByName('id').AsInteger;
        ProjectIds[I] := Qry.FieldByName('project_id').AsInteger;
        Titles[I] := Qry.FieldByName('title').AsString;
        AppliesTo[I] := Qry.FieldByName('applies_to').AsString;
        Inc(I);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    if Length(Ids) < 2 then Exit;

    // Pairwise comparison with similarity scoring
    for I := 0 to High(Ids) - 1 do
    begin
      for J := I + 1 to High(Ids) do
      begin
        var IsMatch := False;
        MatchReason := '';
        Score := 0.0;

        // Check 1: identical title
        if SameText(Titles[I], Titles[J]) then
        begin
          IsMatch := True;
          MatchReason := 'exact-title';
          Score := 1.0;
        end;

        // Check 2: title substring overlap >20 chars
        if (not IsMatch) and (Length(Titles[I]) > 20) and (Length(Titles[J]) > 20) then
        begin
          if ContainsText(Titles[I], Titles[J]) or ContainsText(Titles[J], Titles[I]) then
          begin
            IsMatch := True;
            MatchReason := 'title-substring';
            Score := 0.8;
          end;
        end;

        // Check 3: Jaccard similarity on title words (threshold 0.4)
        if not IsMatch then
        begin
          Score := JaccardSimilarity(Titles[I], Titles[J]);
          if Score >= 0.4 then
          begin
            IsMatch := True;
            MatchReason := Format('jaccard(%.2f)', [Score]);
          end;
        end;

        // Check 4: specific applies_to match (only non-generic values)
        if (not IsMatch) and (AppliesTo[I] <> '') and (AppliesTo[J] <> '') then
        begin
          if SameText(AppliesTo[I], AppliesTo[J]) and
             IsSpecificAppliesTo(AppliesTo[I]) then
          begin
            IsMatch := True;
            MatchReason := 'specific-applies-to';
            Score := 0.6;
          end;
        end;

        if IsMatch then
        begin
          DedupeSlug := Format('dedupe-%d-%d', [Ids[I], Ids[J]]);
          NoteTitle := Format('[Dedupe] Lesson #%d und #%d: %s / %s',
            [Ids[I], Ids[J], Titles[I], Titles[J]]);
          if Length(NoteTitle) > 250 then
            NoteTitle := Copy(NoteTitle, 1, 247) + '...';

          // Idempotent: check if note already exists (including archived/dismissed)
          ChkQry := Ctx.CreateQuery(
            'SELECT 1 FROM documents ' +
            'WHERE doc_type = ''note'' AND slug = :slug ' +
            '  AND status <> ''deleted'' LIMIT 1');
          try
            ChkQry.ParamByName('slug').AsString := DedupeSlug;
            ChkQry.Open;
            if not ChkQry.Eof then
              Continue;
          finally
            ChkQry.Free;
          end;

          NoteContent := Format(
            'Potential duplicate lessons detected (match: %s, score: %.2f):' + #13#10 +
            '- Lesson #%d: %s' + #13#10 +
            '- Lesson #%d: %s' + #13#10 +
            'Review and consider merging.',
            [MatchReason, Score, Ids[I], Titles[I], Ids[J], Titles[J]]);

          // Create note
          InsQry := Ctx.CreateQuery(
            'INSERT INTO documents (project_id, doc_type, slug, title, content, status, ' +
            '  created_at, updated_at, confidence) ' +
            'VALUES (:proj_id, ''note'', :slug, :title, :content, ''active'', NOW(), NOW(), 1.0)');
          try
            InsQry.ParamByName('proj_id').AsInteger := ProjectIds[I];
            InsQry.ParamByName('slug').AsString := DedupeSlug;
            InsQry.ParamByName('title').AsString := NoteTitle;
            InsQry.ParamByName('content').AsString := NoteContent;
            InsQry.ExecSQL;
          finally
            InsQry.Free;
          end;

          // Get last insert id and add tag
          ChkQry := Ctx.CreateQuery('SELECT LAST_INSERT_ID() AS new_id');
          try
            ChkQry.Open;
            var NewDocId := ChkQry.FieldByName('new_id').AsInteger;
            if NewDocId > 0 then
            begin
              TagQry := Ctx.CreateQuery(
                'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
              try
                TagQry.ParamByName('doc_id').AsInteger := NewDocId;
                TagQry.ParamByName('tag').AsString := 'merge-candidate';
                TagQry.ExecSQL;
              finally
                TagQry.Free;
              end;
            end;
          finally
            ChkQry.Free;
          end;

          Inc(Count);
          FLogger.Log(mlDebug, Format(
            'Lesson dedupe: #%d and #%d match (%s, score=%.2f)',
            [Ids[I], Ids[J], MatchReason, Score]));
        end;
      end;
    end;
  finally
    Ctx := nil;
  end;

  FStats.LessonDupes := Count;
  if Count > 0 then
    FLogger.Log(mlInfo, Format('Lesson dedupe: %d merge candidates found', [Count]));
end;

{ --- Job: Contradiction Detection (C4.2) --- }

procedure TMxAIBatchRunner.RunContradictionDetectionJob;
var
  Ctx: IMxDbContext;
  Qry, ChkQry, InsQry, TagQry: TFDQuery;
  Count: Integer;
  NoteTitle, NoteContent: string;
  DocId, TargetDocId, ProjectId: Integer;
  DocTitle, DocType, TargetTitle, TargetStatus: string;
begin
  Count := 0;
  Ctx := FPool.AcquireContext;
  try
    // Find active specs/plans referencing superseded/archived decisions
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title, d.doc_type, d.project_id, ' +
      '  r.target_doc_id, dt.title AS target_title, dt.status AS target_status ' +
      'FROM documents d ' +
      'JOIN projects p ON p.id = d.project_id AND p.is_active = TRUE ' +
      'JOIN doc_relations r ON r.source_doc_id = d.id ' +
      'JOIN documents dt ON dt.id = r.target_doc_id ' +
      'WHERE d.status = ''active'' ' +
      '  AND d.doc_type IN (''spec'', ''plan'') ' +
      '  AND dt.doc_type = ''decision'' ' +
      '  AND dt.status IN (''superseded'', ''archived'')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;
        DocTitle := Qry.FieldByName('title').AsString;
        DocType := Qry.FieldByName('doc_type').AsString;
        ProjectId := Qry.FieldByName('project_id').AsInteger;
        TargetDocId := Qry.FieldByName('target_doc_id').AsInteger;
        TargetTitle := Qry.FieldByName('target_title').AsString;
        TargetStatus := Qry.FieldByName('target_status').AsString;

        NoteTitle := Format('[Contradiction] %s #%d references %s ADR #%d',
          [DocType, DocId, TargetStatus, TargetDocId]);

        // Idempotent: check if note already exists
        ChkQry := Ctx.CreateQuery(
          'SELECT 1 FROM documents ' +
          'WHERE doc_type = ''note'' AND title = :title ' +
          '  AND status NOT IN (''deleted'', ''archived'') LIMIT 1');
        try
          ChkQry.ParamByName('title').AsString := NoteTitle;
          ChkQry.Open;
          if not ChkQry.Eof then
          begin
            Qry.Next;
            Continue;
          end;
        finally
          ChkQry.Free;
        end;

        NoteContent := Format(
          'Status inconsistency detected:' + #13#10 +
          '- Active %s #%d: %s' + #13#10 +
          '- References %s decision #%d: %s' + #13#10 +
          'The referenced ADR is no longer active. Review the %s and update or re-link.',
          [DocType, DocId, DocTitle, TargetStatus, TargetDocId, TargetTitle, DocType]);

        // Create note (slug required by schema)
        InsQry := Ctx.CreateQuery(
          'INSERT INTO documents (project_id, doc_type, slug, title, content, status, ' +
          '  created_at, updated_at, confidence) ' +
          'VALUES (:proj_id, ''note'', :slug, :title, :content, ''active'', NOW(), NOW(), 1.0)');
        try
          InsQry.ParamByName('proj_id').AsInteger := ProjectId;
          InsQry.ParamByName('slug').AsString :=
            Format('contradiction-%d-%d', [DocId, TargetDocId]);
          InsQry.ParamByName('title').AsString := NoteTitle;
          InsQry.ParamByName('content').AsString := NoteContent;
          InsQry.ExecSQL;
        finally
          InsQry.Free;
        end;

        // Get last insert id and add tag
        ChkQry := Ctx.CreateQuery('SELECT LAST_INSERT_ID() AS new_id');
        try
          ChkQry.Open;
          var NewDocId := ChkQry.FieldByName('new_id').AsInteger;
          if NewDocId > 0 then
          begin
            TagQry := Ctx.CreateQuery(
              'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
            try
              TagQry.ParamByName('doc_id').AsInteger := NewDocId;
              TagQry.ParamByName('tag').AsString := 'status-inconsistency';
              TagQry.ExecSQL;
            finally
              TagQry.Free;
            end;
          end;
        finally
          ChkQry.Free;
        end;

        Inc(Count);
        FLogger.Log(mlDebug, Format('Contradiction: %s #%d refs %s ADR #%d (%s)',
          [DocType, DocId, TargetStatus, TargetDocId, TargetTitle]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  finally
    Ctx := nil;
  end;

  FStats.Contradictions := Count;
  if Count > 0 then
    FLogger.Log(mlInfo, Format('Contradiction detection: %d inconsistencies found', [Count]));
end;

{ --- Job: Stale Candidate Promotion (C4.3) --- }

procedure TMxAIBatchRunner.RunStaleCandidatePromotionJob;
var
  Ctx: IMxDbContext;
  Qry, UpdQry: TFDQuery;
  Count: Integer;
  DocId: Integer;
  Title: string;
begin
  Count := 0;
  Ctx := FPool.AcquireContext;
  try
    // Promote stale_candidate to stale after 14 days without update
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title FROM documents d ' +
      'JOIN projects p ON p.id = d.project_id AND p.is_active = TRUE ' +
      'WHERE d.status = ''stale_candidate'' ' +
      '  AND d.updated_at < NOW() - INTERVAL 14 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;
        Title := Qry.FieldByName('title').AsString;

        UpdQry := Ctx.CreateQuery(
          'UPDATE documents SET status = ''stale'', ' +
          '  updated_at = NOW() WHERE id = :id');
        try
          UpdQry.ParamByName('id').AsInteger := DocId;
          UpdQry.ExecSQL;
        finally
          UpdQry.Free;
        end;

        Inc(Count);
        FLogger.Log(mlDebug, Format('Stale promotion: doc %d (%s) promoted to stale', [DocId, Title]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  finally
    Ctx := nil;
  end;

  FStats.StalePromoted := Count;
  if Count > 0 then
    FLogger.Log(mlInfo, Format('Stale promotion: %d documents promoted from stale_candidate to stale', [Count]));
end;

// C3: Weekly recall effectiveness metrics report
procedure TMxAIBatchRunner.RunRecallEffectivenessJob;
var
  Ctx: IMxDbContext;
  Qry, InsQry: TFDQuery;
  ProjectId, DocId, Total, Hits: Integer;
  Hitrate: Double;
  Report: TStringBuilder;
  Slug, DateStr: string;
begin
  Ctx := FPool.AcquireContext;
  try
    // Resolve SelfSlug project_id (for storing the report note)
    Qry := Ctx.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
    try
      Qry.ParamByName('slug').AsString := FConfig.SelfSlug;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        FLogger.Log(mlDebug, 'Recall effectiveness: project ' + FConfig.SelfSlug + ' not found, skipping');
        Exit;
      end;
      ProjectId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;

    // Check if last report was < 7 days ago (idempotency guard)
    Qry := Ctx.CreateQuery(
      'SELECT d.id FROM documents d ' +
      'JOIN doc_tags dt ON dt.doc_id = d.id ' +
      'WHERE d.project_id = :proj ' +
      '  AND d.doc_type = ''note'' ' +
      '  AND dt.tag = ''recall-metrics'' ' +
      '  AND d.created_at > NOW() - INTERVAL 7 DAY ' +
      'ORDER BY d.created_at DESC LIMIT 1');
    try
      Qry.ParamByName('proj').AsInteger := ProjectId;
      Qry.Open;
      if not Qry.IsEmpty then
      begin
        FLogger.Log(mlDebug, 'Recall effectiveness: last report < 7 days ago, skipping');
        Exit;
      end;
    finally
      Qry.Free;
    end;

    // Build the metrics report
    Report := TStringBuilder.Create;
    try
      DateStr := FormatDateTime('yyyy-mm-dd', Now);
      Report.AppendLine('# Recall Effectiveness Report ' + DateStr);
      Report.AppendLine('');

      // C3.1a: Hitrate
      Total := 0;
      Hits := 0;
      Qry := Ctx.CreateQuery(
        'SELECT COUNT(*) AS total, ' +
        '  SUM(CASE WHEN treffer_count > 0 THEN 1 ELSE 0 END) AS hits ' +
        'FROM recall_log ' +
        'WHERE created_at > NOW() - INTERVAL 7 DAY');
      try
        Qry.Open;
        Total := Qry.FieldByName('total').AsInteger;
        Hits := Qry.FieldByName('hits').AsInteger;
      finally
        Qry.Free;
      end;

      if Total > 0 then
        Hitrate := (Hits / Total) * 100.0
      else
        Hitrate := 0;
      Report.AppendLine(Format('## Hitrate: %.1f%% (%d/%d)', [Hitrate, Hits, Total]));
      Report.AppendLine('');

      // C3.1b: Outcome distribution
      Report.AppendLine('## Outcome Distribution');
      Qry := Ctx.CreateQuery(
        'SELECT outcome, COUNT(*) AS cnt ' +
        'FROM recall_log ' +
        'WHERE created_at > NOW() - INTERVAL 7 DAY ' +
        'GROUP BY outcome ORDER BY cnt DESC');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Report.AppendLine(Format('- %s: %d', [
            Qry.FieldByName('outcome').AsString,
            Qry.FieldByName('cnt').AsInteger]));
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
      Report.AppendLine('');

      // C3.1c: Gate-Level distribution
      Report.AppendLine('## Gate Levels');
      Qry := Ctx.CreateQuery(
        'SELECT COALESCE(gate_level, ''(none)'') AS gl, COUNT(*) AS cnt ' +
        'FROM recall_log ' +
        'WHERE created_at > NOW() - INTERVAL 7 DAY ' +
        'GROUP BY gate_level ORDER BY cnt DESC');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Report.AppendLine(Format('- %s: %d', [
            Qry.FieldByName('gl').AsString,
            Qry.FieldByName('cnt').AsInteger]));
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
      Report.AppendLine('');

      // C3.2: Top ignored lessons (shown/no_edit_followed grouped by gate_reason)
      Report.AppendLine('## Top Ignored (shown/no_edit_followed)');
      Qry := Ctx.CreateQuery(
        'SELECT gate_reason, COUNT(*) AS cnt ' +
        'FROM recall_log ' +
        'WHERE outcome IN (''no_edit_followed'', ''shown'') ' +
        '  AND gate_reason IS NOT NULL AND gate_reason <> '''' ' +
        '  AND created_at > NOW() - INTERVAL 7 DAY ' +
        'GROUP BY gate_reason ORDER BY cnt DESC LIMIT 5');
      try
        Qry.Open;
        if Qry.IsEmpty then
          Report.AppendLine('- (none)')
        else
          while not Qry.Eof do
          begin
            Report.AppendLine(Format('- %s (%dx)', [
              Qry.FieldByName('gate_reason').AsString,
              Qry.FieldByName('cnt').AsInteger]));
            Qry.Next;
          end;
      finally
        Qry.Free;
      end;

      // C3.3: Store as note with tag recall-metrics
      if Total = 0 then
      begin
        FLogger.Log(mlDebug, 'Recall effectiveness: no recall_log entries in last 7 days, skipping report');
        Exit;
      end;

      Slug := 'recall-metrics-' + DateStr;

      InsQry := Ctx.CreateQuery(
        'INSERT INTO documents (project_id, doc_type, slug, title, content, status, ' +
        '  created_at, updated_at, created_by) ' +
        'VALUES (:proj_id, ''note'', :slug, :title, :content, ''active'', NOW(), NOW(), ''ai-batch'')');
      try
        InsQry.ParamByName('proj_id').AsInteger := ProjectId;
        InsQry.ParamByName('slug').AsString := Slug;
        InsQry.ParamByName('title').AsString := '[Recall Metrics] ' + DateStr;
        InsQry.ParamByName('content').DataType := ftWideMemo;
        InsQry.ParamByName('content').AsString := Report.ToString;
        InsQry.ExecSQL;
      finally
        InsQry.Free;
      end;

      // Get inserted doc_id
      Qry := Ctx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
      try
        Qry.Open;
        DocId := Qry.FieldByName('id').AsInteger;
      finally
        Qry.Free;
      end;

      // Insert tag
      if DocId > 0 then
      begin
        InsQry := Ctx.CreateQuery(
          'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
        try
          InsQry.ParamByName('doc_id').AsInteger := DocId;
          InsQry.ParamByName('tag').AsString := 'recall-metrics';
          InsQry.ExecSQL;
        finally
          InsQry.Free;
        end;
      end;

      FLogger.Log(mlInfo, Format('Recall effectiveness: report created (doc_id=%d, hitrate=%.1f%%, total=%d)',
        [DocId, Hitrate, Total]));

    finally
      Report.Free;
    end;
  finally
    Ctx := nil;
  end;
end;

{ --- Job: Skill Precision (C5) --- }

procedure TMxAIBatchRunner.RunSkillPrecisionJob;

  procedure CheckSkillRules(ACtx: IMxDbContext; const ASkillName: string;
    AMinConfirmPct: Double; AProjectId: Integer);
  var
    Qry, ChkQry, InsQry, TagQry: TFDQuery;
    RuleId: string;
    Total, Confirmed, NewDocId: Integer;
    ConfirmPct: Double;
    NoteTitle, NoteContent, PctStr: string;
  begin
    // Find rules with enough findings (>=5) older than 30 days
    // and confirmation rate below threshold
    Qry := ACtx.CreateQuery(
      'SELECT rule_id, COUNT(*) AS total, ' +
      '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN 1 ELSE 0 END) AS confirmed ' +
      'FROM skill_findings ' +
      'WHERE skill_name = :skill ' +
      '  AND created_at < NOW() - INTERVAL 30 DAY ' +
      'GROUP BY rule_id ' +
      'HAVING confirmed * 100.0 / total < :threshold AND total >= 5');
    try
      Qry.ParamByName('skill').AsString := ASkillName;
      Qry.ParamByName('threshold').AsFloat := AMinConfirmPct;
      Qry.Open;
      while not Qry.Eof do
      begin
        RuleId := Qry.FieldByName('rule_id').AsString;
        Total := Qry.FieldByName('total').AsInteger;
        Confirmed := Qry.FieldByName('confirmed').AsInteger;
        if Total > 0 then
          ConfirmPct := (Confirmed * 100.0) / Total
        else
          ConfirmPct := 0;
        PctStr := FormatFloat('0.0', ConfirmPct);

        NoteTitle := Format('[Precision] %s rule %s: %s%% confirmation after 30d',
          [ASkillName, RuleId, PctStr]);

        // Idempotent: check if note already exists
        ChkQry := ACtx.CreateQuery(
          'SELECT 1 FROM documents ' +
          'WHERE doc_type = ''note'' AND title = :title ' +
          '  AND status NOT IN (''deleted'', ''archived'') LIMIT 1');
        try
          ChkQry.ParamByName('title').AsString := NoteTitle;
          ChkQry.Open;
          if not ChkQry.Eof then
          begin
            Qry.Next;
            Continue;
          end;
        finally
          ChkQry.Free;
        end;

        NoteContent := Format(
          'Low-precision rule detected:' + #13#10 +
          '- Skill: %s' + #13#10 +
          '- Rule: %s' + #13#10 +
          '- Findings (>30d): %d total, %d confirmed (%s%%)' + #13#10 +
          '- Threshold: %.0f%%' + #13#10 +
          'Consider disabling or tuning this rule via Admin-UI.',
          [ASkillName, RuleId, Total, Confirmed, PctStr, AMinConfirmPct]);

        // Create note
        InsQry := ACtx.CreateQuery(
          'INSERT INTO documents (project_id, doc_type, slug, title, content, status, ' +
          '  created_at, updated_at, confidence) ' +
          'VALUES (:proj_id, ''note'', :slug, :title, :content, ''active'', NOW(), NOW(), 1.0)');
        try
          InsQry.ParamByName('proj_id').AsInteger := AProjectId;
          InsQry.ParamByName('slug').AsString :=
            Format('skill-precision-%s-%s', [ASkillName, RuleId]);
          InsQry.ParamByName('title').AsString := NoteTitle;
          InsQry.ParamByName('content').AsString := NoteContent;
          InsQry.ExecSQL;
        finally
          InsQry.Free;
        end;

        // Get last insert id and add tag
        ChkQry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS new_id');
        try
          ChkQry.Open;
          NewDocId := ChkQry.FieldByName('new_id').AsInteger;
          if NewDocId > 0 then
          begin
            TagQry := ACtx.CreateQuery(
              'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
            try
              TagQry.ParamByName('doc_id').AsInteger := NewDocId;
              TagQry.ParamByName('tag').AsString := 'auto-disable-candidate';
              TagQry.ExecSQL;
            finally
              TagQry.Free;
            end;
          end;
        finally
          ChkQry.Free;
        end;

        FLogger.Log(mlDebug, Format('Skill precision: %s rule %s has %s%% confirmation (%d/%d)',
          [ASkillName, RuleId, PctStr, Confirmed, Total]));
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  end;

var
  Ctx: IMxDbContext;
  Qry, ProjQry: TFDQuery;
  ProjectId, DismissedCount: Integer;
  ProjectIds: array of Integer;
  I: Integer;
begin
  Ctx := FPool.AcquireContext;
  try
    // Load all active projects
    ProjQry := Ctx.CreateQuery(
      'SELECT id FROM projects WHERE is_active = TRUE');
    try
      ProjQry.Open;
      SetLength(ProjectIds, 0);
      I := 0;
      while not ProjQry.Eof do
      begin
        SetLength(ProjectIds, I + 1);
        ProjectIds[I] := ProjQry.FieldByName('id').AsInteger;
        Inc(I);
        ProjQry.Next;
      end;
    finally
      ProjQry.Free;
    end;

    // C5.1+C5.2: Check skill rules for each project
    for I := 0 to High(ProjectIds) do
    begin
      ProjectId := ProjectIds[I];
      CheckSkillRules(Ctx, 'mxDesignChecker', 0.01, ProjectId);
      CheckSkillRules(Ctx, 'mxBugChecker', 20.0, ProjectId);
    end;

    // C5.3: Reclassify old 'dismissed' to 'false_positive' for cleaner metrics
    Qry := Ctx.CreateQuery(
      'UPDATE skill_findings SET user_reaction = ''false_positive'' ' +
      'WHERE user_reaction = ''dismissed'' ' +
      '  AND created_at < NOW() - INTERVAL 30 DAY');
    try
      Qry.ExecSQL;
      DismissedCount := Qry.RowsAffected;
    finally
      Qry.Free;
    end;
    if DismissedCount > 0 then
      FLogger.Log(mlInfo, Format('Skill precision: %d dismissed findings reclassified to false_positive', [DismissedCount]));
  finally
    Ctx := nil;
  end;
end;

{ --- Job: Health Auto-Notes (Phase 3b, Spec#1139) --- }

procedure TMxAIBatchRunner.RunHealthAutoNotesJob;

  procedure CreateHealthNote(ACtx: IMxDbContext; AProjectId: Integer;
    const ATitle, ADetails, ASeverityTag: string);
  var
    ChkQry, InsQry, TagQry: TFDQuery;
    Slug: string;
    DocId: Integer;
  begin
    // Deduplicate by title
    ChkQry := ACtx.CreateQuery(
      'SELECT id FROM documents WHERE project_id = :pid ' +
      '  AND title = :title AND status != ''deleted'' LIMIT 1');
    try
      ChkQry.ParamByName('pid').AsInteger := AProjectId;
      ChkQry.ParamByName('title').AsString := ATitle;
      ChkQry.Open;
      if not ChkQry.IsEmpty then Exit; // already exists
    finally
      ChkQry.Free;
    end;

    Slug := 'health-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '-' +
      IntToStr(Random(999));

    InsQry := ACtx.CreateQuery(
      'INSERT INTO documents (project_id, doc_type, slug, title, content, ' +
      '  status, created_by, summary_l1) ' +
      'VALUES (:pid, ''note'', :slug, :title, :content, ''active'', ' +
      '  ''ai-batch'', :summary)');
    try
      InsQry.ParamByName('pid').AsInteger := AProjectId;
      InsQry.ParamByName('slug').AsString := Slug;
      InsQry.ParamByName('title').AsString := ATitle;
      InsQry.ParamByName('content').DataType := ftWideMemo;
      InsQry.ParamByName('content').AsString := ADetails;
      InsQry.ParamByName('summary').AsString := Copy(ADetails, 1, 200);
      InsQry.ExecSQL;
    finally
      InsQry.Free;
    end;

    InsQry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
    try
      InsQry.Open;
      DocId := InsQry.FieldByName('id').AsInteger;
    finally
      InsQry.Free;
    end;

    // Tags: health-finding + severity tag
    TagQry := ACtx.CreateQuery(
      'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:id, :tag)');
    try
      TagQry.ParamByName('id').AsInteger := DocId;
      TagQry.ParamByName('tag').AsString := 'health-finding';
      TagQry.ExecSQL;
      TagQry.ParamByName('tag').AsString := ASeverityTag;
      TagQry.ExecSQL;
      TagQry.ParamByName('tag').AsString := 'mxhealth-auto';
      TagQry.ExecSQL;
    finally
      TagQry.Free;
    end;
  end;

var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Created: Integer;
begin
  Created := 0;
  Ctx := FPool.AcquireContext;
  try
    // P1: Documents without summaries (ERROR)
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title, p.slug AS project_slug, d.project_id ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.status NOT IN (''deleted'', ''archived'') ' +
      '  AND d.doc_type NOT IN (''session_note'', ''workflow_log'') ' +
      '  AND (d.summary_l1 IS NULL OR d.summary_l1 = '''') ' +
      '  AND d.created_at < NOW() - INTERVAL 1 DAY ' +
      'LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        CreateHealthNote(Ctx, Qry.FieldByName('project_id').AsInteger,
          '[Health] Fehlende Summary: ' + Qry.FieldByName('title').AsString,
          Format('Severity: ERROR'#10'Doc #%d (%s) in Projekt %s hat keine summary_l1.'#10 +
            'Gefunden: %s',
            [Qry.FieldByName('id').AsInteger, Qry.FieldByName('title').AsString,
             Qry.FieldByName('project_slug').AsString,
             FormatDateTime('yyyy-mm-dd', Now)]),
          'bug');
        Inc(Created);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // P3: Orphaned relations (WARNING)
    Qry := Ctx.CreateQuery(
      'SELECT dr.id AS rel_id, dr.source_doc_id, dr.target_doc_id, ' +
      '  dr.relation_type, p.slug AS project_slug, ds.project_id ' +
      'FROM doc_relations dr ' +
      'JOIN documents ds ON ds.id = dr.source_doc_id ' +
      'JOIN projects p ON p.id = ds.project_id ' +
      'LEFT JOIN documents dt ON dt.id = dr.target_doc_id AND dt.status != ''deleted'' ' +
      'WHERE dt.id IS NULL ' +
      'LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        CreateHealthNote(Ctx, Qry.FieldByName('project_id').AsInteger,
          Format('[Health] Verwaiste Relation: %s #%d → #%d',
            [Qry.FieldByName('relation_type').AsString,
             Qry.FieldByName('source_doc_id').AsInteger,
             Qry.FieldByName('target_doc_id').AsInteger]),
          Format('Severity: WARNING'#10'Relation %s von Doc #%d zeigt auf geloeschtes/fehlendes Doc #%d.'#10 +
            'Projekt: %s. Gefunden: %s',
            [Qry.FieldByName('relation_type').AsString,
             Qry.FieldByName('source_doc_id').AsInteger,
             Qry.FieldByName('target_doc_id').AsInteger,
             Qry.FieldByName('project_slug').AsString,
             FormatDateTime('yyyy-mm-dd', Now)]),
          'improvement');
        Inc(Created);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // P4: Low-confidence active docs (WARNING)
    Qry := Ctx.CreateQuery(
      'SELECT d.id, d.title, d.confidence, d.doc_type, p.slug AS project_slug, d.project_id ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.status = ''active'' AND d.confidence < 0.3 ' +
      '  AND d.doc_type IN (''spec'', ''plan'', ''decision'') ' +
      '  AND d.created_at < NOW() - INTERVAL 7 DAY ' +
      'LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        CreateHealthNote(Ctx, Qry.FieldByName('project_id').AsInteger,
          Format('[Health] Niedrige Confidence: %s #%d (%.0f%%)',
            [Qry.FieldByName('doc_type').AsString,
             Qry.FieldByName('id').AsInteger,
             Qry.FieldByName('confidence').AsFloat * 100]),
          Format('Severity: WARNING'#10'%s "%s" (Doc #%d) hat nur %.0f%% Confidence und ist active.'#10 +
            'Projekt: %s. Verifizierung empfohlen. Gefunden: %s',
            [Qry.FieldByName('doc_type').AsString,
             Qry.FieldByName('title').AsString,
             Qry.FieldByName('id').AsInteger,
             Qry.FieldByName('confidence').AsFloat * 100,
             Qry.FieldByName('project_slug').AsString,
             FormatDateTime('yyyy-mm-dd', Now)]),
          'improvement');
        Inc(Created);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    if Created > 0 then
      FLogger.Log(mlInfo, Format('Health auto-notes: %d notes created', [Created]));
  finally
    Ctx := nil;
  end;
end;

// ---------------------------------------------------------------------------
// Auto-dismiss pending findings older than IgnoredTimeoutDays (default 7)
// ---------------------------------------------------------------------------
procedure TMxAIBatchRunner.RunFindingAutoDismissJob;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Count: Integer;
  TimeoutDays: Integer;
begin
  TimeoutDays := 7; // auto-dismiss pending findings after 7 days
  Count := 0;
  Ctx := FPool.AcquireContext;
  try
    Qry := Ctx.CreateQuery(
      'UPDATE skill_findings ' +
      'SET user_reaction = ''dismissed'', ' +
      '  reacted_at = NOW() ' +
      'WHERE user_reaction = ''pending'' ' +
      '  AND created_at < NOW() - INTERVAL :days DAY');
    try
      Qry.ParamByName('days').AsInteger := TimeoutDays;
      Qry.ExecSQL;
      Count := Qry.RowsAffected;
    finally
      Qry.Free;
    end;
  finally
    Ctx := nil;
  end;
  if Count > 0 then
    FLogger.Log(mlInfo, Format('Finding auto-dismiss: %d pending findings dismissed (>%d days)',
      [Count, TimeoutDays]));
end;

{ --- claude.exe Subprocess (Fire-and-Forget Thread) --- }

procedure TMxAIBatchRunner.StartClaudeExeThread;
var
  ExePath, Prompt: string;
  Logger: IMxLogger;
begin
  ExePath := FConfig.AIClaudeExePath;

  // Check if claude.exe exists (if absolute path given)
  if (ExePath <> 'claude') and not FileExists(ExePath) then
  begin
    FLogger.Log(mlWarning, 'AI Batch: claude.exe not found at ' + ExePath);
    Exit;
  end;

  Prompt := StringReplace(AI_BATCH_PROMPT, 'mxLore', FConfig.SelfSlug, [rfReplaceAll]);
  Logger := FLogger; // Capture interface ref for thread safety

  var LogPath := ExtractFilePath(ParamStr(0)) + 'logs\ai_batch_claude.log';
  var LogPathCapture := LogPath; // Capture for thread

  FAIThread := TThread.CreateAnonymousThread(
    procedure
    {$IFDEF MSWINDOWS}
    var
      SI: TStartupInfo;
      PI: TProcessInformation;
      SA: TSecurityAttributes;
      CmdLine: string;
      ExitCode: DWORD;
      hLogFile: THandle;
    begin
      CmdLine := Format('"%s" -p "%s"', [ExePath, Prompt]);

      // Create log file for stdout/stderr
      SA.nLength := SizeOf(SA);
      SA.bInheritHandle := True;
      SA.lpSecurityDescriptor := nil;
      hLogFile := CreateFile(PChar(LogPathCapture),
        GENERIC_WRITE, FILE_SHARE_READ, @SA,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

      FillChar(SI, SizeOf(SI), 0);
      SI.cb := SizeOf(SI);
      SI.dwFlags := STARTF_USESTDHANDLES;
      SI.hStdInput := 0;
      if hLogFile <> INVALID_HANDLE_VALUE then
      begin
        SI.hStdOutput := hLogFile;
        SI.hStdError := hLogFile;
      end
      else
      begin
        SI.hStdOutput := 0;
        SI.hStdError := 0;
      end;

      FillChar(PI, SizeOf(PI), 0);

      if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
        CREATE_NO_WINDOW or CREATE_NEW_PROCESS_GROUP, nil, nil, SI, PI) then
      begin
        Logger.Log(mlWarning, Format('AI Batch: failed to start claude.exe (error %d)',
          [GetLastError]));
        if hLogFile <> INVALID_HANDLE_VALUE then
          CloseHandle(hLogFile);
        Exit;
      end;

      try
        Logger.Log(mlInfo, Format('AI Batch: claude.exe started (PID %d, log: %s)',
          [PI.dwProcessId, LogPathCapture]));

        // Wait max 10 minutes (70 items need time)
        if WaitForSingleObject(PI.hProcess, 600000) = WAIT_TIMEOUT then
        begin
          Logger.Log(mlWarning, 'AI Batch: claude.exe timed out after 10 min, terminating');
          TerminateProcess(PI.hProcess, 1);
        end
        else
        begin
          GetExitCodeProcess(PI.hProcess, ExitCode);
          Logger.Log(mlInfo, Format('AI Batch: claude.exe finished (exit code %d)', [ExitCode]));
        end;
      finally
        CloseHandle(PI.hProcess);
        CloseHandle(PI.hThread);
        if hLogFile <> INVALID_HANDLE_VALUE then
          CloseHandle(hLogFile);
      end;
    end
    {$ELSE}
    begin
      Logger.Log(mlWarning, 'AI Batch: claude.exe subprocess not supported on this platform');
    end
    {$ENDIF}
  );

  FAIThread.FreeOnTerminate := False; // We manage lifetime in Destroy
  FAIThread.Start;
  FStats.ClaudeExeStarted := True;
end;

{ --- Main Entry Point --- }

procedure TMxAIBatchRunner.RunAll;
var
  Ctx: IMxDbContext;
  Pending: TJSONObject;
  PendingCount: Integer;
begin
  if not FConfig.AIEnabled then
  begin
    FLogger.Log(mlInfo, 'AI Batch: disabled in config ([AI] Enabled=0)');
    Exit;
  end;

  FLogger.Log(mlInfo, 'AI Batch: starting boot-time jobs');
  FStats := Default(TMxAIBatchStats);

  // SQL-only jobs (synchronous, fast)
  try RunStaleDetectionJob except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch stale detection failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunStubWarningJob except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch stub warning failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunRecallTimeoutJob;
    LogBatchRun(jtRecallTimeout, 1, 'timeout check');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch recall timeout failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunViolationCounterJob;
    LogBatchRun(jtViolationCounter, 1, 'violation counters');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch violation counter failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunLessonDedupeJob;
    LogBatchRun(jtLessonDedupe, FStats.LessonDupes, 'dupes found');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch lesson dedupe failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunContradictionDetectionJob;
    LogBatchRun(jtContradictionDetection, FStats.Contradictions, 'contradictions');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch contradiction detection failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunStaleCandidatePromotionJob;
    LogBatchRun(jtStaleCandidatePromotion, FStats.StalePromoted, 'promoted');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch stale promotion failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunRecallEffectivenessJob;
    LogBatchRun(jtRecallEffectiveness, 1, 'effectiveness report');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch recall effectiveness failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunSkillPrecisionJob;
    LogBatchRun(jtSkillPrecision, 1, 'precision check');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch skill precision failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunHealthAutoNotesJob;
    LogBatchRun(jtHealthAutoNotes, 1, 'health notes');
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch health auto-notes failed: ' + E.Message);
    Inc(FStats.Errors); end end;
  try RunFindingAutoDismissJob;
  except on E: Exception do
  begin FLogger.Log(mlError, 'AI Batch finding auto-dismiss failed: ' + E.Message);
    Inc(FStats.Errors); end end;

  // Check if there's AI work to do before spawning claude.exe
  try
    Ctx := FPool.AcquireContext;
    Pending := GetPendingWorkItems(Ctx);
    try
      PendingCount := Pending.GetValue<Integer>('total', 0);
    finally
      Pending.Free;
    end;
  except
    on E: Exception do
    begin
      FLogger.Log(mlWarning, 'AI Batch: failed to check pending items: ' + E.Message);
      PendingCount := 0;
      Inc(FStats.Errors);
    end;
  end;

  // Start claude.exe only if there's work
  if PendingCount > 0 then
  begin
    FLogger.Log(mlInfo, Format('AI Batch: %d pending items, starting claude.exe', [PendingCount]));
    try
      StartClaudeExeThread;
    except
      on E: Exception do
      begin
        FLogger.Log(mlError, 'AI Batch: claude.exe start failed: ' + E.Message);
        Inc(FStats.Errors);
      end;
    end;
  end
  else
    FLogger.Log(mlInfo, 'AI Batch: no pending AI work');

  FLogger.Log(mlInfo, Format(
    'AI Batch: sync done. %d stale, %d stubs, %d dupes, %d contradictions, %d promoted, claude=%s, %d errors',
    [FStats.StaleDetected, FStats.StubsWarned,
     FStats.LessonDupes, FStats.Contradictions, FStats.StalePromoted,
     IfThen(FStats.ClaudeExeStarted, 'started', 'skipped'),
     FStats.Errors]));
end;

end.
