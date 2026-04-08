unit mx.Proxy.Http;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  System.Net.HttpClient, System.Net.URLClient, System.NetConsts,
  System.Generics.Collections;

type
  TMxProxyHttpClient = class
  private
    FUrl: string;
    FApiKey: string;
    FConnectionTimeout: Integer;
    FReadTimeout: Integer;
    FSessionId: string;
    FClient: THTTPClient;
    function BuildErrorResponse(const AId: TJSONValue;
      ACode: Integer; const AMessage: string): string;
    function ParseSSEData(const AResponseBody: string): TArray<string>;
    function GetResponseHeader(const AResponse: IHTTPResponse;
      const AName: string): string;
    function ReInitialize: Boolean;
  public
    constructor Create(const AUrl, AApiKey: string;
      AConnectionTimeout, AReadTimeout: Integer);
    destructor Destroy; override;
    function Forward(const AJsonRpcLine: string;
      out ANewSessionId: string): TArray<string>;
    property SessionId: string read FSessionId write FSessionId;
  end;

implementation

constructor TMxProxyHttpClient.Create(const AUrl, AApiKey: string;
  AConnectionTimeout, AReadTimeout: Integer);
begin
  inherited Create;
  FUrl := AUrl;
  FApiKey := AApiKey;
  FConnectionTimeout := AConnectionTimeout;
  FReadTimeout := AReadTimeout;
  FClient := THTTPClient.Create;
  FClient.ConnectionTimeout := FConnectionTimeout;
  FClient.ResponseTimeout := FReadTimeout;
end;

destructor TMxProxyHttpClient.Destroy;
begin
  FClient.Free;
  inherited;
end;

function TMxProxyHttpClient.BuildErrorResponse(const AId: TJSONValue;
  ACode: Integer; const AMessage: string): string;
var
  Resp, Err: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    if (AId <> nil) and not (AId is TJSONNull) then
      Resp.AddPair('id', AId.Clone as TJSONValue)
    else
      Resp.AddPair('id', TJSONNull.Create);
    Err := TJSONObject.Create;
    Err.AddPair('code', TJSONNumber.Create(ACode));
    Err.AddPair('message', AMessage);
    Resp.AddPair('error', Err);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

function TMxProxyHttpClient.ParseSSEData(const AResponseBody: string): TArray<string>;
var
  Lines: TArray<string>;
  I: Integer;
  CurrentData: string;
  ResultList: TList<string>;
  Line: string;
