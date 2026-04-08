unit mx.Admin.Server;

interface

uses
  System.SysUtils, System.Classes, System.JSON, Data.DB,
  FireDAC.Comp.Client,
  Sparkle.HttpSys.Server,
  Sparkle.HttpServer.Module,
  Sparkle.HttpServer.Context,
  Sparkle.HttpServer.Request,
  Sparkle.Module.Static,
  mx.Types, mx.Config, mx.Log, mx.Data.Pool, mx.Data.Context, mx.Admin.Auth;

type
  TMxAdminApiModule = class(THttpServerModule)
  private
    FPool: TMxConnectionPool;
    FAuth: TMxAdminAuth;
    FLogger: IMxLogger;
    FConfig: TMxConfig;
    procedure RouteRequest(const C: THttpServerContext;
      const ASegments: TArray<string>; const ASession: TMxAdminSession);
    procedure HandleProxyDownload(const C: THttpServerContext);
    function HasNoDevelopers: Boolean;
  protected
    procedure ProcessRequest(const C: THttpServerContext); override;
  public
    constructor Create(const ABaseUri: string; APool: TMxConnectionPool;
      AAuth: TMxAdminAuth; AConfig: TMxConfig; ALogger: IMxLogger); reintroduce;
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

implementation

uses
  System.DateUtils,
  mx.Admin.Api.Auth, mx.Admin.Api.Developer,
  mx.Admin.Api.Keys, mx.Admin.Api.Projects,
  mx.Admin.Api.Global, mx.Admin.Api.Skills;

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
  IsLogin: Boolean;
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

    // Auth middleware (skip for login + setup mode when 0 developers)
    Session.Valid := False;
    if not IsLogin then
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

    // POST /projects
    if (Len = 1) and (C.Request.MethodType = THttpMethod.Post) then
    begin
      mx.Admin.Api.Projects.HandleCreateProject(C, FPool, FLogger);
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
    end;

    MxSendError(C, 404, 'not_found');
    Exit;
  end;

  MxSendError(C, 404, 'not_found');
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
