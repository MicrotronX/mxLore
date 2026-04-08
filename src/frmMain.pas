unit frmMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Generics.Collections, System.SyncObjs,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Menus,
  mx.Types, mx.Log, mx.Server.Boot, mx.Server.Host;

type
  TLogEntry = record
    Line: string;
    Color: TColor;
  end;

  TfrmMain = class(TForm, IMxServerHost)
    pnlStatus: TPanel;
    pnlButtons: TPanel;
    reLog: TRichEdit;
    lblStatus: TLabel;
    lblPorts: TLabel;
    lblUptime: TLabel;
    lblRequests: TLabel;
    btnStartStop: TButton;
    tmrUptime: TTimer;
    tmrLogFlush: TTimer;
    TrayIcon: TTrayIcon;
    pmTray: TPopupMenu;
    miShow: TMenuItem;
    miStartStop: TMenuItem;
    N1: TMenuItem;
    miExit: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure btnStartStopClick(Sender: TObject);
    procedure tmrUptimeTimer(Sender: TObject);
    procedure tmrLogFlushTimer(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
    procedure miShowClick(Sender: TObject);
    procedure miStartStopClick(Sender: TObject);
    procedure miExitClick(Sender: TObject);
  private
    FBoot: TMxServerBoot;
    FRunning: Boolean;
    FStartTime: TDateTime;
    FRequestCount: Integer;
    FShuttingDown: Boolean;
    FAutoStartDone: Boolean;
    FLogLock: TCriticalSection;
    FLogQueue: TList<TLogEntry>;
    // IMxServerHost
    procedure OnStarted(const APort, AAdminPort: Integer);
    procedure OnStopped;
    procedure OnLogEntry(const ATimestamp: TDateTime; ALevel: TMxLogLevel; const AMessage: string);
    procedure OnRequestHandled(const AToolName: string; AElapsedMs: Integer; ASuccess: Boolean);
    procedure OnError(const AMessage: string);
    function IsGUIMode: Boolean;
    // IInterface (non-refcounted on TForm)
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
    // Server management
    procedure StartServer;
    procedure StopServer;
    procedure DoShutdown;
  end;

var
  MainForm: TfrmMain;

implementation

{$R *.dfm}

{ IInterface — non-refcounted }

function TfrmMain._AddRef: Integer;
begin
  Result := -1;
end;

function TfrmMain._Release: Integer;
begin
  Result := -1;
end;

{ IMxServerHost }

function TfrmMain.IsGUIMode: Boolean;
begin
  Result := True;
end;

procedure TfrmMain.OnStarted(const APort, AAdminPort: Integer);
begin
  if FShuttingDown then Exit;
  TThread.Queue(nil,
    procedure
    begin
      FRunning := True;
      FStartTime := Now;
      FRequestCount := 0;
      lblStatus.Caption := 'Running';
      lblStatus.Font.Color := clGreen;
      if AAdminPort > 0 then
        lblPorts.Caption := Format('MCP: %d | Admin: %d', [APort, AAdminPort])
      else
        lblPorts.Caption := Format('MCP: %d', [APort]);
      lblRequests.Caption := 'Requests: 0';
      btnStartStop.Caption := 'Stop';
      btnStartStop.Enabled := True;
      tmrUptime.Enabled := True;
    end);
end;

procedure TfrmMain.OnStopped;
begin
  if FShuttingDown then Exit;
  TThread.Queue(nil,
    procedure
    begin
      FRunning := False;
      lblStatus.Caption := 'Stopped';
      lblStatus.Font.Color := clRed;
      btnStartStop.Caption := 'Start';
      btnStartStop.Enabled := True;
      tmrUptime.Enabled := False;
    end);
end;

procedure TfrmMain.OnLogEntry(const ATimestamp: TDateTime; ALevel: TMxLogLevel;
  const AMessage: string);
var
  Entry: TLogEntry;
begin
  if FShuttingDown then Exit;
  Entry.Line := FormatDateTime('hh:nn:ss', ATimestamp) + ' ' + AMessage;
  case ALevel of
    mlError, mlFatal: Entry.Color := clRed;
    mlWarning: Entry.Color := $000080FF;  // Orange (BGR)
  else
    Entry.Color := clGray;
  end;
  FLogLock.Enter;
  try
    FLogQueue.Add(Entry);
  finally
    FLogLock.Leave;
  end;
end;

procedure TfrmMain.OnRequestHandled(const AToolName: string;
  AElapsedMs: Integer; ASuccess: Boolean);
begin
  if FShuttingDown then Exit;
  TThread.Queue(nil,
    procedure
    begin
      Inc(FRequestCount);
      lblRequests.Caption := Format('Requests: %d', [FRequestCount]);
    end);
end;

procedure TfrmMain.OnError(const AMessage: string);
begin
  if FShuttingDown then Exit;
  TThread.Queue(nil,
    procedure
    begin
      lblStatus.Caption := 'Error';
      lblStatus.Font.Color := clRed;
      btnStartStop.Caption := 'Start';
      btnStartStop.Enabled := True;
    end);
  // Also log it
  OnLogEntry(Now, mlError, AMessage);
end;

{ Form events }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FShuttingDown := False;
  FRunning := False;
  FAutoStartDone := False;
  FLogLock := TCriticalSection.Create;
  FLogQueue := TList<TLogEntry>.Create;

    TrayIcon.Icon := Application.Icon;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FLogQueue.Free;
  FLogLock.Free;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if not FAutoStartDone then
  begin
    FAutoStartDone := True;
    StartServer;
  end;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if not FShuttingDown then
  begin
    // Minimize to tray instead of closing
    CanClose := False;
    Hide;
    TrayIcon.BalloonHint := 'mxLoreMCP laeuft im Hintergrund';
    TrayIcon.ShowBalloonHint;
  end;
  // FShuttingDown=True -> real close (via miExitClick)
end;

{ Server management }

procedure TfrmMain.StartServer;
var
  ConfigPath: string;
begin
  btnStartStop.Enabled := False;
  lblStatus.Caption := 'Starting...';
  lblStatus.Font.Color := clBlue;

  try
    if ParamCount > 0 then
      ConfigPath := ParamStr(1)
    else
      ConfigPath := ExtractFilePath(ParamStr(0)) + 'mxLoreMCP.ini';

    FBoot := TMxServerBoot.Create(ConfigPath, Self);

    // Register log observer for GUI live feed
    (FBoot.Logger as TStructuredLogger).OnLogEntry :=
      procedure(ATimestamp: TDateTime; ALevel: TMxLogLevel; AMsg: string)
      begin
        Self.OnLogEntry(ATimestamp, ALevel, AMsg);
      end;

    FBoot.Start;  // Direct on main thread — Sparkle is non-blocking
  except
    on E: Exception do
    begin
      FreeAndNil(FBoot);
      OnError('Server start failed: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.StopServer;
var
  Boot: TMxServerBoot;
begin
  if not Assigned(FBoot) then Exit;  // Idempotent
  btnStartStop.Enabled := False;
  lblStatus.Caption := 'Stopping...';
  lblStatus.Font.Color := clBlue;

  // Take ownership, nil immediately (lifecycle safety)
  Boot := FBoot;
  FBoot := nil;

  // Async stop to prevent GUI freeze
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        Boot.Stop;
      finally
        TThread.Queue(nil,
          procedure
          begin
            Boot.Free;
            if not FShuttingDown then
            begin
              // UI already updated by OnStopped callback
            end
            else
              Application.Terminate;
          end);
      end;
    end).Start;
end;

procedure TfrmMain.DoShutdown;
begin
  FShuttingDown := True;
  tmrLogFlush.Enabled := False;
  tmrUptime.Enabled := False;
  if FRunning then
    StopServer  // Async — Application.Terminate in callback
  else
    Application.Terminate;
end;

{ Button + TrayIcon events }

procedure TfrmMain.btnStartStopClick(Sender: TObject);
begin
  if FRunning then
    StopServer
  else
    StartServer;
end;

procedure TfrmMain.TrayIconDblClick(Sender: TObject);
begin
  Show;
  WindowState := wsNormal;
  ShowWindow(Handle, SW_SHOW);
  SetForegroundWindow(Handle);
end;

procedure TfrmMain.miShowClick(Sender: TObject);
begin
  TrayIconDblClick(Sender);
end;

procedure TfrmMain.miStartStopClick(Sender: TObject);
begin
  btnStartStopClick(Sender);
end;

procedure TfrmMain.miExitClick(Sender: TObject);
begin
  FShuttingDown := True;
  Application.Terminate;
end;

{ Timer events }

procedure TfrmMain.tmrUptimeTimer(Sender: TObject);
var
  Elapsed: TDateTime;
  H, M, S, MSec: Word;
begin
  if not FRunning then Exit;
  Elapsed := Now - FStartTime;
  DecodeTime(Elapsed, H, M, S, MSec);
  lblUptime.Caption := Format('Uptime: %d:%02d:%02d',
    [Trunc(Elapsed) * 24 + H, M, S]);
end;

procedure TfrmMain.tmrLogFlushTimer(Sender: TObject);
var
  Snapshot: TArray<TLogEntry>;
  I: Integer;
begin
  FLogLock.Enter;
  try
    if FLogQueue.Count = 0 then Exit;
    Snapshot := FLogQueue.ToArray;
    FLogQueue.Clear;
  finally
    FLogLock.Leave;
  end;

  reLog.Lines.BeginUpdate;
  try
    for I := 0 to High(Snapshot) do
    begin
      reLog.SelStart := Length(reLog.Text);
      reLog.SelLength := 0;
      reLog.SelAttributes.Color := Snapshot[I].Color;
      reLog.Lines.Add(Snapshot[I].Line);
    end;
    // Max 1000 lines
    while reLog.Lines.Count > 1000 do
      reLog.Lines.Delete(0);
  finally
    reLog.Lines.EndUpdate;
  end;
  // Auto-scroll
  SendMessage(reLog.Handle, WM_VSCROLL, SB_BOTTOM, 0);
end;

end.
