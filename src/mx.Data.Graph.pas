unit mx.Data.Graph;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils,
  Data.DB, FireDAC.Comp.Client,
  mx.Types;

type
  TMxGraphNode = record
    Id: Integer;
    NodeType: string;    // file, function, pattern, lesson, doc, module
    Name: string;
    ProjectId: Integer;  // 0 = cross-project
    DocId: Integer;      // 0 = no linked document
    Metadata: string;    // JSON string
    CreatedAt: TDateTime;
    UpdatedAt: TDateTime;
  end;

  TMxGraphEdge = record
    Id: Integer;
    SourceNodeId: Integer;
    TargetNodeId: Integer;
    EdgeType: string;    // references, caused_by, fixes, contradicts, applies_to, calls, imports
    Weight: Double;
    Metadata: string;    // JSON string
    CreatedAt: TDateTime;
  end;

  TMxGraphData = class
  public
    // --- Nodes ---
    class function FindOrCreateNode(ACtx: IMxDbContext;
      const ANodeType, AName: string;
      AProjectId: Integer; ADocId: Integer = 0): Integer; static;

    class function GetNode(ACtx: IMxDbContext;
      ANodeId: Integer): TMxGraphNode; static;

    class function FindNode(ACtx: IMxDbContext;
      const ANodeType, AName: string;
      AProjectId: Integer): Integer; static;

    class function DeleteNode(ACtx: IMxDbContext;
      ANodeId: Integer): Boolean; static;

    // --- Edges ---
    class function FindOrCreateEdge(ACtx: IMxDbContext;
      ASourceId, ATargetId: Integer;
      const AEdgeType: string; AWeight: Double = 1.0): Integer; static;

    class function UpdateEdgeWeight(ACtx: IMxDbContext;
      AEdgeId: Integer; AWeight: Double): Boolean; static;

    class function DeleteEdge(ACtx: IMxDbContext;
      AEdgeId: Integer): Boolean; static;

    // --- Queries ---
    class function GetEdgesFrom(ACtx: IMxDbContext;
      ANodeId: Integer;
      const AEdgeType: string = ''): TArray<TMxGraphEdge>; static;

    class function GetEdgesTo(ACtx: IMxDbContext;
      ANodeId: Integer;
      const AEdgeType: string = ''): TArray<TMxGraphEdge>; static;

    class function GetNeighbors(ACtx: IMxDbContext;
      ANodeId: Integer; ADepth: Integer = 1;
      const AEdgeType: string = ''): TArray<TMxGraphNode>; static;

    class function GetNodesForDoc(ACtx: IMxDbContext;
      ADocId: Integer): TArray<TMxGraphNode>; static;

    class function GetNodesForProject(ACtx: IMxDbContext;
      AProjectId: Integer;
      const ANodeType: string = ''): TArray<TMxGraphNode>; static;
  end;

implementation

{ TMxGraphData }

// --- Nodes ---

class function TMxGraphData.FindOrCreateNode(ACtx: IMxDbContext;
  const ANodeType, AName: string;
  AProjectId: Integer; ADocId: Integer): Integer;
var
  Qry: TFDQuery;
begin
  // Try find existing
  Result := FindNode(ACtx, ANodeType, AName, AProjectId);
  if Result > 0 then
    Exit;

  // Create new
  Qry := ACtx.CreateQuery(
    'INSERT INTO graph_nodes (node_type, name, project_id, doc_id) ' +
    'VALUES (:ntype, :name, :pid, :did)');
  try
    Qry.ParamByName('ntype').AsWideString :=ANodeType;
    Qry.ParamByName('name').AsWideString :=AName;
    if AProjectId > 0 then
      Qry.ParamByName('pid').AsInteger := AProjectId
    else
    begin
      Qry.ParamByName('pid').DataType := ftInteger;
      Qry.ParamByName('pid').Clear;
    end;
    if ADocId > 0 then
      Qry.ParamByName('did').AsInteger := ADocId
    else
    begin
      Qry.ParamByName('did').DataType := ftInteger;
      Qry.ParamByName('did').Clear;
    end;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
  Qry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
  try
    Qry.Open;
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.GetNode(ACtx: IMxDbContext;
  ANodeId: Integer): TMxGraphNode;
var
  Qry: TFDQuery;
