program mxMCPProxy;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  mx.Proxy.Config in 'mx.Proxy.Config.pas',
  mx.Proxy.Http in 'mx.Proxy.Http.pas',
  mx.Proxy.Core in 'mx.Proxy.Core.pas';

const
  PROXY_VERSION = '1.0.2';

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

  try
    if ParamCount >= 1 then
      IniPath := ParamStr(1)
    else
      IniPath := GetExeDir + 'mxMCPProxy.ini';

    Config := TMxProxyConfig.Create(IniPath);
    try
      if Config.ServerUrl = '' then
      begin
        WriteLn(ErrOutput, 'ERROR: ServerUrl nicht konfiguriert in ' + IniPath);
        ExitCode := 1;
        Exit;
      end;

      if Config.ApiKey = '' then
      begin
        WriteLn(ErrOutput, 'ERROR: ApiKey nicht konfiguriert in ' + IniPath);
        ExitCode := 1;
        Exit;
      end;

      WriteLn(ErrOutput, 'mxMCPProxy v' + PROXY_VERSION);
      WriteLn(ErrOutput, 'URL: ' + Config.ServerUrl);
      WriteLn(ErrOutput, 'Ready.');

      Proxy := TMxStdioProxy.Create(Config);
      try
        Proxy.Run;
      finally
        Proxy.Free;
      end;
    finally
      Config.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
