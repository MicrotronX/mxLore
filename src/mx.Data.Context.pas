unit mx.Data.Context;

interface

uses
  System.SysUtils,
  FireDAC.Stan.Intf, FireDAC.Comp.Client,
  mx.Types, mx.Log;

type
  /// Per-Request DB Context. Acquires a pooled connection on Create,
  /// returns it on Destroy. Thread-safe through FireDAC connection pooling.
  TMxDbContext = class(TInterfacedObject, IMxDbContext)
  private
    FConnection: TFDConnection;
    FAccessControl: IAccessControl;
    FAclMode: TAclMode;
    FAuthResult: TMxAuthResult;
    FLogger: IMxLogger;
    function GetAccessControl: IAccessControl;
    function GetLogger: IMxLogger;
  public
    constructor Create(const AConnectionDefName: string); overload;
    constructor Create(const AConnectionDefName: string;
      const AAuthResult: TMxAuthResult; AAclMode: TAclMode;
      ALogger: IMxLogger); overload;
    destructor Destroy; override;

    // IMxDbContext
    function CreateQuery(const ASQL: string): TFDQuery;
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    property AccessControl: IAccessControl read GetAccessControl;
    property Logger: IMxLogger read GetLogger;
  end;

implementation

uses
  mx.Logic.AccessControl;  // implementation-only: factory access for TMxAccessControl

constructor TMxDbContext.Create(const AConnectionDefName: string);
begin
  inherited Create;
  FConnection := TFDConnection.Create(nil);
  FConnection.ConnectionDefName := AConnectionDefName;
  FConnection.Connected := True;
  FAclMode := amOff;
  FAuthResult.Valid := False;
  FLogger := TMxNullLogger.Create;
end;

constructor TMxDbContext.Create(const AConnectionDefName: string;
  const AAuthResult: TMxAuthResult; AAclMode: TAclMode; ALogger: IMxLogger);
begin
  inherited Create;
  FConnection := TFDConnection.Create(nil);
  FConnection.ConnectionDefName := AConnectionDefName;
  FConnection.Connected := True;
  FAuthResult := AAuthResult;
  FAclMode := AAclMode;
  FLogger := ALogger;
end;

function TMxDbContext.GetLogger: IMxLogger;
begin
  Result := FLogger;
end;

function TMxDbContext.GetAccessControl: IAccessControl;
begin
  if FAccessControl = nil then
  begin
    if (FAclMode = amOff) or (not FAuthResult.Valid) then
      FAccessControl := TMxNullAccessControl.Create(
        FAuthResult.DeveloperId, FAuthResult.DeveloperName, FAuthResult.IsAdmin)
    else
      FAccessControl := TMxAccessControl.Create(
        FAuthResult.DeveloperId, FAuthResult.DeveloperName, FAuthResult.IsAdmin,
        FAclMode, FAuthResult.Permissions, FConnection, FLogger);
  end;
  Result := FAccessControl;
end;

destructor TMxDbContext.Destroy;
begin
  if Assigned(FConnection) then
  begin
    if FConnection.InTransaction then
      FConnection.Rollback;
    FConnection.Connected := False;
    FConnection.Free;
  end;
  inherited;
end;

function TMxDbContext.CreateQuery(const ASQL: string): TFDQuery;
begin
  Result := TFDQuery.Create(nil);
  Result.Connection := FConnection;
  Result.SQL.Text := ASQL;
  // CALL statements require text protocol - MariaDB binary protocol
  // rejects prepared CALL statements. DirectExecute uses COM_QUERY.
  // Note: NextRecordSet does NOT work with DirectExecute=True,
  // so multi-result SPs (sp_detail, sp_briefing) use separate queries.
  if ASQL.TrimLeft.StartsWith('CALL ', True) then
    Result.ResourceOptions.DirectExecute := True;
end;

procedure TMxDbContext.StartTransaction;
begin
  FConnection.StartTransaction;
end;

procedure TMxDbContext.Commit;
begin
  FConnection.Commit;
end;

procedure TMxDbContext.Rollback;
begin
  FConnection.Rollback;
end;

end.
