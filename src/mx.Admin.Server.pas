unit mx.Admin.Server;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, Data.DB,
  FireDAC.Comp.Client,
  Sparkle.HttpSys.Server,
  Sparkle.HttpServer.Module,
  Sparkle.HttpServer.Context,
  Sparkle.HttpServer.Request,
  Sparkle.Module.Static,
  mx.Types, mx.Config, mx.Log, mx.Data.Pool, mx.Data.Context, mx.Admin.Auth,
  mx.Logic.Settings, mx.Logic.RateLimit;

type
  TMxAdminApiModule = class(THttpServerModule)
  private
    FPool: TMxConnectionPool;
    FAuth: TMxAdminAuth;
    FLogger: IMxLogger;
    FConfig: TMxConfig;
    FSettingsCache: TMxSettingsCache;
    FInviteRateLimit: TMxRateLimit;
    procedure RouteRequest(const C: THttpServerContext;
      const ASegments: TArray<string>; const ASession: TMxAdminSession);
    procedure HandleProxyDownload(const C: THttpServerContext);
    function HasNoDevelopers: Boolean;
  protected
    procedure ProcessRequest(const C: THttpServerContext); override;
  public
    constructor Create(const ABaseUri: string; APool: TMxConnectionPool;
      AAuth: TMxAdminAuth; AConfig: TMxConfig; ALogger: IMxLogger); reintroduce;
    destructor Destroy; override;
  end;

  // Serves connect.html for clean /connect URL (invite landing page)
  TMxConnectPageModule = class(THttpServerModule)
  private
    FFilePath: string;
  protected
    procedure ProcessRequest(const C: THttpServerContext); override;
  public
    constructor Create(const ABaseUri, AWwwPath: string); reintroduce;
  end;

  TMxAdminServer = class
  private
    FServer: THttpSysServer;
    FAuth: TMxAdminAuth;
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
    FPort: Integer;
  public
    constructor Create(APool: TMxConnectionPool; AConfig: TMxConfig;
      ALogger: IMxLogger);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

// Shared helpers for API handler units
procedure MxSendJson(const C: THttpServerContext; AStatusCode: Integer;
  AJson: TJSONObject);
procedure MxSendError(const C: THttpServerContext; AStatusCode: Integer;
  const AError: string);
function MxParseBody(const C: THttpServerContext): TJSONObject;
procedure MxSetSessionCookie(const C: THttpServerContext;
  const AToken: string; AMaxAge: Integer);
procedure MxClearSessionCookie(const C: THttpServerContext);
function MxDateStr(AField: TField): string;

/// <summary>
///   Returns the real client IP address. If the direct RemoteIp is listed in
///   ATrustedProxies (comma/semicolon/space-separated), honors the first
///   X-Forwarded-For entry. Otherwise returns RemoteIp unchanged.
/// </summary>
/// <remarks>
///   NEVER trust X-Forwarded-For without a trusted-proxy allow-list — any
///   client can spoof the header. Use settings key 'connect.trusted_proxies'
///   which defaults to '127.0.0.1'.
/// </remarks>
function MxGetClientIp(const C: THttpServerContext;
  const ATrustedProxies: string): string;

implementation

uses
  System.DateUtils,
  mx.Admin.Api.Auth, mx.Admin.Api.Developer,
  mx.Admin.Api.Keys, mx.Admin.Api.Projects,
  mx.Admin.Api.Global, mx.Admin.Api.Skills,
  mx.Admin.Api.Settings, mx.Admin.Api.Invite,
  mx.Admin.Api.SelfUpdate, mx.Admin.Api.Notes,
  mx.Admin.Api.Intelligence, mx.Admin.Api.IniEditor,
  mx.Admin.Api.ProjectBundle;

{ Shared helpers }

function MxDateStr(AField: TField): string;
begin
  if AField.IsNull then
    Result := ''
  else
    Result := FormatDateTime('dd.mm.yyyy hh:nn', AField.AsDateTime);
