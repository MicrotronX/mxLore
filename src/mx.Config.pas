unit mx.Config;

interface

uses
  System.SysUtils, System.IniFiles, System.IOUtils, System.Win.Registry,
  System.Generics.Collections, System.Classes, Winapi.Windows, mx.Types;

type
  TMxConfig = class
  private
    // Database
    FDBHost: string;
    FDBPort: Integer;
    FDBDatabase: string;
    FDBUsername: string;
    FDBPassword: string;
    FVendorHome: string;
    // Server
    FBindAddress: string;
    FServerPort: Integer;
    FMaxConnections: Integer;
    FSetupVersion: string;
    // Limits
    FDefaultTokenBudget: Integer;
    FMaxResultRows: Integer;
    FSessionTimeoutMinutes: Integer;
    // Backup
    FBackupPath: string;
    FWarnAfterHours: Integer;
    // Security
    FAclMode: TAclMode;
    FAllowUrlApiKey: Boolean;
    // Admin
    FAdminPort: Integer;
    // Logging
    FLogFile: string;
    FLogLevel: string;
    // Prefetch
    FPrefetchSessionWindow: Integer;
    // AI Batch
    FAIEnabled: Boolean;
    FAIApiKey: string;
    FAIDefaultModel: string;
    FAIMaxCallsPerBoot: Integer;
    FAIMaxTokensPerBoot: Integer;
    FAISummaryEnabled: Boolean;
    FAITaggingEnabled: Boolean;
    FAIStaleDetectionEnabled: Boolean;
    FAIStubWarningEnabled: Boolean;
    FAIClaudeExePath: string;
    // Embedding / Semantic Search
    FEmbeddingApiKey: string;
    FEmbeddingEnabled: Boolean;
    FEmbeddingUrl: string;
    FEmbeddingModel: string;
    FEmbeddingDimensions: Integer;
    FEmbeddingMaxInputChars: Integer;
    FEmbeddingTimeoutMs: Integer;
    FEmbeddingDocTypes: string;
    FSemanticWeight: Double;
    FKeywordWeight: Double;
    FBatchIntervalMinutes: Integer;
    FEmbeddingBatchSize: Integer;
    // Identity
    FSelfSlug: string;
    // Fetch (mx_fetch tool — Build 85, ADR #2078; Bug#2866 redesign: caller-id whitelist)
    FFetchAllowedCallers: TArray<string>;
  public
    constructor Create(const AIniPath: string);

    // Database
    property DBHost: string read FDBHost;
    property DBPort: Integer read FDBPort;
    property DBDatabase: string read FDBDatabase;
    property DBUsername: string read FDBUsername;
    property DBPassword: string read FDBPassword;
    property VendorHome: string read FVendorHome;
    // Server
    property BindAddress: string read FBindAddress;
    property ServerPort: Integer read FServerPort;
    property MaxConnections: Integer read FMaxConnections;
    property SetupVersion: string read FSetupVersion;
    // Limits
    property DefaultTokenBudget: Integer read FDefaultTokenBudget;
    property MaxResultRows: Integer read FMaxResultRows;
    property SessionTimeoutMinutes: Integer read FSessionTimeoutMinutes;
    // Backup
    property BackupPath: string read FBackupPath;
    property WarnAfterHours: Integer read FWarnAfterHours;
    // Security
    property AclMode: TAclMode read FAclMode;
    property AllowUrlApiKey: Boolean read FAllowUrlApiKey;
    // Admin
    property AdminPort: Integer read FAdminPort;
    // Logging
    property LogFile: string read FLogFile;
    property LogLevel: string read FLogLevel;
    // Prefetch
    property PrefetchSessionWindow: Integer read FPrefetchSessionWindow;
    // AI Batch
    property AIEnabled: Boolean read FAIEnabled;
    property AIApiKey: string read FAIApiKey;
    property AIDefaultModel: string read FAIDefaultModel;
    property AIMaxCallsPerBoot: Integer read FAIMaxCallsPerBoot;
    property AIMaxTokensPerBoot: Integer read FAIMaxTokensPerBoot;
    property AISummaryEnabled: Boolean read FAISummaryEnabled;
    property AITaggingEnabled: Boolean read FAITaggingEnabled;
    property AIStaleDetectionEnabled: Boolean read FAIStaleDetectionEnabled;
    property AIStubWarningEnabled: Boolean read FAIStubWarningEnabled;
    property AIClaudeExePath: string read FAIClaudeExePath;
    // Embedding / Semantic Search
    property EmbeddingApiKey: string read FEmbeddingApiKey;
    property EmbeddingEnabled: Boolean read FEmbeddingEnabled;
    property EmbeddingUrl: string read FEmbeddingUrl;
    property EmbeddingModel: string read FEmbeddingModel;
    property EmbeddingDimensions: Integer read FEmbeddingDimensions;
    property EmbeddingMaxInputChars: Integer read FEmbeddingMaxInputChars;
    property EmbeddingTimeoutMs: Integer read FEmbeddingTimeoutMs;
    property EmbeddingDocTypes: string read FEmbeddingDocTypes;
    property SemanticWeight: Double read FSemanticWeight;
    property KeywordWeight: Double read FKeywordWeight;
    property BatchIntervalMinutes: Integer read FBatchIntervalMinutes;
    property EmbeddingBatchSize: Integer read FEmbeddingBatchSize;
    // Identity
    property SelfSlug: string read FSelfSlug;
    // Fetch (mx_fetch tool — Build 85, ADR #2078; Bug#2866 redesign: caller-id whitelist)
    property FetchAllowedCallers: TArray<string> read FFetchAllowedCallers;
  end;

