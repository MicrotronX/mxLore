unit mx.Admin.Api.Settings;

// v2.4.0: REST handlers for runtime-editable settings (/api/settings/*)
// Uses mx.Logic.Settings TMxSettingsCache for cached reads and atomic writes.

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Logic.Settings;

// GET /api/settings — list all settings
procedure HandleGetSettings(const C: THttpServerContext;
  ACache: TMxSettingsCache; ALogger: IMxLogger);

// PUT /api/settings — atomic batch update
// Body: { "connect.internal_host": "...", "connect.external_mcp_url": "...", ... }
procedure HandlePutSettings(const C: THttpServerContext;
  ACache: TMxSettingsCache; AUpdatedBy: Integer; ALogger: IMxLogger);

// POST /api/settings/test-connection — self-ping a URL
// Body: { "url": "http://...", "mode": "mcp"|"http" }
//   mode="mcp"  (default if URL ends with /mcp): POST JSON-RPC initialize
//   mode="http" (for admin URLs): HEAD request
// Response: { "ok": true/false, "status_code": 200, "error": "...", "latency_ms": 42, "kind": "mcp"|"http" }
//
// SECURITY NOTE (SSRF): This endpoint makes HTTP requests to arbitrary URLs
// provided by the admin. It is authenticated (admin session + CSRF required)
// and intentional for self-hosted deployments where admins need to verify
// connectivity to their own infrastructure. No private-IP blocking is applied
// because admins legitimately need to test internal/LAN URLs. Accepted risk
// for admin-only functionality in self-hosted context.
procedure HandleTestConnection(const C: THttpServerContext;
  ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.DateUtils, System.Net.HttpClient, System.Net.URLClient,
  mx.Admin.Server;

procedure HandleGetSettings(const C: THttpServerContext;
  ACache: TMxSettingsCache; ALogger: IMxLogger);
var
  All: TDictionary<string, string>;
  Pair: TPair<string, string>;
  Arr: TJSONArray;
  Obj, Json: TJSONObject;
begin
  All := ACache.GetAll;
  try
    Arr := TJSONArray.Create;
    for Pair in All do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('key', Pair.Key);
      Obj.AddPair('value', Pair.Value);
      Arr.AddElement(Obj);
    end;
    Json := TJSONObject.Create;
    try
      Json.AddPair('settings', Arr);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    All.Free;
  end;
end;

procedure HandlePutSettings(const C: THttpServerContext;
  ACache: TMxSettingsCache; AUpdatedBy: Integer; ALogger: IMxLogger);
const
  // Allow-list of setting key prefixes that can be set via the API
  ValidPrefixes: array[0..0] of string = ('connect.');
var
  Body, Json: TJSONObject;
  Pair: TJSONPair;
  Updates: TDictionary<string, string>;
  i, p: Integer;
  Key, Val: string;
  KeyAllowed: Boolean;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  Updates := TDictionary<string, string>.Create;
  try
    // Collect all key/value pairs from the JSON body
    for i := 0 to Body.Count - 1 do
    begin
      Pair := Body.Pairs[i];
      Key := Pair.JsonString.Value;

      // Check allow-list — reject with 400 on unknown prefix
      KeyAllowed := False;
      for p := Low(ValidPrefixes) to High(ValidPrefixes) do
        if Key.StartsWith(ValidPrefixes[p]) then
        begin
          KeyAllowed := True;
          Break;
        end;
      if not KeyAllowed then
      begin
        MxSendError(C, 400, 'unknown_key:' + Key);
        Exit;
      end;

      // Extract value: strings preferred; null → empty; numbers/bools stringified
      if (Pair.JsonValue = nil) or (Pair.JsonValue is TJSONNull) then
        Val := ''
      else if Pair.JsonValue is TJSONString then
        Val := (Pair.JsonValue as TJSONString).Value
      else if Pair.JsonValue is TJSONNumber then
        Val := (Pair.JsonValue as TJSONNumber).ToString
      else if Pair.JsonValue is TJSONBool then
      begin
        if (Pair.JsonValue as TJSONBool).AsBoolean then
          Val := 'true'
        else
          Val := 'false';
      end
      else
      begin
        MxSendError(C, 400, 'invalid_value_type:' + Key);
        Exit;
      end;

      Updates.AddOrSetValue(Key, Val);
    end;

    if Updates.Count = 0 then
    begin
      MxSendError(C, 400, 'empty_body');
      Exit;
    end;

    if not ACache.SetMultiple(Updates, AUpdatedBy) then
    begin
      MxSendError(C, 500, 'update_failed');
      Exit;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(True));
      Json.AddPair('updated_count', TJSONNumber.Create(Updates.Count));
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Updates.Free;
    Body.Free;
  end;
