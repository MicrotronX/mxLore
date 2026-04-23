unit mx.Tool.Agent;

interface

uses
  System.SysUtils, System.StrUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.SyncObjs, Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl,
  mx.Logic.AgentMessaging;

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
    Qry.ParamByName('slug').AsWideString :=ASlug;
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

// Helper: Get current session ID for a specific API key (Spec #1964).
// Unlike GetActiveSessionId (which picks newest across project), this is
// unique per client_key_id because only one active session exists per key
// at a time. Required for intra-project messaging where multiple sessions
// of the same developer must be distinguished by their API key.
function GetSessionIdByKey(AContext: IMxDbContext; AClientKeyId: Integer): Integer;
var
  Qry: TFDQuery;
begin
  Result := 0;
  if AClientKeyId <= 0 then Exit;
  Qry := AContext.CreateQuery(
    'SELECT id FROM sessions WHERE client_key_id = :ckid AND ended_at IS NULL ' +
    'ORDER BY started_at DESC LIMIT 1');
  try
    Qry.ParamByName('ckid').AsInteger := AClientKeyId;
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
const
  PAYLOAD_SOFT_LIMIT = 1000;
  PAYLOAD_HARD_LIMIT = 4000;
var
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  TargetSlug, MsgType, Payload: string;
  TargetProjectId, SenderProjectId, SenderSessionId, RefDocId, MsgId: Integer;
  TargetDeveloperId, PayloadLen: Integer;
  Data: TJSONObject;
  Warnings: TJSONArray;
  IsSelfTarget, IsAdmin, TargetIsAdmin, TargetHasReadWrite: Boolean;
  SenderHasReadWrite, SenderHasComment: Boolean;
  AcceptsMessages: Boolean;
