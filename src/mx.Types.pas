unit mx.Types;

interface

uses
  System.SysUtils, System.JSON, FireDAC.Comp.Client;

type
  // --- Enums ---

  TMxLogLevel = (mlDebug, mlInfo, mlWarning, mlError, mlFatal);

  TMxDocType = (dtPlan, dtSpec, dtDecision, dtStatus, dtWorkflowLog,
                dtSessionNote, dtFinding, dtReference, dtSnippet);

  TMxDocStatus = (dsDraft, dsActive, dsCompleted, dsSuperseded,
                  dsDeprecated, dsDeleted);

  TMxPermission = (mpRead, mpReadWrite, mpAdmin);

  // FR#2936/ADR-3264: 4-level ordered hierarchy for User-Workspace ACL-Extension.
  // ORDERED — do not reorder. IsAtLeast() and DB <-> enum mapping rely on Ord().
  //
  // Semantics (ordered low->high):
  //   alNone      (0) : no access at all
  //   alReadOnly  (1) : can read, cannot write anything
  //   alComment   (2) : can read + create/edit notes (doc_type='note' only, M2+)
  //   alReadWrite (3) : full read + write on all doc types
  //
  // Key invariant (per ADR-3264 "reviewer can read + comment"):
  //   IsAtLeast(alComment, alReadOnly) = TRUE  -- commenter CAN read
  //   IsAtLeast(alReadWrite, alComment) = TRUE  -- writer CAN comment
  //   IsAtLeast(alReadOnly, alComment) = FALSE -- pure reader CANNOT comment
  //
  // Mapping: alNone='none' | alReadOnly='read' | alComment='comment' | alReadWrite='read-write'
  TAccessLevel = (alNone, alReadOnly, alComment, alReadWrite);

  TAclMode = (amOff, amAudit, amEnforce);

  // --- Interfaces ---

  IMxLogger = interface
    ['{B2C3D4E5-F6A7-4901-BCDE-F12345678901}']
    procedure Log(ALevel: TMxLogLevel; const AMsg: string;
                  AData: TJSONObject = nil);
  end;

  IAccessControl = interface
    ['{D4E5F6A7-B8C9-4123-DEFA-234567890ABC}']
    function GetDeveloperId: Integer;
    function GetDeveloperName: string;
    function IsAdmin: Boolean;
    function CheckProject(AProjectId: Integer; ALevel: TAccessLevel): Boolean;
    function GetAllowedProjectIds(ALevel: TAccessLevel): TArray<Integer>;
    // FR#2936/Plan#3266 M3.12 — TRUE when the ACL-lookup failed/timed out
    // during session setup; consumer auth layers cap effective access at
    // alReadOnly and may surface AR_DB_CHECK_DEGRADED.
    function IsDegraded: Boolean;
  end;

  IMxDbContext = interface
    ['{209081AD-E0DB-4A94-BA35-3C8FC102C8A8}']
    function CreateQuery(const ASQL: string): TFDQuery;
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function GetAccessControl: IAccessControl;
    property AccessControl: IAccessControl read GetAccessControl;
    function GetLogger: IMxLogger;
    property Logger: IMxLogger read GetLogger;
  end;

  TMxEventHandler = reference to procedure(const AEventType: string;
                                            const AData: TJSONObject);

  IMxEventBus = interface
    ['{C3D4E5F6-A7B8-4012-CDEF-123456789012}']
    procedure Publish(const AEventType: string; const AData: TJSONObject);
    procedure Subscribe(const AEventType: string; AHandler: TMxEventHandler);
  end;

  // --- Records ---

  TMxAuthResult = record
    Valid: Boolean;
    KeyId: Integer;
    KeyName: string;
    Permissions: TMxPermission;
    DeveloperId: Integer;
    DeveloperName: string;
    IsAdmin: Boolean;
    // FR#2936/Plan#3266 M3.11 — reason code for tool_call_log.auth_reason
    // (sql/049 step 5). Set by ValidateKey (AR_OK / AR_KEY_EXPIRED_GRACE /
    // default AR_KEY_INVALID on not-found). Pre-auth failure codes that
    // short-circuit before the INSERT path (AR_KEY_EXPIRED / AR_KEY_REVOKED)
    // DEFERRED to M3.11b (separate INSERT pipeline in mx.MCP.Server).
    AuthReason: string;
    // FR#2936/Plan#3266 M3.6b — request-context forensic capture, populated
    // by mx.MCP.Server after ValidateKey (X-Forwarded-For + User-Agent).
    // Consumed by HandleKeyRevoke (self-revoke) for revoke_ip/revoke_user_agent
    // so the Compromise-Playbook Forensik-Trio is complete on MCP path too
    // (Session 267 mxDesignChecker WARN#1 fix).
    RemoteIp: string;
    UserAgent: string;
    // FR#2936/Plan#3266 M3.4b — expiry horizon for X-Key-Expires-In header.
    // Copy of client_keys.expires_at (0 = no expiry set / unlimited key).
    // Populated by ValidateKey in both PBKDF2 and legacy paths.
    ExpiresAt: TDateTime;
  end;

  // FR#2936/Plan#3266 M1.5: Authorize-wrapper input/output records.
  // Future-slots (RateLimitBucket/AuditTag/RequestId) reserved for M3 work —
  // kept nullable/empty in v1 to avoid churn when M3 lands.
  TAuthContext = record
    CallerId: Integer;          // developer_id from MxGetThreadAuth
    Tool: string;               // MCP tool name, e.g. 'mx_search'
    ProjectId: Integer;         // 0 = global/no-project, >0 = specific project
    RequiredLevel: TAccessLevel; // min level resolved from Master-Map
    // Future-slots (M3, keep empty in M1):
    RateLimitBucket: string;
    AuditTag: string;
    RequestId: string;
  end;

  TAuthResult = record
    Allowed: Boolean;
    DenialReason: string;       // Human-readable, for logs + denial responses
    DenialCode: string;         // Short code, e.g. 'NO_ACCESS', 'WRONG_LEVEL', 'UNKNOWN_TOOL'
  end;

  // --- Tool Handler Type ---

  TMxToolHandler = reference to function(const AParams: TJSONObject;
                                          AContext: IMxDbContext): TJSONObject;

  // --- Null Implementations (Phase 1 stubs) ---

  TNullEventBus = class(TInterfacedObject, IMxEventBus)
  public
    procedure Publish(const AEventType: string; const AData: TJSONObject);
    procedure Subscribe(const AEventType: string; AHandler: TMxEventHandler);
  end;

  // --- Helper ---

  TMxDocTypeHelper = record helper for TMxDocType
    function ToString: string;
    class function FromString(const AValue: string): TMxDocType; static;
  end;

  TMxPermissionHelper = record helper for TMxPermission
    class function FromString(const AValue: string): TMxPermission; static;
  end;

  TAclModeHelper = record helper for TAclMode
    class function FromString(const AValue: string): TAclMode; static;
  end;

