unit mx.Tool.Registry;

interface

uses
  System.SysUtils, System.JSON, Data.DB,
  mx.Types, mx.Errors, mx.Data.Pool, mx.MCP.Schema,
  mx.Intelligence.AIBatch;

type
  TMxToolRegistry = class
  public
    class procedure RegisterAll(ARegistry: TMxMcpRegistry);
  end;

  function SafeExecute(AHandler: TMxToolHandler; const AParams: TJSONObject;
    APool: TMxConnectionPool; ALogger: IMxLogger): TJSONObject;
  function StripCompactWrapper(AResponse: TJSONObject): string;

implementation

uses
  FireDAC.Stan.Error, FireDAC.Comp.Client,
  mx.Logic.AccessControl,
  mx.Tool.Read, mx.Tool.Write, mx.Tool.Write.Meta, mx.Tool.Write.Batch,
  mx.Tool.Session,
  mx.Tool.Env, mx.Tool.Migrate, mx.Tool.Onboard,
  mx.Tool.Trace, mx.Tool.ProjectRelation, mx.Tool.Agent,
  mx.Tool.SkillEvolution,
  mx.Tool.Recall,
  mx.Tool.Graph,
  mx.Tool.Fetch;

{ SafeExecute }

function SafeExecute(AHandler: TMxToolHandler; const AParams: TJSONObject;
  APool: TMxConnectionPool; ALogger: IMxLogger): TJSONObject;
var
  Ctx: IMxDbContext;
  Auth: TMxAuthResult;
  SessionId: Integer;
  Qry: TFDQuery;
  FilePath: string;
begin
  try
    Auth := MxGetThreadAuth;
    Ctx := APool.AcquireAuthContext(Auth, ALogger);
    Result := AHandler(AParams, Ctx);

    // Heartbeat: refresh last_heartbeat if session_id was passed
    SessionId := AParams.GetValue<Integer>('session_id', 0);
    if SessionId > 0 then
    begin
      try
        Qry := Ctx.CreateQuery(
          'UPDATE sessions SET last_heartbeat = NOW() WHERE id = :sid AND ended_at IS NULL');
        try
          Qry.ParamByName('sid').AsInteger := SessionId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      except
        // Non-critical: don't fail the tool call if heartbeat fails
      end;

      // Feature#614 Phase 2: Track files touched per session
      FilePath := AParams.GetValue<string>('target_file', '');
      if FilePath = '' then
        FilePath := AParams.GetValue<string>('file_path', '');
      if FilePath <> '' then
      begin
        try
          Qry := Ctx.CreateQuery(
            'UPDATE sessions SET files_touched = JSON_ARRAY_APPEND(' +
            '  COALESCE(files_touched, JSON_ARRAY()), ''$'', :fp) ' +
            'WHERE id = :sid AND ended_at IS NULL ' +
            '  AND (files_touched IS NULL OR NOT JSON_CONTAINS(files_touched, JSON_QUOTE(:fp2)))');
          try
            Qry.ParamByName('fp').AsString := FilePath;
            Qry.ParamByName('fp2').AsString := FilePath;
            Qry.ParamByName('sid').AsInteger := SessionId;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;
        except
          // Non-critical
        end;
      end;
    end;
  except
    on E: EMxError do
    begin
      ALogger.Log(mlWarning, E.Message);
      Result := MxErrorResponse(E.Code, E.Message);
    end;
    on E: EMxAccessDenied do
    begin
      ALogger.Log(mlWarning, 'Access denied: ' + E.Message);
      Result := MxErrorResponse('ACCESS_DENIED', E.Message);
    end;
    on E: EFDDBEngineException do
    begin
      if E.Kind = ekUKViolated then
        ALogger.Log(mlWarning, 'Duplicate: ' + E.Message)
      else
        ALogger.Log(mlError, 'DB error: ' + E.Message);
      Result := MapDBError(E);
    end;
    on E: Exception do
    begin
      ALogger.Log(mlError, 'Unexpected: ' + E.Message);
      Result := MxErrorResponse('INTERNAL', 'Internal server error');
    end;
  end;
