unit mx.Admin.Api.Graph;

// ===========================================================================
// Spec#7677 / Inbox#1635 — Animated Knowledge Graph for the Admin UI.
// Serves the node/link payload that the D3 force-directed graph (admin/www)
// renders. One project per request, scoped by slug.
//
//   GET /api/graph?project={slug}[&limit=N]
//   -> { project, node_count, total_nodes, truncated, link_count,
//        nodes:[{id,type,title,summary,status}], links:[{s,t,rel}] }
//
// Nodes come from `documents` (soft-deleted excluded). Links come from
// `doc_relations` but ONLY where BOTH endpoints survive in the returned
// node set — this guarantees the client never receives an edge that points
// at a missing node (which would make D3 forceLink throw), even when the
// node list is truncated for performance (AC#8).
// ===========================================================================

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Admin.Auth;

// Admin-gated (mirrors /global/* — cross-document project view). The server
// router applies RequireAdmin before dispatching here.
procedure HandleGetGraph(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);

// Universe view (Spec#7677 phase-2): every active project is a "galaxy" sized
// by its live doc_count, with a doc_type breakdown for colour/shape, and
// project_relations as inter-galaxy links.
//   GET /api/graph/universe
//   -> { galaxies:[{id,slug,name,doc_count,types:{<doc_type>:n}}],
//        links:[{s,t,rel}] }
procedure HandleGetUniverse(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  System.Net.URLClient,
  Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server;

// Default cap on returned nodes. Spec#7677 AC#8 asks for acceptable
// performance on the largest project; force-directed layout degrades well
// before the data does, so we cap here and report `truncated` so the client
// can surface a "showing N of T" hint. Override via ?limit=N (hard max 2000).
const
  GRAPH_DEFAULT_LIMIT = 600;
  GRAPH_MAX_LIMIT     = 2000;

// Minimal query-param reader (the QGet in mx.Admin.Api.Projects is unit-local
// and not exported). Handles the optional leading '?' and URL-decodes.
function GraphQGet(const AQuery, AName: string): string;
var
  Q, Key: string;
  Parts: TArray<string>;
  I, EqPos: Integer;
begin
  Result := '';
  if AQuery = '' then Exit;
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
      Result := StringReplace(Result, '+', ' ', [rfReplaceAll]);
      Result := TURI.URLDecode(Result);
      Exit;
    end;
  end;
end;

procedure HandleGetGraph(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Nodes, Links: TJSONArray;
  NodeIds: TDictionary<Integer, Boolean>;
  Slug: string;
  ProjId, Lim, TotalNodes, LinkCount, Src, Tgt: Integer;
begin
  Slug := Trim(GraphQGet(C.Request.Uri.Query, 'project'));
  if Slug = '' then
  begin
    MxSendError(C, 400, 'missing_project');
    Exit;
  end;

  Lim := StrToIntDef(GraphQGet(C.Request.Uri.Query, 'limit'), GRAPH_DEFAULT_LIMIT);
  if Lim < 1 then Lim := 1;
  if Lim > GRAPH_MAX_LIMIT then Lim := GRAPH_MAX_LIMIT;

  Json := TJSONObject.Create;
  NodeIds := TDictionary<Integer, Boolean>.Create;
  try
    try
      Ctx := APool.AcquireContext;

      // 1) Resolve slug -> project_id (empty result = unknown project).
      ProjId := 0;
      Qry := Ctx.CreateQuery('SELECT id FROM projects WHERE slug = :slug');
      try
        Qry.ParamByName('slug').AsWideString := Slug;
        Qry.Open;
        if not Qry.Eof then
          ProjId := Qry.FieldByName('id').AsInteger;
      finally
        Qry.Free;
      end;
      if ProjId = 0 then
      begin
        // NodeIds is released by the outer finally — freeing it here too
        // would double-free. Json has no finally guard, so free it here.
        Json.Free;
        MxSendError(C, 404, 'project_not_found');
        Exit;
      end;

      // 2) Total node count (for the truncated/"N of T" hint).
      TotalNodes := 0;
      Qry := Ctx.CreateQuery(
        'SELECT COUNT(*) AS c FROM documents ' +
        'WHERE project_id = :pid AND status <> ''deleted''');
      try
        Qry.ParamByName('pid').AsInteger := ProjId;
        Qry.Open;
        if not Qry.Eof then
          TotalNodes := Qry.FieldByName('c').AsInteger;
      finally
        Qry.Free;
      end;

      // 3) Nodes — newest first so a truncated view keeps the live work.
      //    Attach to Json immediately so Json owns it: any later exception is
      //    cleaned up transitively by Json.Free (no detached-array leak window).
      Nodes := TJSONArray.Create;
      Json.AddPair('nodes', Nodes);
      Qry := Ctx.CreateQuery(
        'SELECT id, doc_type, title, status, summary_l1 ' +
        'FROM documents ' +
        'WHERE project_id = :pid AND status <> ''deleted'' ' +
        'ORDER BY updated_at DESC LIMIT :lim');
      try
        Qry.ParamByName('pid').AsInteger := ProjId;
        Qry.ParamByName('lim').AsInteger := Lim;
        Qry.Open;
        while not Qry.Eof do
        begin
          var Nid := Qry.FieldByName('id').AsInteger;
          NodeIds.AddOrSetValue(Nid, True);
          var Row := TJSONObject.Create;
          Row.AddPair('id', TJSONNumber.Create(Nid));
          Row.AddPair('type', Qry.FieldByName('doc_type').AsString);
          Row.AddPair('title', Qry.FieldByName('title').AsString);
          Row.AddPair('status', Qry.FieldByName('status').AsString);
          Row.AddPair('summary', Qry.FieldByName('summary_l1').AsString);
          Nodes.Add(Row);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      // 4) Links — project-internal relations, kept only when BOTH endpoints
      //    are in the returned node set (prevents orphan edges on truncation).
      Links := TJSONArray.Create;
      Json.AddPair('links', Links);
      LinkCount := 0;
      Qry := Ctx.CreateQuery(
        'SELECT r.source_doc_id AS s, r.target_doc_id AS t, ' +
        '       r.relation_type AS rel ' +
        'FROM doc_relations r ' +
        'JOIN documents sd ON r.source_doc_id = sd.id ' +
        'JOIN documents td ON r.target_doc_id = td.id ' +
        'WHERE sd.project_id = :pid AND td.project_id = :pid ' +
        '  AND sd.status <> ''deleted'' AND td.status <> ''deleted''');
      try
        Qry.ParamByName('pid').AsInteger := ProjId;
        Qry.Open;
        while not Qry.Eof do
        begin
          Src := Qry.FieldByName('s').AsInteger;
          Tgt := Qry.FieldByName('t').AsInteger;
          if NodeIds.ContainsKey(Src) and NodeIds.ContainsKey(Tgt) then
          begin
            var L := TJSONObject.Create;
            L.AddPair('s', TJSONNumber.Create(Src));
            L.AddPair('t', TJSONNumber.Create(Tgt));
            L.AddPair('rel', Qry.FieldByName('rel').AsString);
            Links.Add(L);
            Inc(LinkCount);
          end;
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      Json.AddPair('project', Slug);
      Json.AddPair('node_count', TJSONNumber.Create(NodeIds.Count));
      Json.AddPair('total_nodes', TJSONNumber.Create(TotalNodes));
      Json.AddPair('truncated',
        TJSONBool.Create(TotalNodes > NodeIds.Count));
      Json.AddPair('link_count', TJSONNumber.Create(LinkCount));
      // 'nodes'/'links' already attached at creation (see above).
      MxSendJson(C, 200, Json);
      Json.Free;
    except
      on E: Exception do
      begin
        Json.Free;
        ALogger.Log(mlError, '[GetGraph] ' + E.Message);
        MxSendError(C, 500, 'internal_error');
      end;
    end;
  finally
    NodeIds.Free;
  end;
end;

procedure HandleGetUniverse(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Galaxies, Links: TJSONArray;
  TypesByProj: TDictionary<Integer, TJSONObject>;
  Pid: Integer;
  TypesObj: TJSONObject;
begin
  Json := TJSONObject.Create;
  // Holds references to each galaxy's nested 'types' object (NOT owner — the
  // objects are owned by their galaxy, which is owned by Json). Freed in finally.
  TypesByProj := TDictionary<Integer, TJSONObject>.Create;
  try
    try
      Ctx := APool.AcquireContext;

      // 1) Galaxies = active projects + live doc_count (0 for empty projects).
      Galaxies := TJSONArray.Create;
      Json.AddPair('galaxies', Galaxies);
      Qry := Ctx.CreateQuery(
        'SELECT p.id, p.slug, p.name, COUNT(d.id) AS doc_count ' +
        'FROM projects p ' +
        'LEFT JOIN documents d ON d.project_id = p.id AND d.status <> ''deleted'' ' +
        'WHERE p.is_active = 1 AND p.deleted_at IS NULL ' +
        'GROUP BY p.id, p.slug, p.name ' +
        'ORDER BY doc_count DESC');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Pid := Qry.FieldByName('id').AsInteger;
          var G := TJSONObject.Create;
          G.AddPair('id', TJSONNumber.Create(Pid));
          G.AddPair('slug', Qry.FieldByName('slug').AsString);
          G.AddPair('name', Qry.FieldByName('name').AsString);
          G.AddPair('doc_count',
            TJSONNumber.Create(Qry.FieldByName('doc_count').AsInteger));
          TypesObj := TJSONObject.Create;
          G.AddPair('types', TypesObj);   // owned by G
          TypesByProj.AddOrSetValue(Pid, TypesObj);
          Galaxies.Add(G);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      // 2) doc_type breakdown per project -> nested 'types' map per galaxy.
      Qry := Ctx.CreateQuery(
        'SELECT project_id, doc_type, COUNT(*) AS c ' +
        'FROM documents WHERE status <> ''deleted'' ' +
        'GROUP BY project_id, doc_type');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          Pid := Qry.FieldByName('project_id').AsInteger;
          if TypesByProj.TryGetValue(Pid, TypesObj) then
            TypesObj.AddPair(Qry.FieldByName('doc_type').AsString,
              TJSONNumber.Create(Qry.FieldByName('c').AsInteger));
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      // 3) Links = project_relations where BOTH ends are active projects.
      Links := TJSONArray.Create;
      Json.AddPair('links', Links);
      Qry := Ctx.CreateQuery(
        'SELECT pr.source_project_id AS s, pr.target_project_id AS t, ' +
        '       pr.relation_type AS rel ' +
        'FROM project_relations pr ' +
        'JOIN projects sp ON pr.source_project_id = sp.id ' +
        '  AND sp.is_active = 1 AND sp.deleted_at IS NULL ' +
        'JOIN projects tp ON pr.target_project_id = tp.id ' +
        '  AND tp.is_active = 1 AND tp.deleted_at IS NULL');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          var L := TJSONObject.Create;
          L.AddPair('s', TJSONNumber.Create(Qry.FieldByName('s').AsInteger));
          L.AddPair('t', TJSONNumber.Create(Qry.FieldByName('t').AsInteger));
          L.AddPair('rel', Qry.FieldByName('rel').AsString);
          Links.Add(L);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;

      MxSendJson(C, 200, Json);
      Json.Free;
    except
      on E: Exception do
      begin
        Json.Free;
        ALogger.Log(mlError, '[GetUniverse] ' + E.Message);
        MxSendError(C, 500, 'internal_error');
      end;
    end;
  finally
    TypesByProj.Free;
  end;
end;

end.