end;

procedure MxSendJson(const C: THttpServerContext; AStatusCode: Integer;
  AJson: TJSONObject);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(AJson.ToJSON);
  C.Response.StatusCode := AStatusCode;
  C.Response.ContentType := 'application/json; charset=utf-8';
  C.Response.Close(Bytes);
end;

procedure MxSendError(const C: THttpServerContext; AStatusCode: Integer;
  const AError: string);
var
  Json: TJSONObject;
begin
  Json := TJSONObject.Create;
  try
    Json.AddPair('error', AError);
    MxSendJson(C, AStatusCode, Json);
  finally
    Json.Free;
  end;
end;

function MxParseBody(const C: THttpServerContext): TJSONObject;
var
  BodyStr: string;
  Val: TJSONValue;
begin
  Result := nil;
  BodyStr := TEncoding.UTF8.GetString(C.Request.Content);
  if BodyStr = '' then Exit;

  Val := TJSONObject.ParseJSONValue(BodyStr);
  if (Val <> nil) and (Val is TJSONObject) then
    Result := TJSONObject(Val)
  else
    Val.Free;
end;

procedure MxSetSessionCookie(const C: THttpServerContext;
  const AToken: string; AMaxAge: Integer);
begin
  C.Response.Headers.SetValue('Set-Cookie',
    'mxadmin_session=' + AToken +
    '; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=' + IntToStr(AMaxAge));
end;

procedure MxClearSessionCookie(const C: THttpServerContext);
begin
  C.Response.Headers.SetValue('Set-Cookie',
    'mxadmin_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0');
end;

function MxGetClientIp(const C: THttpServerContext;
  const ATrustedProxies: string): string;
var
  RemoteIp, ForwardedFor: string;
  ProxyList: TArray<string>;
  I, CommaPos: Integer;
  IsTrusted: Boolean;
begin
  Result := C.Request.RemoteIp;
  if (Result = '') or (ATrustedProxies = '') then Exit;

  // Is the direct peer in the trusted-proxy allow-list?
  IsTrusted := False;
  ProxyList := ATrustedProxies.Split([',', ';', ' '],
    TStringSplitOptions.ExcludeEmpty);
  RemoteIp := Result;
  for I := 0 to High(ProxyList) do
    if SameText(Trim(ProxyList[I]), RemoteIp) then
    begin
      IsTrusted := True;
      Break;
    end;
  if not IsTrusted then Exit;

  // Trusted peer — honor X-Forwarded-For (take first entry = original client)
  if not C.Request.Headers.GetIfExists('X-Forwarded-For', ForwardedFor) then
    Exit;
  CommaPos := Pos(',', ForwardedFor);
  if CommaPos > 0 then
    ForwardedFor := Copy(ForwardedFor, 1, CommaPos - 1);
  ForwardedFor := Trim(ForwardedFor);
  if ForwardedFor <> '' then
    Result := ForwardedFor;
end;

{ TMxAdminApiModule }

constructor TMxAdminApiModule.Create(const ABaseUri: string;
  APool: TMxConnectionPool; AAuth: TMxAdminAuth; AConfig: TMxConfig;
  ALogger: IMxLogger);
begin
  inherited Create(ABaseUri);
  FPool := APool;
  FAuth := AAuth;
  FConfig := AConfig;
  FLogger := ALogger;
  FSettingsCache := TMxSettingsCache.Create(APool);
  // 20 requests / 5 min (300 sec) rolling window — ADR#1755 + R3 Phase 2.7
  FInviteRateLimit := TMxRateLimit.Create(20, 300);
end;

destructor TMxAdminApiModule.Destroy;
begin
  FInviteRateLimit.Free;
  FSettingsCache.Free;
  inherited;
end;