// --- Thread-local auth (set by HTTP layer, read by tool layer) ---
procedure MxSetThreadAuth(const AResult: TMxAuthResult);
function MxGetThreadAuth: TMxAuthResult;

// --- doc_type whitelist (Wave 2c: consolidates 4 parallel copies in
//     mx.Tool.Read/Write/Write.Batch that drifted twice — Bug#3012 + FAIL#7).
//     Single source of truth; add new doc_types HERE and nowhere else. ---
function IsAllowedDocType(const AValue: string): Boolean;

// --- TAccessLevel helpers (FR#2936/Plan#3266 M1.2-M1.3) ---
// IsAtLeast: ordered comparison; alReadWrite >= alReadOnly >= alComment >= alNone
function IsAtLeast(ACurrent, ARequired: TAccessLevel): Boolean;
// String <-> enum mapping. Unknown strings default to alNone (safe default-deny).
function StringToAccessLevel(const AValue: string): TAccessLevel;
function AccessLevelToString(ALevel: TAccessLevel): string;

const
  MXAI_VERSION = '2.4.0';
  MXAI_BUILD   = 106;
  // Build 106 (Session 270): Admin-UI Bundle — FR#3294 Intelligence Banner
  //   + FR#3472 A+B+C Thread-Viewer + FR#3600 Doc-Detail Tab-Layout
  //   + FR#3296 Settings-Tabs + FR#3610 Settings Control-Plane (INI-Editor
  //   mit 3-Tier classification: editable / read-only infra / secret).
  //   New endpoints: /api/intelligence/status, /api/docs/:id/thread,
  //   /api/projects/:id/reviews, /api/ini GET+PUT.
  // Build 105 (Session 268c): same-dev cross-project messaging fix —
  //   mx.Tool.Agent.HandleAgentInbox self-echo filter is now project-
  //   scoped (filters only within same project) instead of global. Previous
  //   global filter broke messaging between agents using the same developer_id
  //   across different Claude-Code sessions (e.g. mx-erp ↔ mx-erp-docs).
  //   Paired with mxMCPProxy 1.0.6 — FKnownIds persisted to disk so Proxy
  //   restarts do not re-write already-delivered IDs to the JSON file
  //   (fixes accumulation gap observed as 12-message-buildup in agent_inbox_
  //   mx-erp.json before a clean ack cycle completed).
  // Build 104 (Session 268b release-cut): FR#2936 M3 Follow-up Pack —
  //   FR#3504-#1 HandleUpdateKey clears last_warned_stage on expires_at renewal
  //   (prevents silent warning-suppression after role-change) +
  //   FR#3517-#2 Admin-rotate-foreign-key owner-notify via urgent agent_message
  //   (best-effort post-commit, rotation stays 201 even if notify fails) +
  //   FR#3517-#1 X-Key-Grace-Expires-In header during 24h grace-period
  //   (replaces X-Key-Expires-In which would be negative) +
  //   FR#3517-#4 Rotation Rollback-failure now logs mlWarning (ops visibility) +
  //   FR#3504-#3 Spec#3194 §I3 erratum appended (client_keys not developers).
  // Build 103 (Session 268 release-cut): FR#2936 Plan#3266 M3 KOMPLETT 12/12 —
  //   M3.4a Cadence-Writer boot-integrated + M3.4b X-Key-Expires-In HTTP-Header
  //   (3 auth-paths) + M3.5 atomic Rotation-API POST /api/keys/:id/rotate
  //   + M3.12 DB-Timeout Degraded-Mode (CmdExecTimeout=500ms, FDegraded flag,
  //   DenialCode='DB_DEGRADED') + M3.4c Emergency Recovery via doc#3473 Phase 7
  //   DB-direct (no CLI). Bug#3345 FireDAC .AsWideString migration across
  //   297 sites/33 units (ACP-triple-hop fixed, trip-wire-verified doc#3496).
  //   Checker-pass 0 CRIT, 5 inline fixes. FR#3504+FR#3517 track 9 follow-ups.
  // Build 102 (Session 265 release-cut): Bug#3348 NotifyRelatedProjects strip
  //   (ADR#3349 — Agent-Inbox only for explicit messages, cross-project
  //   doc_changed auto-broadcast removed). Bug#3350 HandleRevokeKey TOCTOU 409
  //   guard. Bug#3351 HandleUpdateKey expires_at realign per M3.3 role-defaults
  //   (admin/readwrite/read = 180/90/30d). FR#3352 M3.1 Dedup R1 60min filed
  //   as followup. 0/0/0 checker findings (2 WARN fixed inline).
  // Build 101 (Session 264, FR#2936/Plan#3266 M3 Bundles 1+2+3 partial):
  //   sql/049 schema + M3.1 asymmetric agent-messaging + M3.2 opt-out
  //   + M3.3 role-default expires_at + M3.4 Grace-Period + M3.6 Revocation
  //   + M3.7 Forensik + M3.8 active_prefix UNIQUE. M3.5 Rotation + M3.4 cadence
  //   + M3.9-M3.12 RFC7807/Degraded-Mode DEFERRED.
  MX_KEY_PREFIX = 'mxk_';
  MXAI_PROTOCOL = '2025-11-25';
  MXAI_SCHEMA_VERSION = '1.0.0';
  MXAI_CONNECTION_DEF = 'MXAI_KNOWLEDGE';

  // FR#2936/Plan#3266 M3.11 — reason codes for tool_call_log.auth_reason
  // VARCHAR(32) NULL (sql/049 step 5). Realigned with Spec#3194 v3 §I9
  // (Session 267 mxDesignChecker WARN#3). Single source of truth — handlers
  // and auth layers MUST reuse these consts, no ad-hoc string literals.
  // AR_OK is an M3.11-implicit success marker (not in Spec §I9 enum, kept for
  // log completeness). All others map 1:1 to §I9 code names.
  AR_OK                      = 'ok';
  AR_KEY_INVALID             = 'key_invalid';
  AR_KEY_EXPIRED             = 'key_expired';
  AR_KEY_EXPIRED_GRACE       = 'key_expired_grace';
  AR_KEY_REVOKED             = 'key_revoked';
  AR_ROLE_INSUFFICIENT       = 'role_insufficient';
  AR_PROJECT_NOT_ASSIGNED    = 'project_not_assigned';
  AR_WRITE_SCOPE_VIOLATION   = 'write_scope_violation';
  AR_TOOL_NOT_WHITELISTED    = 'tool_not_whitelisted';
  AR_RATE_LIMITED            = 'rate_limited';
  AR_UI_LOGIN_DISABLED       = 'ui_login_disabled';
  AR_UI_LOGIN_LOCKED         = 'ui_login_locked';
  AR_MSG_DUPLICATE           = 'msg_duplicate';
  AR_RECIPIENT_OPT_OUT       = 'recipient_opt_out';
  AR_DB_CHECK_DEGRADED       = 'db_check_degraded';
  // Reserved: never emitted by current code. M3.5 rotation is single-tx
  // (all-or-nothing, no orphan state, no boot-reconcile pass). Kept as a
  // forward-slot in case the design ever moves to two-phase.
  AR_ROTATION_CRASH_RECOVERED = 'rotation_crash_recovered';
  AR_BREAK_GLASS_USED        = 'break_glass_used';

