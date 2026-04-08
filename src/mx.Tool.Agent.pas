unit mx.Tool.Agent;

interface

uses
  System.SysUtils, System.StrUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.SyncObjs, Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function HandleAgentSend(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleAgentInbox(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleAgentAck(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleAgentPeers(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// Rate-limit tracking (in-memory, per session, thread-safe)
var
  GRateLimits: TDictionary<Integer, TPair<TDateTime, Integer>>;
  GRateLock: TCriticalSection;

function CheckRateLimit(ASessionId: Integer): Boolean;
var
  Entry: TPair<TDateTime, Integer>;
begin
  GRateLock.Enter;
  try
    if GRateLimits.TryGetValue(ASessionId, Entry) then
    begin
      if MinutesBetween(Now, Entry.Key) >= 1 then
      begin
        GRateLimits.AddOrSetValue(ASessionId, TPair<TDateTime, Integer>.Create(Now, 1));
        Result := True;
      end
      else if Entry.Value >= 10 then
        Result := False
      else
      begin
        GRateLimits.AddOrSetValue(ASessionId,
          TPair<TDateTime, Integer>.Create(Entry.Key, Entry.Value + 1));
        Result := True;
      end;
    end
    else
    begin
      GRateLimits.AddOrSetValue(ASessionId, TPair<TDateTime, Integer>.Create(Now, 1));
      Result := True;
    end;
  finally
    GRateLock.Leave;
  end;
end;

// Helper: Resolve project slug to ID with ACL check
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
  finally
    Qry.Free;
  end;
  if not AContext.AccessControl.CheckProject(Result, ALevel) then
    raise EMxAccessDenied.Create(ASlug, ALevel);
end;

// Helper: Check project_relation exists between two projects
function HasProjectRelation(AContext: IMxDbContext; AProjA, AProjB: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'SELECT 1 FROM project_relations ' +
    'WHERE (source_project_id = :a AND target_project_id = :b) ' +
    'OR (source_project_id = :b2 AND target_project_id = :a2) LIMIT 1');
  try
    Qry.ParamByName('a').AsInteger := AProjA;
    Qry.ParamByName('b').AsInteger := AProjB;
    Qry.ParamByName('a2').AsInteger := AProjA;
    Qry.ParamByName('b2').AsInteger := AProjB;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

// Helper: Get current session ID for this project
function GetActiveSessionId(AContext: IMxDbContext; AProjectId: Integer): Integer;
var
  Qry: TFDQuery;
begin
  Result := 0;
  Qry := AContext.CreateQuery(
    'SELECT id FROM sessions WHERE project_id = :pid AND ended_at IS NULL ' +
    'ORDER BY started_at DESC LIMIT 1');
  try
    Qry.ParamByName('pid').AsInteger := AProjectId;
    Qry.Open;
    if not Qry.IsEmpty then
      Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_agent_send — Send message to a related project
// ---------------------------------------------------------------------------
function HandleAgentSend(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  TargetSlug, MsgType, Payload: string;
  TargetProjectId, SenderProjectId, SenderSessionId, RefDocId, MsgId: Integer;
  Data: TJSONObject;
begin
  Auth := MxGetThreadAuth;

  TargetSlug := AParams.GetValue<string>('target_project', '');
  MsgType := AParams.GetValue<string>('message_type', '');
  Payload := AParams.GetValue<string>('payload', '');
  RefDocId := AParams.GetValue<Integer>('ref_doc_id', 0);

  if TargetSlug = '' then
    raise EMxValidation.Create('Parameter "target_project" is required');
  if MsgType = '' then
    raise EMxValidation.Create('Parameter "message_type" is required');
  // Validate message_type (join/leave reserved for internal use)
  if not MatchStr(MsgType, ['task', 'info', 'question', 'response', 'status', 'setup_report']) then
    raise EMxValidation.Create('Invalid message_type "' + MsgType +
      '". Allowed: task, info, question, response, status, setup_report');
  if Payload = '' then
    raise EMxValidation.Create('Parameter "payload" is required');
  if TargetSlug = '_global' then
    raise EMxValidation.Create('Cannot send messages to _global project');

  // Payload size limit
  if Length(Payload) > 16384 then
    raise EMxValidation.Create('Payload too large (max 16KB)');

  // Resolve sender project from session context
  SenderProjectId := AParams.GetValue<Integer>('_sender_project_id', 0);
  if SenderProjectId = 0 then
  begin
    // Try to get from current active session via project param
    var SenderSlug := AParams.GetValue<string>('project', '');
    if SenderSlug = '' then
      raise EMxValidation.Create('Parameter "project" (sender) is required');
    SenderProjectId := ResolveProject(AContext, SenderSlug, alWrite);
  end;

  // Resolve target project (need Read access)
  TargetProjectId := ResolveProject(AContext, TargetSlug, alRead);

  // Must have project_relation (setup_report exempt — allows error reporting without relation)
  if (MsgType <> 'setup_report') and
     not HasProjectRelation(AContext, SenderProjectId, TargetProjectId) then
    raise EMxError.Create('NO_RELATION',
      'No project_relation between sender and target project');

  // Get sender session
  SenderSessionId := GetActiveSessionId(AContext, SenderProjectId);

  // Rate limit
  if (SenderSessionId > 0) and not CheckRateLimit(SenderSessionId) then
    raise EMxError.Create('RATE_LIMITED',
      'Max 10 messages per minute per session');

  // Insert message
  Qry := AContext.CreateQuery(
    'INSERT INTO agent_messages ' +
    '(sender_session_id, sender_project_id, sender_developer_id, ' +
    ' target_project_id, message_type, payload, ref_doc_id, ' +
    ' priority, expires_at) ' +
    'VALUES (:sid, :spid, :did, :tpid, :mtype, :payload, :rdid, ' +
    ' :prio, DATE_ADD(NOW(), INTERVAL :ttl DAY))');
  try
    Qry.ParamByName('sid').AsInteger := SenderSessionId;
    Qry.ParamByName('spid').AsInteger := SenderProjectId;
    Qry.ParamByName('did').AsInteger := Auth.DeveloperId;
    Qry.ParamByName('tpid').AsInteger := TargetProjectId;
    Qry.ParamByName('mtype').AsString := MsgType;
    Qry.ParamByName('payload').AsString := Payload;
    Qry.ParamByName('rdid').DataType := ftInteger;
    if RefDocId > 0 then
      Qry.ParamByName('rdid').AsInteger := RefDocId
    else
      Qry.ParamByName('rdid').Clear;
    var Prio := AParams.GetValue<string>('priority', 'normal');
    if (Prio <> 'normal') and (Prio <> 'urgent') then
      Prio := 'normal';
    Qry.ParamByName('prio').AsString := Prio;
    var TtlDays := AParams.GetValue<Integer>('ttl_days', 1);
    if TtlDays < 1 then TtlDays := 1;
    if TtlDays > 30 then TtlDays := 30;
    Qry.ParamByName('ttl').AsInteger := TtlDays;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  // Get inserted ID
  Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS msg_id');
  try
    Qry.Open;
    MsgId := Qry.FieldByName('msg_id').AsInteger;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('message_id', TJSONNumber.Create(MsgId));
    Data.AddPair('target_project', TargetSlug);
    Data.AddPair('message_type', MsgType);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_agent_inbox — Get pending messages for a project
// ---------------------------------------------------------------------------
function HandleAgentInbox(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug: string;
  ProjectId, Limit: Integer;
  Data: TJSONObject;
  Messages: TJSONArray;
  Row: TJSONObject;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  Limit := AParams.GetValue<Integer>('limit', 20);
  if Limit < 1 then Limit := 1;
  if Limit > 50 then Limit := 50;

  ProjectId := ResolveProject(AContext, ProjectSlug, alRead);

  // Archive expired messages first
  Qry := AContext.CreateQuery(
    'UPDATE agent_messages SET status = ''archived'' ' +
    'WHERE target_project_id = :pid AND status = ''pending'' ' +
    'AND expires_at IS NOT NULL AND expires_at < NOW()');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  // Fetch pending messages
  Qry := AContext.CreateQuery(
    'SELECT am.id, am.message_type, am.payload, am.ref_doc_id, ' +
    '  am.ref_message_id, am.priority, am.created_at, ' +
    '  p.slug AS sender_project, d.name AS sender_name ' +
    'FROM agent_messages am ' +
    'JOIN projects p ON am.sender_project_id = p.id ' +
    'JOIN developers d ON am.sender_developer_id = d.id ' +
    'WHERE am.target_project_id = :pid AND am.status = ''pending'' ' +
    'ORDER BY am.created_at ASC LIMIT :lim');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.ParamByName('lim').AsInteger := Limit;
    Qry.Open;

    Messages := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Row.AddPair('message_type', Qry.FieldByName('message_type').AsString);
      Row.AddPair('payload', Qry.FieldByName('payload').AsString);
      if not Qry.FieldByName('ref_doc_id').IsNull then
        Row.AddPair('ref_doc_id',
          TJSONNumber.Create(Qry.FieldByName('ref_doc_id').AsInteger));
      if not Qry.FieldByName('ref_message_id').IsNull then
        Row.AddPair('ref_message_id',
          TJSONNumber.Create(Qry.FieldByName('ref_message_id').AsInteger));
      Row.AddPair('priority', Qry.FieldByName('priority').AsString);
      Row.AddPair('sender_project', Qry.FieldByName('sender_project').AsString);
      Row.AddPair('sender_name', Qry.FieldByName('sender_name').AsString);
      Row.AddPair('created_at', Qry.FieldByName('created_at').AsString);
      Messages.Add(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('count', TJSONNumber.Create(Messages.Count));
    Data.AddPair('messages', Messages);
    Result := MxSuccessResponse(Data);
  except
    Messages.Free;
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_agent_ack — Acknowledge messages (mark as read/archived)
// ---------------------------------------------------------------------------
function HandleAgentAck(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  MsgIds: TJSONArray;
  ProjectSlug, NewStatus, IdList: string;
  ProjectId, I, Affected: Integer;
  Data: TJSONObject;
begin
  MsgIds := AParams.GetValue<TJSONArray>('message_ids', nil);
  if (MsgIds = nil) or (MsgIds.Count = 0) then
    raise EMxValidation.Create('Parameter "message_ids" is required (array of integers)');
  if MsgIds.Count > 50 then
    raise EMxValidation.Create('Maximum 50 message_ids per ack call');

  // Ownership: only ack messages for own project
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  ProjectId := ResolveProject(AContext, ProjectSlug, alRead);

  NewStatus := AParams.GetValue<string>('new_status', 'read');
  if (NewStatus <> 'read') and (NewStatus <> 'archived') then
    raise EMxValidation.Create('new_status must be "read" or "archived"');

  // Build ID list (safe: only integers)
  IdList := '';
  for I := 0 to MsgIds.Count - 1 do
  begin
    if IdList <> '' then IdList := IdList + ',';
    IdList := IdList + IntToStr(MsgIds.Items[I].GetValue<Integer>);
  end;

  // Only ack messages targeted at caller's project
  if NewStatus = 'read' then
    Qry := AContext.CreateQuery(
      'UPDATE agent_messages SET status = ''read'', read_at = NOW() ' +
      'WHERE id IN (' + IdList + ') AND target_project_id = :pid AND status = ''pending''')
  else
    Qry := AContext.CreateQuery(
      'UPDATE agent_messages SET status = ''archived'' ' +
      'WHERE id IN (' + IdList + ') AND target_project_id = :pid');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.ExecSQL;
    Affected := Qry.RowsAffected;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('acknowledged', TJSONNumber.Create(Affected));
    Data.AddPair('new_status', NewStatus);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_agent_peers — Active sessions on related projects
// ---------------------------------------------------------------------------
function HandleAgentPeers(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug: string;
  ProjectId: Integer;
  Data: TJSONObject;
  Peers: TJSONArray;
  Row: TJSONObject;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  ProjectId := ResolveProject(AContext, ProjectSlug, alRead);

  // Find active sessions on related projects (with heartbeat filter)
  // Feature#614 Phase 2: include files_touched for conflict detection
  Qry := AContext.CreateQuery(
    'SELECT DISTINCT p.slug AS project_slug, p.name AS project_name, ' +
    '  s.id AS session_id, s.started_at, s.last_heartbeat, ' +
    '  pr.relation_type, s.files_touched ' +
    'FROM sessions s ' +
    'JOIN projects p ON s.project_id = p.id ' +
    'JOIN project_relations pr ON ' +
    '  (pr.source_project_id = :pid AND pr.target_project_id = s.project_id) ' +
    '  OR (pr.target_project_id = :pid2 AND pr.source_project_id = s.project_id) ' +
    'WHERE s.ended_at IS NULL ' +
    '  AND (s.last_heartbeat IS NULL OR s.last_heartbeat > DATE_SUB(NOW(), INTERVAL 5 MINUTE)) ' +
    '  AND s.project_id != :pid3 ' +
    'ORDER BY s.started_at DESC');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.ParamByName('pid2').AsInteger := ProjectId;
    Qry.ParamByName('pid3').AsInteger := ProjectId;
    Qry.Open;

    Peers := TJSONArray.Create;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('project', Qry.FieldByName('project_slug').AsString);
      Row.AddPair('project_name', Qry.FieldByName('project_name').AsString);
      Row.AddPair('session_id',
        TJSONNumber.Create(Qry.FieldByName('session_id').AsInteger));
      Row.AddPair('started_at', Qry.FieldByName('started_at').AsString);
      Row.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
      // Feature#614: files_touched for conflict detection
      if not Qry.FieldByName('files_touched').IsNull then
        Row.AddPair('files_touched', Qry.FieldByName('files_touched').AsString);
      Peers.Add(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  // Feature#614: Detect file overlaps with own session
  var OwnFiles: string := '';
  var SessionId := AParams.GetValue<Integer>('session_id', 0);
  if SessionId > 0 then
  begin
    try
      Qry := AContext.CreateQuery(
        'SELECT files_touched FROM sessions WHERE id = :sid');
      try
        Qry.ParamByName('sid').AsInteger := SessionId;
        Qry.Open;
        if not Qry.IsEmpty and not Qry.FieldByName('files_touched').IsNull then
          OwnFiles := Qry.FieldByName('files_touched').AsString;
      finally
        Qry.Free;
      end;
    except
      // Non-critical
    end;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('peer_count', TJSONNumber.Create(Peers.Count));
    Data.AddPair('peers', Peers);
    if OwnFiles <> '' then
      Data.AddPair('own_files_touched', OwnFiles);
    Result := MxSuccessResponse(Data);
  except
    Peers.Free;
    Data.Free;
    raise;
  end;
end;

initialization
  GRateLimits := TDictionary<Integer, TPair<TDateTime, Integer>>.Create;
  GRateLock := TCriticalSection.Create;

finalization
  GRateLock.Free;
  GRateLimits.Free;

end.
