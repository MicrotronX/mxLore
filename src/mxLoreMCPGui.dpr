program mxLoreMCPGui;

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  Vcl.Forms,
  // FireDAC drivers (must be in .dpr for static linking)
  FireDAC.Phys.MySQL,
  FireDAC.DApt,
  FireDAC.Stan.Async,
  {$IFDEF MSWINDOWS}
  FireDAC.VCLUI.Wait,  // WICHTIG: VCLUI statt ConsoleUI fuer VCL-App!
  {$ENDIF}
  // Project units
  mx.Types          in 'mx.Types.pas',
  mx.Errors         in 'mx.Errors.pas',
  mx.Config         in 'mx.Config.pas',
  mx.Log            in 'mx.Log.pas',
  mx.Data.Pool      in 'mx.Data.Pool.pas',
  mx.Data.Context   in 'mx.Data.Context.pas',
  mx.Auth           in 'mx.Auth.pas',
  mx.Crypto          in 'mx.Crypto.pas',
  mx.MCP.Schema     in 'mx.MCP.Schema.pas',
  mx.MCP.Protocol   in 'mx.MCP.Protocol.pas',
  mx.MCP.Server     in 'mx.MCP.Server.pas',
  mx.Tool.Registry  in 'mx.Tool.Registry.pas',
  mx.Tool.Read      in 'mx.Tool.Read.pas',
  mx.Tool.Write     in 'mx.Tool.Write.pas',
  mx.Tool.Write.Meta in 'mx.Tool.Write.Meta.pas',
  mx.Tool.Write.Batch in 'mx.Tool.Write.Batch.pas',
  mx.Tool.Recall    in 'mx.Tool.Recall.pas',
  mx.Tool.Session       in 'mx.Tool.Session.pas',
  mx.Logic.AccessControl in 'mx.Logic.AccessControl.pas',
  mx.Logic.AgentMessaging in 'mx.Logic.AgentMessaging.pas',
  mx.Logic.Projects      in 'mx.Logic.Projects.pas',
  mx.Logic.SelfUpdate    in 'mx.Logic.SelfUpdate.pas',
  mx.Admin.Api.SelfUpdate in 'mx.Admin.Api.SelfUpdate.pas',
  mx.Admin.Auth         in 'mx.Admin.Auth.pas',
  mx.Admin.Server       in 'mx.Admin.Server.pas',
  mx.Admin.Api.Auth     in 'mx.Admin.Api.Auth.pas',
  mx.Admin.Api.Developer in 'mx.Admin.Api.Developer.pas',
  mx.Admin.Api.Keys     in 'mx.Admin.Api.Keys.pas',
  mx.Admin.Api.Projects in 'mx.Admin.Api.Projects.pas',
  mx.Admin.Api.Global   in 'mx.Admin.Api.Global.pas',
  mx.Tool.Notes         in 'mx.Tool.Notes.pas',
  mx.Tool.Env           in 'mx.Tool.Env.pas',
  mx.Tool.Migrate       in 'mx.Tool.Migrate.pas',
  mx.Tool.Onboard       in 'mx.Tool.Onboard.pas',
  mx.Tool.ProjectRelation in 'mx.Tool.ProjectRelation.pas',
  mx.Data.SkillEvolution in 'mx.Data.SkillEvolution.pas',
  mx.Logic.SkillEvolution in 'mx.Logic.SkillEvolution.pas',
  mx.Tool.SkillEvolution in 'mx.Tool.SkillEvolution.pas',
  mx.Admin.Api.Skills in 'mx.Admin.Api.Skills.pas',
  mx.Server.Boot        in 'mx.Server.Boot.pas',
  mx.Server.Host        in 'mx.Server.Host.pas',
  frmMain               in 'frmMain.pas' {MainForm};

{$R *.res}

const
  // C4: 30s total budget with exponential backoff (300ms -> cap 2s). A
  // finish-update child must wait out the parent's ExitProcess + AlwaysUp
  // service teardown, which can exceed 4.5s on loaded servers. The 10x500ms
  // loop we shipped in Build 90 exhausted too early and left the GUI
  // running on the stale binary.
  MUTEX_BUDGET_MS = 30000;
  MUTEX_BACKOFF_START_MS = 300;
  MUTEX_BACKOFF_CAP_MS = 2000;
var
  Mutex: THandle;
  FinishZip: string;
  MutexElapsedMs: Cardinal;
  MutexBackoffMs: Cardinal;
  MutexStartTick: Cardinal;
