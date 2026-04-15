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

  TAccessLevel = (alRead, alWrite);

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

const
  MXAI_VERSION = '2.4.0';
  MXAI_BUILD   = 94;  // Build 94 (Session 248, WF-2026-04-15-007 Phase 3d): Bug#3011 mx_search since= param (ISO8601 date-only + AsDateTime bind) + Bug#3012 doc_type='skill' whitelist (4 sites + shared const) + Bug#3018 mx_update_doc destructive-write safety (append_content param + 50% length-gate with 12-keyword bypass + FOR UPDATE race-hardening) + Wave 2a quality fixes (relevance CASE skill branch, EmbeddingDocTypes, admin stats, NativeInt length math) + Wave 2b new tools (mx_doc_revisions + mx_get_revision) + Wave 2c whitelist consolidation (mx.Types.AllowedDocTypes).
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