end;

procedure HandleTestConnection(const C: THttpServerContext;
  ALogger: IMxLogger);
var
  Body, Json: TJSONObject;
  Url, Mode, Kind, ServerName, ServerVersion: string;
  UrlValue, ModeValue: TJSONValue;
  Client: THTTPClient;
  Response: IHTTPResponse;
  StartTime: TDateTime;
  LatencyMs: Integer;
  OkResult: Boolean;
  ErrMsg: string;
  StatusCode: Integer;
  McpBody: TStringStream;
  RespStream: TStringStream;
  ParsedValue, ResultValue, ServerInfoValue, NameValue, VerValue: TJSONValue;
  RespJson, ResultObj, ServerInfoObj, ErrorObjTyped: TJSONObject;
  ErrorValue, MsgValue: TJSONValue;
  RespText, LowerErr: string;
  IsMcpResponse, IsJsonAuthError: Boolean;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;

  ServerName := '';
  ServerVersion := '';

  try
    Url := '';
    UrlValue := Body.GetValue('url');
    if (UrlValue <> nil) and (UrlValue is TJSONString) then
      Url := (UrlValue as TJSONString).Value;

    if (Url = '') or not (Url.StartsWith('http://') or Url.StartsWith('https://')) then
    begin
      MxSendError(C, 400, 'invalid_url');
      Exit;
    end;

    // Mode auto-detect: URLs ending in /mcp -> MCP protocol test, else HTTP HEAD
    Mode := '';
    ModeValue := Body.GetValue('mode');
    if (ModeValue <> nil) and (ModeValue is TJSONString) then
      Mode := (ModeValue as TJSONString).Value;
    if Mode = '' then
    begin
      if Url.EndsWith('/mcp') or Url.EndsWith('/mcp/') then
        Mode := 'mcp'
      else
        Mode := 'http';
    end;

    OkResult := False;
    ErrMsg := '';
    StatusCode := 0;
    LatencyMs := 0;
    Kind := Mode;

    Client := THTTPClient.Create;
    try
      Client.ConnectionTimeout := 5000;
      Client.ResponseTimeout := 5000;
      Client.HandleRedirects := False;
      StartTime := Now;
      try
        if Mode = 'mcp' then
        begin
          // Send MCP JSON-RPC initialize request.
          // A real MCP server responds with JSON-RPC 2.0 envelope (result or error).
          // mxLore requires auth on /mcp -> returns 401. We accept 401 + any
          // 200-OK JSON-RPC response as "alive and MCP-compatible".
          McpBody := TStringStream.Create(
            '{"jsonrpc":"2.0","method":"initialize","params":{' +
            '"protocolVersion":"2024-11-05",' +
            '"capabilities":{},' +
            '"clientInfo":{"name":"mxLore-admin-test","version":"1.0"}' +
            '},"id":1}', TEncoding.UTF8);
          RespStream := TStringStream.Create('', TEncoding.UTF8);
          try
            Client.ContentType := 'application/json';
            Response := Client.Post(Url, McpBody, RespStream);
            LatencyMs := MilliSecondsBetween(Now, StartTime);
            StatusCode := Response.StatusCode;
            RespText := RespStream.DataString;

            // Parse response body as JSON.
            // We accept three JSON shapes as "MCP-compatible":
            //   1. JSON-RPC envelope with 'jsonrpc' field  -> real MCP server
            //   2. JSON-RPC error object with auth hint    -> foreign MCP auth wall
            //   3. Plain JSON with 'error' string containing auth hint -> mxLore auth wall
            //
            // Note: ParseJSONValue returns the owning TJSONValue (may be object,
            // array, string, number, null, bool). We use soft 'is' checks, never
            // `as`, to avoid EInvalidCast + leaks on non-object responses.
            IsMcpResponse := False;
            IsJsonAuthError := False;
            ParsedValue := nil;
            try
              ParsedValue := TJSONObject.ParseJSONValue(RespText);
              if (ParsedValue <> nil) and (ParsedValue is TJSONObject) then
              begin
                RespJson := TJSONObject(ParsedValue);

                // Shape 1: JSON-RPC envelope
                if RespJson.GetValue('jsonrpc') <> nil then
                begin
                  IsMcpResponse := True;
                  // Extract server info from result if present (unauthed init)
                  ResultValue := RespJson.GetValue('result');
                  if (ResultValue <> nil) and (ResultValue is TJSONObject) then
                  begin
                    ResultObj := TJSONObject(ResultValue);
                    ServerInfoValue := ResultObj.GetValue('serverInfo');
                    if (ServerInfoValue <> nil) and (ServerInfoValue is TJSONObject) then
                    begin
                      ServerInfoObj := TJSONObject(ServerInfoValue);
                      NameValue := ServerInfoObj.GetValue('name');
                      if (NameValue <> nil) and (NameValue is TJSONString) then
                        ServerName := TJSONString(NameValue).Value;
                      VerValue := ServerInfoObj.GetValue('version');
                      if (VerValue <> nil) and (VerValue is TJSONString) then
                        ServerVersion := TJSONString(VerValue).Value;
                    end;
                  end;
                end;

                // Check 'error' field — can be STRING (mxLore) or OBJECT (JSON-RPC error)
                ErrorValue := RespJson.GetValue('error');
                if ErrorValue <> nil then
                begin
                  if ErrorValue is TJSONString then
                  begin
                    // Shape 3: mxLore {"error":"Missing Authorization header"}
                    LowerErr := TJSONString(ErrorValue).Value.ToLower;
                    if LowerErr.Contains('authorization') or
                       LowerErr.Contains('api key') or
                       LowerErr.Contains('unauthorized') or
                       LowerErr.Contains('api-key') then
                      IsJsonAuthError := True;
                  end
                  else if ErrorValue is TJSONObject then
                  begin
                    // Shape 2: JSON-RPC error object { "code":..., "message":"..." }
                    ErrorObjTyped := TJSONObject(ErrorValue);
                    MsgValue := ErrorObjTyped.GetValue('message');
                    if (MsgValue <> nil) and (MsgValue is TJSONString) then
                    begin
                      LowerErr := TJSONString(MsgValue).Value.ToLower;
                      ErrMsg := 'MCP: ' + TJSONString(MsgValue).Value;
                      if LowerErr.Contains('authorization') or
                         LowerErr.Contains('api key') or
                         LowerErr.Contains('unauthorized') or
                         LowerErr.Contains('auth') then
                        IsJsonAuthError := True;
                    end;
                  end;
                end;
              end;
            except
              on E: Exception do
              begin
                IsMcpResponse := False;
                IsJsonAuthError := False;
              end;
            end;
            // Free the parsed value unconditionally (object, array, whatever)
            ParsedValue.Free;

            // Decision logic for MCP (strict — reverse proxies often return 401
            // for any path; we must verify the body is actually from an MCP server):
            //   200 + JSON-RPC envelope              -> real MCP server, OK
            //   401 + JSON-RPC error envelope        -> foreign MCP requiring auth, OK
            //   401 + mxLore fingerprint             -> mxLore requiring auth, OK
            //   401 + anything else                  -> NOT an MCP endpoint (proxy/IIS/etc.)
            //   404                                  -> URL wrong
            //   other                                -> not an MCP endpoint
            if (StatusCode = 200) and IsMcpResponse then
              OkResult := True
            else if StatusCode = 401 then
            begin
              // Accept 401 ONLY if JSON body proves this is an MCP server
              if IsMcpResponse then
              begin
                OkResult := True;  // JSON-RPC envelope = real MCP server
                if ErrMsg = '' then
                  ErrMsg := 'auth required (expected)';
              end
              else if IsJsonAuthError then
              begin
                OkResult := True;  // JSON error body with auth hint = mxLore-style
                if ErrMsg = '' then
                  ErrMsg := 'auth required (expected)';
              end
              else
              begin
                OkResult := False;
                ErrMsg := 'HTTP 401 but body is not JSON/MCP ' +
                          '(reverse proxy or generic auth wall)';
              end;
            end
            else if StatusCode = 404 then
            begin
              OkResult := False;
              ErrMsg := 'URL not found — check path (404)';
            end
            else if (StatusCode = 200) and not IsMcpResponse then
            begin
              OkResult := False;
              ErrMsg := 'Endpoint responds but is not MCP-compatible';
            end
            else if (StatusCode >= 500) and (StatusCode < 600) then
            begin
              OkResult := False;
              ErrMsg := 'Server error (' + IntToStr(StatusCode) + ')';
            end
            else
            begin
              OkResult := False;
              ErrMsg := 'Unexpected HTTP ' + IntToStr(StatusCode);
            end;
          finally
            McpBody.Free;
            RespStream.Free;
          end;
        end
        else
        begin
          // HTTP mode: HEAD request, classify by status code
          Response := Client.Head(Url);
          LatencyMs := MilliSecondsBetween(Now, StartTime);
          StatusCode := Response.StatusCode;

          if ((StatusCode >= 200) and (StatusCode < 400)) or
             (StatusCode = 401) or
             (StatusCode = 403) or
             (StatusCode = 405) then
            OkResult := True
          else if StatusCode = 404 then
          begin
            OkResult := False;
            ErrMsg := 'URL not found — check path (404)';
          end
          else if (StatusCode >= 500) and (StatusCode < 600) then
          begin
            OkResult := False;
            ErrMsg := 'Server error (' + IntToStr(StatusCode) + ')';
          end
          else
          begin
            OkResult := False;
            ErrMsg := 'Unexpected HTTP ' + IntToStr(StatusCode);
          end;
        end;
      except
        on E: ENetHTTPClientException do
        begin
          LatencyMs := MilliSecondsBetween(Now, StartTime);
          ErrMsg := E.Message;
          OkResult := False;
        end;
        on E: Exception do
        begin
          LatencyMs := MilliSecondsBetween(Now, StartTime);
          ErrMsg := E.Message;
          OkResult := False;
        end;
      end;
    finally
      Client.Free;
    end;

    Json := TJSONObject.Create;
    try
      Json.AddPair('ok', TJSONBool.Create(OkResult));
      Json.AddPair('kind', Kind);
      Json.AddPair('status_code', TJSONNumber.Create(StatusCode));
      Json.AddPair('latency_ms', TJSONNumber.Create(LatencyMs));
      if ErrMsg <> '' then
        Json.AddPair('error', ErrMsg);
      if ServerName <> '' then
        Json.AddPair('server_name', ServerName);
      if ServerVersion <> '' then
        Json.AddPair('server_version', ServerVersion);
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
  finally
    Body.Free;
  end;
end;

end.
