unit mx.Logic.AccessControl;

interface

uses
  System.SysUtils, System.Generics.Collections, FireDAC.Comp.Client,
  mx.Types;

type
  EMxAccessDenied = class(Exception)
  public
    ProjectSlug: string;
    RequiredLevel: TAccessLevel;
    constructor Create(const AProjectSlug: string; ALevel: TAccessLevel);
  end;

  /// <summary>
  /// Full ACL implementation. Eager-loads project permissions on creation.
  /// Respects AclMode (audit logs but allows, enforce blocks).
  /// </summary>
  TMxAccessControl = class(TInterfacedObject, IAccessControl)
  private
    FDeveloperId: Integer;
    FDeveloperName: string;
    FIsAdmin: Boolean;
    FAclMode: TAclMode;
    FGlobalRole: TMxPermission;
    FGlobalProjectId: Integer;
    // project_id -> access_level
    FProjectAccess: TDictionary<Integer, TAccessLevel>;
    FLogger: IMxLogger;
    procedure LoadPermissions(AConnection: TFDConnection);
    procedure LoadGlobalProjectId(AConnection: TFDConnection);
    function EffectiveLevel(AProjLevel: TAccessLevel): TAccessLevel;
  public
    constructor Create(ADeveloperId: Integer; const ADeveloperName: string;
      AIsAdmin: Boolean; AAclMode: TAclMode; AGlobalRole: TMxPermission;
      AConnection: TFDConnection; ALogger: IMxLogger);
    destructor Destroy; override;
    // IAccessControl
    function GetDeveloperId: Integer;
    function GetDeveloperName: string;
    function IsAdmin: Boolean;
    function CheckProject(AProjectId: Integer; ALevel: TAccessLevel): Boolean;
    function GetAllowedProjectIds(ALevel: TAccessLevel): TArray<Integer>;
  end;

  // FR#2936/Plan#3266 M1.6: Tool-Authorization wrapper.
  // Single chokepoint for all MCP-tool-level authorization, to replace the
  // scattered `AContext.AccessControl.CheckProject(..., alReadOnly|alReadWrite)`
  // calls in individual tool handlers (M2+ work will migrate them).
  //
  // Impl-order (7-step):
  //   1. Init  -> Result := denied
  //   2. Whitelist -> Tool must exist in MASTER_MAP; unknown -> UNKNOWN_TOOL
  //   3. Admin-Bypass -> IsAdmin short-circuits to Allowed=True
  //   4. Global-vs-Project -> ProjectId=0 is non-admin-reject in M1
  //   5. CheckProject -> IsAtLeast(effective, MinLevel) via ACL
  //   6. Denial-Log -> structured log of deny reason via Logger
  //   7. Return -> Allowed/DenialReason/DenialCode populated
  function Authorize(const ACtx: TAuthContext;
    AContext: IMxDbContext): TAuthResult;

  // FR#2936/Plan#3266 M1.7: Master-Map lookup (exposed for mxDesignChecker
  // CI rule (c) Impl-Order Whitelist-Check VOR Admin-Bypass).
  function TryLookupToolMinLevel(const ATool: string;
    out AMinLevel: TAccessLevel): Boolean;

  // FR#2936/Plan#3266 M2.9: Draft-Filter X2 helper.
  // Returns TRUE when the caller's effective access on AProjectId is exactly
  // alReadOnly (no comment/write privileges, not admin). Read-handlers use
  // this to AND `status <> 'draft'` into their WHERE clauses, preventing
  // pure read-only auditors from seeing in-progress drafts.
  // AProjectId=0 (cross-project search) -> caller MUST be admin or get FALSE.
  function ShouldFilterDrafts(AContext: IMxDbContext;
    AProjectId: Integer): Boolean;

