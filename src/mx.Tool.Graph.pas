unit mx.Tool.Graph;

interface

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Graph, mx.Logic.AccessControl;

function HandleGraphLink(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleGraphQuery(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// Helper: Resolve project slug to ID with ACL check
// ---------------------------------------------------------------------------
function ResolveProject(AContext: IMxDbContext; const ASlug: string;
  ALevel: TAccessLevel): Integer;
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ASlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ASlug);
    Result := Qry.FieldByName('id').AsInteger;
    if not AContext.AccessControl.CheckProject(Result, ALevel) then
      raise EMxAccessDenied.Create(ASlug, ALevel);
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_graph_link
// ---------------------------------------------------------------------------
function HandleGraphLink(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  ProjectSlug, SourceType, SourceName, TargetType, TargetName, EdgeType: string;
  Weight: Double;
  ProjectId, SourceNodeId, TargetNodeId, EdgeId: Integer;
  EdgeExisted, SourceExisted, TargetExisted: Boolean;
  Data: TJSONObject;
begin
  // --- Parameter extraction ---
  ProjectSlug := AParams.GetValue<string>('project', '');
  SourceType  := AParams.GetValue<string>('source_type', '');
  SourceName  := AParams.GetValue<string>('source_name', '');
  TargetType  := AParams.GetValue<string>('target_type', '');
  TargetName  := AParams.GetValue<string>('target_name', '');
  EdgeType    := AParams.GetValue<string>('edge_type', '');
  Weight      := AParams.GetValue<Double>('weight', 1.0);

  // --- Validation ---
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  if SourceType = '' then
    raise EMxValidation.Create('Parameter "source_type" is required');
  if SourceName = '' then
    raise EMxValidation.Create('Parameter "source_name" is required');
  if TargetType = '' then
    raise EMxValidation.Create('Parameter "target_type" is required');
  if TargetName = '' then
    raise EMxValidation.Create('Parameter "target_name" is required');
  if EdgeType = '' then
    raise EMxValidation.Create('Parameter "edge_type" is required');
  if (Weight < 0) or (Weight > 10) then
    raise EMxValidation.Create('Parameter "weight" must be between 0 and 100');

  // --- ACL: write access required ---
  ProjectId := ResolveProject(AContext, ProjectSlug, alReadWrite);

  AContext.StartTransaction;
  try
    // Check if source node already exists
    SourceExisted := TMxGraphData.FindNode(AContext, SourceType, SourceName, ProjectId) > 0;
    SourceNodeId := TMxGraphData.FindOrCreateNode(AContext, SourceType, SourceName, ProjectId);

    // Check if target node already exists
    TargetExisted := TMxGraphData.FindNode(AContext, TargetType, TargetName, ProjectId) > 0;
    TargetNodeId := TMxGraphData.FindOrCreateNode(AContext, TargetType, TargetName, ProjectId);

    // Check if edge already exists before FindOrCreate
    EdgeExisted := False;
    begin
      var Qry := AContext.CreateQuery(
        'SELECT id FROM graph_edges WHERE source_node_id = :src ' +
        'AND target_node_id = :tgt AND edge_type = :etype');
      try
        Qry.ParamByName('src').AsInteger := SourceNodeId;
        Qry.ParamByName('tgt').AsInteger := TargetNodeId;
        Qry.ParamByName('etype').AsString := EdgeType;
        Qry.Open;
        EdgeExisted := not Qry.IsEmpty;
      finally
        Qry.Free;
      end;
    end;

    EdgeId := TMxGraphData.FindOrCreateEdge(AContext, SourceNodeId, TargetNodeId,
      EdgeType, Weight);

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('source_node_id', TJSONNumber.Create(SourceNodeId));
    Data.AddPair('target_node_id', TJSONNumber.Create(TargetNodeId));
    Data.AddPair('edge_id', TJSONNumber.Create(EdgeId));
    Data.AddPair('created', TJSONBool.Create(not EdgeExisted));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_graph_query — BFS traversal with depth limit
// ---------------------------------------------------------------------------
// FR#2936/Plan#3266 M2.9 Draft-Filter X2 deferred for HandleGraphQuery:
// graph_nodes does not currently project the underlying-document status. The
// graph response exposes only node IDs/types/names + edge metadata (no body),
// so a pure-read-only caller seeing draft-linked nodes does not leak draft
// content. Filter is added when nodes gain a status passthrough (post-M3).
function HandleGraphQuery(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
const
  MAX_DEPTH = 3;
  MAX_NODES = 100;
var
  ProjectSlug, NodeType, NodeName, EdgeTypeFilter, Direction: string;
  DocId, Depth, ProjectId: Integer;
  StartNodeIds: TList<Integer>;
  VisitedNodes: TDictionary<Integer, TMxGraphNode>;
  CollectedEdges: TList<TMxGraphEdge>;
  BfsQueue: TQueue<TPair<Integer, Integer>>; // (node_id, current_depth)
  Qry: TFDQuery;
  Node: TMxGraphNode;
  Edges: TArray<TMxGraphEdge>;
  Edge: TMxGraphEdge;
  Pair: TPair<Integer, Integer>;
  NeighborId, CurrentDepth: Integer;
  NodesArr, EdgesArr: TJSONArray;
  NodeObj, EdgeObj: TJSONObject;
  Data: TJSONObject;
  DoOutgoing, DoIncoming: Boolean;
begin
  // --- Parameter extraction ---
  ProjectSlug := AParams.GetValue<string>('project', '');
  NodeType    := AParams.GetValue<string>('node_type', '');
  NodeName    := AParams.GetValue<string>('node_name', '');
  DocId       := AParams.GetValue<Integer>('doc_id', 0);
  Depth       := AParams.GetValue<Integer>('depth', 1);
  EdgeTypeFilter := AParams.GetValue<string>('edge_type', '');
  Direction   := AParams.GetValue<string>('direction', 'both');

  // --- Validation ---
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  if (NodeName = '') and (DocId = 0) and (NodeType = '') then
    raise EMxValidation.Create(
      'At least one of "node_name", "doc_id", or "node_type" is required');
  if Depth < 1 then
    Depth := 1;
  if Depth > MAX_DEPTH then
    raise EMxValidation.Create(
      'Parameter "depth" must be between 1 and ' + IntToStr(MAX_DEPTH));
  if (Direction <> 'outgoing') and (Direction <> 'incoming') and (Direction <> 'both') then
    raise EMxValidation.Create(
      'Parameter "direction" must be one of: outgoing, incoming, both');

  DoOutgoing := (Direction = 'outgoing') or (Direction = 'both');
  DoIncoming := (Direction = 'incoming') or (Direction = 'both');

  // --- ACL: read access required ---
  ProjectId := ResolveProject(AContext, ProjectSlug, alReadOnly);

  // --- Find start nodes ---
  StartNodeIds := TList<Integer>.Create;
  VisitedNodes := TDictionary<Integer, TMxGraphNode>.Create;
  CollectedEdges := TList<TMxGraphEdge>.Create;
  BfsQueue := TQueue<TPair<Integer, Integer>>.Create;
  try
    // Find starting nodes based on parameters
    if DocId > 0 then
    begin
      // By doc_id
      var Nodes := TMxGraphData.GetNodesForDoc(AContext, DocId);
      for Node in Nodes do
        if Node.ProjectId = ProjectId then
          StartNodeIds.Add(Node.Id);
    end
    else if (NodeName <> '') and (NodeType <> '') then
    begin
      // By type + name
      var NId := TMxGraphData.FindNode(AContext, NodeType, NodeName, ProjectId);
      if NId > 0 then
        StartNodeIds.Add(NId);
    end
    else if NodeName <> '' then
    begin
      // By name only — search across types
      Qry := AContext.CreateQuery(
        'SELECT id FROM graph_nodes WHERE name = :name AND project_id = :pid');
      try
        Qry.ParamByName('name').AsString := NodeName;
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.Open;
        while not Qry.Eof do
        begin
          StartNodeIds.Add(Qry.FieldByName('id').AsInteger);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    end
    else if NodeType <> '' then
    begin
      // By type only — return all nodes of that type
      var Nodes := TMxGraphData.GetNodesForProject(AContext, ProjectId, NodeType);
      for Node in Nodes do
      begin
        if VisitedNodes.Count >= MAX_NODES then
          Break;
        VisitedNodes.AddOrSetValue(Node.Id, Node);
      end;
    end;

    if (StartNodeIds.Count = 0) and (VisitedNodes.Count = 0) then
      raise EMxNotFound.Create('No matching nodes found');

    // --- BFS traversal ---
    // Seed BFS queue with start nodes
    for var SId in StartNodeIds do
    begin
      Node := TMxGraphData.GetNode(AContext, SId);
      if Node.Id > 0 then
      begin
        VisitedNodes.AddOrSetValue(Node.Id, Node);
        BfsQueue.Enqueue(TPair<Integer, Integer>.Create(SId, 0));
      end;
    end;

    while BfsQueue.Count > 0 do
    begin
      if VisitedNodes.Count >= MAX_NODES then
        Break;

      Pair := BfsQueue.Dequeue;
      CurrentDepth := Pair.Value;

      if CurrentDepth >= Depth then
        Continue;

      // Outgoing edges
      if DoOutgoing then
      begin
        Edges := TMxGraphData.GetEdgesFrom(AContext, Pair.Key, EdgeTypeFilter);
        for Edge in Edges do
        begin
          CollectedEdges.Add(Edge);
          NeighborId := Edge.TargetNodeId;
          if not VisitedNodes.ContainsKey(NeighborId) then
          begin
            Node := TMxGraphData.GetNode(AContext, NeighborId);
            if Node.Id > 0 then
            begin
              VisitedNodes.AddOrSetValue(NeighborId, Node);
              BfsQueue.Enqueue(TPair<Integer, Integer>.Create(NeighborId, CurrentDepth + 1));
            end;
            if VisitedNodes.Count >= MAX_NODES then
              Break;
          end;
        end;
      end;

      // Incoming edges
      if DoIncoming and (VisitedNodes.Count < MAX_NODES) then
      begin
        Edges := TMxGraphData.GetEdgesTo(AContext, Pair.Key, EdgeTypeFilter);
        for Edge in Edges do
        begin
          CollectedEdges.Add(Edge);
          NeighborId := Edge.SourceNodeId;
          if not VisitedNodes.ContainsKey(NeighborId) then
          begin
            Node := TMxGraphData.GetNode(AContext, NeighborId);
            if Node.Id > 0 then
            begin
              VisitedNodes.AddOrSetValue(NeighborId, Node);
              BfsQueue.Enqueue(TPair<Integer, Integer>.Create(NeighborId, CurrentDepth + 1));
            end;
            if VisitedNodes.Count >= MAX_NODES then
              Break;
          end;
        end;
      end;
    end;

    // --- Build response ---
    NodesArr := TJSONArray.Create;
    for var KV in VisitedNodes do
    begin
      NodeObj := TJSONObject.Create;
      NodeObj.AddPair('id', TJSONNumber.Create(KV.Value.Id));
      NodeObj.AddPair('type', KV.Value.NodeType);
      NodeObj.AddPair('name', KV.Value.Name);
      if KV.Value.DocId > 0 then
        NodeObj.AddPair('doc_id', TJSONNumber.Create(KV.Value.DocId))
      else
        NodeObj.AddPair('doc_id', TJSONNull.Create);

      // Count edges for this node
      var OutCount := 0;
      var InCount := 0;
      for var CE in CollectedEdges do
      begin
        if CE.SourceNodeId = KV.Key then
          Inc(OutCount);
        if CE.TargetNodeId = KV.Key then
          Inc(InCount);
      end;
      NodeObj.AddPair('edges_out', TJSONNumber.Create(OutCount));
      NodeObj.AddPair('edges_in', TJSONNumber.Create(InCount));
      NodesArr.AddElement(NodeObj);
    end;

    // Deduplicate edges by id
    var SeenEdgeIds := TDictionary<Integer, Boolean>.Create;
    try
      EdgesArr := TJSONArray.Create;
      for var CE in CollectedEdges do
      begin
        if not SeenEdgeIds.ContainsKey(CE.Id) then
        begin
          SeenEdgeIds.Add(CE.Id, True);
          EdgeObj := TJSONObject.Create;
          EdgeObj.AddPair('source', TJSONNumber.Create(CE.SourceNodeId));
          EdgeObj.AddPair('target', TJSONNumber.Create(CE.TargetNodeId));
          EdgeObj.AddPair('type', CE.EdgeType);
          EdgeObj.AddPair('weight', TJSONNumber.Create(CE.Weight));
          EdgesArr.AddElement(EdgeObj);
        end;
      end;
    finally
      SeenEdgeIds.Free;
    end;

    Data := TJSONObject.Create;
    try
      Data.AddPair('nodes', NodesArr);
      Data.AddPair('edges', EdgesArr);
      Data.AddPair('node_count', TJSONNumber.Create(VisitedNodes.Count));
      Data.AddPair('edge_count', TJSONNumber.Create(EdgesArr.Count));
      Result := MxSuccessResponse(Data);
    except
      Data.Free;
      raise;
    end;
  finally
    BfsQueue.Free;
    CollectedEdges.Free;
    VisitedNodes.Free;
    StartNodeIds.Free;
  end;
end;

end.
