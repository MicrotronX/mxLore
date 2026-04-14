unit mx.Admin.Api.SelfUpdate;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Admin.Auth;

procedure HandleSelfUpdateStatus(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
procedure HandleSelfUpdateRecheck(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
procedure HandleSelfUpdateInstall(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.SyncObjs,
  mx.Errors, mx.Admin.Server, mx.Logic.SelfUpdate;

var
  gRecheckCooldown  : TDictionary<string, TDateTime>;
  gCooldownLock     : TCriticalSection;
  gInstallInFlight  : Boolean = False;
  gInstallLock      : TCriticalSection;

function SelfUpdateStateToString(AState: TMxUpdateState): string;
begin
  case AState of
    usIdle:            Result := 'idle';
    usUpdateAvailable: Result := 'update_available';
    usDownloading:     Result := 'downloading';
    usSwapping:        Result := 'swapping';
    usPostUpdateOk:    Result := 'post_update_ok';
    usError:           Result := 'error';
  else
    Result := 'unknown';
  end;
end;

function BuildStatusJson(const AInfo: TMxUpdateInfo): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('ok',             TJSONBool.Create(True));
  Result.AddPair('state',          SelfUpdateStateToString(AInfo.State));
  Result.AddPair('build_current',  TJSONNumber.Create(AInfo.CurrentBuild));
  Result.AddPair('build_latest',   TJSONNumber.Create(AInfo.LatestBuild));
  Result.AddPair('latest_tag',     AInfo.LatestTag);
  Result.AddPair('release_name',   AInfo.ReleaseName);
  Result.AddPair('zip_url',        AInfo.ZipUrl);
  Result.AddPair('zip_sha256',     AInfo.ZipSha256);
  Result.AddPair('last_checked',
    FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', AInfo.LastCheckedAt));
  Result.AddPair('error_message',  AInfo.ErrorMessage);
end;

function BuildDisabledJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONBool.Create(False));
  Result.AddPair('state', 'disabled');
end;

procedure HandleSelfUpdateStatus(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Info: TMxUpdateInfo;
  Json: TJSONObject;
begin
  if not MxSelfUpdate_Config.Enabled then
  begin
    Json := BuildDisabledJson;
    try
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
    Exit;
  end;

  Info := MxSelfUpdate_Check(False);
  ResetPostUpdateIfNeeded(Info);

  Json := BuildStatusJson(Info);
  try
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

procedure HandleSelfUpdateRecheck(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  Key: string;
  Last: TDateTime;
  OnCooldown: Boolean;
  Info: TMxUpdateInfo;
  Json, Obj: TJSONObject;
begin
  if not MxSelfUpdate_Config.Enabled then
  begin
    Json := BuildDisabledJson;
    try
      MxSendJson(C, 200, Json);
    finally
      Json.Free;
    end;
    Exit;
  end;

  Key := ASession.Token;
  OnCooldown := False;
  gCooldownLock.Enter;
  try
    if gRecheckCooldown.TryGetValue(Key, Last) and
       (SecondsBetween(Now, Last) < 60) then
      OnCooldown := True
    else
      gRecheckCooldown.AddOrSetValue(Key, Now);
  finally
    gCooldownLock.Leave;
  end;

  if OnCooldown then
  begin
    Obj := TJSONObject.Create;
    try
      Obj.AddPair('ok', TJSONBool.Create(False));
      Obj.AddPair('state', 'cooldown');
      Obj.AddPair('message', 'recheck cooldown 60s');
      MxSendJson(C, 429, Obj);
    finally
      Obj.Free;
    end;
    Exit;
  end;

  Info := MxSelfUpdate_Check(True);
  Json := BuildStatusJson(Info);
  try
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
  if Assigned(ALogger) then
    ALogger.Log(mlInfo, Format('SelfUpdate recheck by dev#%d: state=%s latest=%d',
      [ASession.DeveloperId, SelfUpdateStateToString(Info.State), Info.LatestBuild]));
end;

procedure HandleSelfUpdateInstall(const C: THttpServerContext;
  const ASession: TMxAdminSession; ALogger: IMxLogger);
var
  ClaimedSlot: Boolean;
  Obj: TJSONObject;
begin
  if not MxSelfUpdate_Config.Enabled then
  begin
    Obj := BuildDisabledJson;
    try
      MxSendJson(C, 200, Obj);
    finally
      Obj.Free;
    end;
    Exit;
  end;

  // Concurrent-install guard: only one Install may run at a time.
  ClaimedSlot := False;
  gInstallLock.Enter;
  try
    if not gInstallInFlight then
    begin
      gInstallInFlight := True;
      ClaimedSlot := True;
    end;
  finally
    gInstallLock.Leave;
  end;

  if not ClaimedSlot then
  begin
    Obj := TJSONObject.Create;
    try
      Obj.AddPair('ok', TJSONBool.Create(False));
      Obj.AddPair('state', 'busy');
      Obj.AddPair('message', 'install already in progress');
      MxSendJson(C, 409, Obj);
    finally
      Obj.Free;
    end;
    Exit;
  end;

  try
    if Assigned(ALogger) then
      ALogger.Log(mlInfo, Format('SelfUpdate install triggered by dev#%d',
        [ASession.DeveloperId]));

    // Acknowledge request BEFORE spawning the replacement, so the client
    // receives a response before the listener shuts down.
    Obj := TJSONObject.Create;
    try
      Obj.AddPair('ok', TJSONBool.Create(True));
      Obj.AddPair('state', 'swapping');
      Obj.AddPair('message', 'installing; server will restart');
      MxSendJson(C, 202, Obj);
    finally
      Obj.Free;
    end;

    // This halts the process after spawning the successor; handler never
    // returns past this line on success.
    MxSelfUpdate_InstallAndRestart;
  except
    on E: EMxError do
    begin
      gInstallLock.Enter;
      try
        gInstallInFlight := False;
      finally
        gInstallLock.Leave;
      end;
      if Assigned(ALogger) then
        ALogger.Log(mlError,
          'SelfUpdate install failed: ' + E.Code + ': ' + E.Message);
      // Response already sent above; nothing more to write.
    end;
    on E: Exception do
    begin
      gInstallLock.Enter;
      try
        gInstallInFlight := False;
      finally
        gInstallLock.Leave;
      end;
      if Assigned(ALogger) then
        ALogger.Log(mlError,
          'SelfUpdate install failed: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

initialization
  gRecheckCooldown := TDictionary<string, TDateTime>.Create;
  gCooldownLock    := TCriticalSection.Create;
  gInstallLock     := TCriticalSection.Create;

finalization
  gRecheckCooldown.Free;
  gCooldownLock.Free;
  gInstallLock.Free;

end.