end;

function StripCompactWrapper(AResponse: TJSONObject): string;
var
  StatusVal, DataVal, WarningsVal: TJSONValue;
  Warnings: TJSONArray;
  DataObj: TJSONObject;
  WrapObj: TJSONObject;
begin
  StatusVal := AResponse.GetValue('status');
  if (StatusVal = nil) or (StatusVal.Value <> 'ok') then
  begin
    Result := AResponse.ToJSON;
    Exit;
  end;

  DataVal := AResponse.GetValue('data');
  if DataVal = nil then
  begin
    Result := AResponse.ToJSON;
    Exit;
  end;

  WarningsVal := AResponse.GetValue('warnings');
  Warnings := nil;
  if (WarningsVal is TJSONArray) and (TJSONArray(WarningsVal).Count > 0) then
    Warnings := TJSONArray(WarningsVal);

  if Warnings = nil then
    Result := DataVal.ToJSON
  else if DataVal is TJSONObject then
  begin
    DataObj := DataVal as TJSONObject;
    DataObj.AddPair('_w', Warnings.Clone as TJSONArray);
    Result := DataObj.ToJSON;
  end
  else
  begin
    WrapObj := TJSONObject.Create;
    try
      WrapObj.AddPair('results', DataVal.Clone as TJSONValue);
      WrapObj.AddPair('_w', Warnings.Clone as TJSONArray);
      Result := WrapObj.ToJSON;
    finally
      WrapObj.Free;
    end;
  end;
end;

{ TMxToolRegistry }