begin
  // --finish-update=<zip>: child spawned by MxSelfUpdate_InstallAndRestart.
  // Runs the extraction BEFORE the mutex check (parent still holds it).
  // After FinishUpdate the child falls through to the normal mutex retry
  // loop; parent should be gone by then and the child acquires the mutex
  // cleanly, then runs Application.Run like a normal GUI launch.
  if FindCmdLineSwitch('finish-update', FinishZip, True, [clstValueNextParam]) then
  begin
    UpdateLog('GUI dpr: --finish-update detected, zip=' + FinishZip);
    try
      // C5: dpr runs before mx.Server.Boot LoadConfig, so gConfig is still
      // zero-init. MaxFinishRetries=0 would halt every retry. Load the INI
      // now so FinishUpdate sees the real retry budget.
      MxSelfUpdate_LoadConfig(ExtractFilePath(ParamStr(0)) + 'mxLoreMCP.ini');
      MxSelfUpdate_FinishUpdate(FinishZip);
      UpdateLog('GUI dpr: FinishUpdate returned normally');
    except
      on E: Exception do
      begin
        UpdateLog('GUI dpr: FinishUpdate raised ' + E.ClassName + ': ' + E.Message);
        // W6: persist error so next parent boot surfaces usError.
        MxSelfUpdate_WriteChildError(
          'GUI FinishUpdate raised ' + E.ClassName + ': ' + E.Message);
      end;
    end;
  end
  else if TFile.Exists(MarkerFilePath) then
  begin
    UpdateLog('GUI dpr: marker found without --finish-update, running recovery');
    try
      // C5: see above. Recovery path hits the same pre-LoadConfig window.
      MxSelfUpdate_LoadConfig(ExtractFilePath(ParamStr(0)) + 'mxLoreMCP.ini');
      var RecoveryMarker := ReadMarker(MarkerFilePath);
      MxSelfUpdate_FinishUpdate(RecoveryMarker.ZipPath);
      UpdateLog('GUI dpr: recovery FinishUpdate returned normally');
    except
      on E: Exception do
      begin
        UpdateLog('GUI dpr: recovery FinishUpdate raised ' + E.ClassName + ': ' + E.Message);
        // W6: persist error so next parent boot surfaces usError.
        MxSelfUpdate_WriteChildError(
          'GUI recovery FinishUpdate raised ' + E.ClassName + ': ' + E.Message);
      end;
    end;
  end;

  // C4: Single-Instance protection with 30s exp-backoff budget. A
  // finish-update child may boot seconds after the parent issued
  // ExitProcess — the parent + AlwaysUp service teardown can take
  // several seconds, so a short retry window loses the race and leaves
  // the GUI sitting on the stale binary.
  Mutex := 0;
  MutexBackoffMs := MUTEX_BACKOFF_START_MS;
  MutexStartTick := GetTickCount;
  while True do
  begin
    Mutex := CreateMutex(nil, True, 'Global\mxLoreMCPGui');
    if GetLastError <> ERROR_ALREADY_EXISTS then Break;
    CloseHandle(Mutex);
    Mutex := 0;
    MutexElapsedMs := GetTickCount - MutexStartTick;
    if MutexElapsedMs >= MUTEX_BUDGET_MS then Break;
    Sleep(MutexBackoffMs);
    MutexBackoffMs := MutexBackoffMs + (MutexBackoffMs div 2); // *1.5
    if MutexBackoffMs > MUTEX_BACKOFF_CAP_MS then
      MutexBackoffMs := MUTEX_BACKOFF_CAP_MS;
  end;
  if (Mutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    // C4: budget exhausted — drop the update.marker so the next boot
    // does not re-enter recovery and spin on the same stale state.
    UpdateLog('GUI dpr: mutex budget exhausted, removing update.marker');
    try
      if TFile.Exists(MarkerFilePath) then TFile.Delete(MarkerFilePath);
    except
      on E: Exception do
        UpdateLog('GUI dpr: marker cleanup failed: ' + E.Message);
    end;
    // Another instance holds the mutex — surface that window instead.
    var Wnd := FindWindow(nil, 'mxLoreMCP Server');
    if Wnd <> 0 then
    begin
      ShowWindow(Wnd, SW_RESTORE);
      SetForegroundWindow(Wnd);
    end;
    if Mutex <> 0 then CloseHandle(Mutex);
    Exit;
  end;
  try
    Application.Initialize;
    Application.MainFormOnTaskbar := False;
    Application.CreateForm(TfrmMain, MainForm);
    Application.Run;
  finally
    ReleaseMutex(Mutex);
    CloseHandle(Mutex);
  end;
end.