begin
  ResultList := TList<string>.Create;
  try
    Lines := AResponseBody.Split([#10]);
    CurrentData := '';
    for I := 0 to High(Lines) do
    begin
      Line := Lines[I].TrimRight([#13]);
      if Line.StartsWith('data:') then
      begin
        if CurrentData <> '' then
          CurrentData := CurrentData + #10 + Line.Substring(5).TrimLeft
        else
          CurrentData := Line.Substring(5).TrimLeft;
      end
      else if (Line = '') and (CurrentData <> '') then
      begin
        ResultList.Add(CurrentData);
        CurrentData := '';
      end;
      // event:, id:, retry: — ignorieren
    end;
    if CurrentData <> '' then
      ResultList.Add(CurrentData);
    Result := ResultList.ToArray;
  finally
    ResultList.Free;
  end;
end;

function TMxProxyHttpClient.GetResponseHeader(const AResponse: IHTTPResponse;
  const AName: string): string;
var
  Header: TNameValuePair;
begin
  Result := '';
  for Header in AResponse.Headers do
    if SameText(Header.Name, AName) then
      Exit(Header.Value);
end;

function TMxProxyHttpClient.ReInitialize: Boolean;
var
  InitBody, NotifBody: TStringStream;
  Response: IHTTPResponse;
  NewSid: string;
begin
  Result := False;
  WriteLn(ErrOutput, 'INFO: Re-Initialize MCP session...');

  // Schritt 1: initialize Request
  InitBody := TStringStream.Create(
    '{"jsonrpc":"2.0","id":"_reinit","method":"initialize","params":{' +
    '"protocolVersion":"2024-11-05","capabilities":{},' +
    '"clientInfo":{"name":"mxMCPProxy","version":"1.0.2"}}}',
    TEncoding.UTF8);
  try
    FClient.CustomHeaders['Content-Type'] := 'application/json';
    FClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
    FClient.CustomHeaders['Accept'] := 'application/json, text/event-stream';
    FClient.CustomHeaders['Mcp-Session-Id'] := '';

    Response := FClient.Post(FUrl, InitBody);
    if not (Response.StatusCode in [200, 201, 202]) then
    begin
      WriteLn(ErrOutput, 'ERROR: Re-Initialize failed: HTTP ' +
        IntToStr(Response.StatusCode));
      Exit;
    end;

    NewSid := GetResponseHeader(Response, 'Mcp-Session-Id');
    if NewSid <> '' then
      FSessionId := NewSid;
  finally
    InitBody.Free;
  end;

  // Schritt 2: initialized Notification
  NotifBody := TStringStream.Create(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    TEncoding.UTF8);
  try
    FClient.CustomHeaders['Content-Type'] := 'application/json';
    FClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
    if FSessionId <> '' then
      FClient.CustomHeaders['Mcp-Session-Id'] := FSessionId;

    FClient.Post(FUrl, NotifBody);
    // Notification hat keine Response — ignorieren
  finally
    NotifBody.Free;
  end;

  WriteLn(ErrOutput, 'INFO: Re-Initialize OK, neue Session: ' + FSessionId);
  Result := True;
end;

function TMxProxyHttpClient.Forward(const AJsonRpcLine: string;
  out ANewSessionId: string): TArray<string>;
var
  RequestBody: TStringStream;
  Response: IHTTPResponse;
  ContentType, ResponseBody: string;
  RequestId: TJSONValue;
  ParsedReq: TJSONObject;
  RetryCount: Integer;
begin
  ANewSessionId := '';
  SetLength(Result, 0);

  RequestId := nil;
  ParsedReq := nil;
  try
    ParsedReq := TJSONObject.ParseJSONValue(AJsonRpcLine) as TJSONObject;
    if ParsedReq <> nil then
      RequestId := ParsedReq.GetValue('id');
  except
    // Parse-Fehler: RequestId bleibt nil
  end;

  try
    for RetryCount := 0 to 1 do
    begin
      RequestBody := TStringStream.Create(AJsonRpcLine, TEncoding.UTF8);
      try
        try
          FClient.CustomHeaders['Content-Type'] := 'application/json';
          FClient.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
          FClient.CustomHeaders['Accept'] := 'application/json, text/event-stream';
          if FSessionId <> '' then
            FClient.CustomHeaders['Mcp-Session-Id'] := FSessionId
          else
            FClient.CustomHeaders['Mcp-Session-Id'] := '';

          Response := FClient.Post(FUrl, RequestBody);

          ANewSessionId := GetResponseHeader(Response, 'Mcp-Session-Id');

          case Response.StatusCode of
            200, 201, 202:
              begin
                ContentType := Response.MimeType.ToLower;
                ResponseBody := Response.ContentAsString(TEncoding.UTF8);

                if ContentType.Contains('text/event-stream') then
                  Result := ParseSSEData(ResponseBody)
                else
                begin
                  SetLength(Result, 1);
                  Result[0] := ResponseBody;
                end;
                Break;
              end;
            401, 403:
              begin
                SetLength(Result, 1);
                Result[0] := BuildErrorResponse(RequestId, -32001, 'Authentication failed');
                Break;
              end;
            400, 404:
              begin
                if RetryCount = 0 then
                begin
                  // Stale Session oder Server-Restart: Re-Initialize
                  if ReInitialize then
                  begin
                    ANewSessionId := FSessionId; // Neue Session an Core melden
                    WriteLn(ErrOutput, 'INFO: Re-Initialize erfolgreich, retry mit neuer Session');
                    Continue;
                  end;
                end;
                SetLength(Result, 1);
                Result[0] := BuildErrorResponse(RequestId, -32002,
                  Format('Server error: HTTP %d', [Response.StatusCode]));
                Break;
              end;
          else
            begin
              SetLength(Result, 1);
              Result[0] := BuildErrorResponse(RequestId, -32002,
                Format('Server error: HTTP %d', [Response.StatusCode]));
              Break;
            end;
          end;
        except
          on E: ENetHTTPClientException do
          begin
            if RetryCount = 0 then
            begin
              WriteLn(ErrOutput, 'WARN: Connection-Fehler, retry in 1s: ' + E.Message);
              Sleep(1000);
              Continue;
            end;
            SetLength(Result, 1);
            Result[0] := BuildErrorResponse(RequestId, -32000, 'MCP server unreachable');
            Break;
          end;
          on E: Exception do
          begin
            SetLength(Result, 1);
            Result[0] := BuildErrorResponse(RequestId, -32603, E.Message);
            Break;
          end;
        end;
      finally
        RequestBody.Free;
      end;
    end;
  finally
    ParsedReq.Free;
  end;
end;

end.
