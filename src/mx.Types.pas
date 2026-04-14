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

const
  MXAI_VERSION = '2.4.0';
  MXAI_BUILD   = 86;  // Bug#2228 Phase1: HandleInitProject ACL check on revive + _global reserved slug + auth-required + typed EFDDBEngineException.ekUKViolated race-fallback; Notes.pas retry-loop same pattern-fix (Plan#2233)
  MX_KEY_PREFIX = 'mxk_';
  MXAI_PROTOCOL = '2025-11-25';
  MXAI_SCHEMA_VERSION = '1.0.0';
  MXAI_CONNECTION_DEF = 'MXAI_KNOWLEDGE';

var
  MXAI_SETUP_VERSION: string;  // Set from INI at boot (Spec#1302)
  MXAI_ADMIN_PORT: Integer;    // Set from INI at boot (for mx_ping)

implementation

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
