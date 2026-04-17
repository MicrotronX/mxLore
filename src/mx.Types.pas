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
  MXAI_BUILD   = 100;  // Build 100 (Session 264, FR#2936/Plan#3266 M2.7+M2.8+M2.9): M2.7 Token-Bucket 50 writes per 10h per developer (in-memory TDictionary+TCriticalSection in mx.Tool.Notes, applied to HandleCreateNote+HandleUpdateNote). M2.8 'promoted_from' relation-type added to mx.Tool.Write.Meta whitelist (Draft->Published transition via existing mx_add_relation). M2.9 Draft-Filter X2 — new ShouldFilterDrafts helper in mx.Logic.AccessControl filters draft docs from pure alReadOnly callers, applied to HandleDetail, HandleSearch (project+cross-project paths), HandleBriefing, HandleRecall. HandleGraphQuery deferred (graph_nodes don't expose linked-doc status). Builds 96-99 stay (M1+M2.1-M2.6).
  MX_KEY_PREFIX = 'mxk_';
  MXAI_PROTOCOL = '2025-11-25';
  MXAI_SCHEMA_VERSION = '1.0.0';
  MXAI_CONNECTION_DEF = 'MXAI_KNOWLEDGE';

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
