unit mx.Admin.Api.Auth;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Admin.Auth;

procedure HandleLogin(const C: THttpServerContext;
  APool: TMxConnectionPool; AAuth: TMxAdminAuth; ALogger: IMxLogger);
procedure HandleLogout(const C: THttpServerContext;
  AAuth: TMxAdminAuth; const ASession: TMxAdminSession; ALogger: IMxLogger);
procedure HandleCheckSession(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON,
  Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server;

// FR#4006 / Plan#4007 M1 T03: build { project_id_str : access_level_str }
// map for the logged-in developer. Admins get an empty object — the
// Frontend checks the separate is_admin flag for hard-bypass UX.
function BuildAccessLevelsJson(APool: TMxConnectionPool;
  ADevId: Integer): TJSONObject;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Result := TJSONObject.Create;
  try
    if ADevId <= 0 then Exit;
    Ctx := APool.AcquireContext;
    Qry := Ctx.CreateQuery(
      'SELECT project_id, access_level FROM developer_project_access ' +
      'WHERE developer_id = :id');
    try
      Qry.ParamByName('id').AsInteger := ADevId;
      Qry.Open;
      while not Qry.Eof do
      begin
        Result.AddPair(
          IntToStr(Qry.FieldByName('project_id').AsInteger),
          Qry.FieldByName('access_level').AsString);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure HandleLogin(const C: THttpServerContext;
  APool: TMxConnectionPool; AAuth: TMxAdminAuth; ALogger: IMxLogger);
var
  Body, Json, DevJson: TJSONObject;
  ApiKey: string;
  Session: TMxAdminSession;
  LoginResult: TMxLoginResult;
  CookieMaxAge: Integer;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  try
    ApiKey := Body.GetValue<string>('api_key', '');
    if ApiKey = '' then
    begin
      MxSendError(C, 400, 'missing_api_key');
      Exit;
    end;

    LoginResult := AAuth.Login(ApiKey, Session);

    case LoginResult of
      lrInvalidKey:
      begin
        ALogger.Log(mlWarning, 'Admin login failed: invalid key');
        MxSendError(C, 401, 'invalid_key');
      end;

      lrNotAdmin:
      begin
        ALogger.Log(mlWarning, 'Admin login failed: not admin');
        // Unified error code — Frontend api.js matches only
        // forbidden|access_denied|doc_not_found|not_found for 403 routing.
        MxSendError(C, 403, 'forbidden');
      end;

      lrUiLoginDisabled:
      begin
        ALogger.Log(mlWarning, 'Admin login failed: UI login disabled');
        MxSendError(C, 403, 'ui_login_disabled');
      end;

      lrSuccess:
      begin
        ALogger.Log(mlInfo, 'Admin login: ' + Session.DeveloperName);

        // Cookie Max-Age in seconds
        CookieMaxAge := Round((Session.ExpiresAt - Now) * 86400);
        MxSetSessionCookie(C, Session.Token, CookieMaxAge);

        Json := TJSONObject.Create;
        try
          Json.AddPair('csrf_token', Session.CsrfToken);
          DevJson := TJSONObject.Create;
          try
            DevJson.AddPair('id', TJSONNumber.Create(Session.DeveloperId));
            DevJson.AddPair('name', Session.DeveloperName);
            // FR#4006 / Plan#4007 M1 T03: Frontend needs is_admin + per-
            // project access levels to render 4-level ACL badges and to
            // hide/show admin-only nav items.
            DevJson.AddPair('is_admin', TJSONBool.Create(Session.IsAdmin));
            DevJson.AddPair('access_levels',
              BuildAccessLevelsJson(APool, Session.DeveloperId));
          except
            DevJson.Free;
            raise;
          end;
          // Ownership transferred to Json — must not free DevJson past here.
          Json.AddPair('developer', DevJson);
          MxSendJson(C, 200, Json);
        finally
          Json.Free;
        end;
      end;
    end;
  finally
    Body.Free;
  end;
end;

procedure HandleLogout(const C: THttpServerContext;
  AAuth: TMxAdminAuth; const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Json: TJSONObject;
begin
  AAuth.Logout(ASession.Token);
  MxClearSessionCookie(C);
  ALogger.Log(mlInfo, 'Admin logout: ' + ASession.DeveloperName);

  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

procedure HandleCheckSession(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Json, DevJson: TJSONObject;
begin
  // Session already validated by middleware — just return info
  Json := TJSONObject.Create;
  try
    Json.AddPair('csrf_token', ASession.CsrfToken);
    DevJson := TJSONObject.Create;
    try
      DevJson.AddPair('id', TJSONNumber.Create(ASession.DeveloperId));
      DevJson.AddPair('name', ASession.DeveloperName);
      // FR#4006 / Plan#4007 M1 T03: mirror Login-response shape so the
      // Frontend has the same is_admin + access_levels after page reload.
      DevJson.AddPair('is_admin', TJSONBool.Create(ASession.IsAdmin));
      DevJson.AddPair('access_levels',
        BuildAccessLevelsJson(APool, ASession.DeveloperId));
    except
      DevJson.Free;
      raise;
    end;
    // Ownership transferred to Json — must not free DevJson past here.
    Json.AddPair('developer', DevJson);
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