type
  /// <summary>
  /// Null implementation: allows everything. Used when AclMode = off.
  /// </summary>
  TMxNullAccessControl = class(TInterfacedObject, IAccessControl)
  private
    FDeveloperId: Integer;
    FDeveloperName: string;
    FIsAdmin: Boolean;
  public
    constructor Create(ADeveloperId: Integer; const ADeveloperName: string;
      AIsAdmin: Boolean);
    function GetDeveloperId: Integer;
    function GetDeveloperName: string;
    function IsAdmin: Boolean;
    function CheckProject(AProjectId: Integer; ALevel: TAccessLevel): Boolean;
    function GetAllowedProjectIds(ALevel: TAccessLevel): TArray<Integer>;
  end;

implementation

uses
  System.JSON;

// FR#2936/Plan#3266 M1.7: Master-Map Tool -> MinRole.
// Default-Deny: tools not listed here are rejected by Authorize() with UNKNOWN_TOOL.
// alComment-level tools will land in M2 (mx_note_*). v1 uses only alReadOnly + alReadWrite.
// Admin-only tools still use alReadWrite here; the IsAdmin short-circuit in Authorize
// is separate from role mapping. Sensitive ops (set_env/delete_env/onboard/init_project)
// are effectively admin-only because CheckProject rejects non-admin for the _global
// project's developer management, not enforced via Master-Map itself.
type
  TMasterMapEntry = record
    Tool: string;
    MinLevel: TAccessLevel;
    // FR#2936/Plan#3266 M2-TODO resolutions:
    // - AdminOnly: structural enforcement of admin-only tools (5 entries).
    //   Authorize denies with ADMIN_ONLY for non-admin callers even if project
    //   ACL would otherwise pass.
    // - ScopeGlobalAllowed: mark tools whose legitimate scope includes global
    //   (ProjectId=0). Authorize allows such calls for any non-admin caller
    //   past whitelist, instead of rejecting as NO_GLOBAL_ACCESS.
    AdminOnly: Boolean;
    ScopeGlobalAllowed: Boolean;
  end;

