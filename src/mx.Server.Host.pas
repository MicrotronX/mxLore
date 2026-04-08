unit mx.Server.Host;

interface

uses
  System.SysUtils, mx.Types;

type
  IMxServerHost = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    procedure OnStarted(const APort, AAdminPort: Integer);
    procedure OnStopped;
    procedure OnLogEntry(const ATimestamp: TDateTime; ALevel: TMxLogLevel; const AMessage: string);
    procedure OnRequestHandled(const AToolName: string; AElapsedMs: Integer; ASuccess: Boolean);
    procedure OnError(const AMessage: string);
    function IsGUIMode: Boolean;
  end;

  TMxConsoleHost = class(TInterfacedObject, IMxServerHost)
  public
    procedure OnStarted(const APort, AAdminPort: Integer);
    procedure OnStopped;
    procedure OnLogEntry(const ATimestamp: TDateTime; ALevel: TMxLogLevel; const AMessage: string);
    procedure OnRequestHandled(const AToolName: string; AElapsedMs: Integer; ASuccess: Boolean);
    procedure OnError(const AMessage: string);
    function IsGUIMode: Boolean;
  end;

implementation

{ TMxConsoleHost }

procedure TMxConsoleHost.OnStarted(const APort, AAdminPort: Integer);
begin
  WriteLn('mxLoreMCP v', MXAI_VERSION, ' running on port ', APort);
  if AAdminPort > 0 then
    WriteLn('Admin UI running on port ', AAdminPort);
  WriteLn('Press Ctrl+C to stop.');
end;

procedure TMxConsoleHost.OnStopped;
begin
  WriteLn('Server stopped.');
end;

procedure TMxConsoleHost.OnLogEntry(const ATimestamp: TDateTime; ALevel: TMxLogLevel;
  const AMessage: string);
begin
  // Console-Output wird von TStructuredLogger.FConsoleOutput gehandhabt.
  // Hier KEIN WriteLn — sonst doppeltes Logging.
end;

procedure TMxConsoleHost.OnRequestHandled(const AToolName: string;
  AElapsedMs: Integer; ASuccess: Boolean);
begin
  // Console braucht keinen Request-Counter
end;

procedure TMxConsoleHost.OnError(const AMessage: string);
begin
  // Nur fuer fatale Startup-Fehler (vor Logger-Initialisierung).
  // Runtime-Errors gehen ueber IMxLogger.
  WriteLn(ErrOutput, 'ERROR: ', AMessage);
end;

function TMxConsoleHost.IsGUIMode: Boolean;
begin
  Result := False;
end;

end.