begin
  Auth := MxGetThreadAuth;
  IsAdmin := AContext.AccessControl.IsAdmin;

  TargetSlug := AParams.GetValue<string>('target_project', '');
  MsgType := AParams.GetValue<string>('message_type', '');
  Payload := AParams.GetValue<string>('payload', '');
  RefDocId := AParams.GetValue<Integer>('ref_doc_id', 0);
  TargetDeveloperId := AParams.GetValue<Integer>('target_developer_id', 0);

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

  // M3.1 size limits: 1000 soft (warning) / 4000 hard (reject). Replaces the
  // earlier 16KB single cap per Plan#3266 (smaller messages encourage clear
  // prompts and protect inbox UX).
  PayloadLen := Length(Payload);
  if PayloadLen > PAYLOAD_HARD_LIMIT then
    raise EMxValidation.CreateFmt(
      'Payload too large (%d > %d chars hard limit). Split or summarise.',
      [PayloadLen, PAYLOAD_HARD_LIMIT]);

  // Resolve sender project from session context. M3.1: lower floor to alReadOnly
  // (everyone may attempt). Asymmetric send-rules below gate by effective level.
  SenderProjectId := AParams.GetValue<Integer>('_sender_project_id', 0);
  if SenderProjectId = 0 then
  begin
    var SenderSlug := AParams.GetValue<string>('project', '');
    if SenderSlug = '' then
      raise EMxValidation.Create('Parameter "project" (sender) is required');
    SenderProjectId := ResolveProject(AContext, SenderSlug, alReadOnly);
  end;

  // Resolve target project (need Read access)
  TargetProjectId := ResolveProject(AContext, TargetSlug, alReadOnly);

  // M3.1 asymmetric send-rules per sender effective level on sender project:
  //   admin            -> any project, any target
  //   alReadWrite      -> same-project only
  //   alComment        -> may send to admins OR alReadWrite-on-target_project
  //   alReadOnly       -> no send at all (pure-read)
  // Self-Messaging always allowed (caller may queue notes-to-self).
  IsSelfTarget := (TargetDeveloperId > 0) and (TargetDeveloperId = Auth.DeveloperId);
  if not IsAdmin then
  begin
    SenderHasReadWrite := AContext.AccessControl.CheckProject(SenderProjectId, alReadWrite);
    SenderHasComment   := AContext.AccessControl.CheckProject(SenderProjectId, alComment);

    if not IsSelfTarget then
    begin
      // pure-read sender -> no send
      if not SenderHasComment then
        raise EMxError.Create('SEND_DENIED',
          'Pure-read access cannot send agent messages. Need at least alComment.');

      // alReadWrite sender -> same-project only
      if SenderHasReadWrite and (SenderProjectId <> TargetProjectId) then
        raise EMxError.Create('SEND_DENIED',
          'alReadWrite senders may only message within their own project. Cross-project requires admin.');

      // alComment sender (not read-write, not admin) -> target must be admin
      // OR have alReadWrite on the target project. Cross-project not allowed.
      if (not SenderHasReadWrite) and SenderHasComment then
      begin
        if SenderProjectId <> TargetProjectId then
          raise EMxError.Create('SEND_DENIED',
            'alComment senders may only message within their own project.');
        if TargetDeveloperId > 0 then
        begin
          // Inspect target developer
          TargetIsAdmin := False;
          TargetHasReadWrite := False;
          Qry := AContext.CreateQuery(
            'SELECT d.role, ' +
            '  EXISTS (SELECT 1 FROM developer_project_access dpa ' +
            '          WHERE dpa.developer_id = d.id AND dpa.project_id = :pid ' +
            '            AND dpa.access_level = ''read-write'') AS has_rw ' +
            'FROM developers d WHERE d.id = :did');
          try
            Qry.ParamByName('did').AsInteger := TargetDeveloperId;
            Qry.ParamByName('pid').AsInteger := TargetProjectId;
            Qry.Open;
            if not Qry.IsEmpty then
            begin
              TargetIsAdmin := SameText(Qry.FieldByName('role').AsString, 'admin');
              TargetHasReadWrite := Qry.FieldByName('has_rw').AsBoolean;
            end;
          finally
            Qry.Free;
          end;
          if not (TargetIsAdmin or TargetHasReadWrite) then
            raise EMxError.Create('SEND_DENIED',
              'alComment senders may only message admins or alReadWrite developers on the target project.');
        end;
      end;
    end;
  end;

  // Spec #1964: Same-project messaging skips NO_RELATION check.
  // Cross-project still requires project_relation (setup_report exempt + admin-bypass via M3.1).
  if (SenderProjectId <> TargetProjectId) and
     (MsgType <> 'setup_report') and
     (not IsAdmin) and
     not HasProjectRelation(AContext, SenderProjectId, TargetProjectId) then
    raise EMxError.Create('NO_RELATION',
      'No project_relation between sender and target project');

  // M3.1+M3.2: target_developer_id validation. Self-target now ALLOWED
  // (Plan#3266 Spec#3194 — agents queue notes-to-self for follow-up reminders).
  if (TargetDeveloperId > 0) and (not IsSelfTarget) then
  begin
    // Target developer must have access to target project
    Qry := AContext.CreateQuery(
      'SELECT 1 FROM developer_project_access ' +
      'WHERE developer_id = :did AND project_id = :pid LIMIT 1');
    try
      Qry.ParamByName('did').AsInteger := TargetDeveloperId;
      Qry.ParamByName('pid').AsInteger := TargetProjectId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxError.Create('INVALID_TARGET',
          'Invalid target_developer_id for this request');
    finally
      Qry.Free;
    end;

    // M3.2 accept_agent_messages opt-out (admin-sender bypasses this gate;
    // self-target also exempt — captured above).
    if not IsAdmin then
    begin
      AcceptsMessages := True;
      Qry := AContext.CreateQuery(
        'SELECT accept_agent_messages FROM developers WHERE id = :did');
      try
        Qry.ParamByName('did').AsInteger := TargetDeveloperId;
        Qry.Open;
        if not Qry.IsEmpty then
          AcceptsMessages := Qry.FieldByName('accept_agent_messages').AsBoolean;
      finally
        Qry.Free;
      end;
      if not AcceptsMessages then
        raise EMxError.Create('TARGET_OPT_OUT',
          'Target developer has opted out of agent messages. Admin-priority-override required.');
    end;
  end;

  // Get sender session
  SenderSessionId := GetActiveSessionId(AContext, SenderProjectId);

  // M3.2 Rate-limit (10 msg/min per session). Self-Messaging exempt — caller
  // may flood their own inbox with reminders without throttling.
  if (not IsSelfTarget) and (SenderSessionId > 0)
     and not CheckRateLimit(SenderSessionId) then
    raise EMxError.Create('RATE_LIMITED',
      'Max 10 messages per minute per session');

  // Insert message
  Qry := AContext.CreateQuery(
    'INSERT INTO agent_messages ' +
    '(sender_session_id, sender_project_id, sender_developer_id, ' +
    ' target_project_id, target_developer_id, message_type, payload, ref_doc_id, ' +
    ' priority, expires_at) ' +
    'VALUES (:sid, :spid, :did, :tpid, :tdid, :mtype, :payload, :rdid, ' +
    ' :prio, DATE_ADD(NOW(), INTERVAL :ttl DAY))');
  try
    Qry.ParamByName('sid').AsInteger := SenderSessionId;
    Qry.ParamByName('spid').AsInteger := SenderProjectId;
    Qry.ParamByName('did').AsInteger := Auth.DeveloperId;
    Qry.ParamByName('tpid').AsInteger := TargetProjectId;
    Qry.ParamByName('tdid').DataType := ftInteger;
    if TargetDeveloperId > 0 then
      Qry.ParamByName('tdid').AsInteger := TargetDeveloperId
    else
      Qry.ParamByName('tdid').Clear;
    Qry.ParamByName('mtype').AsWideString :=MsgType;
    Qry.ParamByName('payload').AsWideString :=Payload;
    Qry.ParamByName('rdid').DataType := ftInteger;
    if RefDocId > 0 then
      Qry.ParamByName('rdid').AsInteger := RefDocId
    else
      Qry.ParamByName('rdid').Clear;
    var Prio := AParams.GetValue<string>('priority', 'normal');
    if (Prio <> 'normal') and (Prio <> 'urgent') then
      Prio := 'normal';
    Qry.ParamByName('prio').AsWideString :=Prio;
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
    if TargetDeveloperId > 0 then
      Data.AddPair('target_developer_id', TJSONNumber.Create(TargetDeveloperId));
    Data.AddPair('message_type', MsgType);
    // M3.1 soft-size warning surfaces alongside success — caller can tune next msg.
    // mxBugChecker WARN#2: protect Warnings allocation in case AddPair raises
    // before ownership transfer (Format with constant args is safe in practice
    // but the pattern matches outer try/except so reviewers don't second-guess).
    if PayloadLen > PAYLOAD_SOFT_LIMIT then
    begin
      Warnings := TJSONArray.Create;
      try
        Warnings.Add(Format('payload exceeds soft limit (%d > %d chars) -- consider summarising',
          [PayloadLen, PAYLOAD_SOFT_LIMIT]));
        Data.AddPair('warnings', Warnings);
      except
        Warnings.Free;
        raise;
      end;
    end;
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
  Auth: TMxAuthResult;
  Opts: TAgentInboxOptions;
  Rows: TArray<TAgentInboxRow>;
  ProjectSlug: string;
  Data: TJSONObject;
  Messages: TJSONArray;
  JRow: TJSONObject;
  I: Integer;
