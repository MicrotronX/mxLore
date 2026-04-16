program mxMCPProxy;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  mx.Proxy.Log in 'mx.Proxy.Log.pas',
  mx.Proxy.Config in 'mx.Proxy.Config.pas',
  mx.Proxy.Http in 'mx.Proxy.Http.pas',
  mx.Proxy.Core in 'mx.Proxy.Core.pas';

const
  PROXY_VERSION = '1.0.5';

function GetExeDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  GetModuleFileName(0, Buf, Length(Buf));
  Result := ExtractFilePath(Buf);
end;

var
  Config: TMxProxyConfig;
  Proxy: TMxStdioProxy;
  IniPath: string;
begin
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);

  // Fix Delphi RTL: ReadLn/WriteLn use TextRec.CodePage, not Console CP.
  // Without this, piped stdin (from Claude Code) is read as Windows-1252.
  TTextRec(Input).CodePage := CP_UTF8;
  TTextRec(Output).CodePage := CP_UTF8;
  TTextRec(ErrOutput).CodePage := CP_UTF8;

  LogInit;
  Log('=== mxMCPProxy v' + PROXY_VERSION + ' startup ===');
  Log('[boot] ExePath: ' + ParamStr(0));
  Log('[boot] ExeDir: ' + GetExeDir);
  Log('[boot] CWD: ' + GetCurrentDir);
  Log('[boot] ParamCount: ' + IntToStr(ParamCount));

  // Force stdin pipe to blocking mode. Claude Code (Node.js/libuv) creates
  // the child stdin pipe in PIPE_NOWAIT mode; Delphi's RTL then reads 0 bytes
  // immediately and treats it as permanent EOF, causing ReadLn to hot-loop
  // returning '' after the initial handshake. Forcing PIPE_WAIT makes
  // ReadFile (and therefore ReadLn) block correctly until data arrives or
  // the pipe is actually closed.
  var StdinH: THandle := GetStdHandle(STD_INPUT_HANDLE);
  var PipeState: DWORD := 0;
  if GetNamedPipeHandleState(StdinH, @PipeState, nil, nil, nil, nil, 0) then
  begin
    Log('[boot] stdin pipe state (before): 0x' + IntToHex(PipeState, 8)
        + ' nowait=' + BoolToStr((PipeState and PIPE_NOWAIT) <> 0, True));
    PipeState := (PipeState and (not PIPE_NOWAIT)) or PIPE_WAIT or PIPE_READMODE_BYTE;
    if SetNamedPipeHandleState(StdinH, PipeState, nil, nil) then
      Log('[boot] stdin pipe forced to PIPE_WAIT: 0x' + IntToHex(PipeState, 8))
    else
      Log('[boot] SetNamedPipeHandleState FAILED: err=' + IntToStr(GetLastError));
  end
  else
    Log('[boot] GetNamedPipeHandleState failed (stdin not a named pipe? err='
        + IntToStr(GetLastError) + ') — assuming file/console, OK');

  try
    if ParamCount >= 1 then
      IniPath := ParamStr(1)
    else
      IniPath := GetExeDir + 'mxMCPProxy.ini';
    Log('[boot] IniPath: ' + IniPath);
    Log('[boot] IniPath exists: ' + BoolToStr(FileExists(IniPath), True));

    // First-run bootstrap: if no INI present, write a default template from
    // the embedded constant and exit so the user can edit it. No .example
    // file needed — the template lives in the code.
    if not FileExists(IniPath) then
    begin
      Log('[boot] First-run: ' + ExtractFileName(IniPath) + ' not found, writing default template.');
      TMxProxyConfig.WriteDefaultIni(IniPath);
      Log('[boot] First-run: wrote ' + IniPath);
      Log('[boot] First-run: Please edit ServerUrl and ApiKey, then restart.');
      ExitCode := 1;
      Exit;
    end;

    Config := TMxProxyConfig.Create(IniPath);
    try
      SetLogLevel(Config.LogLevel);
      Log('[boot] Config loaded. ServerUrl=' + Config.ServerUrl
          + ' ApiKey=' + Copy(Config.ApiKey, 1, 6) + '***'
          + ' AgentPolling=' + BoolToStr(Config.AgentPolling, True)
          + ' WorkDir=' + Config.WorkDir
          + ' InboxDir=' + Config.InboxDir
          + ' LogLevel=' + Config.LogLevel);

      if Config.ServerUrl = '' then
      begin
        Log('ERROR: ServerUrl nicht konfiguriert in ' + IniPath);
        ExitCode := 1;
        Exit;
      end;

      if Config.ApiKey = '' then
      begin
        Log('ERROR: ApiKey nicht konfiguriert in ' + IniPath);
        ExitCode := 1;
        Exit;
      end;

      Log('mxMCPProxy v' + PROXY_VERSION);
      Log('URL: ' + Config.ServerUrl);
      Log('Ready.');

      Log('[boot] Creating TMxStdioProxy...');
      Proxy := TMxStdioProxy.Create(Config);
      Log('[boot] TMxStdioProxy.Create returned OK');
      try
        Log('[boot] Entering Proxy.Run loop');
        Proxy.Run;
        Log('[boot] Proxy.Run returned (clean exit)');
      finally
        Log('[boot] Freeing Proxy...');
        Proxy.Free;
        Log('[boot] Proxy freed');
      end;
    finally
      Log('[boot] Freeing Config...');
      Config.Free;
      Log('[boot] Config freed');
    end;
  except
    on E: Exception do
    begin
      Log('FATAL: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
  Log('=== mxMCPProxy shutdown, ExitCode=' + IntToStr(ExitCode) + ' ===');
end.
