unit mx.Logic.Settings;

// v2.4.0: Runtime settings cache with thread-safe read access.
// Wraps mx.Data.Settings with in-memory cache + TMultiReadExclusiveWriteSynchronizer.
// Cache is invalidated on every write; reads are lock-free after first load.
//
// Also provides Auto-Detect for internal host (LAN IP) via Windows GetAdaptersAddresses.

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  {$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.Winsock2, Winapi.IpHlpApi, Winapi.IpTypes,
  {$ENDIF}
  mx.Types, mx.Data.Pool, mx.Data.Settings;

{$IFDEF MSWINDOWS}
// MIB-II ifType constants (not exposed by Winapi.IpTypes)
// Source: IANA ifType-MIB, https://www.iana.org/assignments/ianaiftype-mib/
const
  IF_TYPE_SOFTWARE_LOOPBACK = 24;
  IF_TYPE_TUNNEL            = 131;
{$ENDIF}

type
  TMxSettingsCache = class
  private
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FPool: TMxConnectionPool;
    FCache: TDictionary<string, string>;
    FLoaded: Boolean;
    procedure EnsureLoaded;
  public
    constructor Create(APool: TMxConnectionPool);
    destructor Destroy; override;

    // Thread-safe read. Returns empty string if key missing.
    function Get(const AKey: string): string;

    // Returns all settings as a copy (snapshot).
    function GetAll: TDictionary<string, string>;

    // Forces reload from DB on next Get.
    procedure Invalidate;

    // Thread-safe write. Writes to DB and invalidates cache.
    function SetValue(const AKey, AValue: string; AUpdatedBy: Integer): Boolean;

    // Atomic batch write. Transaction-safe, invalidates cache on success.
    function SetMultiple(const AUpdates: TDictionary<string, string>;
      AUpdatedBy: Integer): Boolean;
  end;

// Global helper: Get internal host. Returns connect.internal_host setting,
// or Auto-Detect LAN IP if setting is empty. Falls back to '127.0.0.1'.
function ResolveInternalHost(ACache: TMxSettingsCache): string;

// Windows: detect first non-loopback IPv4 adapter. Returns '' on failure.
function DetectLanIP: string;

implementation

uses
  System.Win.ComObj;

{ TMxSettingsCache }

constructor TMxSettingsCache.Create(APool: TMxConnectionPool);
begin
  inherited Create;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FPool := APool;
  FCache := TDictionary<string, string>.Create;
  FLoaded := False;
end;

destructor TMxSettingsCache.Destroy;
begin
  FCache.Free;
  FLock.Free;
  inherited;
end;

procedure TMxSettingsCache.EnsureLoaded;
var
  Ctx: IMxDbContext;
  Records: TArray<TMxSettingRecord>;
  Rec: TMxSettingRecord;
begin
  // Fast path: already loaded
  FLock.BeginRead;
  try
    if FLoaded then Exit;
  finally
    FLock.EndRead;
  end;

  // Slow path: reload from DB under write lock
  FLock.BeginWrite;
  try
    if FLoaded then Exit;  // Double-check after lock upgrade

    Ctx := FPool.AcquireContext;
    try
      Records := TMxSettingsData.GetAllSettings(Ctx);
      FCache.Clear;
      for Rec in Records do
        FCache.AddOrSetValue(Rec.Key, Rec.Value);
      FLoaded := True;
    finally
      Ctx := nil;
    end;
  finally
    FLock.EndWrite;
  end;
end;

function TMxSettingsCache.Get(const AKey: string): string;
begin
  EnsureLoaded;
  FLock.BeginRead;
  try
    if not FCache.TryGetValue(AKey, Result) then
      Result := '';
  finally
    FLock.EndRead;
  end;
end;

function TMxSettingsCache.GetAll: TDictionary<string, string>;
var
  Pair: TPair<string, string>;
begin
  EnsureLoaded;
  Result := TDictionary<string, string>.Create;
  FLock.BeginRead;
  try
    for Pair in FCache do
      Result.AddOrSetValue(Pair.Key, Pair.Value);
  finally
    FLock.EndRead;
  end;
end;

procedure TMxSettingsCache.Invalidate;
begin
  FLock.BeginWrite;
  try
    FLoaded := False;
    FCache.Clear;
  finally
    FLock.EndWrite;
  end;
end;

function TMxSettingsCache.SetValue(const AKey, AValue: string;
  AUpdatedBy: Integer): Boolean;
var
  Ctx: IMxDbContext;
begin
  Ctx := FPool.AcquireContext;
  try
    Result := TMxSettingsData.SetSetting(Ctx, AKey, AValue, AUpdatedBy);
    if Result then
      Invalidate;
  finally
    Ctx := nil;
  end;
end;

function TMxSettingsCache.SetMultiple(const AUpdates: TDictionary<string, string>;
  AUpdatedBy: Integer): Boolean;
var
  Ctx: IMxDbContext;
begin
  Ctx := FPool.AcquireContext;
  try
    Result := TMxSettingsData.SetMultipleSettings(Ctx, AUpdates, AUpdatedBy);
    if Result then
      Invalidate;
  finally
    Ctx := nil;
  end;
end;

{ Helpers }

function DetectLanIP: string;
{$IFDEF MSWINDOWS}
var
  AdaptersSize: ULONG;
  AdaptersBuf: Pointer;
  Adapter: PIP_ADAPTER_ADDRESSES;
  UnicastAddr: PIP_ADAPTER_UNICAST_ADDRESS;
  SockAddr: PSockAddrIn;
  IP: string;
  Ret: DWORD;
{$ENDIF}
begin
  Result := '';
  {$IFDEF MSWINDOWS}
  AdaptersSize := 15000;  // Reasonable initial buffer
  AdaptersBuf := nil;
  GetMem(AdaptersBuf, AdaptersSize);
  try
    Ret := GetAdaptersAddresses(AF_INET, 0, nil, AdaptersBuf, @AdaptersSize);
    if Ret = ERROR_BUFFER_OVERFLOW then
    begin
      // Resize: free first, null out pointer so a failing GetMem leaves
      // AdaptersBuf = nil for the finally block (no double-free).
      FreeMem(AdaptersBuf);
      AdaptersBuf := nil;
      GetMem(AdaptersBuf, AdaptersSize);
      Ret := GetAdaptersAddresses(AF_INET, 0, nil, AdaptersBuf, @AdaptersSize);
    end;

    if Ret <> NO_ERROR then Exit;

    Adapter := AdaptersBuf;
    while Adapter <> nil do
    begin
      // Skip loopback, down interfaces, tunnel/virtual
      if (Adapter^.OperStatus = IfOperStatusUp) and
         (Adapter^.IfType <> IF_TYPE_SOFTWARE_LOOPBACK) and
         (Adapter^.IfType <> IF_TYPE_TUNNEL) then
      begin
        UnicastAddr := Adapter^.FirstUnicastAddress;
        while UnicastAddr <> nil do
        begin
          if UnicastAddr^.Address.lpSockaddr^.sa_family = AF_INET then
          begin
            SockAddr := PSockAddrIn(UnicastAddr^.Address.lpSockaddr);
            IP := Format('%d.%d.%d.%d', [
              SockAddr^.sin_addr.S_un_b.s_b1,
              SockAddr^.sin_addr.S_un_b.s_b2,
              SockAddr^.sin_addr.S_un_b.s_b3,
              SockAddr^.sin_addr.S_un_b.s_b4
            ]);
            // Prefer private ranges: 10.x, 172.16-31, 192.168.x
            if (SockAddr^.sin_addr.S_un_b.s_b1 = 10) or
               ((SockAddr^.sin_addr.S_un_b.s_b1 = 172) and
                (SockAddr^.sin_addr.S_un_b.s_b2 >= 16) and
                (SockAddr^.sin_addr.S_un_b.s_b2 <= 31)) or
               ((SockAddr^.sin_addr.S_un_b.s_b1 = 192) and
                (SockAddr^.sin_addr.S_un_b.s_b2 = 168)) then
            begin
              Result := IP;
              Exit;  // Prefer first private IP found
            end;
            if Result = '' then
              Result := IP;  // Fallback: first public non-loopback
          end;
          UnicastAddr := UnicastAddr^.Next;
        end;
      end;
      Adapter := Adapter^.Next;
    end;
  finally
    if AdaptersBuf <> nil then
      FreeMem(AdaptersBuf);
  end;
  {$ENDIF}
end;

function ResolveInternalHost(ACache: TMxSettingsCache): string;
begin
  if Assigned(ACache) then
    Result := ACache.Get('connect.internal_host')
  else
    Result := '';

  if Result = '' then
    Result := DetectLanIP;

  if Result = '' then
    Result := '127.0.0.1';  // Last-resort fallback
end;

end.