const
  MASTER_MAP: array[0..43] of TMasterMapEntry = (
    // --- Read tools (20) ---
    (Tool: 'mx_ping';                     MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: True),
    (Tool: 'mx_search';                   MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: True),
    (Tool: 'mx_detail';                   MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_fetch';                    MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: True),
    (Tool: 'mx_briefing';                 MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_recall';                   MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: True),
    (Tool: 'mx_recall_outcome';           MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_graph_query';              MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_session_start';            MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_session_delta';            MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_agent_peers';              MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_agent_inbox';              MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_get_revision';             MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_doc_revisions';            MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_batch_detail';             MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_skill_findings_list';      MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_skill_metrics';            MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_get_env';                  MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_decision_trace';           MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_ai_batch_pending';         MinLevel: alReadOnly;  AdminOnly: False; ScopeGlobalAllowed: False),
    // --- Write tools (17) ---
    (Tool: 'mx_create_doc';               MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_update_doc';               MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_delete_doc';               MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_add_tags';                 MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_remove_tags';              MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_add_relation';             MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_remove_relation';          MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_add_project_relation';     MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_remove_project_relation';  MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_graph_link';               MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_agent_send';               MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_agent_ack';                MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_batch_create';             MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_batch_update';             MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_ai_batch_log';             MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_skill_feedback';           MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_skill_manage';             MinLevel: alReadWrite; AdminOnly: False; ScopeGlobalAllowed: False),
    // --- Admin-only tools (5) ---
    (Tool: 'mx_set_env';                  MinLevel: alReadWrite; AdminOnly: True;  ScopeGlobalAllowed: False),
    (Tool: 'mx_delete_env';               MinLevel: alReadWrite; AdminOnly: True;  ScopeGlobalAllowed: False),
    (Tool: 'mx_onboard_developer';        MinLevel: alReadWrite; AdminOnly: True;  ScopeGlobalAllowed: True),
    (Tool: 'mx_init_project';             MinLevel: alReadWrite; AdminOnly: True;  ScopeGlobalAllowed: False),
    (Tool: 'mx_migrate_project';          MinLevel: alReadWrite; AdminOnly: True;  ScopeGlobalAllowed: False),
    // --- Comment-level tools (2, FR#2936 M2.4 + M2.5) ---
    (Tool: 'mx_create_note';              MinLevel: alComment;   AdminOnly: False; ScopeGlobalAllowed: False),
    (Tool: 'mx_update_note';              MinLevel: alComment;   AdminOnly: False; ScopeGlobalAllowed: False)
  );

function TryLookupToolMinLevel(const ATool: string;
  out AMinLevel: TAccessLevel): Boolean;
var
  I: Integer;
begin
  for I := Low(MASTER_MAP) to High(MASTER_MAP) do
  begin
    if SameText(MASTER_MAP[I].Tool, ATool) then
    begin
      AMinLevel := MASTER_MAP[I].MinLevel;
      Exit(True);
    end;
  end;
  AMinLevel := alNone; // Default-Deny sentinel
  Result := False;
end;

// FR#2936 M2-TODO resolution: full-entry lookup needed by Authorize to
// enforce AdminOnly + ScopeGlobalAllowed without a second scan of MASTER_MAP.
function TryLookupToolEntryImpl(const ATool: string;
  out AEntry: TMasterMapEntry): Boolean;
var
  I: Integer;
begin
  for I := Low(MASTER_MAP) to High(MASTER_MAP) do
  begin
    if SameText(MASTER_MAP[I].Tool, ATool) then
    begin
      AEntry := MASTER_MAP[I];
      Exit(True);
    end;
  end;
  Result := False;
end;

// FR#2936/Plan#3266 M1.6: Authorize wrapper. 7-step impl-order:
// Init -> Whitelist -> Admin-Bypass -> Global/Project split -> CheckProject -> Denial-Log -> Return.
// ⚡ mxDesignChecker CI rule (c): the Whitelist step MUST run BEFORE Admin-Bypass —
// this preserves Default-Deny for unknown tools even for admins (otherwise a typo in
// a new tool name would silently succeed for admins, masking the registration bug).
function Authorize(const ACtx: TAuthContext; AContext: IMxDbContext): TAuthResult;
var
  Entry: TMasterMapEntry;
  MinLevel: TAccessLevel;
  ACL: IAccessControl;
  Logger: IMxLogger;
  LogData: TJSONObject;

  procedure LogDenial;
  begin
    if Logger = nil then Exit;
    LogData := TJSONObject.Create;
    try
      LogData.AddPair('tool', ACtx.Tool);
      LogData.AddPair('caller_id', TJSONNumber.Create(ACtx.CallerId));
      LogData.AddPair('project_id', TJSONNumber.Create(ACtx.ProjectId));
      LogData.AddPair('required', AccessLevelToString(ACtx.RequiredLevel));
      LogData.AddPair('denial_code', Result.DenialCode);
      LogData.AddPair('denial_reason', Result.DenialReason);
      if ACtx.RequestId <> '' then
        LogData.AddPair('request_id', ACtx.RequestId);
      Logger.Log(mlWarning, 'Authorize: denied', LogData);
    finally
      LogData.Free;
    end;
  end;

begin
  // Step 1: Init — denied by default
  Result.Allowed := False;
  Result.DenialReason := '';
  Result.DenialCode := '';

  if AContext = nil then
  begin
    Result.DenialCode := 'NO_CONTEXT';
    Result.DenialReason := 'IMxDbContext is nil';
    Exit;
  end;

  Logger := AContext.Logger;

  // Step 2: Whitelist — tool must be in Master-Map (Default-Deny).
  // ⚡ MUST run BEFORE Admin-Bypass (see function header).
  if (ACtx.Tool = '') or not TryLookupToolEntryImpl(ACtx.Tool, Entry) then
  begin
    Result.DenialCode := 'UNKNOWN_TOOL';
    Result.DenialReason := Format('Tool "%s" not in Master-Map (default-deny)',
      [ACtx.Tool]);
    LogDenial;
    Exit;
  end;
  MinLevel := Entry.MinLevel;

  ACL := AContext.AccessControl;
  if ACL = nil then
  begin
    Result.DenialCode := 'NO_ACL';
    Result.DenialReason := 'IAccessControl is nil';
    LogDenial;
    Exit;
  end;

  // Step 3: Admin-Bypass — admins always allowed for known tools.
  if ACL.IsAdmin then
  begin
    Result.Allowed := True;
    Exit;
  end;

  // Step 3.5: Admin-only structural enforcement (FR#2936 M2-TODO resolution).
  // Reached only by non-admin callers (admin short-circuited in Step 3). Tools
  // flagged AdminOnly in MASTER_MAP are hard-denied regardless of project ACL.
  if Entry.AdminOnly then
  begin
    Result.DenialCode := 'ADMIN_ONLY';
    Result.DenialReason := Format(
      'Tool "%s" is admin-only and caller is not admin', [ACtx.Tool]);
    LogDenial;
    Exit;
  end;

  // Step 4: Global-vs-Project split (FR#2936 M2-TODO resolution).
  // ProjectId=0 = global scope. By default non-admin is denied (most tools are
  // per-project). Tools flagged ScopeGlobalAllowed in MASTER_MAP are
  // legitimately global (mx_ping, mx_search scope='all', mx_recall global,
  // mx_fetch, …) — allowed for any non-admin caller who cleared whitelist.
  // Future M3: may route through CheckProject on the '_global' project instead
  // of direct-allow once per-global-project ACL rows exist.
  if ACtx.ProjectId = 0 then
  begin
    if Entry.ScopeGlobalAllowed then
    begin
      Result.Allowed := True;
      Exit;
    end;
    Result.DenialCode := 'NO_GLOBAL_ACCESS';
    Result.DenialReason := Format(
      'Tool "%s" requires admin for global scope (ProjectId=0)', [ACtx.Tool]);
    LogDenial;
    Exit;
  end;

  // Step 5: CheckProject — ordered >=-comparison via IsAtLeast.
  // MinLevel (from Master-Map) is the floor; if caller specified a higher
  // RequiredLevel in ACtx, take the max (caller can't lower the bar).
  if Ord(ACtx.RequiredLevel) > Ord(MinLevel) then
    MinLevel := ACtx.RequiredLevel;

  if not ACL.CheckProject(ACtx.ProjectId, MinLevel) then
  begin
    Result.DenialCode := 'WRONG_LEVEL';
    Result.DenialReason := Format(
      'Insufficient access for tool "%s" on project %d: need %s',
      [ACtx.Tool, ACtx.ProjectId, AccessLevelToString(MinLevel)]);
    // Step 6: Denial-Log (CheckProject also logs internally when amAudit,
    // but we log again at the Authorize layer for tool-level trace).
    LogDenial;
    Exit;
  end;

  // Step 7: Allowed
  Result.Allowed := True;
end;

{ EMxAccessDenied }
// FR#2936/Plan#3266 M1.4: uses AccessLevelToString (mx.Types) instead of
// local ACL_LEVEL_NAMES array; new 4-level hierarchy makes the const stale.

constructor EMxAccessDenied.Create(const AProjectSlug: string;
  ALevel: TAccessLevel);
begin
  inherited CreateFmt('No %s access to project ''%s''',
    [AccessLevelToString(ALevel), AProjectSlug]);
  ProjectSlug := AProjectSlug;
  RequiredLevel := ALevel;
end;

{ TMxAccessControl }

constructor TMxAccessControl.Create(ADeveloperId: Integer;
  const ADeveloperName: string; AIsAdmin: Boolean; AAclMode: TAclMode;
  AGlobalRole: TMxPermission; AConnection: TFDConnection; ALogger: IMxLogger);
begin
  inherited Create;
  FDeveloperId := ADeveloperId;
  FDeveloperName := ADeveloperName;
  FIsAdmin := AIsAdmin;
  FAclMode := AAclMode;
  FGlobalRole := AGlobalRole;
  FLogger := ALogger;
  FProjectAccess := TDictionary<Integer, TAccessLevel>.Create;
  LoadGlobalProjectId(AConnection);
  if not FIsAdmin then
    LoadPermissions(AConnection);
end;

destructor TMxAccessControl.Destroy;
begin
  FProjectAccess.Free;
  inherited;
end;

procedure TMxAccessControl.LoadGlobalProjectId(AConnection: TFDConnection);
var
  Qry: TFDQuery;
begin
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := AConnection;
    Qry.SQL.Text := 'SELECT id FROM projects WHERE slug = ''_global'' LIMIT 1';
    Qry.Open;
    if not Qry.IsEmpty then
      FGlobalProjectId := Qry.FieldByName('id').AsInteger
    else
      FGlobalProjectId := 0;
  finally
    Qry.Free;
  end;
end;

procedure TMxAccessControl.LoadPermissions(AConnection: TFDConnection);
var
  Qry: TFDQuery;
begin
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := AConnection;
    Qry.SQL.Text :=
      'SELECT project_id, access_level ' +
      'FROM developer_project_access ' +
      'WHERE developer_id = :dev_id';
    Qry.ParamByName('dev_id').AsInteger := FDeveloperId;
    Qry.Open;
    while not Qry.Eof do
    begin
      var ProjId := Qry.FieldByName('project_id').AsInteger;
      var LevelStr := Qry.FieldByName('access_level').AsString;
      // FR#2936/Plan#3266 M1.4: use StringToAccessLevel for 4-level hierarchy.
      // Unknown/legacy values default to alNone (safe default-deny).
      // Legacy 'write' is intentionally NOT recognised — sql/046 migration
      // is expected to have rewritten any legacy rows, but even without
      // migration, alNone is a safe fallback (DB columns post-migration use
      // 'none'|'comment'|'read'|'read-write').
      FProjectAccess.AddOrSetValue(ProjId, StringToAccessLevel(LevelStr));
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxAccessControl.EffectiveLevel(AProjLevel: TAccessLevel): TAccessLevel;
begin
  // FR#2936/Plan#3266 M1.4: MIN(GlobalRole cap, ProjectLevel) for 4-level hierarchy.
  // - mpRead caps effective at alReadOnly (prevents project-level elevation above global-read).
  // - mpReadWrite/mpAdmin: project-level wins (capped at project, which for admin is N/A since IsAdmin short-circuits earlier).
  // - If project-level is already <= alReadOnly (alNone/alComment/alReadOnly), keep project-level — caps don't downgrade.
  if (FGlobalRole = mpRead) and (Ord(AProjLevel) > Ord(alReadOnly)) then
    Result := alReadOnly
  else
    Result := AProjLevel;
end;

function TMxAccessControl.GetDeveloperId: Integer;
begin
  Result := FDeveloperId;
end;

function TMxAccessControl.GetDeveloperName: string;
begin
  Result := FDeveloperName;
end;

function TMxAccessControl.IsAdmin: Boolean;
begin
  Result := FIsAdmin;
end;

function TMxAccessControl.CheckProject(AProjectId: Integer;
  ALevel: TAccessLevel): Boolean;
var
  ProjLevel: TAccessLevel;
  Effective: TAccessLevel;
  LogData: TJSONObject;
begin
  // Admin bypasses all checks
  if FIsAdmin then
    Exit(True);

  // _global project: always accessible for all authenticated developers
  if (FGlobalProjectId > 0) and (AProjectId = FGlobalProjectId) then
    Exit(True);

  // Check if developer has any access to this project
  if not FProjectAccess.TryGetValue(AProjectId, ProjLevel) then
  begin
    // No access entry at all — effective = alNone.
    // Allow only if ALevel == alNone (trivial check).
    if ALevel = alNone then
      Exit(True);
    if FAclMode = amAudit then
    begin
      LogData := TJSONObject.Create;
      try
        LogData.AddPair('developer_id', TJSONNumber.Create(FDeveloperId));
        LogData.AddPair('developer', FDeveloperName);
        LogData.AddPair('project_id', TJSONNumber.Create(AProjectId));
        LogData.AddPair('required', AccessLevelToString(ALevel));
        LogData.AddPair('result', 'denied_no_access');
        if FLogger <> nil then
          FLogger.Log(mlWarning, 'AUDIT: access_denied', LogData);
      finally
        LogData.Free;
      end;
      Exit(True); // Audit mode: log but allow
    end;
    Exit(False);
  end;

  // Has access — 4-level ordered check via IsAtLeast (FR#2936/Plan#3266 M1.4).
  Effective := EffectiveLevel(ProjLevel);
  Result := IsAtLeast(Effective, ALevel);

  if (not Result) and (FAclMode = amAudit) then
  begin
    LogData := TJSONObject.Create;
    try
      LogData.AddPair('developer_id', TJSONNumber.Create(FDeveloperId));
      LogData.AddPair('developer', FDeveloperName);
      LogData.AddPair('project_id', TJSONNumber.Create(AProjectId));
      LogData.AddPair('required', AccessLevelToString(ALevel));
      LogData.AddPair('effective', AccessLevelToString(Effective));
      LogData.AddPair('result', 'denied_insufficient');
      if FLogger <> nil then
        FLogger.Log(mlWarning, 'AUDIT: access_denied', LogData);
    finally
      LogData.Free;
    end;
    Result := True; // Audit mode: log but allow
  end;
end;

function TMxAccessControl.GetAllowedProjectIds(
  ALevel: TAccessLevel): TArray<Integer>;
var
  Pair: TPair<Integer, TAccessLevel>;
  List: TList<Integer>;
begin
  // Admin: return empty array (means "all" — caller must handle)
  if FIsAdmin then
    Exit(nil);

  List := TList<Integer>.Create;
  try
    for Pair in FProjectAccess do
    begin
      // FR#2936/Plan#3266 M1.4: IsAtLeast applies the 4-level ordered comparison.
      if IsAtLeast(EffectiveLevel(Pair.Value), ALevel) then
        List.Add(Pair.Key);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

{ TMxNullAccessControl }

constructor TMxNullAccessControl.Create(ADeveloperId: Integer;
  const ADeveloperName: string; AIsAdmin: Boolean);
begin
  inherited Create;
  FDeveloperId := ADeveloperId;
  FDeveloperName := ADeveloperName;
  FIsAdmin := AIsAdmin;
end;

function TMxNullAccessControl.GetDeveloperId: Integer;
begin
  Result := FDeveloperId;
end;

function TMxNullAccessControl.GetDeveloperName: string;
begin
  Result := FDeveloperName;
end;

function TMxNullAccessControl.IsAdmin: Boolean;
begin
  Result := FIsAdmin;
end;

function TMxNullAccessControl.CheckProject(AProjectId: Integer;
  ALevel: TAccessLevel): Boolean;
begin
  Result := True; // No enforcement
end;

function TMxNullAccessControl.GetAllowedProjectIds(
  ALevel: TAccessLevel): TArray<Integer>;
begin
  Result := nil; // nil = all projects allowed
end;

// FR#2936/Plan#3266 M2.9: Draft-Filter X2 helper.
// Filters drafts when caller is exactly alReadOnly on the project. Caller
// with alComment+ on the project sees drafts (they may be reviewing them).
// Admins always see drafts. Non-project (AProjectId=0) callers must be admin
// to see anything cross-project; non-admin cross-project callers get FALSE
// here too — handlers should fall back to their own ACL check (or rely on
// per-doc ProjectId resolution and call this again).
function ShouldFilterDrafts(AContext: IMxDbContext;
  AProjectId: Integer): Boolean;
var
  ACL: IAccessControl;
begin
  ACL := AContext.AccessControl;
  if ACL.IsAdmin then Exit(False);
  if AProjectId <= 0 then Exit(False); // global scope handled per-doc by caller
  // Caller has alComment or higher on this project -> may see drafts.
  if ACL.CheckProject(AProjectId, alComment) then Exit(False);
  // Caller has at least alReadOnly (otherwise they would have failed earlier
  // ACL check) but NOT alComment -> exactly alReadOnly -> filter drafts.
  Result := ACL.CheckProject(AProjectId, alReadOnly);
end;

end.
