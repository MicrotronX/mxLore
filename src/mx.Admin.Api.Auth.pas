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
  const ASession: TMxAdminSession; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON,
  mx.Admin.Server;

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
        MxSendError(C, 403, 'not_admin');
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
          DevJson.AddPair('id', TJSONNumber.Create(Session.DeveloperId));
          DevJson.AddPair('name', Session.DeveloperName);
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
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Json, DevJson: TJSONObject;
begin
  // Session already validated by middleware — just return info
  Json := TJSONObject.Create;
  try
    Json.AddPair('csrf_token', ASession.CsrfToken);
    DevJson := TJSONObject.Create;
    DevJson.AddPair('id', TJSONNumber.Create(ASession.DeveloperId));
    DevJson.AddPair('name', ASession.DeveloperName);
    Json.AddPair('developer', DevJson);
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
