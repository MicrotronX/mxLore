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

const
  ACL_LEVEL_NAMES: array[TAccessLevel] of string = ('read', 'write');

{ EMxAccessDenied }

constructor EMxAccessDenied.Create(const AProjectSlug: string;
  ALevel: TAccessLevel);
begin
  inherited CreateFmt('No %s access to project ''%s''',
    [ACL_LEVEL_NAMES[ALevel], AProjectSlug]);
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
      if SameText(LevelStr, 'write') then
        FProjectAccess.AddOrSetValue(ProjId, alWrite)
      else
        FProjectAccess.AddOrSetValue(ProjId, alRead);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxAccessControl.EffectiveLevel(AProjLevel: TAccessLevel): TAccessLevel;
begin
  // Effective = Minimum(GlobalRole, ProjectLevel)
  // GlobalRole=read -> always read regardless of project assignment
  if FGlobalRole = mpRead then
    Result := alRead
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
    // No access entry at all
    if FAclMode = amAudit then
    begin
      LogData := TJSONObject.Create;
      try
        LogData.AddPair('developer_id', TJSONNumber.Create(FDeveloperId));
        LogData.AddPair('developer', FDeveloperName);
        LogData.AddPair('project_id', TJSONNumber.Create(AProjectId));
        LogData.AddPair('required', ACL_LEVEL_NAMES[ALevel]);
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

  // Has access — check level
  Effective := EffectiveLevel(ProjLevel);

  // Read requested: any access level suffices
  if ALevel = alRead then
    Exit(True);

  // Write requested: need effective write level
  Result := (Effective = alWrite);

  if (not Result) and (FAclMode = amAudit) then
  begin
    LogData := TJSONObject.Create;
    try
      LogData.AddPair('developer_id', TJSONNumber.Create(FDeveloperId));
      LogData.AddPair('developer', FDeveloperName);
      LogData.AddPair('project_id', TJSONNumber.Create(AProjectId));
      LogData.AddPair('required', ACL_LEVEL_NAMES[ALevel]);
      LogData.AddPair('effective', ACL_LEVEL_NAMES[Effective]);
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
      if ALevel = alRead then
        List.Add(Pair.Key) // Any access allows reading
      else if EffectiveLevel(Pair.Value) = alWrite then
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

end.