begin
  // Spec #1964: Auth context needed for intra-project targeting filter.
  Auth := MxGetThreadAuth;

  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  Opts.LimitCount := AParams.GetValue<Integer>('limit', 20);
  if Opts.LimitCount < 1 then Opts.LimitCount := 1;
  if Opts.LimitCount > 50 then Opts.LimitCount := 50;

  Opts.ProjectId := ResolveProject(AContext, ProjectSlug, alReadOnly);
  Opts.MyDeveloperId := Auth.DeveloperId;
  Opts.FilterTargetDeveloper := True;  // Spec #1964 broadcast/direct filter
  Opts.FilterSelfEcho := True;         // Build 105 intra-project self-talk guard

  // FR#3836: Logic layer handles archive-expired pre-step + query + filters +
  // record materialisation. Shell only builds the MCP-tool JSON response shape.
  Rows := FetchAgentInbox(AContext, Opts);

  Messages := TJSONArray.Create;
  try
    for I := Low(Rows) to High(Rows) do
    begin
      JRow := TJSONObject.Create;
      try
        JRow.AddPair('id', TJSONNumber.Create(Rows[I].Id));
        JRow.AddPair('message_type', Rows[I].MessageType);
        JRow.AddPair('payload', Rows[I].Payload);
        if Rows[I].HasRefDocId then
          JRow.AddPair('ref_doc_id', TJSONNumber.Create(Rows[I].RefDocId));
        if Rows[I].HasRefMessageId then
          JRow.AddPair('ref_message_id', TJSONNumber.Create(Rows[I].RefMessageId));
        JRow.AddPair('priority', Rows[I].Priority);
        JRow.AddPair('sender_project', Rows[I].SenderProject);
        JRow.AddPair('sender_name', Rows[I].SenderName);
        // Spec #1964: target_developer fields (NULL = broadcast)
        if Rows[I].HasTargetDeveloperId then
        begin
          JRow.AddPair('target_developer_id',
            TJSONNumber.Create(Rows[I].TargetDeveloperId));
          JRow.AddPair('target_developer_name', Rows[I].TargetDeveloperName);
        end;
        JRow.AddPair('created_at', Rows[I].CreatedAt);
        Messages.Add(JRow);
        JRow := nil; // ownership transferred to Messages
      except
        JRow.Free;
        raise;
      end;
    end;
  except
    Messages.Free;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('count', TJSONNumber.Create(Messages.Count));
    Data.AddPair('messages', Messages);
    Messages := nil; // ownership transferred to Data
    Result := MxSuccessResponse(Data);
  except
    Messages.Free; // no-op if nil (Data.Free handles it)
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
  MsgIds: TJSONArray;
  Ids: TArray<Integer>;
  Opts: TAgentAckOptions;
  ProjectSlug: string;
  Data: TJSONObject;
  Affected, I: Integer;
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

  Opts.NewStatus := AParams.GetValue<string>('new_status', 'read');
  if (Opts.NewStatus <> 'read') and (Opts.NewStatus <> 'archived') then
    raise EMxValidation.Create('new_status must be "read" or "archived"');

  // FR#3860: MCP-tool path enforces target_project_id ownership — callers
  // must specify which project they are acking messages for.
  Opts.EnforceOwnership := True;
  Opts.ProjectId := ResolveProject(AContext, ProjectSlug, alReadOnly);

  SetLength(Ids, MsgIds.Count);
  for I := 0 to MsgIds.Count - 1 do
    Ids[I] := MsgIds.Items[I].GetValue<Integer>;

  // FR#3836: Logic layer builds the IN-clause + query; MCP-tool path enforces
  // target_project_id ownership via Opts.ProjectId > 0.
  Affected := AckAgentMessages(AContext, Ids, Opts);

  Data := TJSONObject.Create;
  try
    Data.AddPair('acknowledged', TJSONNumber.Create(Affected));
    Data.AddPair('new_status', Opts.NewStatus);
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
  Auth: TMxAuthResult;
  Qry: TFDQuery;
  ProjectSlug, Scope, HeartbeatClause: string;
  ProjectId, RecentHours, MySessionId: Integer;
  Data: TJSONObject;
  Peers: TJSONArray;
  Row: TJSONObject;

  procedure AddPeerRow(const APeerScope: string);
  begin
    Row := TJSONObject.Create;
    try
      Row.AddPair('project', Qry.FieldByName('project_slug').AsString);
      Row.AddPair('project_name', Qry.FieldByName('project_name').AsString);
      Row.AddPair('session_id',
        TJSONNumber.Create(Qry.FieldByName('session_id').AsInteger));
      Row.AddPair('started_at', Qry.FieldByName('started_at').AsString);
      if not Qry.FieldByName('relation_type').IsNull then
        Row.AddPair('relation_type', Qry.FieldByName('relation_type').AsString);
      Row.AddPair('developer_name', Qry.FieldByName('developer_name').AsString);
      if not Qry.FieldByName('client_key_name').IsNull then
        Row.AddPair('client_key_name', Qry.FieldByName('client_key_name').AsString);
      Row.AddPair('peer_scope', APeerScope);
      // Feature#614: files_touched for conflict detection
      if not Qry.FieldByName('files_touched').IsNull then
        Row.AddPair('files_touched', Qry.FieldByName('files_touched').AsString);
      Peers.Add(Row);
    except
      Row.Free;
      raise;
    end;
  end;

