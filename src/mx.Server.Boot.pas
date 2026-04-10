unit mx.Server.Boot;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}
  mx.Types, mx.Config, mx.Log, mx.Data.Pool, mx.Auth,
  mx.MCP.Schema, mx.MCP.Server, mx.Tool.Registry, mx.Admin.Server,
  mx.Server.Host, mx.Intelligence.Prefetch, mx.Intelligence.AIBatch,
  mx.Intelligence.Embedding, mx.Intelligence.HybridSearch;

type
  TMxServerBoot = class
  private
    FConfig: TMxConfig;
    FLogger: IMxLogger;
    FPool: TMxConnectionPool;
    FAuth: TMxAuthManager;
    FRegistry: TMxMcpRegistry;
    FMcpServer: TMxMcpServer;
    FEventBus: IMxEventBus;
    FAdminServer: TMxAdminServer;
    FShutdownEvent: TEvent;
    FHost: IMxServerHost;
    FConsoleHandlerRegistered: Boolean;
    FAIBatch: TMxAIBatchRunner;
    procedure EnsureDatabase;
    procedure RunAutoSchema;
    procedure RunDiagnostics;
    procedure RunAutoCleanup;
    procedure RunAutoBackup;
    procedure SetupServer;
    procedure SetupShutdownHandler;
  public
    constructor Create(const AConfigPath: string; AHost: IMxServerHost = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure Run;
    property Logger: IMxLogger read FLogger;
  end;

implementation

uses
  System.IOUtils, System.DateUtils, System.Types,
  FireDAC.Comp.Client, FireDAC.Phys.MySQL,
  mx.Admin.Api.Global;

var
  GShutdownEvent: TEvent = nil;

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  Result := False;
  case CtrlType of
    CTRL_C_EVENT,
    CTRL_CLOSE_EVENT,
    CTRL_SHUTDOWN_EVENT:
    begin
      if Assigned(GShutdownEvent) then
        GShutdownEvent.SetEvent;
      Result := True;
    end;
  end;
end;
{$ENDIF}

{ TMxServerBoot }

constructor TMxServerBoot.Create(const AConfigPath: string; AHost: IMxServerHost);
var
  BasePath, IniPath: string;
  Defaults: TStringList;
begin
  inherited Create;
  FConsoleHandlerRegistered := False;

  // Host-Abstraktion (Console als Default)
  if Assigned(AHost) then
    FHost := AHost
  else
    FHost := TMxConsoleHost.Create;

  // 0. Auto-Bootstrap: ensure directories exist
  BasePath := ExtractFilePath(ParamStr(0));
  ForceDirectories(BasePath + 'logs');

  // Generate default INI if missing
  IniPath := AConfigPath;
  if not FileExists(IniPath) then
  begin
    Defaults := TStringList.Create;
    try
      Defaults.Add('; mxLore MCP Server — Configuration');
      Defaults.Add('; Generated on first start. Please adjust and restart.');
      Defaults.Add(';');
      Defaults.Add('; Quick-Start: set Password and run mxLoreMCP.exe');
      Defaults.Add('; Full docs: https://www.mxlore.dev');
      Defaults.Add('');
      Defaults.Add('[Database]');
      Defaults.Add('Host=localhost');
      Defaults.Add('Port=3306');
      Defaults.Add('Database=mxai_knowledge');
      Defaults.Add('Username=root');
      Defaults.Add('; Password: plain text (simplest setup)');
      Defaults.Add('Password=');
      Defaults.Add('; PasswordEnc: XOR-obfuscated (optional, run: mxLoreMCP.exe --encrypt "pw")');
      Defaults.Add(';PasswordEnc=');
      Defaults.Add('; VendorHome: path to MariaDB (auto-detected from registry/common paths)');
      Defaults.Add('; Only set if auto-detection fails.');
      Defaults.Add(';VendorHome=');
      Defaults.Add('');
      Defaults.Add('[Server]');
      Defaults.Add('; 127.0.0.1 = localhost only. Change to 0.0.0.0 for LAN access.');
      Defaults.Add('BindAddress=127.0.0.1');
      Defaults.Add('Port=8080');
      Defaults.Add('MaxConnections=10');
      Defaults.Add('; SelfSlug: this server''s project name in the DB (auto-created on boot)');
      Defaults.Add('SelfSlug=mxLore');
      Defaults.Add('');
      Defaults.Add('[Limits]');
      Defaults.Add('DefaultTokenBudget=2000');
      Defaults.Add('MaxResultRows=50');
      Defaults.Add('SessionTimeoutMinutes=480');
      Defaults.Add('');
      Defaults.Add('[Backup]');
      Defaults.Add('; BackupPath: default is backups\ in exe directory');
      Defaults.Add(';BackupPath=');
      Defaults.Add('WarnAfterHours=24');
      Defaults.Add('');
      Defaults.Add('[Security]');
      Defaults.Add('; off = no ACL, audit = log violations, enforce = block unauthorized');
      Defaults.Add('developer_acl_mode=enforce');
      Defaults.Add('');
      Defaults.Add('[Admin]');
      Defaults.Add('; Admin UI port (0 = disabled). Open http://localhost:<port> to manage.');
      Defaults.Add('admin_port=8081');
      Defaults.Add('');
      Defaults.Add('[Logging]');
      Defaults.Add('LogFile=logs\mxLoreMCP.log');
      Defaults.Add('LogLevel=INFO');
      Defaults.SaveToFile(IniPath, TEncoding.UTF8);
    finally
      Defaults.Free;
    end;
    // Log to file (works in all modes: console, GUI, service)
    var Msg := 'Config generated: ' + IniPath + sLineBreak +
               'Please set the database password in the INI file and restart.' + sLineBreak +
               'Docs: https://www.mxlore.dev';
    TFile.WriteAllText(BasePath + 'FIRST-START-README.txt', Msg, TEncoding.UTF8);
    // Console output only if not GUI/service
    if not FHost.IsGUIMode then
    begin
      WriteLn('Config generated: ', IniPath);
      WriteLn('Please set database password and restart.');
    end;
    raise Exception.Create('First start: INI generated. Set password and restart. See FIRST-START-README.txt');
  end;

  // 0. FormatSettings auf ISO setzen (FireDAC nutzt System-Locale fuer DateTime-Parsing)
  // MariaDB liefert DATETIME als "YYYY-MM-DD HH:MM:SS" — muss korrekt geparst werden
  FormatSettings.ShortDateFormat := 'yyyy-mm-dd';
  FormatSettings.DateSeparator := '-';
  FormatSettings.TimeSeparator := ':';
  FormatSettings.LongTimeFormat := 'hh:nn:ss';

  // 1. Configuration
  FConfig := TMxConfig.Create(AConfigPath);
  MXAI_SETUP_VERSION := FConfig.SetupVersion;
  MXAI_ADMIN_PORT := FConfig.AdminPort;

  // 2. Logger (ConsoleOutput=False im GUI-Modus — kein Console-Handle)
  FLogger := TStructuredLogger.Create(FConfig.LogFile, FConfig.LogLevel,
    not FHost.IsGUIMode);
  FLogger.Log(mlInfo, 'mxLoreMCP v' + MXAI_VERSION + ' starting');

  // 3. Database: auto-create if missing, then connect pool
  FLogger.Log(mlDebug, 'DB connecting to ' + FConfig.DBHost + ':' +
    IntToStr(FConfig.DBPort) + '/' + FConfig.DBDatabase +
    ' as ' + FConfig.DBUsername +
    ' (pwd length: ' + IntToStr(Length(FConfig.DBPassword)) + ')');
  try
    // First: connect without database to check/create
    EnsureDatabase;
    // Then: connect pool to the actual database
    FPool := TMxConnectionPool.Create(FConfig);
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, 'DB connection FAILED: ' + E.Message);
      FLogger.Log(mlError, 'Check mxLoreMCP.ini:');
      FLogger.Log(mlError, '  [Database] Host=' + FConfig.DBHost +
        ' Port=' + IntToStr(FConfig.DBPort) +
        ' Database=' + FConfig.DBDatabase +
        ' Username=' + FConfig.DBUsername);
      FLogger.Log(mlError, '  VendorHome=' + FConfig.VendorHome +
        ' (must contain libmariadb.dll)');
      raise;
    end;
  end;
  FLogger.Log(mlDebug, 'Database pool initialized');

  // 4. Auth manager
  FAuth := TMxAuthManager.Create(FPool);

  // 5. Event bus (null implementation for Phase 1)
  FEventBus := TNullEventBus.Create;

  // 5b. Auto-schema: detect empty DB and run setup.sql
  RunAutoSchema;

  // 5b2. Auto-migrate: apply pending migrations (column detection)
  try
    var MigCtx := FPool.AcquireContext;
    try
      // sql/043: embedding VECTOR column
      var MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.columns ' +
        'WHERE table_schema = :db AND table_name = ''documents'' ' +
        'AND column_name = ''embedding''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: applying sql/043 (embedding VECTOR column)');
          var MigPath := ExtractFilePath(ParamStr(0)) + 'sql' + PathDelim +
            '043-embedding-vector.sql';
          if FileExists(MigPath) then
          begin
            // Direct DDL — no mysql CLI needed for simple ALTER/CREATE
            var DdlQry := MigCtx.CreateQuery(
              'ALTER TABLE documents ADD COLUMN embedding VECTOR(1536) DEFAULT NULL');
            try DdlQry.ExecSQL; finally DdlQry.Free; end;
            DdlQry := MigCtx.CreateQuery(
              'ALTER TABLE documents ADD COLUMN embedding_stale TINYINT(1) NOT NULL DEFAULT 1');
            try DdlQry.ExecSQL; finally DdlQry.Free; end;
            DdlQry := MigCtx.CreateQuery(
              'CREATE INDEX idx_embedding_stale ON documents (embedding_stale, doc_type)');
            try DdlQry.ExecSQL; finally DdlQry.Free; end;
            FLogger.Log(mlInfo, 'Auto-migrate: sql/043 columns + index applied');
            // Triggers via mysql CLI (DELIMITER not supported in FireDAC)
            FLogger.Log(mlInfo, 'Auto-migrate: triggers must be applied manually: ' +
              'mysql < sql/043-embedding-vector.sql');
          end
          else
            FLogger.Log(mlWarning, 'Auto-migrate: sql/043 file not found at ' + MigPath);
        end;
      finally
        MigQry.Free;
      end;

      // sql/044: tool_call_log table
      MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.tables ' +
        'WHERE table_schema = :db AND table_name = ''tool_call_log''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: creating tool_call_log table (sql/044)');
          var DdlQry := MigCtx.CreateQuery(
            'CREATE TABLE IF NOT EXISTS tool_call_log (' +
            '  id BIGINT NOT NULL AUTO_INCREMENT, ' +
            '  tool_name VARCHAR(50) NOT NULL, ' +
            '  session_id INT DEFAULT NULL, ' +
            '  developer_id INT DEFAULT NULL, ' +
            '  response_bytes INT NOT NULL DEFAULT 0, ' +
            '  latency_ms INT NOT NULL DEFAULT 0, ' +
            '  is_error TINYINT(1) NOT NULL DEFAULT 0, ' +
            '  error_code VARCHAR(30) DEFAULT NULL, ' +
            '  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3), ' +
            '  PRIMARY KEY (id), ' +
            '  KEY idx_tcl_tool (tool_name), ' +
            '  KEY idx_tcl_session (session_id), ' +
            '  KEY idx_tcl_created (created_at), ' +
            '  KEY idx_tcl_tool_created (tool_name, created_at)' +
            ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci');
          try DdlQry.ExecSQL; finally DdlQry.Free; end;
          FLogger.Log(mlInfo, 'Auto-migrate: tool_call_log created');
        end;
      finally
        MigQry.Free;
      end;

      // v2.4.0: app_settings table (runtime-editable config via Admin-UI)
      MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.tables ' +
        'WHERE table_schema = :db AND table_name = ''app_settings''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: creating app_settings table (v2.4.0)');
          var DdlQry := MigCtx.CreateQuery(
            'CREATE TABLE IF NOT EXISTS app_settings (' +
            '  setting_key VARCHAR(100) NOT NULL PRIMARY KEY, ' +
            '  setting_value TEXT, ' +
            '  updated_by INT DEFAULT NULL, ' +
            '  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP' +
            ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci');
          try DdlQry.ExecSQL; finally DdlQry.Free; end;

          // Seed default keys (empty values, admin configures via UI)
          var SeedQry := MigCtx.CreateQuery(
            'INSERT IGNORE INTO app_settings (setting_key, setting_value) VALUES ' +
            '(''connect.internal_host'', ''''), ' +
            '(''connect.external_mcp_url'', ''''), ' +
            '(''connect.external_admin_url'', ''''), ' +
            '(''connect.trusted_proxies'', ''127.0.0.1'')');
          try SeedQry.ExecSQL; finally SeedQry.Free; end;

          FLogger.Log(mlInfo, 'Auto-migrate: app_settings created + seeded');
        end;
      finally
        MigQry.Free;
      end;

      // v2.4.0: invite_links table (team onboarding via time-limited tokens)
      MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.tables ' +
        'WHERE table_schema = :db AND table_name = ''invite_links''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: creating invite_links table (v2.4.0)');
          var DdlQry := MigCtx.CreateQuery(
            'CREATE TABLE IF NOT EXISTS invite_links (' +
            '  id INT NOT NULL AUTO_INCREMENT, ' +
            '  token VARCHAR(128) NOT NULL, ' +
            '  developer_id INT NOT NULL, ' +
            '  client_key_id INT NOT NULL, ' +
            '  mode VARCHAR(30) NOT NULL DEFAULT ''external'', ' +
            '  expires_at DATETIME NOT NULL, ' +
            '  first_viewed_at DATETIME DEFAULT NULL, ' +
            '  revoked_at DATETIME DEFAULT NULL, ' +
            '  revoked_by INT DEFAULT NULL, ' +
            '  consumer_ip VARCHAR(45) DEFAULT NULL, ' +
            '  created_by INT NOT NULL, ' +
            '  created_at DATETIME DEFAULT CURRENT_TIMESTAMP, ' +
            '  PRIMARY KEY (id), ' +
            '  UNIQUE KEY uq_invite_token (token), ' +
            '  KEY idx_invite_expires (expires_at), ' +
            '  KEY idx_invite_developer (developer_id), ' +
            '  CONSTRAINT fk_invite_developer FOREIGN KEY (developer_id) ' +
            '    REFERENCES developers(id) ON DELETE CASCADE, ' +
            '  CONSTRAINT fk_invite_client_key FOREIGN KEY (client_key_id) ' +
            '    REFERENCES client_keys(id) ON DELETE CASCADE, ' +
            '  CONSTRAINT fk_invite_created_by FOREIGN KEY (created_by) ' +
            '    REFERENCES developers(id), ' +
            '  CONSTRAINT fk_invite_revoked_by FOREIGN KEY (revoked_by) ' +
            '    REFERENCES developers(id) ON DELETE SET NULL' +
            ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci');
          try DdlQry.ExecSQL; finally DdlQry.Free; end;
          FLogger.Log(mlInfo, 'Auto-migrate: invite_links created');
        end;
      finally
        MigQry.Free;
      end;

      // v2.4.0 R4: Add columns for raw_api_key storage (Security Review ADR#1767)
      //   - raw_api_key_obfuscated: XOR-obfuscated via mxEncryptStaticString
      //   - confirmed_at: set by consumer via POST /api/invite/{token}/confirm
      // Idempotent: only ADD if missing (checked via information_schema)
      MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.columns ' +
        'WHERE table_schema = :db AND table_name = ''invite_links'' ' +
        '  AND column_name = ''raw_api_key_obfuscated''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: adding raw_api_key_obfuscated + confirmed_at to invite_links');
          var AlterQry := MigCtx.CreateQuery(
            'ALTER TABLE invite_links ' +
            '  ADD COLUMN raw_api_key_obfuscated VARCHAR(256) DEFAULT NULL, ' +
            '  ADD COLUMN confirmed_at DATETIME DEFAULT NULL');
          try AlterQry.ExecSQL; finally AlterQry.Free; end;
          FLogger.Log(mlInfo, 'Auto-migrate: invite_links columns added');
        end;
      finally
        MigQry.Free;
      end;

      // v2.4.0 R5 (Bugfix): token column was VARCHAR(64), but the security
      // review (ADR#1767) raised token entropy to 256 bits → 'inv_' + 64 hex
      // chars = 68 chars total. Idempotent widen to 128 to leave headroom.
      MigQry := MigCtx.CreateQuery(
        'SELECT character_maximum_length FROM information_schema.columns ' +
        'WHERE table_schema = :db AND table_name = ''invite_links'' ' +
        '  AND column_name = ''token''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if (not MigQry.IsEmpty) and
           (MigQry.FieldByName('character_maximum_length').AsInteger < 128) then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: widening invite_links.token to VARCHAR(128)');
          var AlterQry := MigCtx.CreateQuery(
            'ALTER TABLE invite_links MODIFY COLUMN token VARCHAR(128) NOT NULL');
          try AlterQry.ExecSQL; finally AlterQry.Free; end;
          FLogger.Log(mlInfo, 'Auto-migrate: invite_links.token widened');
        end;
      finally
        MigQry.Free;
      end;
      // v2.4.0: developers.role column (team member role label)
      MigQry := MigCtx.CreateQuery(
        'SELECT 1 FROM information_schema.columns ' +
        'WHERE table_schema = :db AND table_name = ''developers'' ' +
        '  AND column_name = ''role''');
      try
        MigQry.ParamByName('db').AsString := FConfig.DBDatabase;
        MigQry.Open;
        if MigQry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Auto-migrate: adding role column to developers');
          var AlterQry := MigCtx.CreateQuery(
            'ALTER TABLE developers ADD COLUMN role VARCHAR(50) DEFAULT NULL AFTER email');
          try AlterQry.ExecSQL; finally AlterQry.Free; end;
          FLogger.Log(mlInfo, 'Auto-migrate: developers.role added');
        end;
      finally
        MigQry.Free;
      end;
    finally
      MigCtx := nil;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Auto-migrate check skipped: ' + E.Message);
  end;

  // 5c. Ensure SelfSlug project exists in DB
  try
    var EnsureCtx := FPool.AcquireContext;
    try
      var EnsureQry := EnsureCtx.CreateQuery(
        'INSERT IGNORE INTO projects (slug, name, path, is_active, created_at) ' +
        'VALUES (:slug, :name, :path, TRUE, NOW())');
      try
        EnsureQry.ParamByName('slug').AsString := FConfig.SelfSlug;
        EnsureQry.ParamByName('name').AsString := FConfig.SelfSlug + ' — MCP Server';
        EnsureQry.ParamByName('path').AsString := ExtractFilePath(ParamStr(0));
        EnsureQry.ExecSQL;
        if EnsureQry.RowsAffected > 0 then
          FLogger.Log(mlInfo, 'Auto-created project: ' + FConfig.SelfSlug);
      finally
        EnsureQry.Free;
      end;
    finally
      EnsureCtx := nil;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Could not ensure SelfSlug project: ' + E.Message);
  end;

  // 6. Diagnostics
  RunDiagnostics;

  // 6b. Auto-cleanup old session notes
  RunAutoCleanup;

  // 6c. Predictive Prefetch: Boot-Time Scoring
  try
    var Prefetch := TMxPrefetchCalculator.Create(FPool, FLogger);
    try
      Prefetch.SessionWindow := FConfig.PrefetchSessionWindow;
      Prefetch.Calculate;
    finally
      Prefetch.Free;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Prefetch calculation skipped: ' + E.Message);
  end;

  // 6d. Auto-backup if stale or missing
  RunAutoBackup;

  // 6e. Record boot timestamp for /health endpoint
  MxSetBootTime(Now);

  // 7. Tool registry + MCP server (Sparkle, replaces TMS AI Studio — ADR-0008)
  SetupServer;

  // 8. Admin server (optional)
  if FConfig.AdminPort > 0 then
    FAdminServer := TMxAdminServer.Create(FPool, FConfig, FLogger);

  // 9. Shutdown event (needed by AI Batch timer thread)
  FShutdownEvent := TEvent.Create(nil, True, False, '');

  // 10. AI Batch: Boot-time autonomous data maintenance (AFTER MCP server is ready)
  //    FAIBatch lives until Destroy — claude.exe thread runs in background
  try
    FAIBatch := TMxAIBatchRunner.Create(FPool, FConfig, FLogger, FShutdownEvent);
    FAIBatch.RunAll;  // Starts claude.exe thread, returns immediately
    FAIBatch.StartBatchTimer;  // Periodic embedding refresh

    // Initialize HybridSearch global (used by HandleSearch)
    if FConfig.EmbeddingEnabled and (FConfig.EmbeddingApiKey <> '') then
    begin
      GHybridSearch := TMxHybridSearch.Create(
        TMxEmbeddingClient.Create(FConfig, FLogger), FConfig, FLogger);
      FLogger.Log(mlInfo, 'Semantic Search: enabled (provider: ' +
        FConfig.EmbeddingUrl + ')');
    end;
  except
    on E: Exception do
    begin
      FLogger.Log(mlWarning, 'AI Batch skipped: ' + E.Message);
      FreeAndNil(FAIBatch);
    end;
  end;
end;

destructor TMxServerBoot.Destroy;
begin
  // Unregister console handler FIRST to prevent Use-After-Free
  {$IFDEF MSWINDOWS}
  if FConsoleHandlerRegistered then
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
  {$ENDIF}
  GShutdownEvent := nil;

  if Assigned(FLogger) then
    FLogger.Log(mlInfo, 'Shutting down...');

  // Stop MCP server first (no new requests), then cleanup
  FreeAndNil(FMcpServer);
  FreeAndNil(FAdminServer);
  // Now safe to free HybridSearch (no more worker threads accessing it)
  FreeAndNil(GHybridSearch);
  // AI Batch: Wait for claude.exe thread before freeing Pool
  FreeAndNil(FAIBatch);
  FreeAndNil(FRegistry);
  FreeAndNil(FAuth);
  FreeAndNil(FPool);
  FreeAndNil(FConfig);
  FreeAndNil(FShutdownEvent);

  // Release logger last — other destructors may still log
  FLogger := nil;

  inherited;
end;

procedure TMxServerBoot.EnsureDatabase;
var
  Link: TFDPhysMySQLDriverLink;
  Conn: TFDConnection;
  Qry: TFDQuery;
  SafeName: string;
begin
  if FConfig.DBDatabase = '' then
    raise Exception.Create('Database name is empty in INI [Database] Database=');

  // Sanitize: only allow alphanumeric + underscore
  SafeName := FConfig.DBDatabase;
  for var I := Length(SafeName) downto 1 do
    if not CharInSet(SafeName[I], ['a'..'z','A'..'Z','0'..'9','_']) then
      raise Exception.CreateFmt('Invalid database name "%s" — only a-z, 0-9, _ allowed', [SafeName]);

  Link := TFDPhysMySQLDriverLink.Create(nil);
  try
    Link.VendorHome := FConfig.VendorHome;
    Link.VendorLib := 'libmariadb.dll';

    Conn := TFDConnection.Create(nil);
    try
      Conn.DriverName := 'MySQL';
      Conn.Params.Values['Server'] := FConfig.DBHost;
      Conn.Params.Values['Port'] := IntToStr(FConfig.DBPort);
      Conn.Params.UserName := FConfig.DBUsername;
      Conn.Params.Password := FConfig.DBPassword;
      Conn.Params.Values['CharacterSet'] := 'utf8mb4';
      Conn.LoginPrompt := False;
      Conn.Open;

      Qry := TFDQuery.Create(nil);
      try
        Qry.Connection := Conn;
        Qry.SQL.Text := 'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = :db';
        Qry.ParamByName('db').AsString := SafeName;
        Qry.Open;
        if Qry.IsEmpty then
        begin
          FLogger.Log(mlInfo, 'Database "' + SafeName + '" not found — creating');
          Conn.ExecSQL('CREATE DATABASE `' + SafeName +
            '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
          FLogger.Log(mlInfo, 'Database "' + SafeName + '" created');
        end;
      finally
        Qry.Free;
      end;
    finally
      Conn.Free;
    end;
  finally
    Link.Free;
  end;
end;

procedure TMxServerBoot.RunAutoSchema;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  SetupPath, MysqlExe, CmdLine, BatFile, CredFile: string;
  NeedSetup: Boolean;
  {$IFDEF MSWINDOWS}
  SI: TStartupInfo;
  PI: TProcessInformation;
  ExitCode: DWORD;
  {$ENDIF}
begin
  NeedSetup := False;
  Ctx := FPool.AcquireContext;
  try
    // Check if schema_meta table exists (= schema is installed)
    try
      Qry := Ctx.CreateQuery('SELECT 1 FROM schema_meta LIMIT 1');
      try
        Qry.Open;
      finally
        Qry.Free;
      end;
    except
      NeedSetup := True;
    end;

    if not NeedSetup then
    begin
      FLogger.Log(mlDebug, 'Schema check: OK');
      Exit;
    end;

    // Schema is missing — look for setup.sql
    SetupPath := ExtractFilePath(ParamStr(0)) + 'sql' + PathDelim + 'setup.sql';
    if not FileExists(SetupPath) then
    begin
      FLogger.Log(mlError, 'Database is empty and setup.sql not found at ' + SetupPath);
      FLogger.Log(mlError, 'Please run: mysql -u root -p mxai_knowledge < sql/setup.sql');
      raise Exception.Create('Empty database — run setup.sql first (see log)');
    end;

    FLogger.Log(mlInfo, 'Empty database detected — running setup.sql via mysql CLI');
    FLogger.Log(mlDebug, 'VendorHome: ' + FConfig.VendorHome);

    // Find mysql client binary (same location as mysqldump)
    MysqlExe := IncludeTrailingPathDelimiter(FConfig.VendorHome) + 'bin' + PathDelim + 'mariadb.exe';
    if not FileExists(MysqlExe) then
      MysqlExe := IncludeTrailingPathDelimiter(FConfig.VendorHome) + 'bin' + PathDelim + 'mysql.exe';
    if not FileExists(MysqlExe) then
    begin
      FLogger.Log(mlError, 'mysql/mariadb client not found at ' + FConfig.VendorHome + '\bin\');
      FLogger.Log(mlError, 'Please run manually: mysql -u root -p ' + FConfig.DBDatabase + ' < sql/setup.sql');
      raise Exception.Create('Cannot auto-import schema — mysql client not found (see log)');
    end;
    FLogger.Log(mlDebug, 'MySQL client: ' + MysqlExe);

    // Use --defaults-extra-file to avoid password on command line / in batch file.
    // Same pattern as backup (mx.Admin.Api.Global.pas).
    CredFile := TPath.Combine(ExtractFilePath(ParamStr(0)), '.setup_creds.cnf');
    BatFile := TPath.Combine(ExtractFilePath(ParamStr(0)), '.setup_import.bat');
    try
      // Write temp credentials file (no password on CLI, no batch escaping issues)
      var Creds := TStringList.Create;
      try
        Creds.Add('[client]');
        Creds.Add('password=' + FConfig.DBPassword);
        Creds.SaveToFile(CredFile, TEncoding.ANSI);
      finally
        Creds.Free;
      end;

      // Write batch file with < redirect (mysql needs shell for stdin redirect)
      var BatLines := TStringList.Create;
      try
        BatLines.Add('@echo off');
        BatLines.Add(Format('"%s" --defaults-extra-file="%s" --host=%s --port=%d -u %s %s < "%s"',
          [MysqlExe, CredFile, FConfig.DBHost, FConfig.DBPort,
           FConfig.DBUsername, FConfig.DBDatabase, SetupPath]));
        BatLines.SaveToFile(BatFile, TEncoding.ANSI);
      finally
        BatLines.Free;
      end;

      CmdLine := '"' + BatFile + '"';

      {$IFDEF MSWINDOWS}
      FLogger.Log(mlDebug, 'Importing schema via: ' + MysqlExe);

      FillChar(SI, SizeOf(SI), 0);
      SI.cb := SizeOf(SI);
      SI.dwFlags := STARTF_USESHOWWINDOW;
      SI.wShowWindow := SW_HIDE;
      FillChar(PI, SizeOf(PI), 0);

      if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
        CREATE_NO_WINDOW, nil, nil, SI, PI) then
        raise Exception.Create('CreateProcess error ' + IntToStr(GetLastError));

      var WaitResult := WaitForSingleObject(PI.hProcess, 120000); // max 2 min
      if WaitResult = WAIT_TIMEOUT then
      begin
        TerminateProcess(PI.hProcess, 1);
        FLogger.Log(mlError, 'mysql process timed out after 120s — terminated');
      end;
      GetExitCodeProcess(PI.hProcess, ExitCode);
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);

      if ExitCode <> 0 then
      begin
        FLogger.Log(mlError, 'mysql exit code ' + IntToStr(ExitCode));
        FLogger.Log(mlError, 'Please run manually: mysql -u root -p ' + FConfig.DBDatabase + ' < sql/setup.sql');
        raise Exception.Create('Auto-schema failed — mysql exit code ' + IntToStr(ExitCode));
      end;
      {$ENDIF}

      FLogger.Log(mlInfo, 'Auto-schema: setup.sql imported successfully via mysql CLI');
    finally
      // Clean up temp files (creds file contains password)
      if FileExists(CredFile) then
        System.SysUtils.DeleteFile(CredFile);
      if FileExists(BatFile) then
        System.SysUtils.DeleteFile(BatFile);
    end;
  finally
    Ctx := nil;
  end;
end;

procedure TMxServerBoot.RunAutoCleanup;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Count: Integer;
begin
  try
    Ctx := FPool.AcquireContext;
    Count := 0;

    Qry := Ctx.CreateQuery(
      'SELECT id, content FROM documents ' +
      'WHERE doc_type = ''session_note'' ' +
      '  AND status IN (''active'', ''draft'') ' +
      '  AND updated_at < NOW() - INTERVAL 30 DAY');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        if Pos('- [ ]', Qry.FieldByName('content').AsString) = 0 then
        begin
          var UpdQry := Ctx.CreateQuery(
            'UPDATE documents SET status = ''archived'' WHERE id = :id');
          try
            UpdQry.ParamByName('id').AsInteger := Qry.FieldByName('id').AsInteger;
            UpdQry.ExecSQL;
            Inc(Count);
          finally
            UpdQry.Free;
          end;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // Retention cleanup: purge access_log entries older than 90 days
    Qry := Ctx.CreateQuery(
      'DELETE FROM access_log WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY)');
    try
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // Retention cleanup: purge tool_call_log entries older than 90 days
    Qry := Ctx.CreateQuery(
      'DELETE FROM tool_call_log WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY)');
    try
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    if Count > 0 then
      FLogger.Log(mlInfo, Format('Auto-cleanup: %d old session notes archived', [Count]))
    else
      FLogger.Log(mlDebug, 'Auto-cleanup: no stale session notes found');
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Auto-cleanup failed: ' + E.Message);
  end;
end;

procedure TMxServerBoot.RunAutoBackup;
var
  BackupDir, BackupFile: string;
  Files: TStringDynArray;
  I: Integer;
  BestTime, LastTime: TDateTime;
  AgeHours: Double;
begin
  try
    BackupDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'backups';
    if not TDirectory.Exists(BackupDir) then
      ForceDirectories(BackupDir);

    // Find newest .sql backup
    BestTime := 0;
    Files := TDirectory.GetFiles(BackupDir, '*.sql');
    for I := 0 to High(Files) do
    begin
      LastTime := TFile.GetLastWriteTime(Files[I]);
      if LastTime > BestTime then
        BestTime := LastTime;
    end;

    if BestTime > 0 then
      AgeHours := HourSpan(Now, BestTime)
    else
      AgeHours := 9999; // no backup found

    if AgeHours > 24 then
    begin
      BackupFile := MxRunBackup(FConfig, FLogger);
      FLogger.Log(mlInfo, Format('Auto-backup: %s (%d bytes)',
        [ExtractFileName(BackupFile), TFile.GetSize(BackupFile)]));
    end
    else
      FLogger.Log(mlDebug, Format('Auto-backup: skipped (last backup %.1f hours ago)',
        [AgeHours]));
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Auto-backup failed: ' + E.Message);
  end;
end;

procedure TMxServerBoot.RunDiagnostics;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  SchemaVersion, BackupValue: string;
begin
  FLogger.Log(mlDebug, 'Running startup diagnostics');

  // DB connection test
  if FPool.TestConnection then
    FLogger.Log(mlDebug, 'DB connection OK')
  else
  begin
    FLogger.Log(mlError, 'DB connection FAILED');
    raise Exception.Create('Database connection failed');
  end;

  Ctx := FPool.AcquireContext;

  // Schema version check
  try
    Qry := Ctx.CreateQuery(
      'SELECT MAX(id) AS ver FROM documents');
    try
      Qry.Open;
      SchemaVersion := Qry.FieldByName('ver').AsString;
      FLogger.Log(mlDebug, 'DB max doc_id: ' + SchemaVersion);
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Schema version check failed: ' + E.Message);
  end;

  // Backup freshness check
  try
    Qry := Ctx.CreateQuery(
      'SELECT de.env_value FROM developer_environments de ' +
      'JOIN projects p ON de.project_id = p.id ' +
      'WHERE p.slug = ''_global'' AND de.env_key = ''last_backup_date'' ' +
      'ORDER BY de.updated_at DESC LIMIT 1');
    try
      Qry.Open;
      if not Qry.IsEmpty then
        FLogger.Log(mlDebug, 'Last backup: ' + Qry.FieldByName('env_value').AsString)
      else
        FLogger.Log(mlDebug, 'No backup date recorded');
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Backup check skipped: ' + E.Message);
  end;

  // Project path validation removed: paths are client-side (developer machines),
  // not server-side. Checking them on the server produces false warnings.

  // Ensure _global sentinel project exists
  try
    Qry := Ctx.CreateQuery(
      'INSERT IGNORE INTO projects (slug, name, path) VALUES (''_global'', ''Global'', '''')');
    try
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      FLogger.Log(mlWarning, 'Could not ensure _global project: ' + E.Message);
  end;

  FLogger.Log(mlDebug, 'Diagnostics complete');
end;

procedure TMxServerBoot.SetupServer;
begin
  // Register all tools in the fluent registry
  FRegistry := TMxMcpRegistry.Create;
  TMxToolRegistry.RegisterAll(FRegistry);
  FLogger.Log(mlDebug, Format('Tool registry: %d tools registered', [FRegistry.ToolCount]));

  // Create Sparkle-based MCP server (replaces TMS AI Studio — ADR-0008)
  FMcpServer := TMxMcpServer.Create(FPool, FAuth, FRegistry, FConfig, FLogger);
end;

procedure TMxServerBoot.SetupShutdownHandler;
begin
  GShutdownEvent := FShutdownEvent;
  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
  FConsoleHandlerRegistered := True;
  {$ENDIF}
end;

procedure TMxServerBoot.Start;
begin
  try
    FMcpServer.Start;
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, 'MCP server failed to start: ' + E.Message);
      if Pos('Could not add', E.Message) > 0 then
      begin
        FLogger.Log(mlError, 'Fix: run as Administrator, or reserve the URL:');
        FLogger.Log(mlError, '  netsh http add urlacl url=http://+:' +
          IntToStr(FConfig.ServerPort) + '/ user=Everyone');
        FLogger.Log(mlError, '  netsh http add urlacl url=http://+:' +
          IntToStr(FConfig.AdminPort) + '/ user=Everyone');
      end;
      FHost.OnError('MCP server failed to start on port ' +
        IntToStr(FConfig.ServerPort) + ': ' + E.Message);
      raise;
    end;
  end;
  FLogger.Log(mlInfo, 'Server running on ' + FConfig.BindAddress + ':' +
    IntToStr(FConfig.ServerPort));

  if Assigned(FAdminServer) then
    FAdminServer.Start;

  FHost.OnStarted(FConfig.ServerPort, FConfig.AdminPort);
end;

procedure TMxServerBoot.Stop;
begin
  FLogger.Log(mlInfo, 'Shutdown signal received');
  if Assigned(FAdminServer) then
    FAdminServer.Stop;
  FMcpServer.Stop;
  FHost.OnStopped;
  FLogger.Log(mlInfo, 'Clean shutdown complete');
end;

procedure TMxServerBoot.Run;
begin
  Start;
  try
    if not FHost.IsGUIMode then
      SetupShutdownHandler;
    FShutdownEvent.WaitFor(INFINITE);
  finally
    Stop;
  end;
end;

end.