function TMxAdminApiModule.HasNoDevelopers: Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  // Setup mode: bypass auth until an admin key exists
  // This allows creating developers AND keys before auth kicks in
  Result := False;
  try
    Ctx := FPool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS cnt FROM client_keys ' +
      'WHERE is_active = TRUE AND permissions = ''admin''');
    try
      Qry.Open;
      Result := Qry.FieldByName('cnt').AsInteger = 0;
    finally
      Qry.Free;
    end;
  except
    // On DB error, don't bypass auth
  end;
end;

procedure TMxAdminApiModule.HandleProxyDownload(const C: THttpServerContext);
var
  ExePath: string;
  Stream: TFileStream;
  Bytes: TBytes;
begin
  // Search for proxy exe: exe dir, proxy/, claude-setup/proxy/
  ExePath := '';
  for var SearchPath in [
    ExtractFilePath(ParamStr(0)) + 'mxMCPProxy.exe',
    ExtractFilePath(ParamStr(0)) + 'proxy' + PathDelim + 'mxMCPProxy.exe',
    ExtractFilePath(ParamStr(0)) + 'claude-setup' + PathDelim + 'proxy' + PathDelim + 'mxMCPProxy.exe'] do
    if FileExists(SearchPath) then
    begin
      ExePath := SearchPath;
      Break;
    end;
  if ExePath = '' then
  begin
    MxSendError(C, 404, 'proxy_not_found');
    Exit;
  end;
  Stream := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes, Stream.Size);
  finally
    Stream.Free;
  end;
  C.Response.StatusCode := 200;
  C.Response.Headers.SetValue('Content-Type', 'application/octet-stream');
  C.Response.Headers.SetValue('Content-Disposition',
    'attachment; filename="mxMCPProxy.exe"');
  C.Response.Close(Bytes);
end;

procedure TMxAdminApiModule.ProcessRequest(const C: THttpServerContext);
var
  Path, CookieHeader, Token, CsrfHeader: string;
  Segments: TArray<string>;
  Session: TMxAdminSession;
  IsLogin, IsPublic: Boolean;
