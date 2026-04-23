unit mx.Logic.AgentMessaging;

// FR#3836 — Logic-layer extraction of agent-messaging read-path
// (HandleAgentInbox/HandleAgentInboxGet) + ack-path (HandleAgentAck/
// HandleAgentAckGet) per CC2040 Data->Logic->Tools split. Handlers in
// mx.Tool.Agent + mx.MCP.Server delegate to this unit so defensive guards
// (Bug#3295 nil-Ctx, ownership-transfer) + correctness invariants apply
// uniformly across REST and MCP-tool transports.
//
// CC2050 review (2026-04-23): return records not JSON — transport-format in
// Logic is the 2026 trap that gets re-extracted in 2030 once a second shell
// (SSE, WebSocket-push, richer admin-UI) lands. Each shell picks fields it
// wants from the record rows.
//
// Invariants enforced here (not in shells):
//  - Archive-expired UPDATE runs first on every fetch (was MCP-tool-only,
//    CC2050 flagged as live correctness bug — REST pollers got stale rows).
//  - Query builder preserves `:my_did2`/`:my_pid2` duplicate param-binding
//    (FireDAC macro-expands `:foo` once; rename would break self-echo guard).
//  - Authentication identity (MyDeveloperId) passed explicitly — Logic never
//    reaches for thread-locals (testability + cross-request leakage hygiene).
//  - IMxDbContext passed as parameter per call; never cached (per-request
//    FireDAC connection returns to pool at request end).

interface

uses
  System.SysUtils,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors;

type
  TAgentInboxOptions = record
    ProjectId: Integer;            // target project (mandatory, > 0)
    MyDeveloperId: Integer;        // caller's developer id; 0 = no dev identity
    LimitCount: Integer;           // 1-50, caller enforces bounds
    FilterTargetDeveloper: Boolean;// true => (target_developer_id IS NULL OR = MyDeveloperId)
    FilterSelfEcho: Boolean;       // true => NOT (sender_did = MyDeveloperId AND sender_pid = ProjectId)
  end;

  TAgentInboxRow = record
    Id: Integer;
    MessageType: string;
    Payload: string;
    Priority: string;
    SenderProject: string;
    CreatedAt: string;              // DB string, shells format as needed
    RefDocId: Integer;
    HasRefDocId: Boolean;
    RefMessageId: Integer;
    HasRefMessageId: Boolean;
    SenderName: string;
    HasSenderName: Boolean;         // false only for malformed DB state
    TargetDeveloperId: Integer;
    HasTargetDeveloperId: Boolean;
    TargetDeveloperName: string;
    HasTargetDeveloperName: Boolean;
  end;

  TAgentAckOptions = record
    EnforceOwnership: Boolean;// true => add AND target_project_id = ProjectId
                              // to the UPDATE; false => touch any matching id.
                              // REST path (proxy polls its own project) sets
                              // false; MCP-tool path sets true.
    ProjectId: Integer;       // Only meaningful when EnforceOwnership=true.
    NewStatus: string;        // 'read' or 'archived'
  end;

/// Archive messages past their expires_at so proxy pollers and MCP-tool callers
/// get a consistent view. Runs unconditionally before FetchAgentInbox; exposed
/// separately for test seams + potential future maintenance jobs.
procedure ArchiveExpiredMessages(AContext: IMxDbContext; AProjectId: Integer);

/// Read pending inbox messages for a project, honoring target-developer and
/// self-echo filters per options. Archive-expired runs first (invariant, CC2050).
function FetchAgentInbox(AContext: IMxDbContext;
  const AOpts: TAgentInboxOptions): TArray<TAgentInboxRow>;

/// Mark messages as read or archived. Returns rows affected. When
/// AOpts.EnforceOwnership is true, only rows with matching target_project_id
/// are touched (MCP-tool path); when false, any matching id is touched
/// (REST path — proxy polls its own project without per-call ownership check).
function AckAgentMessages(AContext: IMxDbContext; const AIds: array of Integer;
  const AOpts: TAgentAckOptions): Integer;

implementation

procedure ArchiveExpiredMessages(AContext: IMxDbContext; AProjectId: Integer);
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'UPDATE agent_messages SET status = ''archived'' ' +
    'WHERE target_project_id = :pid AND status = ''pending'' ' +
    'AND expires_at IS NOT NULL AND expires_at < NOW()');
  try
    Qry.ParamByName('pid').AsInteger := AProjectId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

function BuildInboxSql(const AOpts: TAgentInboxOptions): string;
begin
  // Superset query: shells pick the fields they render. Extra JOINs are cheap
  // under LIMIT 20/50 rows.
  Result :=
    'SELECT am.id, am.message_type, am.payload, am.ref_doc_id, ' +
    '  am.ref_message_id, am.priority, am.created_at, ' +
    '  am.target_developer_id, td.name AS target_developer_name, ' +
    '  p.slug AS sender_project, d.name AS sender_name ' +
    'FROM agent_messages am ' +
    'JOIN projects p ON am.sender_project_id = p.id ' +
    'JOIN developers d ON am.sender_developer_id = d.id ' +
    'LEFT JOIN developers td ON am.target_developer_id = td.id ' +
    'WHERE am.target_project_id = :pid AND am.status = ''pending''';

  if AOpts.FilterTargetDeveloper then
    Result := Result +
      '  AND (am.target_developer_id IS NULL OR am.target_developer_id = :my_did)';

  // Self-echo guard: PROJECT-SCOPED — suppress only true intra-project
  // self-talk (same dev AND same project). Cross-project same-dev traffic
  // (e.g. mx-erp <-> mx-erp-docs under one key) must flow through. The
  // duplicate `:my_did2`/`:my_pid2` names are DELIBERATE — FireDAC macro-
  // expands `:foo` once per statement; renaming them breaks the guard.
  if AOpts.FilterSelfEcho then
    Result := Result +
      '  AND NOT (am.sender_developer_id = :my_did2 ' +
      '           AND am.sender_project_id = :my_pid2)';

  Result := Result + ' ORDER BY am.created_at ASC LIMIT :lim';
