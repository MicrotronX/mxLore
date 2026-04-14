program mxLoreMCP;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.IOUtils,
  // FireDAC drivers (must be in .dpr for static linking)
  FireDAC.Phys.MySQL,
  FireDAC.DApt,
  FireDAC.Stan.Async,
  {$IFDEF MSWINDOWS}
  FireDAC.ConsoleUI.Wait,
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
  mx.Logic.SelfUpdate    in 'mx.Logic.SelfUpdate.pas',
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
  mx.Tool.Agent         in 'mx.Tool.Agent.pas',
  mx.Data.SkillEvolution in 'mx.Data.SkillEvolution.pas',
  mx.Logic.SkillEvolution in 'mx.Logic.SkillEvolution.pas',
  mx.Tool.SkillEvolution in 'mx.Tool.SkillEvolution.pas',
  mx.Admin.Api.Skills in 'mx.Admin.Api.Skills.pas',
  mx.Intelligence.Prefetch in 'mx.Intelligence.Prefetch.pas',
  mx.Server.Boot        in 'mx.Server.Boot.pas',
  mx.Server.Host        in 'mx.Server.Host.pas';

var
  Host: IMxServerHost;
  Boot: TMxServerBoot;
  ConfigPath: string;
begin
  try
    // --encrypt: XOR-obfuscate a password for INI (PasswordEnc / ApiKeyEnc)
    if (ParamCount >= 2) and SameText(ParamStr(1), '--encrypt') then
    begin
      WriteLn(mxEncryptStaticString(ParamStr(2)));
      Exit;
    end;

    // --self-test: run mx.Logic.SelfUpdate pure-logic tests and halt
    if (ParamCount >= 1) and SameText(ParamStr(1), '--self-test') then
    begin
      ExitCode := MxSelfUpdate_RunSelfTests;
      Exit;
    end;

    // --finish-update=<zip>: complete extraction after RotateLiveFilesToOld
    // (called by fresh spawn from MxSelfUpdate_InstallAndRestart, or auto-
    // detected via marker-file on plain boot if a prior attempt crashed).
    var FinishZip: string;
    if FindCmdLineSwitch('finish-update', FinishZip, True, [clstValueNextParam]) then
    begin
      try
        MxSelfUpdate_FinishUpdate(FinishZip);
      except
        on E: Exception do
          WriteLn(ErrOutput, 'finish-update failed: ', E.Message);
      end;
    end
    else if TFile.Exists(MarkerFilePath) then
    begin
      WriteLn(ErrOutput,
        '[WARN] Recovering from interrupted update (marker found)');
      try
        var RecoveryMarker := ReadMarker(MarkerFilePath);
        MxSelfUpdate_FinishUpdate(RecoveryMarker.ZipPath);
      except
        on E: Exception do
          WriteLn(ErrOutput, 'marker-recovery finish failed: ', E.Message);
      end;
    end;

    // Config path: same directory as exe, or first positional argument
    // (skip if first arg is a switch like --finish-update=...)
    if (ParamCount > 0) and (not ParamStr(1).StartsWith('--')) then
      ConfigPath := ParamStr(1)
    else
      ConfigPath := ExtractFilePath(ParamStr(0)) + 'mxLoreMCP.ini';

    Host := TMxConsoleHost.Create;
    Boot := TMxServerBoot.Create(ConfigPath, Host);
    try
      Boot.Run;
    finally
      Boot.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
