unit mx.Tool.Fetch;

interface

uses
  System.SysUtils, System.JSON, System.Classes, System.Generics.Collections,
  System.Net.HttpClient, System.Net.URLClient, System.NetEncoding,
  System.SyncObjs, System.DateUtils,
  mx.Types, mx.Errors, mx.Config;

procedure InitFetchConfig(const AConfig: TMxConfig);

function HandleFetch(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// mx_fetch — HTTP fetch tool with host allowlist, header whitelist, rate-limit,
// redirect containment (same-host only), body truncation (UTF-8 safe).
// Security: never log E.Message, never leak request headers.
// ---------------------------------------------------------------------------

var
  gAllowedHosts: TArray<string>;
  gFetchInitialized: Boolean = False;
  gRateLimit: TDictionary<Integer, TDateTime>;
  gRateLimitLock: TCriticalSection;

const
  cMaxBodyBytes        = 51200;   // 50 KiB response body cap
  cMaxOutboundBodyBytes = 262144; // 256 KiB outbound POST body cap
  cMaxRedirects        = 3;       // hard cap on redirect hops
  cDefaultTimeoutMs    = 10000;
  cMinTimeoutMs        = 500;     // matches spec #2076 AC4
  cMaxTimeoutMs        = 60000;
  cRateLimitMs         = 1000;    // 1 req/sec per session
  cRateLimitPruneSec   = 60;      // drop buckets older than 60s

// Allowed request headers (case-insensitive match).
function IsHeaderAllowed(const AName: string): Boolean;
var
  L: string;
begin
  L := LowerCase(AName);
  Result := (L = 'authorization') or
            (L = 'x-mxsa-key') or
            (L = 'x-api-key') or
            (L = 'content-type') or
            (L = 'accept');
end;

function IsHostAllowed(const AHost: string): Boolean;
var
  I: Integer;
  H: string;
begin
  Result := False;
  H := LowerCase(AHost);
  for I := 0 to High(gAllowedHosts) do
    if LowerCase(gAllowedHosts[I]) = H then
      Exit(True);
end;

// Drop rate-limit buckets older than cRateLimitPruneSec. Caller holds lock.
procedure PruneRateLimit;
var
  Cutoff: TDateTime;
  Pair: TPair<Integer, TDateTime>;
  ToRemove: TList<Integer>;
begin
  Cutoff := IncSecond(Now, -cRateLimitPruneSec);
  ToRemove := TList<Integer>.Create;
  try
    for Pair in gRateLimit do
      if Pair.Value < Cutoff then
        ToRemove.Add(Pair.Key);
    for var K in ToRemove do
      gRateLimit.Remove(K);
  finally
    ToRemove.Free;
  end;
end;

// Trim trailing UTF-8 continuation bytes so the resulting buffer decodes cleanly.
// A continuation byte has the top two bits = 10 ((b and $C0) = $80). A leading
// byte of a multi-byte sequence starts with 11xxxxxx. We walk back at most 3
// bytes: if we find a leading byte, drop it and its remaining continuation
// bytes; if we find an ASCII byte (0xxxxxxx) we stop.
procedure TrimUtf8Boundary(var ABytes: TBytes);
var
  Len, I, Back: Integer;
  B: Byte;
begin
  Len := Length(ABytes);
  if Len = 0 then
    Exit;
  // Scan back up to 3 bytes looking for either an ASCII byte (safe) or a
  // multi-byte leading byte that may be incomplete.
  for Back := 0 to 3 do
  begin
    I := Len - 1 - Back;
    if I < 0 then
      Exit;
    B := ABytes[I];
    if (B and $80) = 0 then
      Exit; // pure ASCII — safe boundary
    if (B and $C0) = $C0 then
    begin
      // Leading byte of a multi-byte sequence. Determine expected length.
      var Expected: Integer := 0;
      if (B and $E0) = $C0 then Expected := 2
      else if (B and $F0) = $E0 then Expected := 3
      else if (B and $F8) = $F0 then Expected := 4
      else Expected := 0;
      // Bytes available starting at I = Len - I
      if (Expected > 0) and ((Len - I) < Expected) then
        SetLength(ABytes, I);
      Exit;
    end;
    // else continuation byte: keep walking back
  end;
  // If we walked back 4 continuation bytes without seeing a lead, data is
  // malformed — strip the dangling tail conservatively.
  SetLength(ABytes, Len - 4);
end;

procedure InitFetchConfig(const AConfig: TMxConfig);
begin
  gAllowedHosts := AConfig.FetchAllowedHosts;
  gFetchInitialized := True;
end;

// ---------------------------------------------------------------------------
// mx_fetch — whitelisted HTTP client for outbound tool calls
// ---------------------------------------------------------------------------
function HandleFetch(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  URL, Method, OriginalHost, CurrentUrl, BodyStr, ContentType: string;
  TimeoutMs, SessionId, RedirectCount, StatusCode: Integer;
  FollowRedirects, Truncated, HasUserContentType, HasUserAccept: Boolean;
  HeadersJson, Data, RespHeaders: TJSONObject;
  ParsedBody: TJSONValue;
  URI, RedirectURI: TURI;
  Http: THTTPClient;
  ReqStream: TStringStream;
  RespStream: TBytesStream;
  Response: IHTTPResponse;
  LHeaders: TArray<TNetHeader>;
  RespBytes: TBytes;
  Pair: TJSONPair;
  HeaderName, HeaderValue, Location: string;
  LastTime: TDateTime;
  I: Integer;
begin
  if not gFetchInitialized then
    raise EMxValidation.Create(
      'mx_fetch not initialized — call InitFetchConfig at boot');

  // ---- Parameter extraction & validation ----------------------------------
  URL := AParams.GetValue<string>('url', '');
  if URL.Trim.IsEmpty then
    raise EMxValidation.Create('Parameter "url" is required');

  Method := UpperCase(AParams.GetValue<string>('method', 'GET'));
  if (Method <> 'GET') and (Method <> 'POST') then
    raise EMxValidation.Create('Method must be GET or POST');

  // Spec #2076 FR: body is forbidden on GET (clarity over silent ignore)
  if (Method = 'GET') and (AParams.GetValue<string>('body', '') <> '') then
    raise EMxValidation.Create('Parameter "body" is not allowed for GET requests');

  // body comes as JSON-encoded string (mptString in registry, matching
  // mx_agent_send.payload convention). Parse, validate, serialize back, free.
  HeadersJson := nil;
  BodyStr := '';
  var LBodyParam := AParams.GetValue<string>('body', '');
  if LBodyParam <> '' then
  begin
    var LBV := TJSONObject.ParseJSONValue(LBodyParam);
    if (LBV = nil) or not (LBV is TJSONObject) then
    begin
      LBV.Free;
      raise EMxValidation.Create('Parameter "body" must be a JSON object');
    end;
    try
      BodyStr := (LBV as TJSONObject).ToJSON;
    finally
      LBV.Free;
    end;
    // Spec #2076 NFR-Security: outbound POST body cap 256 KiB
    if Length(BodyStr) > cMaxOutboundBodyBytes then
      raise EMxValidation.CreateFmt(
        'Parameter "body" exceeds %d bytes (got %d)',
        [cMaxOutboundBodyBytes, Length(BodyStr)]);
  end;

  TimeoutMs := AParams.GetValue<Integer>('timeout_ms', cDefaultTimeoutMs);
  if TimeoutMs < cMinTimeoutMs then TimeoutMs := cMinTimeoutMs;
  if TimeoutMs > cMaxTimeoutMs then TimeoutMs := cMaxTimeoutMs;

  FollowRedirects := AParams.GetValue<Boolean>('follow_redirects', True);
  SessionId := AParams.GetValue<Integer>('session_id', 0);

  // ---- URL parsing & host allowlist --------------------------------------
  try
    URI := TURI.Create(URL);
  except
    raise EMxValidation.Create('Invalid URL');
  end;

  if (LowerCase(URI.Scheme) <> 'http') and (LowerCase(URI.Scheme) <> 'https') then
    raise EMxValidation.Create('Scheme must be http or https');

  OriginalHost := LowerCase(URI.Host);
  if not IsHostAllowed(OriginalHost) then
    raise EMxValidation.Create(
      'Host "' + OriginalHost + '" not in [Fetch] AllowedHosts');

  // ---- Header whitelist ---------------------------------------------------
  // headers also come as JSON-encoded string. Parse INSIDE the try/finally
  // so we own + free it without leaking on any earlier raise (URL parse,
  // scheme/host check). All raise points before this line are safe because
  // The body parse is already complete (BodyStr extracted) and HeadersJson
  // has not been allocated yet — no leak window for either resource.
  HasUserContentType := False;
  HasUserAccept := False;
  SetLength(LHeaders, 0);
  var LHeadersParam := AParams.GetValue<string>('headers', '');
  if LHeadersParam <> '' then
  begin
    var LHV := TJSONObject.ParseJSONValue(LHeadersParam);
    if (LHV = nil) or not (LHV is TJSONObject) then
    begin
      LHV.Free;
      raise EMxValidation.Create('Parameter "headers" must be a JSON object');
    end;
    HeadersJson := LHV as TJSONObject;
  end;
  try
    if HeadersJson <> nil then
    begin
      for I := 0 to HeadersJson.Count - 1 do
      begin
        Pair := HeadersJson.Pairs[I];
        HeaderName := Pair.JsonString.Value;
        if not IsHeaderAllowed(HeaderName) then
          raise EMxValidation.Create(
            'Header "' + HeaderName + '" not in whitelist');
        // Header value must be a JSON string (not number/array/object)
        if not (Pair.JsonValue is TJSONString) then
          raise EMxValidation.Create(
            'Header "' + HeaderName + '" value must be a JSON string');
        HeaderValue := Pair.JsonValue.Value;
        SetLength(LHeaders, Length(LHeaders) + 1);
        LHeaders[High(LHeaders)] := TNetHeader.Create(HeaderName, HeaderValue);
        if LowerCase(HeaderName) = 'content-type' then HasUserContentType := True;
        if LowerCase(HeaderName) = 'accept' then HasUserAccept := True;
      end;
    end;
  finally
    HeadersJson.Free;
    HeadersJson := nil;
  end;

  // For POST: force application/json Content-Type (overrides user value).
  if Method = 'POST' then
  begin
    if HasUserContentType then
    begin
      for I := 0 to High(LHeaders) do
        if LowerCase(LHeaders[I].Name) = 'content-type' then
          LHeaders[I] := TNetHeader.Create('Content-Type', 'application/json');
    end
    else
    begin
      SetLength(LHeaders, Length(LHeaders) + 1);
      LHeaders[High(LHeaders)] :=
        TNetHeader.Create('Content-Type', 'application/json');
    end;
  end;

  if not HasUserAccept then
  begin
    SetLength(LHeaders, Length(LHeaders) + 1);
    LHeaders[High(LHeaders)] :=
      TNetHeader.Create('Accept', 'application/json, */*;q=0.8');
  end;

  // ---- Rate limit ---------------------------------------------------------
  gRateLimitLock.Enter;
  try
    PruneRateLimit;
    if gRateLimit.TryGetValue(SessionId, LastTime) then
      if MilliSecondsBetween(Now, LastTime) < cRateLimitMs then
        raise EMxValidation.Create(
          'Rate limit: max 1 request per second per session');
    gRateLimit.AddOrSetValue(SessionId, Now);
  finally
    gRateLimitLock.Leave;
  end;

  // ---- Build request body stream (POST only) -----------------------------
  ReqStream := nil;
  if Method = 'POST' then
    // BodyStr was extracted earlier from the parsed JSON object
    ReqStream := TStringStream.Create(BodyStr, TEncoding.UTF8);

  // ---- HTTP execution with manual redirect handling ----------------------
  CurrentUrl := URL;
  RedirectCount := 0;
  Response := nil;
  RespStream := nil;
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := TimeoutMs;
    Http.ResponseTimeout := TimeoutMs;
    Http.HandleRedirects := False;

    while True do
    begin
      if RedirectCount > cMaxRedirects then
        raise EMxValidation.Create('Too many redirects (max 3)');

      if RespStream <> nil then
      begin
        RespStream.Free;
        RespStream := nil;
      end;
      RespStream := TBytesStream.Create;

      try
        if Method = 'GET' then
          Response := Http.Get(CurrentUrl, RespStream, LHeaders)
        else
        begin
          if ReqStream <> nil then
            ReqStream.Position := 0;
          Response := Http.Post(CurrentUrl, ReqStream, RespStream, LHeaders);
        end;
      except
        on E: Exception do
          // Security: never include E.Message — may echo credentials/tokens
          raise EMxValidation.Create('HTTP fetch failed: ' + E.ClassName);
      end;

      StatusCode := Response.StatusCode;
      if FollowRedirects and
         ((StatusCode = 301) or (StatusCode = 302) or (StatusCode = 303) or
          (StatusCode = 307) or (StatusCode = 308)) then
      begin
        Location := Response.HeaderValue['Location'];
        if Location.Trim.IsEmpty then
          Break;
        try
          RedirectURI := TURI.Create(Location);
        except
          raise EMxValidation.Create('Invalid redirect URL');
        end;
        if LowerCase(RedirectURI.Host) <> OriginalHost then
          raise EMxValidation.Create('Cross-host redirect not allowed');
        CurrentUrl := Location;
        Inc(RedirectCount);
        Continue;
      end;

      Break;
    end;

    // ---- Response body: read, truncate, UTF-8 boundary fix ---------------
    RespStream.Position := 0;
    RespBytes := RespStream.Bytes;
    // TBytesStream.Bytes may be oversized — trim to Size first.
    if Length(RespBytes) > RespStream.Size then
      SetLength(RespBytes, RespStream.Size);

    Truncated := False;
    if Length(RespBytes) > cMaxBodyBytes then
    begin
      SetLength(RespBytes, cMaxBodyBytes);
      Truncated := True;
      TrimUtf8Boundary(RespBytes);
    end;

    BodyStr := TEncoding.UTF8.GetString(RespBytes);

    // ---- Build response JSON --------------------------------------------
    Data := TJSONObject.Create;
    try
      Data.AddPair('status_code', TJSONNumber.Create(StatusCode));

      RespHeaders := TJSONObject.Create;
      HeaderValue := Response.HeaderValue['Content-Type'];
      if HeaderValue <> '' then
        RespHeaders.AddPair('Content-Type', HeaderValue);
      HeaderValue := Response.HeaderValue['Content-Length'];
      if HeaderValue <> '' then
        RespHeaders.AddPair('Content-Length', HeaderValue);
      HeaderValue := Response.HeaderValue['Date'];
      if HeaderValue <> '' then
        RespHeaders.AddPair('Date', HeaderValue);
      HeaderValue := Response.HeaderValue['Server'];
      if HeaderValue <> '' then
        RespHeaders.AddPair('Server', HeaderValue);
      Data.AddPair('headers', RespHeaders);

      ContentType := LowerCase(Response.HeaderValue['Content-Type']);
      ParsedBody := nil;
      if Pos('application/json', ContentType) > 0 then
        ParsedBody := TJSONObject.ParseJSONValue(BodyStr);
      if ParsedBody <> nil then
        Data.AddPair('body', ParsedBody)
      else
        Data.AddPair('body', BodyStr);

      Data.AddPair('truncated', TJSONBool.Create(Truncated));
      Data.AddPair('final_url', CurrentUrl);
      Data.AddPair('redirect_count', TJSONNumber.Create(RedirectCount));

      Result := MxSuccessResponse(Data);
    except
      Data.Free;
      raise;
    end;
  finally
    if RespStream <> nil then
      RespStream.Free;
    if ReqStream <> nil then
      ReqStream.Free;
    Http.Free;
  end;
end;

initialization
  gRateLimit := TDictionary<Integer, TDateTime>.Create;
  gRateLimitLock := TCriticalSection.Create;

finalization
  gRateLimit.Free;
  gRateLimitLock.Free;

end.