end;

function FetchAgentInbox(AContext: IMxDbContext;
  const AOpts: TAgentInboxOptions): TArray<TAgentInboxRow>;
var
  Qry: TFDQuery;
  Rows: TArray<TAgentInboxRow>;
  Row: TAgentInboxRow;
  Count: Integer;
begin
  // Invariant (CC2050): archive-expired runs before every fetch so REST proxy
  // pollers and MCP-tool callers see the same pending set.
  ArchiveExpiredMessages(AContext, AOpts.ProjectId);

  Qry := AContext.CreateQuery(BuildInboxSql(AOpts));
  try
    Qry.ParamByName('pid').AsInteger := AOpts.ProjectId;
    if AOpts.FilterTargetDeveloper then
      Qry.ParamByName('my_did').AsInteger := AOpts.MyDeveloperId;
    if AOpts.FilterSelfEcho then
    begin
      Qry.ParamByName('my_did2').AsInteger := AOpts.MyDeveloperId;
      Qry.ParamByName('my_pid2').AsInteger := AOpts.ProjectId;
    end;
    Qry.ParamByName('lim').AsInteger := AOpts.LimitCount;
    Qry.Open;

    // Record array built INSIDE the Qry try/finally per CC2050 risk #2 —
    // cursor rows must not escape the Qry.Free scope even in exception paths.
    SetLength(Rows, Qry.RecordCount);
    Count := 0;
    while not Qry.Eof do
    begin
      Row := Default(TAgentInboxRow);
      Row.Id           := Qry.FieldByName('id').AsInteger;
      Row.MessageType  := Qry.FieldByName('message_type').AsString;
      Row.Payload      := Qry.FieldByName('payload').AsString;
      Row.Priority     := Qry.FieldByName('priority').AsString;
      Row.SenderProject := Qry.FieldByName('sender_project').AsString;
      Row.CreatedAt    := Qry.FieldByName('created_at').AsString;

      Row.HasRefDocId := not Qry.FieldByName('ref_doc_id').IsNull;
      if Row.HasRefDocId then
        Row.RefDocId := Qry.FieldByName('ref_doc_id').AsInteger;

      Row.HasRefMessageId := not Qry.FieldByName('ref_message_id').IsNull;
      if Row.HasRefMessageId then
        Row.RefMessageId := Qry.FieldByName('ref_message_id').AsInteger;

      Row.HasSenderName := not Qry.FieldByName('sender_name').IsNull;
      if Row.HasSenderName then
        Row.SenderName := Qry.FieldByName('sender_name').AsString;

      Row.HasTargetDeveloperId := not Qry.FieldByName('target_developer_id').IsNull;
      if Row.HasTargetDeveloperId then
        Row.TargetDeveloperId := Qry.FieldByName('target_developer_id').AsInteger;

      Row.HasTargetDeveloperName := not Qry.FieldByName('target_developer_name').IsNull;
      if Row.HasTargetDeveloperName then
        Row.TargetDeveloperName := Qry.FieldByName('target_developer_name').AsString;

      Rows[Count] := Row;
      Inc(Count);
      Qry.Next;
    end;
    SetLength(Rows, Count);
    Result := Rows;
  finally
    Qry.Free;
  end;
end;

function BuildAckIdList(const AIds: array of Integer): string;
var
  I: Integer;
begin
  // Caller already validated that entries are positive integers; we format
  // them verbatim into an IN-clause. Never interpolate caller strings here.
  Result := '';
  for I := Low(AIds) to High(AIds) do
  begin
    if AIds[I] <= 0 then Continue;
    if Result <> '' then Result := Result + ',';
    Result := Result + IntToStr(AIds[I]);
  end;
end;

function AckAgentMessages(AContext: IMxDbContext; const AIds: array of Integer;
  const AOpts: TAgentAckOptions): Integer;
var
  Qry: TFDQuery;
  IdList, Sql: string;
begin
  IdList := BuildAckIdList(AIds);
  if IdList = '' then
    Exit(0);

  if AOpts.NewStatus = 'read' then
    Sql := 'UPDATE agent_messages SET status = ''read'', read_at = NOW() ' +
           'WHERE id IN (' + IdList + ') AND status = ''pending'''
  else if AOpts.NewStatus = 'archived' then
    Sql := 'UPDATE agent_messages SET status = ''archived'' ' +
           'WHERE id IN (' + IdList + ')'
  else
    raise EMxValidation.CreateFmt(
      'AckAgentMessages: invalid NewStatus "%s" (want "read" or "archived")',
      [AOpts.NewStatus]);

  if AOpts.EnforceOwnership then
    Sql := Sql + ' AND target_project_id = :pid';

  Qry := AContext.CreateQuery(Sql);
  try
    if AOpts.EnforceOwnership then
      Qry.ParamByName('pid').AsInteger := AOpts.ProjectId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

end.
