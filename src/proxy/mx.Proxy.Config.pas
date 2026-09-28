unit mx.Proxy.Config;

interface

uses
  System.SysUtils, System.IniFiles, System.IOUtils;

const
  // Single source of truth for the proxy version. Lives in a UNIT, not in the
  // .dpr, so every unit can read it — the initialize handshake used to carry a
  // hardcoded literal that had drifted four releases behind, which made the
  // version the server sees useless for exactly the kind of proxy-version
  // diagnosis it is there for. Keep in sync with VerInfo_Keys in the .dproj.
  MXPROXY_VERSION = '1.0.11';

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

// Stable per-machine device id for the X-Device-Id header (Spec#17110).
// Stored in the user's LOCALAPPDATA, NOT next to the INI: a copied proxy
// folder must not carry the device id to another machine. Loaded once, then
// cached. Empty string when neither reading nor creating it worked — the
// header is then omitted and the server treats the request like an old proxy.
function MxProxyDeviceId: string;

implementation

uses
  Winapi.Windows, mx.Proxy.Log;

var
  GDeviceId: string;
  GDeviceIdLoaded: Boolean;

function MxProxyDeviceId: string;
var
  Dir, FileName, TmpName: string;
begin
  if GDeviceIdLoaded then
    Exit(GDeviceId);
  GDeviceIdLoaded := True;
  try
    Dir := TPath.Combine(System.SysUtils.GetEnvironmentVariable('LOCALAPPDATA'), 'mxLore');
    FileName := TPath.Combine(Dir, 'device.id');
    if not TFile.Exists(FileName) then
    begin
      ForceDirectories(Dir);
      // Write to a temp file and move it into place: the move fails when a
      // parallel proxy created device.id first, and both then read the winner.
      TmpName := FileName + '.' + IntToStr(GetCurrentProcessId) + '.tmp';
      TFile.WriteAllText(TmpName,
        LowerCase(TGUID.NewGuid.ToString.Trim(['{', '}'])), TEncoding.ASCII);
      try
        TFile.Move(TmpName, FileName);
      except
        TFile.Delete(TmpName);
      end;
    end;
    GDeviceId := Trim(TFile.ReadAllText(FileName, TEncoding.ASCII));
  except
    on E: Exception do
    begin
      GDeviceId := '';
      Log('WARN: device id unavailable: ' + E.Message);
    end;
  end;
  Result := GDeviceId;
end;

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
  // Load now, on the main thread, before the poll thread can race the cache.
  MxProxyDeviceId;
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
