unit mx.Intelligence.Prefetch;

interface

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  FireDAC.Comp.Client,
  mx.Types, mx.Data.Pool;

type
  TMxPrefetchCalculator = class
  private
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
    FSessionWindow: Integer;
    FMinScore: Double;
    FTotalCandidates: Integer;
    procedure CalculateForProject(AProjectId: Integer);
    procedure CalculateFrequencyScores(ACtx: IMxDbContext; AProjectId: Integer);
    procedure AddActivePlanBonuses(ACtx: IMxDbContext; AProjectId: Integer);
    procedure AddLinkedAdrBonuses(ACtx: IMxDbContext; AProjectId: Integer);
  public
    constructor Create(APool: TMxConnectionPool; ALogger: IMxLogger);
    procedure Calculate;
    property SessionWindow: Integer read FSessionWindow write FSessionWindow;
    property MinScore: Double read FMinScore write FMinScore;
    property TotalCandidates: Integer read FTotalCandidates;
  end;

implementation

{ TMxPrefetchCalculator }

constructor TMxPrefetchCalculator.Create(APool: TMxConnectionPool;
  ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
  FSessionWindow := 10;
  FMinScore := 0.6;
  FTotalCandidates := 0;
end;

procedure TMxPrefetchCalculator.Calculate;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ProjectIds: TList<Integer>;
  I: Integer;
begin
  FLogger.Log(mlInfo, 'Prefetch calculation starting');
  FTotalCandidates := 0;
  ProjectIds := TList<Integer>.Create;
  try
    try
      // Collect all non-NULL project_ids from access_log
      Ctx := FPool.AcquireContext;
      Qry := Ctx.CreateQuery(
        'SELECT DISTINCT project_id FROM access_log WHERE project_id IS NOT NULL');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          ProjectIds.Add(Qry.FieldByName('project_id').AsInteger);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    except
      on E: Exception do
      begin
        FLogger.Log(mlWarning, 'Prefetch: failed to enumerate projects: ' + E.Message);
        Exit;
      end;
    end;

    if ProjectIds.Count = 0 then
    begin
      FLogger.Log(mlInfo, 'Prefetch: no projects in access_log, 0 candidates');
      Exit;
    end;

    for I := 0 to ProjectIds.Count - 1 do
    begin
      try
        CalculateForProject(ProjectIds[I]);
      except
        on E: Exception do
          FLogger.Log(mlWarning, Format(
            'Prefetch: project %d failed: %s', [ProjectIds[I], E.Message]));
      end;
    end;

    FLogger.Log(mlInfo, Format(
      'Prefetch: %d candidates calculated for %d projects',
      [FTotalCandidates, ProjectIds.Count]));
  finally
    ProjectIds.Free;
  end;
end;

procedure TMxPrefetchCalculator.CalculateForProject(AProjectId: Integer);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Count: Integer;
begin
  Ctx := FPool.AcquireContext;

  // Wrap in transaction to avoid race condition with mx_session_start reads
  Ctx.StartTransaction;
  try
    // Phase 1: Delete old patterns for this project
    Qry := Ctx.CreateQuery(
      'DELETE FROM access_patterns WHERE project_id = :pid');
    try
      Qry.ParamByName('pid').AsInteger := AProjectId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // Phase 2: Insert frequency-based candidates
    CalculateFrequencyScores(Ctx, AProjectId);

    // Phase 3: Bonus -- active plans
    AddActivePlanBonuses(Ctx, AProjectId);

    // Phase 4: Bonus -- linked ADRs via doc_relations
    AddLinkedAdrBonuses(Ctx, AProjectId);

    Ctx.Commit;
  except
    Ctx.Rollback;
    raise;
  end;

  // Count candidates for this project
  Qry := Ctx.CreateQuery(
    'SELECT COUNT(*) AS cnt FROM access_patterns WHERE project_id = :pid');
  try
    Qry.ParamByName('pid').AsInteger := AProjectId;
    Qry.Open;
    Count := Qry.FieldByName('cnt').AsInteger;
    FTotalCandidates := FTotalCandidates + Count;
  finally
    Qry.Free;
  end;
end;

procedure TMxPrefetchCalculator.CalculateFrequencyScores(ACtx: IMxDbContext;
  AProjectId: Integer);
var
  SessionQry, ScoreQry, InsQry: TFDQuery;
  SessionCount: Integer;
  DocId: Integer;
  SessionsHit: Integer;
  Score: Double;
begin
  // Step 1: Count how many distinct non-NULL sessions exist (capped by SessionWindow)
  SessionQry := ACtx.CreateQuery(
    'SELECT COUNT(*) AS cnt FROM (' +
    '  SELECT session_id, MAX(created_at) AS last_access' +
    '  FROM access_log' +
    '  WHERE project_id = :pid AND session_id IS NOT NULL' +
    '  GROUP BY session_id' +
    '  ORDER BY last_access DESC' +
    '  LIMIT :n' +
    ') sub');
  try
    SessionQry.ParamByName('pid').AsInteger := AProjectId;
    SessionQry.ParamByName('n').AsInteger := FSessionWindow;
    SessionQry.Open;
    SessionCount := SessionQry.FieldByName('cnt').AsInteger;
  finally
    SessionQry.Free;
  end;

  if SessionCount = 0 then
    Exit;

  // Step 2: For each doc_id, count in how many of the last N sessions it was loaded
  ScoreQry := ACtx.CreateQuery(
    'SELECT al.doc_id, COUNT(DISTINCT al.session_id) AS sessions_hit' +
    ' FROM access_log al' +
    ' INNER JOIN (' +
    '   SELECT session_id, MAX(created_at) AS last_access' +
    '   FROM access_log' +
    '   WHERE project_id = :pid AND session_id IS NOT NULL' +
    '   GROUP BY session_id' +
    '   ORDER BY last_access DESC' +
    '   LIMIT :n' +
    ' ) recent ON al.session_id = recent.session_id' +
    ' WHERE al.project_id = :pid2' +
    '   AND al.tool_name = ''mx_detail''' +
    '   AND al.doc_id > 0' +
    ' GROUP BY al.doc_id');
  try
    ScoreQry.ParamByName('pid').AsInteger := AProjectId;
    ScoreQry.ParamByName('n').AsInteger := FSessionWindow;
    ScoreQry.ParamByName('pid2').AsInteger := AProjectId;
    ScoreQry.Open;

    // Reuse single InsQry for all inserts
    InsQry := ACtx.CreateQuery(
      'INSERT INTO access_patterns (project_id, doc_id, score, reason, sessions_hit, sessions_total, calculated_at)' +
      ' VALUES (:pid, :did, :score, ''frequency'', :hits, :total, NOW())');
    try
      while not ScoreQry.Eof do
      begin
        DocId := ScoreQry.FieldByName('doc_id').AsInteger;
        SessionsHit := ScoreQry.FieldByName('sessions_hit').AsInteger;
        Score := SessionsHit / SessionCount;

        if Score >= FMinScore then
        begin
          InsQry.ParamByName('pid').AsInteger := AProjectId;
          InsQry.ParamByName('did').AsInteger := DocId;
          InsQry.ParamByName('score').AsFloat := Score;
          InsQry.ParamByName('hits').AsInteger := SessionsHit;
          InsQry.ParamByName('total').AsInteger := SessionCount;
          InsQry.ExecSQL;
        end;

        ScoreQry.Next;
      end;
    finally
      InsQry.Free;
    end;
  finally
    ScoreQry.Free;
  end;
end;

procedure TMxPrefetchCalculator.AddActivePlanBonuses(ACtx: IMxDbContext;
  AProjectId: Integer);
var
  PlanQry, UpsQry: TFDQuery;
begin
  PlanQry := ACtx.CreateQuery(
    'SELECT id FROM documents' +
    ' WHERE project_id = :pid' +
    '   AND doc_type = ''plan''' +
    '   AND status IN (''draft'', ''active'')');
  try
    PlanQry.ParamByName('pid').AsInteger := AProjectId;
    PlanQry.Open;

    UpsQry := ACtx.CreateQuery(
      'INSERT INTO access_patterns (project_id, doc_id, score, reason, sessions_hit, sessions_total, calculated_at)' +
      ' VALUES (:pid, :did, 1.0, ''active_plan'', 0, 0, NOW())' +
      ' ON DUPLICATE KEY UPDATE score = 1.0, reason = ''active_plan''');
    try
      while not PlanQry.Eof do
      begin
        UpsQry.ParamByName('pid').AsInteger := AProjectId;
        UpsQry.ParamByName('did').AsInteger := PlanQry.FieldByName('id').AsInteger;
        UpsQry.ExecSQL;
        PlanQry.Next;
      end;
    finally
      UpsQry.Free;
    end;
  finally
    PlanQry.Free;
  end;
end;

procedure TMxPrefetchCalculator.AddLinkedAdrBonuses(ACtx: IMxDbContext;
  AProjectId: Integer);
var
  AdrQry, UpsQry: TFDQuery;
begin
  // Only ADRs linked from active plans in this project
  AdrQry := ACtx.CreateQuery(
    'SELECT DISTINCT dr.target_doc_id AS doc_id' +
    ' FROM doc_relations dr' +
    ' INNER JOIN documents d ON d.id = dr.target_doc_id' +
    ' INNER JOIN documents src ON src.id = dr.source_doc_id' +
    ' WHERE src.project_id = :pid' +
    '   AND src.doc_type = ''plan''' +
    '   AND src.status IN (''draft'', ''active'')' +
    '   AND d.doc_type = ''decision''' +
    '   AND d.status != ''deleted''');
  try
    AdrQry.ParamByName('pid').AsInteger := AProjectId;
    AdrQry.Open;

    UpsQry := ACtx.CreateQuery(
      'INSERT INTO access_patterns (project_id, doc_id, score, reason, sessions_hit, sessions_total, calculated_at)' +
      ' VALUES (:pid, :did, 1.0, ''linked_adr'', 0, 0, NOW())' +
      ' ON DUPLICATE KEY UPDATE score = GREATEST(score, 1.0),' +
      ' reason = CASE WHEN score < 1.0 THEN ''linked_adr'' ELSE reason END');
    try
      while not AdrQry.Eof do
      begin
        UpsQry.ParamByName('pid').AsInteger := AProjectId;
        UpsQry.ParamByName('did').AsInteger := AdrQry.FieldByName('doc_id').AsInteger;
        UpsQry.ExecSQL;
        AdrQry.Next;
      end;
    finally
      UpsQry.Free;
    end;
  finally
    AdrQry.Free;
  end;
end;

end.