function mxEncryptStaticString(const APlainText: string): string;
function mxDecryptStaticString(const AHexEncoded: string): string;
function mxAutoDetectMariaDB: string;

implementation

const
  XKEY = $A3;

function mxEncryptStaticString(const APlainText: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(APlainText) do
    Result := Result + IntToHex(Ord(APlainText[I]) xor XKEY, 2);
end;

function mxDecryptStaticString(const AHexEncoded: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I < Length(AHexEncoded) do
  begin
    Result := Result + Char(StrToInt('$' + Copy(AHexEncoded, I, 2)) xor XKEY);
    Inc(I, 2);
  end;
end;

function mxAutoDetectMariaDB: string;

  function FindDll(const ADir: string): Boolean;
  var
    LibDir: string;
  begin
    // Check lib\libmariadb.dll (64-bit, our target)
    LibDir := TPath.Combine(ADir, 'lib');
    if FileExists(TPath.Combine(LibDir, 'libmariadb.dll')) then
      Exit(True);
    Result := False;
  end;

var
  Reg: TRegistry;
  KeyNames: TStringList;
  ExeDir, RootPath, S, KeyName: string;
  Dirs: TArray<string>;
  I: Integer;
begin
  // 1. EXE directory (lib\libmariadb*.dll next to exe)
  ExeDir := ExtractFilePath(ParamStr(0));
  if FindDll(ExeDir) then
    Exit(ExeDir);

  // 2. Windows Registry — enumerate SOFTWARE looking for "MariaDB*" keys
  // MSI creates keys like "SOFTWARE\MariaDB 12.2 (x64)" with INSTALLDIR value
  try
    Reg := TRegistry.Create(KEY_READ);
    try
      Reg.RootKey := HKEY_LOCAL_MACHINE;
      for RootPath in ['SOFTWARE', 'SOFTWARE\WOW6432Node'] do
      begin
        if Reg.OpenKeyReadOnly(RootPath) then
        begin
          KeyNames := TStringList.Create;
          try
            Reg.GetKeyNames(KeyNames);
            Reg.CloseKey;
            KeyNames.Sort;
            for I := KeyNames.Count - 1 downto 0 do // newest first
            begin
              KeyName := KeyNames[I];
              if not KeyName.StartsWith('MariaDB', True) then
                Continue;
              if Reg.OpenKeyReadOnly(RootPath + '\' + KeyName) then
              begin
                if Reg.ValueExists('INSTALLDIR') then
                  S := Reg.ReadString('INSTALLDIR')
                else
                  S := '';
                Reg.CloseKey;
                if (S <> '') and FindDll(S) then
                  Exit(S);
              end;
            end;
          finally
            KeyNames.Free;
          end;
        end;
      end;
    finally
      Reg.Free;
    end;
  except
    // Registry not accessible (non-admin, GPO) — skip silently
  end;

  // 3. Common installation paths
  for S in [
    'C:\Program Files\MariaDB',
    'C:\Program Files (x86)\MariaDB',
    'D:\mariadb',
    'C:\mariadb'] do
  begin
    try
      if TDirectory.Exists(S) then
      begin
        // Check subdirectories (versioned: "MariaDB 12.2", "11.8" etc.)
        Dirs := TDirectory.GetDirectories(S);
        TArray.Sort<string>(Dirs);
        for I := High(Dirs) downto 0 do
          if FindDll(Dirs[I]) then
            Exit(Dirs[I]);
        // Direct check
        if FindDll(S) then
          Exit(S);
      end;
    except
      // Access denied on directory — skip
    end;
  end;

  // Not found
  Result := '';
end;

procedure AutoEncryptKey(AIni: TIniFile; const ASection, AKeyName, AEncKeyName: string);
var
  PlainVal, EncVal: string;
begin
  PlainVal := AIni.ReadString(ASection, AKeyName, '');
  EncVal := AIni.ReadString(ASection, AEncKeyName, '');
  if (PlainVal <> '') and (EncVal = '') then
  begin
    try
      AIni.WriteString(ASection, AEncKeyName, mxEncryptStaticString(PlainVal));
      AIni.WriteString(ASection, AKeyName, '');
      WriteLn('[Config] Auto-encrypted [', ASection, '] ', AKeyName, ' -> ', AEncKeyName);
    except
      on E: Exception do
        WriteLn('[Config] WARNING: Auto-encrypt failed for ', AKeyName, ': ', E.Message);
    end;
  end
  else if (PlainVal <> '') and (EncVal <> '') then
    WriteLn('[Config] WARNING: Both ', AKeyName, ' and ', AEncKeyName,
      ' set in [', ASection, '], using ', AEncKeyName);
end;

constructor TMxConfig.Create(const AIniPath: string);
var
  Ini: TIniFile;
begin
  inherited Create;

  if not FileExists(AIniPath) then
    raise Exception.CreateFmt('Config not found: %s', [AIniPath]);

  Ini := TIniFile.Create(AIniPath);
  try
    // Database
    FDBHost     := Ini.ReadString('Database', 'Host', 'localhost');
    FDBPort     := Ini.ReadInteger('Database', 'Port', 3306);
    FDBDatabase := Ini.ReadString('Database', 'Database', 'mxai_knowledge');
    FDBUsername  := Ini.ReadString('Database', 'Username', 'mxai_server');

    // Password: XOR-obfuscated in INI (PasswordEnc), fallback Klartext (Password)
    FDBPassword := mxDecryptStaticString(
      Ini.ReadString('Database', 'PasswordEnc', ''));
    if FDBPassword = '' then
      FDBPassword := Ini.ReadString('Database', 'Password', '');
    if FDBPassword = '' then
      raise Exception.Create('Database password not configured (PasswordEnc or Password in INI)');
    FVendorHome := Ini.ReadString('Database', 'VendorHome', '');
    if FVendorHome = '' then
      FVendorHome := mxAutoDetectMariaDB;
    if FVendorHome = '' then
      raise Exception.Create(
        'MariaDB client library (libmariadb.dll) not found.' + sLineBreak +
        'Set VendorHome in mxLoreMCP.ini or place lib\libmariadb.dll next to the exe.' + sLineBreak +
        'Download: https://mariadb.org/download/?t=connector&p=connector-c');

    // Server
    FBindAddress    := Ini.ReadString('Server', 'BindAddress', '127.0.0.1');
    FServerPort     := Ini.ReadInteger('Server', 'Port', 8080);
    FMaxConnections := Ini.ReadInteger('Server', 'MaxConnections', 10);
    FSetupVersion   := Ini.ReadString('Server', 'SetupVersion', '');
    FSelfSlug       := Ini.ReadString('Server', 'SelfSlug', 'mxLore');

    // Limits
    FDefaultTokenBudget   := Ini.ReadInteger('Limits', 'DefaultTokenBudget', 2000);
    FMaxResultRows        := Ini.ReadInteger('Limits', 'MaxResultRows', 50);
    FSessionTimeoutMinutes := Ini.ReadInteger('Limits', 'SessionTimeoutMinutes', 480);

    // Backup
    FBackupPath     := Ini.ReadString('Backup', 'BackupPath',
      ExtractFilePath(ParamStr(0)) + 'backups');
    FWarnAfterHours := Ini.ReadInteger('Backup', 'WarnAfterHours', 24);

    // Security
    FAclMode := TAclMode.FromString(
      Ini.ReadString('Security', 'developer_acl_mode', 'off'));
    FAllowUrlApiKey := Ini.ReadBool('Security', 'AllowUrlApiKey', False);

    // Admin
    FAdminPort := Ini.ReadInteger('Admin', 'admin_port', 0);

    // Logging
    FLogFile  := Ini.ReadString('Logging', 'LogFile', 'logs\mxLoreMCP.log');
    FLogLevel := Ini.ReadString('Logging', 'LogLevel', 'INFO');

    // Prefetch
    FPrefetchSessionWindow := Ini.ReadInteger('Prefetch', 'SessionWindow', 10);

    // AI Batch
    FAIEnabled := Ini.ReadBool('AI', 'Enabled', False);
    FAIApiKey := mxDecryptStaticString(
      Ini.ReadString('AI', 'ApiKeyEnc', ''));
    if FAIApiKey = '' then
      FAIApiKey := Ini.ReadString('AI', 'ApiKey', '');
    FAIDefaultModel := Ini.ReadString('AI', 'DefaultModel', 'claude-haiku-4-5-20251001');
    FAIMaxCallsPerBoot := Ini.ReadInteger('AI', 'MaxCallsPerBoot', 100);
    FAIMaxTokensPerBoot := Ini.ReadInteger('AI', 'MaxTokensPerBoot', 50000);
    FAISummaryEnabled := Ini.ReadBool('AI', 'SummaryEnabled', True);
    FAITaggingEnabled := Ini.ReadBool('AI', 'TaggingEnabled', True);
    FAIStaleDetectionEnabled := Ini.ReadBool('AI', 'StaleDetectionEnabled', True);
    FAIStubWarningEnabled := Ini.ReadBool('AI', 'StubWarningEnabled', True);
    FAIClaudeExePath := Ini.ReadString('AI', 'ClaudeExePath', 'claude');

    // Embedding / Semantic Search
    FEmbeddingApiKey := mxDecryptStaticString(
      Ini.ReadString('AI', 'EmbeddingApiKeyEnc', ''));
    if FEmbeddingApiKey = '' then
      FEmbeddingApiKey := Ini.ReadString('AI', 'EmbeddingApiKey', '');
    if FEmbeddingApiKey = '' then
      FEmbeddingApiKey := FAIApiKey;  // Fallback: use general AI key
    FEmbeddingEnabled := Ini.ReadBool('AI', 'EmbeddingEnabled', False);
    FEmbeddingUrl := Ini.ReadString('AI', 'EmbeddingUrl',
      'https://api.openai.com/v1/embeddings');
    FEmbeddingModel := Ini.ReadString('AI', 'EmbeddingModel',
      'text-embedding-3-small');
    FEmbeddingDimensions := Ini.ReadInteger('AI', 'EmbeddingDimensions', 1536);
    FEmbeddingMaxInputChars := Ini.ReadInteger('AI', 'EmbeddingMaxInputChars', 30000);
    FEmbeddingTimeoutMs := Ini.ReadInteger('AI', 'EmbeddingTimeoutMs', 30000);
    FEmbeddingDocTypes := Ini.ReadString('AI', 'EmbeddingDocTypes',
      'spec,plan,decision,lesson,note,reference,snippet,bugreport,feature_request,todo,assumption,skill');
    FSemanticWeight := StrToFloatDef(
      Ini.ReadString('AI', 'SemanticWeight', '0.4'), 0.4);
    FKeywordWeight := StrToFloatDef(
      Ini.ReadString('AI', 'KeywordWeight', '0.6'), 0.6);
    FBatchIntervalMinutes := Ini.ReadInteger('AI', 'BatchIntervalMinutes', 15);
    FEmbeddingBatchSize := Ini.ReadInteger('AI', 'EmbeddingBatchSize', 50);

    // Fetch (mx_fetch tool — Build 85, ADR #2078; Bug#2866 redesign)
    // Caller-identity allowlist (Bug#2866): caller_id is a self-declared string,
    // API-key auth remains primary security. Comma-separated, lowercase + trimmed.
    // Default empty = reject all calls until pinned manually.
    var LFetchCallers := Ini.ReadString('Fetch', 'AllowedCallers', '');
    var LRawList := TArray<string>(LFetchCallers.Split([',']));
    SetLength(FFetchAllowedCallers, Length(LRawList));
    var LIdx := 0;
    for var LCaller in LRawList do
    begin
      var LTrimmed := LCaller.Trim.ToLower;
      if LTrimmed <> '' then
      begin
        FFetchAllowedCallers[LIdx] := LTrimmed;
        Inc(LIdx);
      end;
    end;
    SetLength(FFetchAllowedCallers, LIdx);

    // Auto-encrypt: plaintext keys → encrypted, clear plaintext from INI
    AutoEncryptKey(Ini, 'Database', 'Password', 'PasswordEnc');
    AutoEncryptKey(Ini, 'AI', 'ApiKey', 'ApiKeyEnc');
    AutoEncryptKey(Ini, 'AI', 'EmbeddingApiKey', 'EmbeddingApiKeyEnc');
  finally
    Ini.Free;
  end;
end;

end.