begin
  Result := Default(TMxGraphNode);
  Qry := ACtx.CreateQuery(
    'SELECT id, node_type, name, project_id, doc_id, metadata, ' +
    'created_at, updated_at FROM graph_nodes WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := ANodeId;
    Qry.Open;
    if not Qry.Eof then
    begin
      Result.Id := Qry.FieldByName('id').AsInteger;
      Result.NodeType := Qry.FieldByName('node_type').AsString;
      Result.Name := Qry.FieldByName('name').AsString;
      Result.ProjectId := Qry.FieldByName('project_id').AsInteger;
      Result.DocId := Qry.FieldByName('doc_id').AsInteger;
      Result.Metadata := Qry.FieldByName('metadata').AsString;
      Result.CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Result.UpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.FindNode(ACtx: IMxDbContext;
  const ANodeType, AName: string;
  AProjectId: Integer): Integer;
var
  Qry: TFDQuery;
  Sql: string;
begin
  Result := 0;
  if AProjectId > 0 then
    Sql := 'SELECT id FROM graph_nodes WHERE node_type = :ntype ' +
           'AND name = :name AND project_id = :pid'
  else
    Sql := 'SELECT id FROM graph_nodes WHERE node_type = :ntype ' +
           'AND name = :name AND project_id IS NULL';

  Qry := ACtx.CreateQuery(Sql);
  try
    Qry.ParamByName('ntype').AsWideString :=ANodeType;
    Qry.ParamByName('name').AsWideString :=AName;
    if AProjectId > 0 then
      Qry.ParamByName('pid').AsInteger := AProjectId;
    Qry.Open;
    if not Qry.Eof then
      Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.DeleteNode(ACtx: IMxDbContext;
  ANodeId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery('DELETE FROM graph_nodes WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := ANodeId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

// --- Edges ---

class function TMxGraphData.FindOrCreateEdge(ACtx: IMxDbContext;
  ASourceId, ATargetId: Integer;
  const AEdgeType: string; AWeight: Double): Integer;
var
  Qry: TFDQuery;
begin
  // Try find existing
  Qry := ACtx.CreateQuery(
    'SELECT id FROM graph_edges WHERE source_node_id = :src ' +
    'AND target_node_id = :tgt AND edge_type = :etype');
  try
    Qry.ParamByName('src').AsInteger := ASourceId;
    Qry.ParamByName('tgt').AsInteger := ATargetId;
    Qry.ParamByName('etype').AsWideString :=AEdgeType;
    Qry.Open;
    if not Qry.Eof then
    begin
      Result := Qry.FieldByName('id').AsInteger;
      Exit;
    end;
  finally
    Qry.Free;
  end;

  // Create new
  Qry := ACtx.CreateQuery(
    'INSERT INTO graph_edges (source_node_id, target_node_id, edge_type, weight) ' +
    'VALUES (:src, :tgt, :etype, :w)');
  try
    Qry.ParamByName('src').AsInteger := ASourceId;
    Qry.ParamByName('tgt').AsInteger := ATargetId;
    Qry.ParamByName('etype').AsWideString :=AEdgeType;
    Qry.ParamByName('w').AsFloat := AWeight;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
  Qry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
  try
    Qry.Open;
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.UpdateEdgeWeight(ACtx: IMxDbContext;
  AEdgeId: Integer; AWeight: Double): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'UPDATE graph_edges SET weight = :w WHERE id = :id');
  try
    Qry.ParamByName('w').AsFloat := AWeight;
    Qry.ParamByName('id').AsInteger := AEdgeId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.DeleteEdge(ACtx: IMxDbContext;
  AEdgeId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery('DELETE FROM graph_edges WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := AEdgeId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

// --- Queries ---

class function TMxGraphData.GetEdgesFrom(ACtx: IMxDbContext;
  ANodeId: Integer; const AEdgeType: string): TArray<TMxGraphEdge>;
var
  Qry: TFDQuery;
  Sql: string;
  I: Integer;
begin
  Sql := 'SELECT id, source_node_id, target_node_id, edge_type, weight, ' +
         'metadata, created_at FROM graph_edges WHERE source_node_id = :nid';
  if AEdgeType <> '' then
    Sql := Sql + ' AND edge_type = :etype';

  Qry := ACtx.CreateQuery(Sql);
  try
    Qry.ParamByName('nid').AsInteger := ANodeId;
    if AEdgeType <> '' then
      Qry.ParamByName('etype').AsWideString :=AEdgeType;
    Qry.Open;
    I := 0;
    while not Qry.Eof do
    begin
      SetLength(Result, I + 1);
      Result[I].Id := Qry.FieldByName('id').AsInteger;
      Result[I].SourceNodeId := Qry.FieldByName('source_node_id').AsInteger;
      Result[I].TargetNodeId := Qry.FieldByName('target_node_id').AsInteger;
      Result[I].EdgeType := Qry.FieldByName('edge_type').AsString;
      Result[I].Weight := Qry.FieldByName('weight').AsFloat;
      Result[I].Metadata := Qry.FieldByName('metadata').AsString;
      Result[I].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Inc(I);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.GetEdgesTo(ACtx: IMxDbContext;
  ANodeId: Integer; const AEdgeType: string): TArray<TMxGraphEdge>;
var
  Qry: TFDQuery;
  Sql: string;
  I: Integer;
begin
  Sql := 'SELECT id, source_node_id, target_node_id, edge_type, weight, ' +
         'metadata, created_at FROM graph_edges WHERE target_node_id = :nid';
  if AEdgeType <> '' then
    Sql := Sql + ' AND edge_type = :etype';

  Qry := ACtx.CreateQuery(Sql);
  try
    Qry.ParamByName('nid').AsInteger := ANodeId;
    if AEdgeType <> '' then
      Qry.ParamByName('etype').AsWideString :=AEdgeType;
    Qry.Open;
    I := 0;
    while not Qry.Eof do
    begin
      SetLength(Result, I + 1);
      Result[I].Id := Qry.FieldByName('id').AsInteger;
      Result[I].SourceNodeId := Qry.FieldByName('source_node_id').AsInteger;
      Result[I].TargetNodeId := Qry.FieldByName('target_node_id').AsInteger;
      Result[I].EdgeType := Qry.FieldByName('edge_type').AsString;
      Result[I].Weight := Qry.FieldByName('weight').AsFloat;
      Result[I].Metadata := Qry.FieldByName('metadata').AsString;
      Result[I].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Inc(I);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.GetNeighbors(ACtx: IMxDbContext;
  ANodeId: Integer; ADepth: Integer;
  const AEdgeType: string): TArray<TMxGraphNode>;
var
  Qry: TFDQuery;
  Sql: string;
  I: Integer;
begin
  // Single-level neighbors (outgoing + incoming)
  Sql := 'SELECT DISTINCT n.id, n.node_type, n.name, n.project_id, n.doc_id, ' +
         'n.metadata, n.created_at, n.updated_at FROM graph_nodes n ' +
         'INNER JOIN graph_edges e ON (e.target_node_id = n.id AND e.source_node_id = :nid) ' +
         'OR (e.source_node_id = n.id AND e.target_node_id = :nid2)';
  if AEdgeType <> '' then
    Sql := Sql + ' WHERE e.edge_type = :etype';

  Qry := ACtx.CreateQuery(Sql);
  try
    Qry.ParamByName('nid').AsInteger := ANodeId;
    Qry.ParamByName('nid2').AsInteger := ANodeId;
    if AEdgeType <> '' then
      Qry.ParamByName('etype').AsWideString :=AEdgeType;
    Qry.Open;
    I := 0;
    while not Qry.Eof do
    begin
      SetLength(Result, I + 1);
      Result[I].Id := Qry.FieldByName('id').AsInteger;
      Result[I].NodeType := Qry.FieldByName('node_type').AsString;
      Result[I].Name := Qry.FieldByName('name').AsString;
      Result[I].ProjectId := Qry.FieldByName('project_id').AsInteger;
      Result[I].DocId := Qry.FieldByName('doc_id').AsInteger;
      Result[I].Metadata := Qry.FieldByName('metadata').AsString;
      Result[I].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Result[I].UpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
      Inc(I);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  // Note: ADepth > 1 requires recursive BFS — implemented in mx_graph_query tool
end;

class function TMxGraphData.GetNodesForDoc(ACtx: IMxDbContext;
  ADocId: Integer): TArray<TMxGraphNode>;
var
  Qry: TFDQuery;
  I: Integer;
begin
  Qry := ACtx.CreateQuery(
    'SELECT id, node_type, name, project_id, doc_id, metadata, ' +
    'created_at, updated_at FROM graph_nodes WHERE doc_id = :did');
  try
    Qry.ParamByName('did').AsInteger := ADocId;
    Qry.Open;
    I := 0;
    while not Qry.Eof do
    begin
      SetLength(Result, I + 1);
      Result[I].Id := Qry.FieldByName('id').AsInteger;
      Result[I].NodeType := Qry.FieldByName('node_type').AsString;
      Result[I].Name := Qry.FieldByName('name').AsString;
      Result[I].ProjectId := Qry.FieldByName('project_id').AsInteger;
      Result[I].DocId := Qry.FieldByName('doc_id').AsInteger;
      Result[I].Metadata := Qry.FieldByName('metadata').AsString;
      Result[I].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Result[I].UpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
      Inc(I);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxGraphData.GetNodesForProject(ACtx: IMxDbContext;
  AProjectId: Integer; const ANodeType: string): TArray<TMxGraphNode>;
var
  Qry: TFDQuery;
  Sql: string;
  I: Integer;
begin
  Sql := 'SELECT id, node_type, name, project_id, doc_id, metadata, ' +
         'created_at, updated_at FROM graph_nodes WHERE project_id = :pid';
  if ANodeType <> '' then
    Sql := Sql + ' AND node_type = :ntype';

  Qry := ACtx.CreateQuery(Sql);
  try
    Qry.ParamByName('pid').AsInteger := AProjectId;
    if ANodeType <> '' then
      Qry.ParamByName('ntype').AsWideString :=ANodeType;
    Qry.Open;
    I := 0;
    while not Qry.Eof do
    begin
      SetLength(Result, I + 1);
      Result[I].Id := Qry.FieldByName('id').AsInteger;
      Result[I].NodeType := Qry.FieldByName('node_type').AsString;
      Result[I].Name := Qry.FieldByName('name').AsString;
      Result[I].ProjectId := Qry.FieldByName('project_id').AsInteger;
      Result[I].DocId := Qry.FieldByName('doc_id').AsInteger;
      Result[I].Metadata := Qry.FieldByName('metadata').AsString;
      Result[I].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      Result[I].UpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
      Inc(I);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

end.
