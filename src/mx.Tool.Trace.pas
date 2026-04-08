unit mx.Tool.Trace;

interface

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool;

const
  TRAVERSE_FORWARD:  array[0..0] of string = ('leads_to');
  TRAVERSE_BACKWARD: array[0..1] of string = ('caused_by', 'depends_on');
  SHOW_ALTERNATIVES: array[0..0] of string = ('rejected_in_favor_of');
  SHOW_ASSUMPTIONS:  array[0..0] of string = ('assumes');
  SHOW_SUPERSEDED:   array[0..0] of string = ('supersedes');

  MAX_NODES = 50;

function HandleDecisionTrace(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

type
  TTraceNode = record
    DocId: Integer;
    Title: string;
    DocType: string;
    Status: string;
    Relation: string;
    Depth: Integer;
    AccessDenied: Boolean;
    SummaryL1: string;
  end;

// ---------------------------------------------------------------------------
// NodeToJSON — Convert TTraceNode to TJSONObject
// ---------------------------------------------------------------------------
function NodeToJSON(const N: TTraceNode): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(N.DocId));
  Result.AddPair('title', N.Title);
  Result.AddPair('doc_type', N.DocType);
  Result.AddPair('status', N.Status);
  Result.AddPair('relation', N.Relation);
  Result.AddPair('depth', TJSONNumber.Create(N.Depth));
  if N.AccessDenied then
    Result.AddPair('access', 'denied');
end;

// ---------------------------------------------------------------------------
// TraverseRelations — BFS with visited-set and batch query per depth level
// ---------------------------------------------------------------------------
function TraverseRelations(AContext: IMxDbContext; StartDocId: Integer;
  const RelTypes: array of string; MaxDepth: Integer;
  Visited: TDictionary<Integer, Boolean>; Forward: Boolean): TArray<TTraceNode>;
var
  CurrentLevel, NextLevel: TList<Integer>;
  Results: TList<TTraceNode>;
  Depth, i: Integer;
  Qry: TFDQuery;
  Node: TTraceNode;
  DocId: Integer;
  RelTypeFilter, IdList: string;
begin
  Results := TList<TTraceNode>.Create;
  CurrentLevel := TList<Integer>.Create;
  NextLevel := TList<Integer>.Create;
  try
    CurrentLevel.Add(StartDocId);

    // Build relation type filter: 'type1','type2',...
    RelTypeFilter := '';
    for i := 0 to High(RelTypes) do
    begin
      if i > 0 then
        RelTypeFilter := RelTypeFilter + ',';
      RelTypeFilter := RelTypeFilter + QuotedStr(RelTypes[i]);
    end;

    for Depth := 1 to MaxDepth do
    begin
      if (CurrentLevel.Count = 0) or (Visited.Count >= MAX_NODES) then
        Break;

      // Build ID list for batch query
      IdList := '';
      for i := 0 to CurrentLevel.Count - 1 do
      begin
        if i > 0 then
          IdList := IdList + ',';
        IdList := IdList + IntToStr(CurrentLevel[i]);
      end;

      if Forward then
        Qry := AContext.CreateQuery(Format(
          'SELECT r.target_doc_id AS doc_id, r.relation_type, ' +
          'd.title, d.doc_type, d.status, d.summary_l1 ' +
          'FROM doc_relations r ' +
          'LEFT JOIN documents d ON d.id = r.target_doc_id ' +
          'WHERE r.source_doc_id IN (%s) AND r.relation_type IN (%s)',
          [IdList, RelTypeFilter]))
      else
        Qry := AContext.CreateQuery(Format(
          'SELECT r.source_doc_id AS doc_id, r.relation_type, ' +
          'd.title, d.doc_type, d.status, d.summary_l1 ' +
          'FROM doc_relations r ' +
          'LEFT JOIN documents d ON d.id = r.source_doc_id ' +
          'WHERE r.target_doc_id IN (%s) AND r.relation_type IN (%s)',
          [IdList, RelTypeFilter]));
      try
        Qry.Open;

        NextLevel.Clear;
        while not Qry.Eof do
        begin
          DocId := Qry.FieldByName('doc_id').AsInteger;
          if not Visited.ContainsKey(DocId) then
          begin
            Visited.Add(DocId, True);

            Node.DocId := DocId;
            Node.Title := Qry.FieldByName('title').AsString;
            Node.DocType := Qry.FieldByName('doc_type').AsString;
            Node.Status := Qry.FieldByName('status').AsString;
            Node.Relation := Qry.FieldByName('relation_type').AsString;
            Node.Depth := Depth;
            Node.SummaryL1 := Qry.FieldByName('summary_l1').AsString;

            // ACL Phase 1: always allowed (read-only metadata)
            Node.AccessDenied := False;

            Results.Add(Node);
            NextLevel.Add(DocId);
          end;
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      // Swap levels
      CurrentLevel.Clear;
      CurrentLevel.AddRange(NextLevel.ToArray);
    end;

    Result := Results.ToArray;
  finally
    Results.Free;
    CurrentLevel.Free;
    NextLevel.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_decision_trace — Traverse decision chains
