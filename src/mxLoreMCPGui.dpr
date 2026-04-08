program mxLoreMCPGui;

uses
  Winapi.Windows,
  System.SysUtils,
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
  mx.Logic.Projects      in 'mx.Logic.Projects.pas',
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

var
  Mutex: THandle;
begin
  // Single-Instance protection
  Mutex := CreateMutex(nil, True, 'Global\mxLoreMCPGui');
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    // Find existing instance by window caption
    var Wnd := FindWindow(nil, 'mxLoreMCP Server');
    if Wnd <> 0 then
    begin
      ShowWindow(Wnd, SW_RESTORE);
      SetForegroundWindow(Wnd);
    end;
    CloseHandle(Mutex);
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