// Handler for mx_ai_batch_pending
function HandleAIBatchPending(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
begin
  Result := MxSuccessResponse(
    TMxAIBatchRunner.GetPendingWorkItems(AContext), 0);
end;

// Handler for mx_ai_batch_log — claude.exe self-reports results
function HandleAIBatchLog(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  JobType, Status, ErrorMsg, FieldName: string;
  DocId, ProjectId, TokensIn, TokensOut, DurationMs: Integer;
  Data: TJSONObject;
begin
  JobType := AParams.GetValue<string>('job_type', '');
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  ProjectId := AParams.GetValue<Integer>('project_id', 0);
  Status := AParams.GetValue<string>('status', 'success');
  TokensIn := AParams.GetValue<Integer>('tokens_in', 0);
  TokensOut := AParams.GetValue<Integer>('tokens_out', 0);
  DurationMs := AParams.GetValue<Integer>('duration_ms', 0);
  ErrorMsg := AParams.GetValue<string>('error_msg', '');
  FieldName := AParams.GetValue<string>('field_name', '');

  if JobType = '' then
    raise EMxValidation.Create('Parameter "job_type" is required');
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  Qry := AContext.CreateQuery(
    'INSERT INTO ai_batch_log ' +
    '(job_type, doc_id, project_id, field_name, model, ' +
    ' tokens_input, tokens_output, status, error_message, duration_ms) ' +
    'VALUES (:jtype, :doc, :proj, :field, ''claude-exe'', ' +
    ' :tok_in, :tok_out, :status, :err, :dur)');
  try
    Qry.ParamByName('jtype').AsString := JobType;
    Qry.ParamByName('doc').AsInteger := DocId;
    Qry.ParamByName('proj').AsInteger := ProjectId;
    Qry.ParamByName('field').AsString := FieldName;
    Qry.ParamByName('tok_in').AsInteger := TokensIn;
    Qry.ParamByName('tok_out').AsInteger := TokensOut;
    Qry.ParamByName('status').AsString := Status;
    if ErrorMsg <> '' then
      Qry.ParamByName('err').AsString := Copy(ErrorMsg, 1, 500)
    else
    begin
      Qry.ParamByName('err').DataType := ftString;
      Qry.ParamByName('err').Clear;
    end;
    Qry.ParamByName('dur').AsInteger := DurationMs;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  Data.AddPair('logged', TJSONBool.Create(True));
  Data.AddPair('job_type', JobType);
  Data.AddPair('doc_id', TJSONNumber.Create(DocId));
  Result := MxSuccessResponse(Data);
end;

class procedure TMxToolRegistry.RegisterAll(ARegistry: TMxMcpRegistry);
begin
  // ---- READ TOOLS ----
  ARegistry
    .Add('mx_ping', HandlePing)
    .Desc('Server status, DB connection, version');

  ARegistry
    .Add('mx_briefing', HandleBriefing)
    .Desc('Project briefing with relevance-scored documents')
    .Param('project', mptString, True, 'Project slug')
    .Param('token_budget', mptInteger, False, 'Max tokens (def 1500)')
    .Param('doc_type', mptString, False, 'Filter by type')
    .Param('status', mptString, False, 'Filter by status')
    .Param('since', mptString, False, 'ISO timestamp — filter to changes after')
    .Param('session_id', mptInteger, False, 'Session ID');

  ARegistry
    .Add('mx_search', HandleSearch)
    .Desc('Full-text search across documents. Also replaces mx_list_notes (use doc_type+tag filter).')
    .Param('query', mptString, False, 'Search query (optional when using doc_type/tag filters)')
    .Param('scope', mptString, False, 'project or all (def all)')
    .Param('project', mptString, False, 'Project slug')
    .Param('doc_type', mptString, False, 'Filter by type (comma-sep)')
    .Param('tag', mptString, False, 'Filter by tag')
    .Param('status', mptString, False, 'Filter by status (e.g. active, archived)')
    .Param('token_budget', mptInteger, False, 'Max tokens (def 1500)')
    .Param('include_content', mptBoolean, False, 'Include content if <=3 results')
    .Param('include_details', mptBoolean, False, 'Include content+relations if <=5 results')
    .Param('limit', mptInteger, False, 'Max results 1-50 (def 10)')
    .Param('session_id', mptInteger, False, 'Session ID');

  ARegistry
    .Add('mx_detail', HandleDetail)
    .Desc('Full document content (L3) with tags and relations')
    .Param('doc_id', mptInteger, True, 'Document ID')
    .Param('max_content_tokens', mptInteger, False, 'Truncate content at N tokens (def 600, 0=unlimited)')
    .Param('session_id', mptInteger, False, 'Session ID');

  ARegistry
    .Add('mx_batch_detail', HandleBatchDetail)
    .Desc('Multiple documents in one call (max 10)')
    .Param('doc_ids', mptArray, True, 'Array of document IDs')
    .Param('level', mptString, False, 'Detail level: full (default) or summary (no content)')
    .Param('session_id', mptInteger, False, 'Session ID');

  // ---- WRITE TOOLS ----
  ARegistry
    .Add('mx_init_project', HandleInitProject)
    .Desc('Register a new project')
    .Param('slug', mptString, True, 'Project slug (a-z, 0-9, hyphens)')
    .Param('project_name', mptString, True, 'Project name')
    .Param('path', mptString, False, 'Local path')
    .Param('svn_url', mptString, False, 'SVN URL');

  ARegistry
    .Add('mx_create_doc', HandleCreateDoc)
    .Desc('Create a new document with initial revision. Also replaces mx_create_note.')
    .Param('project', mptString, True, 'Project slug')
    .Param('doc_type', mptString, True, 'Type (plan, spec, decision, note, bugreport, feature_request, todo, lesson, ...)')
    .Param('title', mptString, True, 'Title')
    .Param('content', mptString, False, 'Content (markdown). Alias: body')
    .Param('body', mptString, False, 'Alias for content (for mx_create_note compat)')
    .Param('summary_l1', mptString, False, 'One-line summary')
    .Param('summary_l2', mptString, False, 'Detailed summary')
    .Param('created_by', mptString, False, 'Author (def: mcp)')
    .Param('status', mptString, False, 'Status (def: draft)')
    .Param('tags', mptArray, False, 'Tags to add after creation')
    .Param('lesson_data', mptString, False, 'JSON with lesson fields (for doc_type=lesson)');

  ARegistry
    .Add('mx_update_doc', HandleUpdateDoc)
    .Desc('Update a document (with optimistic locking and revision tracking)')
    .Param('doc_id', mptInteger, True, 'Document ID')
    .Param('title', mptString, False, 'New title')
    .Param('content', mptString, False, 'New content (triggers revision)')
    .Param('status', mptString, False, 'draft, active, archived, superseded')
    .Param('doc_type', mptString, False, 'Change type')
    .Param('summary_l1', mptString, False, 'Updated L1 summary')
    .Param('summary_l2', mptString, False, 'Updated L2 summary')
    .Param('change_reason', mptString, False, 'Reason (stored in revision)')
    .Param('changed_by', mptString, False, 'Author (def: mcp)')
    .Param('expected_updated_at', mptString, False, 'Optimistic locking timestamp')
    .Param('verified', mptBoolean, False, 'Set confidence to 1.00')
    .Param('project', mptString, False, 'Move doc to project (slug)');

  ARegistry
    .Add('mx_delete_doc', HandleDeleteDoc)
    .Desc('Soft-delete a document')
    .Param('doc_id', mptInteger, True, 'Document ID');

  ARegistry
    .Add('mx_add_tags', HandleAddTags)
    .Desc('Add tags to a document')
    .Param('doc_id', mptInteger, True, 'Document ID')
    .Param('tags', mptArray, True, 'Tags to add');

  ARegistry
    .Add('mx_remove_tags', HandleRemoveTags)
    .Desc('Remove tags from a document')
    .Param('doc_id', mptInteger, True, 'Document ID')
    .Param('tags', mptArray, True, 'Tags to remove');

  ARegistry
    .Add('mx_add_relation', HandleAddRelation)
    .Desc('Create a relation between documents')
    .Param('source_doc_id', mptInteger, True, 'Source doc ID')
    .Param('target_doc_id', mptInteger, True, 'Target doc ID')
    .Param('relation_type', mptString, True, 'Type (references, supersedes, ...)');

  ARegistry
    .Add('mx_remove_relation', HandleRemoveRelation)
    .Desc('Remove a document relation')
    .Param('relation_id', mptInteger, True, 'Relation ID');

  // mx_next_adr_number removed (B6.6) — auto-number in mx_create_doc for doc_type=decision

  ARegistry
    .Add('mx_batch_create', HandleBatchCreate)
    .Desc('Batch-create documents (single transaction). Item fields: project, doc_type, title, content, created_by, status (def: draft), tags[]')
    .Param('items', mptString, True, 'JSON array of doc objects');

  ARegistry
    .Add('mx_batch_update', HandleBatchUpdate)
    .Desc('Batch-update documents (single transaction)')
    .Param('items', mptString, True, 'JSON array of update objects');

  // ---- SESSION TOOLS ----
  ARegistry
    .Add('mx_session_start', HandleSessionStart)
    .Desc('Start session — returns briefing+workflows+notes in one call')
    .Param('project', mptString, True, 'Project slug')
    .Param('include_briefing', mptBoolean, False, 'Include doc_type_counts+recent+workflows (def true)')
    .Param('include_notes', mptBoolean, False, 'Include notes/bugreports/feature_requests with tags (def false)')
    .Param('since', mptString, False, 'ISO timestamp — only return changes after this time, adds unchanged_count')
    .Param('setup_version', mptString, False, 'Client setup version from ~/.claude/setup-version.json (Spec#1302)');

  // mx_session_save removed (B6.3) — session end handled by mxSave skill

  ARegistry
    .Add('mx_session_delta', HandleSessionDelta)
    .Desc('Docs changed since session boundary (metadata only — no summary/content)')
    .Param('project', mptString, True, 'Project slug')
    .Param('session_id', mptInteger, False, 'Caller session ID — uses its started_at as cutoff')
    .Param('since', mptString, False, 'Explicit ISO 8601 cutoff (overrides session_id)')
    .Param('limit', mptInteger, False, 'Max rows 1-200 (def 50)');

  ARegistry
    .Add('mx_fetch', HandleFetch)
    .Desc('HTTP GET/POST against [Fetch] AllowedHosts. Body capped at 50 KB. Header whitelist enforced.')
    .Param('url', mptString, True, 'Full URL (http/https only)')
    .Param('method', mptString, False, 'GET (def) or POST')
    .Param('body', mptString, False, 'JSON-encoded body string for POST')
    .Param('headers', mptString, False, 'JSON-encoded headers dict. Whitelist: Authorization, X-MXSA-Key, X-API-Key, Content-Type, Accept')
    .Param('timeout_ms', mptInteger, False, 'Request timeout 1000-60000 (def 10000)')
    .Param('follow_redirects', mptBoolean, False, 'Follow same-host 3xx, max 3 hops (def true)')
    .Param('session_id', mptInteger, False, 'Session ID for rate-limit bucket');

  // mx_create_note removed (B6.1) — use mx_create_doc with tags/lesson_data
  // mx_list_notes removed (B6.2) — use mx_search with doc_type+tag filter

  // ---- ENV TOOLS ----
  ARegistry
    .Add('mx_set_env', HandleSetEnv)
    .Desc('Set env value by key')
    .Param('key', mptString, True, 'Key name')
    .Param('env_value', mptString, True, 'Value')
    .Param('project', mptString, False, 'Project slug (def: _global)');

  ARegistry
    .Add('mx_get_env', HandleGetEnv)
    .Desc('Get env value by key, or list all')
    .Param('key', mptString, False, 'Key to look up')
    .Param('project', mptString, False, 'Project slug');

  ARegistry
    .Add('mx_delete_env', HandleDeleteEnv)
    .Desc('Delete an env value')
    .Param('key', mptString, True, 'Key to delete')
    .Param('project', mptString, False, 'Project slug');

  // mx_refresh_summaries removed (B6.5) — server-autonomous batch job

  // ---- MIGRATE TOOLS ----
  ARegistry
    .Add('mx_migrate_project', HandleMigrateProject)
    .Desc('Import docs/*.md into knowledge DB')
    .Param('project', mptString, True, 'Project slug')
    .Param('path', mptString, True, 'Path to docs/ (forward slashes)');

  // ---- ONBOARD TOOLS ----
  ARegistry
    .Add('mx_onboard_developer', HandleOnboardDeveloper)
    .Desc('Developer onboarding info (projects, skills, proxy)')
    .Param('scope', mptString, False, 'Filter: all (default), skills, reference, hooks, proxy, projects, mx_rules')
    .Param('skill_name', mptString, False, 'Return only this skill (e.g. mxSetup)');

  // ---- TRACE TOOLS ----
  ARegistry
    .Add('mx_decision_trace', HandleDecisionTrace)
    .Desc('Traverse decision chains (BFS)')
    .Param('doc_id', mptInteger, True, 'Decision doc ID')
    .Param('max_depth', mptInteger, False, 'Max depth (def 5, max 10)');

  // ---- PROJECT RELATION TOOLS ----
  ARegistry
    .Add('mx_add_project_relation', HandleAddProjectRelation)
    .Desc('Create a project relation')
    .Param('source_project', mptString, True, 'Source slug')
    .Param('target_project', mptString, True, 'Target slug')
    .Param('relation_type', mptString, True, 'depends_on, related_to');

  ARegistry
    .Add('mx_remove_project_relation', HandleRemoveProjectRelation)
    .Desc('Remove a project relation')
    .Param('source_project', mptString, True, 'Source slug')
    .Param('target_project', mptString, True, 'Target slug')
    .Param('relation_type', mptString, True, 'Type to remove');

  // ---- AGENT COMMUNICATION TOOLS ----
  ARegistry
    .Add('mx_agent_send', HandleAgentSend)
    .Desc('Send message to another project agent or a specific developer in the same project')
    .Param('project', mptString, True, 'Sender project slug')
    .Param('target_project', mptString, True, 'Target project slug')
    .Param('message_type', mptString, True, 'task, info, question, response, status, setup_report')
    .Param('payload', mptString, True, 'Message payload (JSON string, max 16KB)')
    .Param('target_developer_id', mptInteger, False, 'Target developer ID (intra-project direct message; empty = broadcast to all devs)')
    .Param('ref_doc_id', mptInteger, False, 'Referenced document ID')
    .Param('priority', mptString, False, 'normal (def) or urgent')
    .Param('ttl_days', mptInteger, False, 'TTL in days (1-30, default 1)');

  ARegistry
    .Add('mx_agent_inbox', HandleAgentInbox)
    .Desc('Get pending messages for a project (filtered by current developer)')
    .Param('project', mptString, True, 'Project slug')
    .Param('limit', mptInteger, False, 'Max messages (def 20, max 50)');

  ARegistry
    .Add('mx_agent_ack', HandleAgentAck)
    .Desc('Acknowledge messages (mark read/archived)')
    .Param('project', mptString, True, 'Project slug (ownership check)')
    .Param('message_ids', mptArray, True, 'Array of message IDs')
    .Param('new_status', mptString, False, 'read (def) or archived');

  ARegistry
    .Add('mx_agent_peers', HandleAgentPeers)
    .Desc('Active peer sessions: cross-project (via relations), same-project (multi-dev), or all')
    .Param('project', mptString, True, 'Project slug')
    .Param('scope', mptString, False, 'cross (def, related projects) | same (same project) | all')
    .Param('recent_hours', mptInteger, False, 'Heartbeat window in hours (0=def=legacy 5min, 1..168=h)')
    .Param('session_id', mptInteger, False, 'Own session ID for file-overlap detection (optional)');

  // ---- SKILL EVOLUTION TOOLS ----
  ARegistry
    .Add('mx_skill_manage', HandleSkillManage)
    .Desc('Unified skill management: record findings, tune rules, rollback params, delete skill data')
    .Param('action', mptString, True, 'record_finding, tune, rollback, delete_skill')
    .Param('skill', mptString, True, 'Skill name (e.g. mxBugChecker)')
    .Param('project', mptString, False, 'Project slug (required for record_finding, tune, rollback)')
    // record_finding params:
    .Param('rule_id', mptString, False, 'Rule identifier (record_finding)')
    .Param('severity', mptString, False, 'info, warning, error, critical (record_finding)')
    .Param('title', mptString, False, 'Short finding description (record_finding)')
    .Param('details', mptString, False, 'Full finding details (record_finding)')
    .Param('file_path', mptString, False, 'Affected file (record_finding)')
    .Param('line_number', mptInteger, False, 'Line number (record_finding)')
    .Param('context_hash', mptString, False, 'Hash for dedup (record_finding)')
    // tune params:
    .Param('auto_apply', mptBoolean, False, 'Apply proposals (tune, def false)')
    .Param('rule_name', mptString, False, 'Target rule (tune+rollback)')
    .Param('tune_action', mptString, False, 'enable, disable, promote, downgrade (tune, requires rule_name)')
    // rollback params:
    .Param('param_key', mptString, False, 'Parameter key (rollback)');

  ARegistry
    .Add('mx_skill_feedback', HandleSkillFeedback)
    .Desc('Submit user reaction to a skill finding. Single mode: finding_uid required. Batch mode: project instead of finding_uid to dismiss all pending findings')
    .Param('finding_uid', mptString, False, 'Finding UID (single mode)')
    .Param('project', mptString, False, 'Project slug (batch mode: dismiss all pending)')
    .Param('reaction', mptString, True, 'confirmed, dismissed, false_positive');

  ARegistry
    .Add('mx_skill_metrics', HandleSkillMetrics)
    .Desc('Get precision/FP-rate metrics per skill and rule')
    .Param('skill', mptString, True, 'Skill name (e.g. mxBugChecker)')
    .Param('project', mptString, True, 'Project slug')
    .Param('rule_id', mptString, False, 'Filter by specific rule')
    .Param('days', mptInteger, False, 'Lookback days (def 90)');

  ARegistry
    .Add('mx_skill_findings_list', HandleSkillFindingsList)
    .Desc('List individual skill findings with details. Filter by skill, rule, status.')
    .Param('project', mptString, True, 'Project slug')
    .Param('skill', mptString, False, 'Filter by skill name (e.g. mxBugChecker)')
    .Param('rule_id', mptString, False, 'Filter by rule (e.g. logik, security)')
    .Param('status', mptString, False, 'Filter: pending, confirmed, dismissed, false_positive (def: all)')
    .Param('limit', mptInteger, False, 'Max results (def 50, max 200)');

  // ---- RECALL (Institutional Memory, Spec#1198) ----
  ARegistry
    .Add('mx_recall', HandleRecall)
    .Desc('Recall relevant project knowledge (lessons, findings, pitfalls) before acting. Returns prioritized context with gate level.')
    .Param('query', mptString, False, 'Search query: filename, function name, pattern or free text')
    .Param('project', mptString, True, 'Project slug')
    .Param('scope', mptString, False, 'project (def), shared-domain, global')
    .Param('intent', mptString, False, 'implement, debug, review, design, migrate, general (def)')
    .Param('session_id', mptInteger, False, 'Session ID')
    .Param('target_file', mptString, False, 'File being worked on');

  ARegistry
    .Add('mx_recall_outcome', HandleRecallOutcome)
    .Desc('Update outcome of a recall invocation (B6.7)')
    .Param('recall_id', mptInteger, True, 'Recall log ID')
    .Param('outcome', mptString, True, 'shown, acknowledged, edited_after_recall, applied, candidate_success, no_edit_followed, overridden, potential_violation, violation')
    .Param('reason', mptString, False, 'Override reason or context');

  // ---- GRAPH TOOLS ----
  ARegistry
    .Add('mx_graph_link', HandleGraphLink)
    .Desc('Create/find graph nodes and link them with a typed edge')
    .Param('project', mptString, True, 'Project slug')
    .Param('source_type', mptString, True, 'Node type: file, function, pattern, lesson, doc, module')
    .Param('source_name', mptString, True, 'Node name (e.g. file path, function name)')
    .Param('target_type', mptString, True, 'Node type')
    .Param('target_name', mptString, True, 'Node name')
    .Param('edge_type', mptString, True, 'Edge type: references, caused_by, fixes, contradicts, applies_to, calls, imports')
    .Param('weight', mptNumber, False, 'Edge weight 0.0-10.0 (def 1.0)');

  ARegistry
    .Add('mx_graph_query', HandleGraphQuery)
    .Desc('Query knowledge graph: find nodes and traverse edges')
    .Param('project', mptString, True, 'Project slug')
    .Param('node_type', mptString, False, 'Filter by node type')
    .Param('node_name', mptString, False, 'Find node by name')
    .Param('doc_id', mptInteger, False, 'Find nodes linked to document')
    .Param('depth', mptInteger, False, 'Traversal depth 1-3 (def 1)')
    .Param('edge_type', mptString, False, 'Filter edges by type')
    .Param('direction', mptString, False, 'outgoing, incoming, both (def both)');

  // ---- AI BATCH TOOLS ----
  ARegistry
    .Add('mx_ai_batch_pending', HandleAIBatchPending)
    .Desc('Get pending AI work items (docs without summaries/tags)');

  ARegistry
    .Add('mx_ai_batch_log', HandleAIBatchLog)
    .Desc('Log AI batch job result (called by claude.exe after processing each doc)')
    .Param('job_type', mptString, True, 'summary, tagging, health_auto_notes, etc.')
    .Param('doc_id', mptInteger, True, 'Processed document ID')
    .Param('project_id', mptInteger, False, 'Project ID (0 if unknown)')
    .Param('field_name', mptString, False, 'Changed field (e.g. summary_l1)')
    .Param('status', mptString, False, 'success or error (def: success)')
    .Param('tokens_in', mptInteger, False, 'Input tokens used')
    .Param('tokens_out', mptInteger, False, 'Output tokens used')
    .Param('duration_ms', mptInteger, False, 'Processing time in ms')
    .Param('error_msg', mptString, False, 'Error message if status=error');
end;

end.