var
  MXAI_SETUP_VERSION: string;  // Set from INI at boot (Spec#1302)
  MXAI_ADMIN_PORT: Integer;    // Set from INI at boot (for mx_ping)

implementation

const
  // Wave 2c: single source of truth for doc_type whitelist.
  // Previously duplicated in mx.Tool.Read (mx_search),
  // mx.Tool.Write (mx_create_doc + mx_update_doc) and
  // mx.Tool.Write.Batch (mx_batch_create). Drifted twice
  // (Bug#3012 initial + FAIL#7 batch-path follow-up).
  cAllowedDocTypes: array[0..15] of string = (
    'plan', 'spec', 'decision', 'status',
    'workflow_log', 'session_note', 'finding', 'reference',
    'snippet', 'note', 'bugreport', 'feature_request',
    'todo', 'assumption', 'lesson', 'skill'
  );

function IsAllowedDocType(const AValue: string): Boolean;
var
  I: Integer;
begin
  for I := Low(cAllowedDocTypes) to High(cAllowedDocTypes) do
    if cAllowedDocTypes[I] = AValue then
      Exit(True);
  Result := False;
end;

{ TAccessLevel helpers (FR#2936/Plan#3266 M1.2-M1.3) }

function IsAtLeast(ACurrent, ARequired: TAccessLevel): Boolean;
begin
  Result := Ord(ACurrent) >= Ord(ARequired);
end;

function StringToAccessLevel(const AValue: string): TAccessLevel;
begin
  if SameText(AValue, 'read-write') then Result := alReadWrite
  else if SameText(AValue, 'read') then Result := alReadOnly
  else if SameText(AValue, 'comment') then Result := alComment
  else if SameText(AValue, 'none') then Result := alNone
  // Legacy belt-and-suspenders: pre-FR#2936 DB rows used 'write' which sql/046
  // migrates to 'read-write' at boot. This alias guards against drift from
  // manual inserts or migration failure — lets legacy 'write' map to alReadWrite
  // instead of silently default-denying (alNone) and locking out the dev.
  else if SameText(AValue, 'write') then Result := alReadWrite
  else Result := alNone; // Unknown => default-deny (alNone)
end;

function AccessLevelToString(ALevel: TAccessLevel): string;
begin
  case ALevel of
    alReadWrite: Result := 'read-write';
    alReadOnly:  Result := 'read';
    alComment:   Result := 'comment';
    alNone:      Result := 'none';
  else
    Result := 'none';
  end;
end;

{ TNullEventBus }

procedure TNullEventBus.Publish(const AEventType: string;
  const AData: TJSONObject);
begin
  // Phase 1: No-op
end;

procedure TNullEventBus.Subscribe(const AEventType: string;
  AHandler: TMxEventHandler);
begin
  // Phase 1: No-op
end;

{ TMxDocTypeHelper }

function TMxDocTypeHelper.ToString: string;
const
  Names: array[TMxDocType] of string = (
    'plan', 'spec', 'decision', 'status', 'workflow_log',
    'session_note', 'finding', 'reference', 'snippet');
begin
  Result := Names[Self];
end;

class function TMxDocTypeHelper.FromString(const AValue: string): TMxDocType;
var
  DT: TMxDocType;
begin
  for DT := Low(TMxDocType) to High(TMxDocType) do
    if SameText(DT.ToString, AValue) then
      Exit(DT);
  raise Exception.CreateFmt('Unknown doc_type: %s', [AValue]);
end;

{ TMxPermissionHelper }

class function TMxPermissionHelper.FromString(const AValue: string): TMxPermission;
begin
  if SameText(AValue, 'admin') then Result := mpAdmin
  else if SameText(AValue, 'readwrite') then Result := mpReadWrite
  else Result := mpRead;
end;

{ TAclModeHelper }

class function TAclModeHelper.FromString(const AValue: string): TAclMode;
begin
  if SameText(AValue, 'audit') then Result := amAudit
  else if SameText(AValue, 'enforce') then Result := amEnforce
  else Result := amOff;
end;

{ Thread-local auth context }

threadvar
  GThreadAuth: TMxAuthResult;

procedure MxSetThreadAuth(const AResult: TMxAuthResult);
begin
  GThreadAuth := AResult;
end;

function MxGetThreadAuth: TMxAuthResult;
begin
  Result := GThreadAuth;
end;

end.