begin
  try
    // Use Uri.AbsolutePath (RawUri contains full URL including scheme+host)
    Path := C.Request.Uri.AbsolutePath;

    // Strip /api prefix
    if Path.StartsWith('/api/', True) then
      Path := Copy(Path, 5, Length(Path))
    else if Path.StartsWith('/api') then
      Path := Copy(Path, 5, Length(Path));


    // Parse segments: /auth/login -> ['auth', 'login']
    Segments := Path.Split(['/'], TStringSplitOptions.ExcludeEmpty);

    IsLogin := (Length(Segments) = 2) and
      SameText(Segments[0], 'auth') and SameText(Segments[1], 'login');

    // Public download endpoint (no auth needed)
    if (Length(Segments) = 2) and SameText(Segments[0], 'download') and
       SameText(Segments[1], 'proxy') and (C.Request.MethodType = THttpMethod.Get) then
    begin
      HandleProxyDownload(C);
      Exit;
    end;

    // Public invite endpoints: /api/invite/<token> (GET = view, POST = accept)
    // These bypass session + CSRF because the future team member has no login
    // yet — the invite token itself is the credential. Rate-limiting and
    // constant-time token compare are enforced inside the handler.
    IsPublic := (Length(Segments) >= 1) and SameText(Segments[0], 'invite');

    // Auth middleware (skip for login + public endpoints + setup mode)
    Session.Valid := False;
    if (not IsLogin) and (not IsPublic) then
    begin
      // Setup mode: skip auth when no developers exist (fresh install)
      if HasNoDevelopers then
      begin
        Session.Valid := True;
        Session.DeveloperId := 0;
        Session.DeveloperName := 'Setup';
      end
      else
      begin
        CookieHeader := '';
        C.Request.Headers.GetIfExists('Cookie', CookieHeader);
        Token := GetCookieValue(CookieHeader, 'mxadmin_session');
        Session := FAuth.ValidateSession(Token);
        if not Session.Valid then
        begin
          MxSendError(C, 401, 'session_invalid');
          Exit;
        end;

        // CSRF check for mutating requests
        if C.Request.MethodType in [THttpMethod.Post, THttpMethod.Put, THttpMethod.Delete] then
        begin
          CsrfHeader := '';
          C.Request.Headers.GetIfExists('X-CSRF-Token', CsrfHeader);
          if not FAuth.ValidateCsrf(Session, CsrfHeader) then
          begin
            MxSendError(C, 403, 'csrf_invalid');
            Exit;
          end;
        end;
      end;
    end;

    // Route to handlers
    RouteRequest(C, Segments, Session);

  except
    on E: Exception do
    begin
      FLogger.Log(mlError, 'Admin API error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

procedure TMxAdminApiModule.RouteRequest(const C: THttpServerContext;
  const ASegments: TArray<string>; const ASession: TMxAdminSession);
var
  Len, Id: Integer;
begin
  Len := Length(ASegments);

  if Len = 0 then
  begin
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /auth/*
  if SameText(ASegments[0], 'auth') and (Len = 2) then
  begin
    if SameText(ASegments[1], 'login') and (C.Request.MethodType = THttpMethod.Post) then
      mx.Admin.Api.Auth.HandleLogin(C, FPool, FAuth, FLogger)
    else if SameText(ASegments[1], 'logout') and (C.Request.MethodType = THttpMethod.Post) then
      mx.Admin.Api.Auth.HandleLogout(C, FAuth, ASession, FLogger)
    else if SameText(ASegments[1], 'check') and (C.Request.MethodType = THttpMethod.Get) then
      mx.Admin.Api.Auth.HandleCheckSession(C, ASession, FLogger)
    else
      MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /developers/*
  if SameText(ASegments[0], 'developers') then
  begin
    // GET /developers
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Developer.HandleGetDevelopers(C, FPool, FLogger);
      Exit;
    end;

    // POST /developers
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Developer.HandleCreateDeveloper(C, FPool, FLogger);
      Exit;
    end;

    // POST /developers/merge
    if (Len = 2) and SameText(ASegments[1], 'merge') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Developer.HandleMergeDevelopers(C, FPool, FLogger);
      Exit;
    end;

    // /developers/:id/*
    if (Len >= 2) and TryStrToInt(ASegments[1], Id) then
    begin
      // PUT /developers/:id
      if (Len = 2) and (C.Request.MethodType = THttpMethod.Put) then
      begin
        mx.Admin.Api.Developer.HandleUpdateDeveloper(C, FPool, Id, FLogger);
        Exit;
      end;

      // DELETE /developers/:id[?hard=true]
      if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
      begin
        mx.Admin.Api.Developer.HandleDeleteDeveloper(C, FPool, Id,
          Pos('hard=true', LowerCase(C.Request.Uri.Query)) > 0, FLogger);
        Exit;
      end;

      // GET /developers/:id/keys
      if (Len = 3) and SameText(ASegments[2], 'keys') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Keys.HandleGetKeys(C, FPool, Id, FLogger);
        Exit;
      end;

      // POST /developers/:id/keys
      if (Len = 3) and SameText(ASegments[2], 'keys') and
         (C.Request.MethodType = THttpMethod.Post) then
      begin
        mx.Admin.Api.Keys.HandleCreateKey(C, FPool, Id, FLogger);
        Exit;
      end;

      // GET /developers/:id/projects
      if (Len = 3) and SameText(ASegments[2], 'projects') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Projects.HandleGetDevProjects(C, FPool, Id, FLogger);
        Exit;
      end;

      // PUT /developers/:id/projects
      if (Len = 3) and SameText(ASegments[2], 'projects') and
         (C.Request.MethodType = THttpMethod.Put) then
      begin
        mx.Admin.Api.Projects.HandleUpdateDevProjects(C, FPool, Id, FLogger);
        Exit;
      end;

      // GET /developers/:id/environments
      if (Len = 3) and SameText(ASegments[2], 'environments') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Keys.HandleGetEnvironments(C, FPool, Id, FLogger);
        Exit;
      end;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /keys/*
  if SameText(ASegments[0], 'keys') then
  begin
    if (Len = 2) and TryStrToInt(ASegments[1], Id) then
    begin
      // DELETE /keys/:id[?hard=true]
      if C.Request.MethodType = THttpMethod.Delete then
      begin
        mx.Admin.Api.Keys.HandleDeleteKey(C, FPool, Id,
          Pos('hard=true', LowerCase(C.Request.Uri.Query)) > 0, FLogger);
        Exit;
      end;

      // PUT /keys/:id (role change)
      if C.Request.MethodType = THttpMethod.Put then
      begin
        mx.Admin.Api.Keys.HandleUpdateKey(C, FPool, Id, FLogger);
        Exit;
      end;
    end;

    // POST /keys/:id/revoke  (FR#2936/Plan#3266 M3.6 — admin revocation)
    if (Len = 3) and TryStrToInt(ASegments[1], Id)
       and SameText(ASegments[2], 'revoke')
       and (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Keys.HandleRevokeKey(C, FPool, Id, ASession.DeveloperId, FLogger);
      Exit;
    end;

    // POST /keys/:id/rotate  (FR#2936/Plan#3266 M3.5 — atomic rotation)
    if (Len = 3) and TryStrToInt(ASegments[1], Id)
       and SameText(ASegments[2], 'rotate')
       and (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Keys.HandleRotateKey(C, FPool, Id, ASession.DeveloperId, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /environments/*
  if SameText(ASegments[0], 'environments') then
  begin
    // DELETE /environments/:id
    if (Len = 2) and TryStrToInt(ASegments[1], Id) and
       (C.Request.MethodType = THttpMethod.Delete) then
    begin
      mx.Admin.Api.Keys.HandleDeleteEnvironment(C, FPool, Id, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /global/*
  if SameText(ASegments[0], 'global') then
  begin
    if (Len = 2) and SameText(ASegments[1], 'stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetGlobalStats(C, FPool, FConfig, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'activity') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetActivity(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'cleanup') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Global.HandlePostCleanup(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'backup') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Global.HandlePostBackup(C, FConfig, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'access-log-stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetAccessLogStats(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'prefetch') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetPrefetchStats(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'health') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetHealth(C, FPool, FConfig, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'sessions') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetActiveSessions(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'skill-evolution') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetSkillEvolution(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'recall-metrics') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetRecallMetrics(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'graph-stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetGraphStats(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'lesson-stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetLessonStats(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'embedding-stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetEmbeddingStats(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'token-stats') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Global.HandleGetTokenStats(C, FPool, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /intelligence/* — FR#3294 Semantic Search status
  if SameText(ASegments[0], 'intelligence') then
  begin
    if (Len = 2) and SameText(ASegments[1], 'status') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Intelligence.HandleGetIntelligenceStatus(
        C, FPool, FConfig, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /ini + /settings/reload — FR#3610 runtime config editor
  if SameText(ASegments[0], 'ini') then
  begin
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.IniEditor.HandleGetIni(C, FPool, FConfig, FLogger);
      Exit;
    end;
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Put) then
    begin
      mx.Admin.Api.IniEditor.HandleSetIni(C, FPool, FConfig, FLogger);
      Exit;
    end;
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /skills/*
  if SameText(ASegments[0], 'skills') then
  begin
    if (Len = 2) and SameText(ASegments[1], 'dashboard') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Skills.HandleGetSkillsDashboard(C, FPool, FLogger);
      Exit;
    end;

    if (Len = 2) and SameText(ASegments[1], 'feedback') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Skills.HandlePostSkillFeedback(C, FPool, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /projects
  if SameText(ASegments[0], 'projects') then
  begin
    // GET /projects
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Projects.HandleGetProjects(C, FPool, FLogger);
      Exit;
    end;

    // POST /projects/merge
    if (Len = 2) and SameText(ASegments[1], 'merge') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Projects.HandleMergeProjects(C, FPool, FLogger);
      Exit;
    end;

    // /projects/:id
    if (Len >= 2) and TryStrToInt(ASegments[1], Id) then
    begin
      // PUT /projects/:id
      if (Len = 2) and (C.Request.MethodType = THttpMethod.Put) then
      begin
        mx.Admin.Api.Projects.HandleUpdateProject(C, FPool, Id, FLogger);
        Exit;
      end;

      // DELETE /projects/:id
      if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
      begin
        mx.Admin.Api.Projects.HandleDeleteProject(C, FPool, Id,
          Pos('hard=true', LowerCase(C.Request.Uri.Query)) > 0, FLogger);
        Exit;
      end;

      // GET /projects/:id/dashboard
      if (Len = 3) and SameText(ASegments[2], 'dashboard') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Projects.HandleGetDashboard(C, FPool, Id, FLogger);
        Exit;
      end;

      // PUT /projects/:id/access  body: {developer_id, access_level}
      if (Len = 3) and SameText(ASegments[2], 'access') and
         (C.Request.MethodType = THttpMethod.Put) then
      begin
        mx.Admin.Api.Projects.HandleSetProjectAccess(C, FPool, Id, FLogger);
        Exit;
      end;

      // GET /projects/:id/documents  — FR#3353 Phase C filterable doc list
      if (Len = 3) and SameText(ASegments[2], 'documents') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Projects.HandleListProjectDocs(C, FPool, Id, FLogger);
        Exit;
      end;

      // GET /projects/:id/reviews  — FR#3472 C Reviews-Tab Root-Aggregate
      if (Len = 3) and SameText(ASegments[2], 'reviews') and
         (C.Request.MethodType = THttpMethod.Get) then
      begin
        mx.Admin.Api.Projects.HandleListProjectReviews(C, FPool, Id, FLogger);
        Exit;
      end;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /docs/:id  — FR#3353 Phase C doc detail + soft-delete
  // /docs/:id/thread — FR#3472 A hierarchischer Review-Thread
  if SameText(ASegments[0], 'docs') then
  begin
    if (Len >= 2) then
    begin
      var DocId := StrToIntDef(ASegments[1], 0);
      if DocId > 0 then
      begin
        if (Len = 2) and (C.Request.MethodType = THttpMethod.Get) then
        begin
          mx.Admin.Api.Projects.HandleGetDocDetail(C, FPool, DocId, FLogger);
          Exit;
        end;
        if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
        begin
          mx.Admin.Api.Projects.HandleDeleteDoc(C, FPool, DocId, FLogger);
          Exit;
        end;
        if (Len = 2) and (C.Request.MethodType = THttpMethod.Put) then
        begin
          mx.Admin.Api.Projects.HandleUpdateDocAdmin(C, FPool, DocId, FLogger);
          Exit;
        end;
        // GET /docs/:id/thread — FR#3472 A
        if (Len = 3) and SameText(ASegments[2], 'thread') and
           (C.Request.MethodType = THttpMethod.Get) then
        begin
          mx.Admin.Api.Projects.HandleGetDocThread(C, FPool, DocId, FLogger);
          Exit;
        end;
      end;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /relations/:id  — FR#3353 Phase C single-relation delete
  if SameText(ASegments[0], 'relations') then
  begin
    if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
    begin
      var RelId := StrToIntDef(ASegments[1], 0);
      if RelId > 0 then
      begin
        mx.Admin.Api.Projects.HandleDeleteRelation(C, FPool, RelId, FLogger);
        Exit;
      end;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /project-relations/:id  — FR#3353 Phase C project-relation delete
  if SameText(ASegments[0], 'project-relations') then
  begin
    if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
    begin
      var PRelId := StrToIntDef(ASegments[1], 0);
      if PRelId > 0 then
      begin
        mx.Admin.Api.Projects.HandleDeleteProjectRelation(C, FPool, PRelId, FLogger);
        Exit;
      end;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /export, /import — FR#3896 Project Export/Import (admin-only)
  if (Len = 1) and SameText(ASegments[0], 'export') and
     (C.Request.MethodType = THttpMethod.Post) then
  begin
    mx.Admin.Api.ProjectBundle.HandleExport(C, FPool, ASession, FLogger);
    Exit;
  end;
  if (Len = 1) and SameText(ASegments[0], 'import') and
     (C.Request.MethodType = THttpMethod.Post) then
  begin
    mx.Admin.Api.ProjectBundle.HandleImport(C, FPool, ASession, FLogger);
    Exit;
  end;

  // /settings/* — v2.4.0 runtime settings
  if SameText(ASegments[0], 'settings') then
  begin
    // GET /settings — list all
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Settings.HandleGetSettings(C, FSettingsCache, FLogger);
      Exit;
    end;

    // PUT /settings — batch update
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Put) then
    begin
      mx.Admin.Api.Settings.HandlePutSettings(C, FSettingsCache,
        ASession.DeveloperId, FLogger);
      Exit;
    end;

    // POST /settings/test-connection
    if (Len = 2) and SameText(ASegments[1], 'test-connection') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Settings.HandleTestConnection(C, FLogger);
      Exit;
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // --- Invites (admin + public) ---
  // /invites[/:id]       (admin, auth required)  — list/create/revoke
  // /invite/:token[/...] (public, rate-limited)  — resolve, confirm
  if SameText(ASegments[0], 'invites') then
  begin
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Invite.HandleListInvites(C, FPool, FLogger);
      Exit;
    end;
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Invite.HandleCreateInvite(C, FPool, FSettingsCache,
        ASession.DeveloperId, FLogger);
      Exit;
    end;
    // DELETE /api/invites/cleanup — bulk remove all revoked+expired
    if (Len = 2) and SameText(ASegments[1], 'cleanup') and
       (C.Request.MethodType = THttpMethod.Delete) then
    begin
      mx.Admin.Api.Invite.HandleCleanupInvites(C, FPool, FLogger);
      Exit;
    end;
    // DELETE /api/invites/{id} — revoke (active) or hard-delete (inactive)
    if (Len = 2) and (C.Request.MethodType = THttpMethod.Delete) then
    begin
      var InviteId := StrToIntDef(ASegments[1], 0);
      if InviteId <= 0 then
      begin
        MxSendError(C, 400, 'invalid_invite_id');
        Exit;
      end;
      mx.Admin.Api.Invite.HandleDeleteInvite(C, FPool, InviteId,
        ASession.DeveloperId, FLogger);
      Exit;
    end;
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  if SameText(ASegments[0], 'invite') then
  begin
    // Public endpoints — IsPublic flag in ProcessRequest bypassed auth+CSRF.
    // Token format: 'inv_' + 64 lowercase hex chars = 68 chars total.
    // Reject anything else BEFORE touching the DB (defense against absurdly
    // long tokens reaching the WHERE clause).
    if Len < 2 then
    begin
      MxSendError(C, 400, 'missing_token');
      Exit;
    end;
    if (Length(ASegments[1]) <> 68) or (not ASegments[1].StartsWith('inv_')) then
    begin
      MxSendError(C, 404, 'invite_not_found');
      Exit;
    end;
    // GET /invite/:token
    if (Len = 2) and (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Invite.HandleResolveInvite(C, FPool, FInviteRateLimit,
        FSettingsCache, ASegments[1], FLogger);
      Exit;
    end;
    // POST /invite/:token/confirm
    if (Len = 3) and SameText(ASegments[2], 'confirm') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Invite.HandleConfirmInvite(C, FPool, FInviteRateLimit,
        FSettingsCache, ASegments[1], FLogger);
      Exit;
    end;
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /notes/*  (FR#2936, Plan#3266 M2.6 — review-thread admin alerts)
  if SameText(ASegments[0], 'notes') then
  begin
    // GET /notes/deep-threads — review-notes with depth >= warn-threshold
    if (Len = 2) and SameText(ASegments[1], 'deep-threads') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.Notes.HandleListDeepThreads(C, FPool, FLogger);
      Exit;
    end;
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  // /self-update/*  (FR#2242, Plan#2311 Phase 4)
  if SameText(ASegments[0], 'self-update') then
  begin
    // GET /self-update/status
    if (Len = 2) and SameText(ASegments[1], 'status') and
       (C.Request.MethodType = THttpMethod.Get) then
    begin
      mx.Admin.Api.SelfUpdate.HandleSelfUpdateStatus(C, ASession, FLogger);
      Exit;
    end;
    // POST /self-update/recheck
    if (Len = 2) and SameText(ASegments[1], 'recheck') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.SelfUpdate.HandleSelfUpdateRecheck(C, ASession, FLogger);
      Exit;
    end;
    // POST /self-update/install
    if (Len = 2) and SameText(ASegments[1], 'install') and
       (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.SelfUpdate.HandleSelfUpdateInstall(C, ASession, FLogger);
      Exit;
    end;
    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  MxSendError(C, 404, 'not_found');
end;

{ TMxConnectPageModule }

constructor TMxConnectPageModule.Create(const ABaseUri, AWwwPath: string);
begin
  inherited Create(ABaseUri);
  FFilePath := IncludeTrailingPathDelimiter(AWwwPath) + 'connect.html';
end;

procedure TMxConnectPageModule.ProcessRequest(const C: THttpServerContext);
var
  Bytes: TBytes;
begin
  if not FileExists(FFilePath) then
  begin
    C.Response.StatusCode := 404;
    C.Response.ContentType := 'text/plain';
    C.Response.Close(TEncoding.UTF8.GetBytes('connect.html not found'));
    Exit;
  end;
  Bytes := TFile.ReadAllBytes(FFilePath);
  C.Response.StatusCode := 200;
  C.Response.ContentType := 'text/html; charset=utf-8';
  C.Response.Headers.SetValue('Cache-Control', 'no-cache');
  C.Response.Close(Bytes);
end;

{ TMxAdminServer }

constructor TMxAdminServer.Create(APool: TMxConnectionPool; AConfig: TMxConfig;
  ALogger: IMxLogger);
var
  BaseUrl, WwwPath: string;
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
  FPort := AConfig.AdminPort;

  FAuth := TMxAdminAuth.Create(FPool, AConfig.SessionTimeoutMinutes);

  BaseUrl := Format('http://+:%d/', [FPort]);
  WwwPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + 'admin' + PathDelim + 'www';

  FServer := THttpSysServer.Create;
  FServer.KeepHostInUrlPrefixes := True;

  // API module (more specific prefix, register first)
  FServer.AddModule(
    TMxAdminApiModule.Create(BaseUrl + 'api/', FPool, FAuth, AConfig, ALogger));

  // /connect clean URL for invite landing page (before static module)
  FServer.AddModule(TMxConnectPageModule.Create(BaseUrl + 'connect', WwwPath));

  // Static file module for admin/www/
  FServer.AddModule(TStaticModule.Create(BaseUrl, WwwPath));

  FLogger.Log(mlDebug, 'Admin server configured on port ' + IntToStr(FPort) +
    ', www: ' + WwwPath);
end;

destructor TMxAdminServer.Destroy;
begin
  Stop;
  FreeAndNil(FServer);
  FreeAndNil(FAuth);
  inherited;
end;

procedure TMxAdminServer.Start;
begin
  FServer.Start;
  FLogger.Log(mlInfo, 'Admin server started on port ' + IntToStr(FPort));
end;

procedure TMxAdminServer.Stop;
begin
  if Assigned(FServer) then
  begin
    FServer.Stop;
    FLogger.Log(mlInfo, 'Admin server stopped');
  end;
end;

end.
