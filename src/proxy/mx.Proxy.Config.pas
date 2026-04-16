unit mx.Proxy.Config;

interface

uses
  System.SysUtils, System.IniFiles, System.IOUtils;

type
  TMxProxyConfig = class
  private
    FServerUrl: string;
    FApiKey: string;
    FConnectionTimeout: Integer;
    FReadTimeout: Integer;
    FAgentPolling: Boolean;
    FAgentPollInterval: Integer;
    FInboxDir: string;
    FWorkDir: string;
    FLogLevel: string;
  public
    constructor Create(const AIniPath: string);
    class procedure WriteDefaultIni(const APath: string); static;
    property ServerUrl: string read FServerUrl;
    property ApiKey: string read FApiKey;
    property ConnectionTimeout: Integer read FConnectionTimeout;
    property ReadTimeout: Integer read FReadTimeout;
    property AgentPolling: Boolean read FAgentPolling;
    property AgentPollInterval: Integer read FAgentPollInterval;
    property InboxDir: string read FInboxDir;
    property WorkDir: string read FWorkDir;
    property LogLevel: string read FLogLevel;
  end;

implementation

constructor TMxProxyConfig.Create(const AIniPath: string);
var
  Ini: TIniFile;
begin
  inherited Create;
  if not FileExists(AIniPath) then
    raise Exception.CreateFmt('INI-Datei nicht gefunden: %s', [AIniPath]);

  Ini := TIniFile.Create(AIniPath);
  try
    FServerUrl := Ini.ReadString('Server', 'Url', '');
    FApiKey := Ini.ReadString('Server', 'ApiKey', '');
    FConnectionTimeout := Ini.ReadInteger('Server', 'ConnectionTimeout', 10000);
    FReadTimeout := Ini.ReadInteger('Server', 'ReadTimeout', 120000);
    FAgentPolling := Ini.ReadBool('Agent', 'Polling', False);
    FAgentPollInterval := Ini.ReadInteger('Agent', 'PollInterval', 15);
    if FAgentPollInterval < 5 then FAgentPollInterval := 5;
    // InboxDir: default = next to EXE + agent_inbox/
    FInboxDir := Ini.ReadString('Agent', 'InboxDir', '');
    if FInboxDir = '' then
      FInboxDir := ExtractFilePath(AIniPath) + 'agent_inbox';
    // WorkDir: override CWD for CLAUDE.md slug detection
    FWorkDir := Ini.ReadString('Agent', 'WorkDir', '');
    // LogLevel: 'info' (default, production-clean) or 'debug' (hot-path tracing for bug hunts)
    FLogLevel := Ini.ReadString('General', 'LogLevel', 'info');
  finally
    Ini.Free;
  end;
end;

class procedure TMxProxyConfig.WriteDefaultIni(const APath: string);
const
  DEFAULT_INI =
    '[Server]'#13#10 +
    '; URL of the mxLore MCP server'#13#10 +
    'Url=https://YOUR-SERVER/mxLore/mcp'#13#10 +
    '; API key for developer identification (from Admin UI)'#13#10 +
    'ApiKey=YOUR_API_KEY_HERE'#13#10 +
    '; TCP connection timeout in ms (Default: 10000)'#13#10 +
    'ConnectionTimeout=10000'#13#10 +
    '; Response/read timeout in ms (Default: 120000)'#13#10 +
    'ReadTimeout=120000'#13#10 +
    #13#10 +
    '[General]'#13#10 +
    '; Log verbosity. info=production-clean (startup+errors+warnings),'#13#10 +
    '; debug=hot-path tracing. Enable debug only for bug hunts.'#13#10 +
    'LogLevel=info'#13#10 +
    #13#10 +
    '[Agent]'#13#10 +
    '; Multi-agent messaging: proxy polls inbox and writes to file.'#13#10 +
    'Polling=1'#13#10 +
    '; Poll interval in seconds (Default: 15, Minimum: 5).'#13#10 +
    'PollInterval=15'#13#10;
begin
  TFile.WriteAllText(APath, DEFAULT_INI, TEncoding.ASCII);
end;

end.
