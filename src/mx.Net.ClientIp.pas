unit mx.Net.ClientIp;

// Shared client-IP resolution for the MCP and Admin HTTP surfaces (BR#19105).
// Lives in its own unit so mx.MCP.Server does not depend on mx.Admin.Server.

interface

uses
  System.SysUtils, Sparkle.HttpServer.Context;

/// <summary>
///   Returns the real client IP address. If the direct RemoteIp is listed in
///   ATrustedProxies (comma/semicolon/space-separated), walks X-Forwarded-For
///   from the RIGHT and returns the first hop that is not a trusted proxy.
///   Otherwise returns RemoteIp unchanged. Result is capped at 45 chars
///   (VARCHAR(45) audit columns).
/// </summary>
/// <remarks>
///   NEVER trust X-Forwarded-For without a trusted-proxy allow-list. The
///   LEFTMOST entry is client-controlled when the proxy appends (IIS ARR,
///   nginx proxy_add_x_forwarded_for), so it is never used. Setting key
///   'connect.trusted_proxies' is seeded to '127.0.0.1' at boot and re-seeded
///   when missing; an empty value ignores XFF (fail-closed).
/// </remarks>
function MxGetClientIp(const C: THttpServerContext;
  const ATrustedProxies: string): string;

implementation

function IsInList(const AAddr: string; const AList: TArray<string>): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AList) do
    if SameText(Trim(AList[I]), AAddr) then
    begin
      Result := True;
      Exit;
    end;
end;

function MxGetClientIp(const C: THttpServerContext;
  const ATrustedProxies: string): string;
var
  ForwardedFor, Hop, Picked: string;
  ProxyList, Hops: TArray<string>;
  I: Integer;
begin
  Result := C.Request.RemoteIp;
  if (Result = '') or (ATrustedProxies = '') then Exit;

  // Is the direct peer in the trusted-proxy allow-list?
  ProxyList := ATrustedProxies.Split([',', ';', ' '],
    TStringSplitOptions.ExcludeEmpty);
  if not IsInList(Result, ProxyList) then Exit;

  // Trusted peer: X-Forwarded-For from the RIGHT, first non-trusted hop wins.
  if not C.Request.Headers.GetIfExists('X-Forwarded-For', ForwardedFor) then
    Exit;
  Hops := ForwardedFor.Split([','], TStringSplitOptions.ExcludeEmpty);
  Picked := '';
  for I := High(Hops) downto 0 do
  begin
    Hop := Trim(Hops[I]);
    if Hop = '' then Continue;
    if not IsInList(Hop, ProxyList) then
    begin
      Picked := Hop;
      Break;
    end;
  end;
  if Picked = '' then Exit;  // every hop is a trusted proxy: keep peer IP

  Result := Picked;
  if Length(Result) > 45 then
    Result := Copy(Result, 1, 45);
end;

end.
