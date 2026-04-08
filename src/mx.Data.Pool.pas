unit mx.Data.Pool;

interface

uses
  System.SysUtils,
  FireDAC.Stan.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool,
  FireDAC.Phys.Intf, FireDAC.Comp.Client, FireDAC.Stan.Option,
  FireDAC.Phys.MySQL,
  mx.Types, mx.Config;

type
  TMxConnectionPool = class
  private
    FManager: TFDManager;
    FDriverLink: TFDPhysMySQLDriverLink;
    FConfig: TMxConfig;
  public
    constructor Create(AConfig: TMxConfig);
    destructor Destroy; override;
    function AcquireContext: IMxDbContext;
    function AcquireAuthContext(const AAuthResult: TMxAuthResult;
      ALogger: IMxLogger): IMxDbContext;
    function TestConnection: Boolean;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  FireDAC.ConsoleUI.Wait,
  {$ENDIF}
  mx.Data.Context;

constructor TMxConnectionPool.Create(AConfig: TMxConfig);
var
  ConnDef: IFDStanConnectionDef;
begin
  inherited Create;
  FConfig := AConfig;

  // MariaDB driver link (VendorLib + PluginDir)
  FDriverLink := TFDPhysMySQLDriverLink.Create(nil);
  FDriverLink.VendorHome := FConfig.VendorHome;
  FDriverLink.VendorLib := 'libmariadb.dll';

  FManager := TFDManager.Create(nil);

  // Register connection definition with pooling
  ConnDef := FManager.ConnectionDefs.AddConnectionDef;
  ConnDef.Name := MXAI_CONNECTION_DEF;
  ConnDef.Params.DriverID := 'MySQL';
  ConnDef.Params.Database := FConfig.DBDatabase;
  ConnDef.Params.UserName := FConfig.DBUsername;
  ConnDef.Params.Password := FConfig.DBPassword;
  ConnDef.Params.Values['Server'] := FConfig.DBHost;
  ConnDef.Params.Values['Port'] := IntToStr(FConfig.DBPort);
  ConnDef.Params.Values['CharacterSet'] := 'utf8mb4';

  // Pool configuration
  ConnDef.Params.Pooled := True;
  ConnDef.Params.Values['POOL_MaximumItems'] := IntToStr(FConfig.MaxConnections);
  ConnDef.Params.Values['POOL_ExpireTimeout'] := '600000';   // 10 min
  ConnDef.Params.Values['POOL_CleanupTimeout'] := '30000';   // 30 sec

  FManager.Active := True;
end;

destructor TMxConnectionPool.Destroy;
begin
  FManager.Active := False;
  FManager.Free;
  FDriverLink.Free;
  inherited;
end;

function TMxConnectionPool.AcquireContext: IMxDbContext;
begin
  Result := TMxDbContext.Create(MXAI_CONNECTION_DEF);
end;

function TMxConnectionPool.AcquireAuthContext(const AAuthResult: TMxAuthResult;
  ALogger: IMxLogger): IMxDbContext;
begin
  Result := TMxDbContext.Create(MXAI_CONNECTION_DEF, AAuthResult,
    FConfig.AclMode, ALogger);
end;

function TMxConnectionPool.TestConnection: Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := False;
  try
    Ctx := AcquireContext;
    Qry := Ctx.CreateQuery('SELECT 1');
    try
      Qry.Open;
      Result := not Qry.IsEmpty;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      WriteLn(ErrOutput, 'DB TestConnection error: ', E.ClassName, ': ', E.Message);
  end;
end;

end.
