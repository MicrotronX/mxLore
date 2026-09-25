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

// Cross-project flow view (FR#16946 / Spec#16961): project -> project edges
// aggregated from four sources, bucketed per month for the time-lapse.
//   GET /api/graph/flow[?from=YYYY-MM&to=YYYY-MM&types=doc,msg,kn,man]
//   -> { projects:[{id,slug,name,docs,group}],
//        links:[{s,t,type,n,last,months:{"YYYY-MM":n}}], null_count }
//   doc = doc_relations across projects, msg = agent_messages sender->target,
//   kn  = access_log reader project -> doc home project, man = project_relations.
//   Self-loops, inactive/deleted projects and deleted docs are excluded.
procedure HandleGetGraphFlow(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);

// Drilldown for one directed edge: newest 50 underlying rows.
//   GET /api/graph/flow/detail?s={project_id}&t={project_id}&type={doc|msg|kn|man}
//   -> { s, t, type, items:[{...row fields...}] }
procedure HandleGetGraphFlowDetail(const C: THttpServerContext;
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

// ---------------------------------------------------------------------------
// Flow view (FR#16946)
// ---------------------------------------------------------------------------

const
  FLOW_TYPES: array[0..3] of string = ('doc', 'msg', 'kn', 'man');

  // Each branch yields (s, t, typ, ts). Only constant SQL is concatenated;
  // all user input goes through :df/:dt (dates) or integer params.
  FLOW_SQL_DOC =
    'SELECT sd.project_id AS s, td.project_id AS t, ''doc'' AS typ, r.created_at AS ts ' +
    'FROM doc_relations r ' +
    'JOIN documents sd ON sd.id = r.source_doc_id ' +
    'JOIN documents td ON td.id = r.target_doc_id ' +
    'WHERE sd.project_id <> td.project_id ' +
    '  AND sd.status <> ''deleted'' AND td.status <> ''deleted'' ' +
    '  AND r.created_at >= :df AND r.created_at < :dt';
  FLOW_SQL_MSG =
    'SELECT m.sender_project_id AS s, m.target_project_id AS t, ''msg'' AS typ, m.created_at AS ts ' +
    'FROM agent_messages m ' +
    'WHERE m.sender_project_id IS NOT NULL AND m.target_project_id IS NOT NULL ' +
    '  AND m.sender_project_id <> m.target_project_id ' +
    '  AND m.created_at >= :df AND m.created_at < :dt';
  // access_log.project_id is the doc's HOME project (mx.Tool.Read logs the
  // looked-up doc's project), so the reader comes from the session. Rows
  // without a session cannot be attributed and are counted separately.
  FLOW_SQL_KN =
    'SELECT se.project_id AS s, d.project_id AS t, ''kn'' AS typ, a.created_at AS ts ' +
    'FROM access_log a ' +
    'JOIN documents d ON d.id = a.doc_id ' +
    'JOIN sessions se ON se.id = a.session_id ' +
    'WHERE se.project_id <> d.project_id ' +
    '  AND d.status <> ''deleted'' ' +
    '  AND a.created_at >= :df AND a.created_at < :dt';
  // project_relations.created_at is a nullable TIMESTAMP (doc_relations uses
  // DATETIME); both are read in the DB session zone, NULL maps to 2000-01.
  FLOW_SQL_MAN =
    'SELECT pr.source_project_id AS s, pr.target_project_id AS t, ''man'' AS typ, ' +
    '       COALESCE(pr.created_at, ''2000-01-01'') AS ts ' +
    'FROM project_relations pr ' +
    'WHERE pr.source_project_id <> pr.target_project_id ' +
    '  AND COALESCE(pr.created_at, ''2000-01-01'') >= :df ' +
    '  AND COALESCE(pr.created_at, ''2000-01-01'') < :dt';

function FlowParseYm(const S: string; out AYear, AMonth: Integer): Boolean;
begin
  Result := (Length(S) = 7) and (S[5] = '-') and
    TryStrToInt(Copy(S, 1, 4), AYear) and TryStrToInt(Copy(S, 6, 2), AMonth) and
    (AYear >= 2000) and (AYear <= 2999) and (AMonth >= 1) and (AMonth <= 12);
end;

function FlowIsType(const S: string): Boolean;
var
  T: string;
begin
  for T in FLOW_TYPES do
    if S = T then Exit(True);
  Result := False;
end;

// Reads from/to into a half-open [ADateFrom, ADateTo) range. Missing params
// mean unbounded. Returns False (and sends 400) on malformed input.
function FlowReadRange(const C: THttpServerContext;
  out ADateFrom, ADateTo: TDateTime): Boolean;
var
  S: string;
  Y, M: Integer;
begin
  Result := False;
  ADateFrom := EncodeDate(1970, 1, 1);
  ADateTo := EncodeDate(3000, 1, 1);
  S := Trim(GraphQGet(C.Request.Uri.Query, 'from'));
  if S <> '' then
  begin
    if not FlowParseYm(S, Y, M) then
    begin
      MxSendError(C, 400, 'invalid_from');
      Exit;
    end;
    ADateFrom := EncodeDate(Y, M, 1);
  end;
  S := Trim(GraphQGet(C.Request.Uri.Query, 'to'));
  if S <> '' then
  begin
    if not FlowParseYm(S, Y, M) then
    begin
      MxSendError(C, 400, 'invalid_to');
      Exit;
    end;
    ADateTo := IncMonth(EncodeDate(Y, M, 1), 1);
  end;
  if ADateTo <= ADateFrom then
  begin
    MxSendError(C, 400, 'invalid_range');
    Exit;
  end;
  Result := True;
end;

// Groups for the ring/column layout without a schema field: slugs starting
// with '_' are shared knowledge, the rest are connected components over
// project_relations (named after their largest project), singletons 'Sonstige'.
procedure FlowAssignGroups(const Ctx: IMxDbContext; AProjects: TJSONArray);
var
  Parent: TDictionary<Integer, Integer>;
  Best: TDictionary<Integer, TJSONObject>;
  Size: TDictionary<Integer, Integer>;
  Qry: TFDQuery;
  I, Pid, Root, Docs, Cnt: Integer;
  P, Cur: TJSONObject;

  function Find(X: Integer): Integer;
  begin
    Result := X;
    while Parent[Result] <> Result do
      Result := Parent[Result];
    // path compression
    while Parent[X] <> Result do
    begin
      var Nx := Parent[X];
      Parent[X] := Result;
      X := Nx;
    end;
  end;

begin
  Parent := TDictionary<Integer, Integer>.Create;
  Best := TDictionary<Integer, TJSONObject>.Create;
  Size := TDictionary<Integer, Integer>.Create;
  try
    for I := 0 to AProjects.Count - 1 do
    begin
      Pid := (AProjects.Items[I] as TJSONObject).GetValue<Integer>('id');
      Parent.AddOrSetValue(Pid, Pid);
    end;

    Qry := Ctx.CreateQuery(
      'SELECT source_project_id AS s, target_project_id AS t FROM project_relations');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var S := Qry.FieldByName('s').AsInteger;
        var T := Qry.FieldByName('t').AsInteger;
        if Parent.ContainsKey(S) and Parent.ContainsKey(T) then
        begin
          var Rs := Find(S);
          var Rt := Find(T);
          if Rs <> Rt then Parent[Rs] := Rt;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // Component size + largest member (knowledge projects stay out of clusters).
    for I := 0 to AProjects.Count - 1 do
    begin
      P := AProjects.Items[I] as TJSONObject;
      if P.GetValue<string>('slug').StartsWith('_') then Continue;
      Root := Find(P.GetValue<Integer>('id'));
      if Size.TryGetValue(Root, Cnt) then
        Size[Root] := Cnt + 1
      else
        Size.Add(Root, 1);
      Docs := P.GetValue<Integer>('docs');
      if (not Best.TryGetValue(Root, Cur)) or (Docs > Cur.GetValue<Integer>('docs')) then
        Best.AddOrSetValue(Root, P);
    end;

    for I := 0 to AProjects.Count - 1 do
    begin
      P := AProjects.Items[I] as TJSONObject;
      if P.GetValue<string>('slug').StartsWith('_') then
        P.AddPair('group', 'Wissen')
      else
      begin
        Root := Find(P.GetValue<Integer>('id'));
        if Size.TryGetValue(Root, Cnt) and (Cnt >= 2) then
          P.AddPair('group', Best[Root].GetValue<string>('slug'))
        else
          P.AddPair('group', 'Sonstige');
      end;
    end;
  finally
    Size.Free;
    Best.Free;
    Parent.Free;
  end;
end;

type
  TFlowAcc = class
    Link: TJSONObject;   // owned by the links array
    Months: TJSONObject; // owned by Link
    N: Integer;
    Last: TDateTime;
  end;

procedure HandleGetGraphFlow(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Projects, Links: TJSONArray;
  Accs: TObjectDictionary<string, TFlowAcc>;
  Acc: TFlowAcc;
  DateFrom, DateTo: TDateTime;
  TypesParam, Sql, Key, Typ, Seen: string;
  Wanted: TArray<string>;
  Branches: TArray<string>;
  UseKn: Boolean;
  NullCount: Integer;
begin
  if not FlowReadRange(C, DateFrom, DateTo) then Exit;

  TypesParam := Trim(GraphQGet(C.Request.Uri.Query, 'types'));
  if TypesParam = '' then
    Wanted := ['doc', 'msg', 'kn', 'man']
  else
    Wanted := TypesParam.Split([',']);
  Branches := [];
  Seen := '';
  UseKn := False;
  for Typ in Wanted do
  begin
    Key := Trim(Typ);
    if not FlowIsType(Key) then
    begin
      MxSendError(C, 400, 'invalid_types');
      Exit;
    end;
    // duplicates (types=doc,doc) would double-count
    if Pos('|' + Key + '|', Seen) > 0 then Continue;
    Seen := Seen + '|' + Key + '|';
    if Key = 'doc' then Branches := Branches + [FLOW_SQL_DOC]
    else if Key = 'msg' then Branches := Branches + [FLOW_SQL_MSG]
    else if Key = 'kn' then begin Branches := Branches + [FLOW_SQL_KN]; UseKn := True; end
    else Branches := Branches + [FLOW_SQL_MAN];
  end;

  Json := TJSONObject.Create;
  Accs := TObjectDictionary<string, TFlowAcc>.Create([doOwnsValues]);
  try
    try
      Ctx := APool.AcquireContext;

      // 1) Projects (same activity filter as the universe view).
      Projects := TJSONArray.Create;
      Json.AddPair('projects', Projects);
      Qry := Ctx.CreateQuery(
        'SELECT p.id, p.slug, p.name, COUNT(d.id) AS docs ' +
        'FROM projects p ' +
        'LEFT JOIN documents d ON d.project_id = p.id AND d.status <> ''deleted'' ' +
        'WHERE p.is_active = 1 AND p.deleted_at IS NULL ' +
        'GROUP BY p.id, p.slug, p.name ' +
        'ORDER BY docs DESC');
      try
        Qry.Open;
        while not Qry.Eof do
        begin
          var P := TJSONObject.Create;
          P.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          P.AddPair('slug', Qry.FieldByName('slug').AsString);
          P.AddPair('name', Qry.FieldByName('name').AsString);
          P.AddPair('docs', TJSONNumber.Create(Qry.FieldByName('docs').AsInteger));
          Projects.Add(P);
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
      FlowAssignGroups(Ctx, Projects);

      // 2) Edges, one row per (s, t, type, month).
      Links := TJSONArray.Create;
      Json.AddPair('links', Links);
      Sql :=
        'SELECT x.s, x.t, x.typ, DATE_FORMAT(x.ts, ''%Y-%m'') AS ym, ' +
        '       COUNT(*) AS c, MAX(x.ts) AS last_ts ' +
        'FROM (' + string.Join(' UNION ALL ', Branches) + ') x ' +
        'JOIN projects sp ON sp.id = x.s AND sp.is_active = 1 AND sp.deleted_at IS NULL ' +
        'JOIN projects tp ON tp.id = x.t AND tp.is_active = 1 AND tp.deleted_at IS NULL ' +
        'GROUP BY x.s, x.t, x.typ, ym';
      Qry := Ctx.CreateQuery(Sql);
      try
        Qry.ParamByName('df').AsDateTime := DateFrom;
        Qry.ParamByName('dt').AsDateTime := DateTo;
        Qry.Open;
        while not Qry.Eof do
        begin
          Typ := Qry.FieldByName('typ').AsString;
          Key := Qry.FieldByName('s').AsString + '|' +
                 Qry.FieldByName('t').AsString + '|' + Typ;
          if not Accs.TryGetValue(Key, Acc) then
          begin
            Acc := TFlowAcc.Create;
            Accs.Add(Key, Acc);
            Acc.Link := TJSONObject.Create;
            Links.Add(Acc.Link);
            Acc.Link.AddPair('s', TJSONNumber.Create(Qry.FieldByName('s').AsInteger));
            Acc.Link.AddPair('t', TJSONNumber.Create(Qry.FieldByName('t').AsInteger));
            Acc.Link.AddPair('type', Typ);
            Acc.Months := TJSONObject.Create;
            Acc.Link.AddPair('months', Acc.Months);
            Acc.Last := 0;
          end;
          Acc.N := Acc.N + Qry.FieldByName('c').AsInteger;
          if Qry.FieldByName('last_ts').AsDateTime > Acc.Last then
            Acc.Last := Qry.FieldByName('last_ts').AsDateTime;
          Acc.Months.AddPair(Qry.FieldByName('ym').AsString,
            TJSONNumber.Create(Qry.FieldByName('c').AsInteger));
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
      for Acc in Accs.Values do
      begin
        Acc.Link.AddPair('n', TJSONNumber.Create(Acc.N));
        Acc.Link.AddPair('last', FormatDateTime('yyyy-mm-dd hh:nn:ss', Acc.Last));
      end;

      // 3) Reads without a reader project cannot be attributed to an edge.
      NullCount := 0;
      if UseKn then
      begin
        Qry := Ctx.CreateQuery(
          'SELECT COUNT(*) AS c FROM access_log a ' +
          'LEFT JOIN sessions se ON se.id = a.session_id ' +
          'WHERE a.doc_id > 0 AND se.id IS NULL ' +
          '  AND a.created_at >= :df AND a.created_at < :dt');
        try
          Qry.ParamByName('df').AsDateTime := DateFrom;
          Qry.ParamByName('dt').AsDateTime := DateTo;
          Qry.Open;
          if not Qry.Eof then
            NullCount := Qry.FieldByName('c').AsInteger;
        finally
          Qry.Free;
        end;
      end;
      Json.AddPair('null_count', TJSONNumber.Create(NullCount));

      MxSendJson(C, 200, Json);
      Json.Free;
    except
      on E: Exception do
      begin
        Json.Free;
        ALogger.Log(mlError, '[GetGraphFlow] ' + E.Message);
        MxSendError(C, 500, 'internal_error');
      end;
    end;
  finally
    Accs.Free;
  end;
end;

procedure HandleGetGraphFlowDetail(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  Items: TJSONArray;
  S, T, I: Integer;
  Typ, Sql: string;
  F: TField;
begin
  S := StrToIntDef(GraphQGet(C.Request.Uri.Query, 's'), 0);
  T := StrToIntDef(GraphQGet(C.Request.Uri.Query, 't'), 0);
  Typ := Trim(GraphQGet(C.Request.Uri.Query, 'type'));
  if (S <= 0) or (T <= 0) or (S = T) or not FlowIsType(Typ) then
  begin
    MxSendError(C, 400, 'invalid_params');
    Exit;
  end;

  if Typ = 'doc' then
    Sql :=
      'SELECT r.created_at AS ts, sd.id AS doc_id, sd.title AS title, ' +
      '       td.id AS target_doc_id, td.title AS target_title, r.relation_type AS info ' +
      'FROM doc_relations r ' +
      'JOIN documents sd ON sd.id = r.source_doc_id ' +
      'JOIN documents td ON td.id = r.target_doc_id ' +
      'WHERE sd.project_id = :s AND td.project_id = :t ' +
      '  AND sd.status <> ''deleted'' AND td.status <> ''deleted'' ' +
      'ORDER BY r.created_at DESC LIMIT 50'
  else if Typ = 'msg' then
    Sql :=
      'SELECT m.created_at AS ts, m.id AS message_id, m.message_type AS info, ' +
      '       m.ref_doc_id AS doc_id, LEFT(m.payload, 200) AS title ' +
      'FROM agent_messages m ' +
      'WHERE m.sender_project_id = :s AND m.target_project_id = :t ' +
      'ORDER BY m.created_at DESC LIMIT 50'
  else if Typ = 'kn' then
    Sql :=
      'SELECT MAX(a.created_at) AS ts, d.id AS doc_id, d.title AS title, ' +
      '       COUNT(*) AS read_count ' +
      'FROM access_log a ' +
      'JOIN documents d ON d.id = a.doc_id ' +
      'JOIN sessions se ON se.id = a.session_id ' +
      'WHERE se.project_id = :s AND d.project_id = :t AND d.status <> ''deleted'' ' +
      'GROUP BY d.id, d.title ORDER BY ts DESC LIMIT 50'
  else
    Sql :=
      'SELECT pr.created_at AS ts, pr.relation_type AS info ' +
      'FROM project_relations pr ' +
      'WHERE pr.source_project_id = :s AND pr.target_project_id = :t ' +
      'ORDER BY pr.created_at DESC LIMIT 50';

  Json := TJSONObject.Create;
  try
    Ctx := APool.AcquireContext;
    Items := TJSONArray.Create;
    Json.AddPair('s', TJSONNumber.Create(S));
    Json.AddPair('t', TJSONNumber.Create(T));
    Json.AddPair('type', Typ);
    Json.AddPair('items', Items);
    Qry := Ctx.CreateQuery(Sql);
    try
      Qry.ParamByName('s').AsInteger := S;
      Qry.ParamByName('t').AsInteger := T;
      Qry.Open;
      while not Qry.Eof do
      begin
        var Row := TJSONObject.Create;
        Items.Add(Row);
        for I := 0 to Qry.FieldCount - 1 do
        begin
          F := Qry.Fields[I];
          if F.IsNull then
            Row.AddPair(F.FieldName, TJSONNull.Create)
          else if F.DataType in [ftSmallint, ftInteger, ftWord, ftLargeint,
            ftAutoInc, ftLongWord, ftShortint, ftByte] then
            Row.AddPair(F.FieldName, TJSONNumber.Create(F.AsLargeInt))
          else if F.DataType in [ftDate, ftDateTime, ftTimeStamp] then
            Row.AddPair(F.FieldName, FormatDateTime('yyyy-mm-dd hh:nn:ss', F.AsDateTime))
          else
            Row.AddPair(F.FieldName, F.AsString);
        end;
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
      ALogger.Log(mlError, '[GetGraphFlowDetail] ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

end.