begin
  // Spec #1964: Auth for own session ID (needed by same-scope self-exclusion).
  Auth := MxGetThreadAuth;

  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  // Spec #1964: scope = cross (default, backward-compat) | same | all
  Scope := LowerCase(AParams.GetValue<string>('scope', 'cross'));
  if not MatchStr(Scope, ['cross', 'same', 'all']) then
    Scope := 'cross';

  // Spec #1964: recent_hours — 0=legacy 5min window, 1..168=hours window
  RecentHours := AParams.GetValue<Integer>('recent_hours', 0);
  if RecentHours < 0 then RecentHours := 0;
  if RecentHours > 168 then RecentHours := 168;

  if RecentHours = 0 then
    HeartbeatClause := '(s.last_heartbeat IS NULL OR ' +
      's.last_heartbeat > DATE_SUB(NOW(), INTERVAL 5 MINUTE))'
  else
    HeartbeatClause := '(s.last_heartbeat IS NULL OR ' +
      's.last_heartbeat > DATE_SUB(NOW(), INTERVAL ' + IntToStr(RecentHours) +
      ' HOUR))';

  ProjectId := ResolveProject(AContext, ProjectSlug, alReadOnly);

  // Resolve caller session via API key (unique per client_key_id)
  MySessionId := GetSessionIdByKey(AContext, Auth.KeyId);

  Peers := TJSONArray.Create;
  try
    // Cross-scope: sessions on related projects via project_relations.
    // Guard against self-loop relations.
    if MatchStr(Scope, ['cross', 'all']) then
    begin
      Qry := AContext.CreateQuery(
        'SELECT DISTINCT p.slug AS project_slug, p.name AS project_name, ' +
        '  s.id AS session_id, s.started_at, s.last_heartbeat, ' +
        '  pr.relation_type, s.files_touched, ' +
        '  d.name AS developer_name, ck.name AS client_key_name ' +
        'FROM sessions s ' +
        'JOIN projects p ON s.project_id = p.id ' +
        'JOIN developers d ON s.developer_id = d.id ' +
        'LEFT JOIN client_keys ck ON s.client_key_id = ck.id ' +
        'JOIN project_relations pr ON ' +
        '  ((pr.source_project_id = :pid AND pr.target_project_id = s.project_id) ' +
        '   OR (pr.target_project_id = :pid2 AND pr.source_project_id = s.project_id)) ' +
        '  AND pr.source_project_id <> pr.target_project_id ' +
        'WHERE s.ended_at IS NULL ' +
        '  AND ' + HeartbeatClause + ' ' +
        '  AND s.project_id <> :pid3 ' +
        '  AND s.started_at > DATE_SUB(NOW(), INTERVAL 7 DAY) ' +
        'ORDER BY s.started_at DESC');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('pid2').AsInteger := ProjectId;
        Qry.ParamByName('pid3').AsInteger := ProjectId;
        Qry.Open;
        while not Qry.Eof do
        begin
          AddPeerRow('cross');
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    end;

    // Same-scope: other sessions on the same project (intra-project coord).
    // Exclude the caller's own session (resolved via client_key_id).
    if MatchStr(Scope, ['same', 'all']) then
    begin
      Qry := AContext.CreateQuery(
        'SELECT p.slug AS project_slug, p.name AS project_name, ' +
        '  s.id AS session_id, s.started_at, s.last_heartbeat, ' +
        '  CAST(NULL AS CHAR(50)) AS relation_type, s.files_touched, ' +
        '  d.name AS developer_name, ck.name AS client_key_name ' +
        'FROM sessions s ' +
        'JOIN projects p ON s.project_id = p.id ' +
        'JOIN developers d ON s.developer_id = d.id ' +
        'LEFT JOIN client_keys ck ON s.client_key_id = ck.id ' +
        'WHERE s.project_id = :pid ' +
        '  AND s.id <> :my_sid ' +
        '  AND s.ended_at IS NULL ' +
        '  AND ' + HeartbeatClause + ' ' +
        '  AND s.started_at > DATE_SUB(NOW(), INTERVAL 7 DAY) ' +
        'ORDER BY s.started_at DESC');
      try
        Qry.ParamByName('pid').AsInteger := ProjectId;
        Qry.ParamByName('my_sid').AsInteger := MySessionId;
        Qry.Open;
        while not Qry.Eof do
        begin
          AddPeerRow('same');
          Qry.Next;
        end;
      finally
        Qry.Free;
      end;
    end;
  except
    Peers.Free;
    raise;
  end;

  // Feature#614: Detect file overlaps with own session
  var OwnFiles: string := '';
  var SessionIdParam := AParams.GetValue<Integer>('session_id', 0);
  if SessionIdParam > 0 then
  begin
    try
      Qry := AContext.CreateQuery(
        'SELECT files_touched FROM sessions WHERE id = :sid');
      try
        Qry.ParamByName('sid').AsInteger := SessionIdParam;
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
    Data.AddPair('scope', Scope);
    Data.AddPair('recent_hours', TJSONNumber.Create(RecentHours));
    Data.AddPair('peer_count', TJSONNumber.Create(Peers.Count));
    Data.AddPair('peers', Peers);
    Peers := nil; // ownership transferred to Data
    if OwnFiles <> '' then
      Data.AddPair('own_files_touched', OwnFiles);
    Result := MxSuccessResponse(Data);
  except
    Peers.Free; // no-op if nil (Data.Free handles it)
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
