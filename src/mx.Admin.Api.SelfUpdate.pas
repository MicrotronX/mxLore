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
  System.SysUtils, System.Classes, System.JSON, System.DateUtils,
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
var
  ErrText: string;
  ErrAt: TDateTime;
  HasErr: Boolean;
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
  // C7b: surface the transient install-error channel so the UI can
  // render banner/Settings text even when the cached state hasn't been
  // flipped (e.g. pre-C7b builds). SetErrorState now also mutates the
  // cached state, but keeping the separate fields is defensive.
  MxSelfUpdate_GetLastError(ErrText, ErrAt, HasErr);
  Result.AddPair('has_last_error', TJSONBool.Create(HasErr));
  Result.AddPair('last_error_text', ErrText);
  if HasErr then
    Result.AddPair('last_error_at',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', ErrAt))
  else
    Result.AddPair('last_error_at', '');
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

  if Assigned(ALogger) then
    ALogger.Log(mlInfo, Format('SelfUpdate install triggered by dev#%d',
      [ASession.DeveloperId]));

  // Send 202 Accepted immediately so the client's fetch() resolves while
  // the listener is still up. Install runs in a background thread so the
  // Sparkle request handler can return cleanly and Sparkle can flush the
  // response BEFORE gStopProc + Halt tear everything down. Running the
  // full install-and-halt sequence inline inside the Sparkle handler
  // caused a race (Admin server Stop while the handler thread was still
  // holding references -> access violation).
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('ok', TJSONBool.Create(True));
    Obj.AddPair('state', 'swapping');
    Obj.AddPair('message', 'installing; server will restart');
    MxSendJson(C, 202, Obj);
  finally
    Obj.Free;
  end;

  // C7g: outer try/except wraps TThread.CreateAnonymousThread(...).Start
  // so a thread-creation failure (rare: OS handle exhaustion, EOutOfMemory
  // during the closure capture) cannot leak gInstallInFlight. Without this,
  // a .Start raise would unwind out of the handler with the slot still
  // claimed and every subsequent Install request would see 'busy' forever.
  try
    TThread.CreateAnonymousThread(
      procedure
      begin
        // W5: widen try/except to cover the pre-InstallAndRestart setup
        // (UpdateLog + Sleep). A raise there previously left
        // gInstallInFlight stuck and never routed through SetErrorState,
        // so the admin UI kept seeing 'busy' forever.
        try
          UpdateLog('Install background thread spawned, sleep(500) pre-flush');
          // Let Sparkle's io flush the 202 to the client before we tear down.
          Sleep(500);
          UpdateLog('Install background thread entering InstallAndRestart');
          MxSelfUpdate_InstallAndRestart;
          // On success this never returns (ExitProcess at the end).
        except
          on E: EMxError do
          begin
            gInstallLock.Enter;
            try
              gInstallInFlight := False;
            finally
              gInstallLock.Leave;
            end;
            MxSelfUpdate_SetErrorState(E.Code + ': ' + E.Message);
            if Assigned(ALogger) then
              ALogger.Log(mlError,
                'SelfUpdate install failed: ' + E.Code + ': ' + E.Message);
          end;
          on E: Exception do
          begin
            gInstallLock.Enter;
            try
              gInstallInFlight := False;
            finally
              gInstallLock.Leave;
            end;
            MxSelfUpdate_SetErrorState(E.ClassName + ': ' + E.Message);
            if Assigned(ALogger) then
              ALogger.Log(mlError,
                'SelfUpdate install failed: ' + E.ClassName + ': ' + E.Message);
          end;
        end;
      end).Start;
  except
    on E: Exception do
    begin
      gInstallLock.Enter;
      try
        gInstallInFlight := False;
      finally
        gInstallLock.Leave;
      end;
      MxSelfUpdate_SetErrorState(
        'THREAD_START_FAIL: ' + E.ClassName + ': ' + E.Message);
      if Assigned(ALogger) then
        ALogger.Log(mlError,
          'SelfUpdate thread start failed: ' + E.ClassName + ': ' + E.Message);
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