// ---------------------------------------------------------------------------
function HandleDecisionTrace(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  DocId, MaxDepth, i: Integer;
  Visited: TDictionary<Integer, Boolean>;
  Data, Decision, Chain, Stats: TJSONObject;
  Causes, Alternatives, Assumptions, Consequences, Superseded, Warnings: TJSONArray;
  Nodes: TArray<TTraceNode>;
  Qry: TFDQuery;
  Obj: TJSONObject;
  Risk: string;
  AssumptionItem: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('doc_id is required');

  MaxDepth := AParams.GetValue<Integer>('max_depth', 5);
  if MaxDepth > 10 then MaxDepth := 10;
  if MaxDepth < 1 then MaxDepth := 1;

  Visited := TDictionary<Integer, Boolean>.Create;
  try
    Visited.Add(DocId, True);  // Mark start node as visited

    // Load start document
    Qry := AContext.CreateQuery(
      'SELECT title, doc_type, status FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      if Qry.Eof then
        raise EMxNotFound.Create(Format('Document not found: %d', [DocId]));

      Decision := TJSONObject.Create;
      Decision.AddPair('id', TJSONNumber.Create(DocId));
      Decision.AddPair('title', Qry.FieldByName('title').AsString);
      Decision.AddPair('doc_type', Qry.FieldByName('doc_type').AsString);
      Decision.AddPair('status', Qry.FieldByName('status').AsString);
    finally
      Qry.Free;
    end;

    Chain := TJSONObject.Create;

    // 1. Causes (backward traversal)
    Causes := TJSONArray.Create;
    Nodes := TraverseRelations(AContext, DocId, TRAVERSE_BACKWARD, MaxDepth,
      Visited, False);
    for i := 0 to High(Nodes) do
      Causes.AddElement(NodeToJSON(Nodes[i]));
    Chain.AddPair('causes', Causes);

    // 2. Rejected alternatives (lateral, depth 1 only)
    Alternatives := TJSONArray.Create;
    Nodes := TraverseRelations(AContext, DocId, SHOW_ALTERNATIVES, 1,
      Visited, True);
    for i := 0 to High(Nodes) do
    begin
      Obj := NodeToJSON(Nodes[i]);
      // reason = summary_l1 of the rejected doc (more informative than title)
      if Nodes[i].SummaryL1 <> '' then
        Obj.AddPair('reason', Nodes[i].SummaryL1)
      else
        Obj.AddPair('reason', Nodes[i].Title);
      Alternatives.AddElement(Obj);
    end;
    Chain.AddPair('alternatives_rejected', Alternatives);

    // 3. Assumptions (lateral, depth 1 only)
    Assumptions := TJSONArray.Create;
    Nodes := TraverseRelations(AContext, DocId, SHOW_ASSUMPTIONS, 1,
      Visited, True);
    for i := 0 to High(Nodes) do
    begin
      Obj := NodeToJSON(Nodes[i]);
      Risk := 'low';
      if Nodes[i].Status = 'draft' then
        Risk := 'medium';       // unverified
      if Nodes[i].Status = 'rejected' then
        Risk := 'critical';     // invalidated
      Obj.AddPair('risk', Risk);
      Assumptions.AddElement(Obj);
    end;
    Chain.AddPair('assumptions', Assumptions);

    // 4. Consequences (forward traversal)
    Consequences := TJSONArray.Create;
    Nodes := TraverseRelations(AContext, DocId, TRAVERSE_FORWARD, MaxDepth,
      Visited, True);
    for i := 0 to High(Nodes) do
      Consequences.AddElement(NodeToJSON(Nodes[i]));
    Chain.AddPair('consequences', Consequences);

    // 5. Superseded (lateral, depth 1 only)
    Superseded := TJSONArray.Create;
    Nodes := TraverseRelations(AContext, DocId, SHOW_SUPERSEDED, 1,
      Visited, True);
    for i := 0 to High(Nodes) do
      Superseded.AddElement(NodeToJSON(Nodes[i]));
    Chain.AddPair('supersedes', Superseded);

    // Warnings — flag critical/medium assumptions
    Warnings := TJSONArray.Create;
    for i := 0 to Assumptions.Count - 1 do
    begin
      AssumptionItem := Assumptions.Items[i] as TJSONObject;
      if AssumptionItem.GetValue<string>('risk', '') = 'critical' then
        Warnings.Add(Format(
          'Assumption #%d ist invalidated (rejected) — Review noetig',
          [AssumptionItem.GetValue<Integer>('id', 0)]));
      if AssumptionItem.GetValue<string>('risk', '') = 'medium' then
        Warnings.Add(Format(
          'Assumption #%d ist unverified (draft) — Validierung empfohlen',
          [AssumptionItem.GetValue<Integer>('id', 0)]));
    end;

    // Traversal stats
    Stats := TJSONObject.Create;
    Stats.AddPair('nodes_visited', TJSONNumber.Create(Visited.Count));
    Stats.AddPair('depth_limit', TJSONNumber.Create(MaxDepth));

    // Build response
    Data := TJSONObject.Create;
    Data.AddPair('decision', Decision);
    Data.AddPair('chain', Chain);
    Data.AddPair('warnings', Warnings);
    Data.AddPair('traversal_stats', Stats);

    Result := MxSuccessResponse(Data);
  finally
    Visited.Free;
  end;
end;

end.
