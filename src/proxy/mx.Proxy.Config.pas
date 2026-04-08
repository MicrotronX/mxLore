unit mx.Proxy.Config;

interface

uses
  System.SysUtils, System.IniFiles;

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
  public
    constructor Create(const AIniPath: string);
    property ServerUrl: string read FServerUrl;
    property ApiKey: string read FApiKey;
    property ConnectionTimeout: Integer read FConnectionTimeout;
    property ReadTimeout: Integer read FReadTimeout;
    property AgentPolling: Boolean read FAgentPolling;
    property AgentPollInterval: Integer read FAgentPollInterval;
    property InboxDir: string read FInboxDir;
    property WorkDir: string read FWorkDir;
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
  finally
    Ini.Free;
  end;
end;

end.
