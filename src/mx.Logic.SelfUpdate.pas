unit mx.Logic.SelfUpdate;

interface

uses
  System.SysUtils, System.JSON;

type
  TMxUpdateState = (
    usIdle,
    usUpdateAvailable,
    usDownloading,
    usSwapping,
    usPostUpdateOk,
    usError
  );

  TMxUpdateInfo = record
    State         : TMxUpdateState;
    CurrentBuild  : Integer;
    LatestBuild   : Integer;
    LatestTag     : string;
    ReleaseName   : string;
    ZipUrl        : string;
    ZipSha256     : string;
    LastCheckedAt : TDateTime;
    ErrorMessage  : string;
  end;

  TMxSelfUpdateConfig = record
    Enabled              : Boolean;
    GithubRepo           : string;
    CheckCacheMinutes    : Integer;
    OldFileRetentionHours: Integer;
    MaxFinishRetries     : Integer;
  end;

  TMxUpdateMarker = record
    OldBuild    : Integer;
    NewBuild    : Integer;
    ZipPath     : string;
    StartedAt   : string;
    FinishStage : string;
    RetryCount  : Integer;
  end;

procedure MxSelfUpdate_LoadConfig(const AIniPath: string);
function  MxSelfUpdate_Config: TMxSelfUpdateConfig;

function  ParseTagName(const ATag: string): Integer;
function  CompareBuild(ACurrent, ALatest: Integer): TMxUpdateState;
function  VerifySHA256(const AFilePath, AExpectedHex: string): Boolean;
function  IsPathWithin(const ABaseDir, AZipEntryName: string): Boolean;

function  MarkerFilePath: string;
procedure WriteMarker(const AMarkerPath: string; const AMarker: TMxUpdateMarker);
function  ReadMarker (const AMarkerPath: string): TMxUpdateMarker;

procedure ResetPostUpdateIfNeeded(var AInfo: TMxUpdateInfo);

type
  TMxSelfUpdateStopProc = reference to procedure;

procedure MxSelfUpdate_RegisterStopProc(AProc: TMxSelfUpdateStopProc);

function  MxSelfUpdate_Check(AForce: Boolean = False): TMxUpdateInfo;
function  MxSelfUpdate_DownloadZip(var AInfo: TMxUpdateInfo): string;
procedure MxSelfUpdate_InstallAndRestart;
procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
procedure MxSelfUpdate_CleanupOldFiles;

function  MxSelfUpdate_RunSelfTests: Integer;

implementation

uses
  System.Classes, System.IniFiles, System.RegularExpressions, System.IOUtils,
  System.Hash, System.StrUtils, System.DateUtils,
  System.Net.HttpClient, System.Net.URLClient, System.Zip, System.TypInfo,
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}
  mx.Errors, mx.Types;

const
  // SYNC NOTE: mirrors mx.Tool.Fetch.pas:IsHostAllowed for GitHub.
  // If shared mx.Logic.HttpSafety.pas is ever built, delete this.
  // github.com is the initial host for browser_download_url (redirects
  // to objects.githubusercontent.com via signed URL).
  ALLOWED_HOSTS: array[0..2] of string = (
    'api.github.com',
    'github.com',
    'objects.githubusercontent.com'
  );

type
  TRenamePair = record
    Src, Dst: string;
  end;

function IsHostAllowed(const AHost: string): Boolean;
var
  I: Integer;
begin
  for I := Low(ALLOWED_HOSTS) to High(ALLOWED_HOSTS) do
    if SameText(AHost, ALLOWED_HOSTS[I]) then Exit(True);
  Result := False;
end;

var
  gStopProc      : TMxSelfUpdateStopProc = nil;
  gLastCheckInfo : TMxUpdateInfo;
  gLastCheckTime : TDateTime;
  gHasCheckInfo  : Boolean = False;

procedure MxSelfUpdate_RegisterStopProc(AProc: TMxSelfUpdateStopProc);
begin
  gStopProc := AProc;
end;

function StagingDir: string;
begin
  Result := IncludeTrailingPathDelimiter(
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'update-staging'));
end;

var
  gConfig: TMxSelfUpdateConfig;

function ParseTagName(const ATag: string): Integer;
var
  M: TMatch;
begin
  M := TRegEx.Match(ATag, '^build-(\d+)$');
  if M.Success then
  begin
    if not TryStrToInt(M.Groups[1].Value, Result) then
      Result := -1;
  end
  else
    Result := -1;
end;

function CompareBuild(ACurrent, ALatest: Integer): TMxUpdateState;
begin
  if ALatest > ACurrent then
    Result := usUpdateAvailable
  else
    Result := usIdle;
end;

function VerifySHA256(const AFilePath, AExpectedHex: string): Boolean;
var
  Actual: string;
begin
  if not TFile.Exists(AFilePath) then Exit(False);
  if Length(AExpectedHex) <> 64 then Exit(False);
  Actual := THashSHA2.GetHashStringFromFile(AFilePath, SHA256);
  Result := SameText(Actual, AExpectedHex);
end;

function IsPathWithin(const ABaseDir, AZipEntryName: string): Boolean;
var
  Base, Target: string;
  I: Integer;
begin
  if AZipEntryName = '' then Exit(False);
  if AZipEntryName.Contains('..') then Exit(False);
  if AZipEntryName.Contains(':') then Exit(False);
  if AZipEntryName.StartsWith('\') or AZipEntryName.StartsWith('/') then
    Exit(False);
  for I := 1 to Length(AZipEntryName) do
    if AZipEntryName[I] < #32 then
      Exit(False);
  try
    Base := IncludeTrailingPathDelimiter(TPath.GetFullPath(ABaseDir));
    Target := TPath.GetFullPath(TPath.Combine(Base, AZipEntryName));
  except
    Exit(False);
  end;
  Result := StartsText(Base, Target);
end;

function MarkerFilePath: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'update.marker');
end;

procedure WriteMarker(const AMarkerPath: string; const AMarker: TMxUpdateMarker);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(AMarkerPath);
  try
    Ini.WriteInteger('Update', 'OldBuild',    AMarker.OldBuild);
    Ini.WriteInteger('Update', 'NewBuild',    AMarker.NewBuild);
    Ini.WriteString ('Update', 'ZipPath',     AMarker.ZipPath);
    Ini.WriteString ('Update', 'StartedAt',   AMarker.StartedAt);
    Ini.WriteString ('Update', 'FinishStage', AMarker.FinishStage);
    Ini.WriteInteger('Update', 'RetryCount',  AMarker.RetryCount);
  finally
    Ini.Free;
  end;
end;

function ReadMarker(const AMarkerPath: string): TMxUpdateMarker;
var
  Ini: TIniFile;
begin
  if not TFile.Exists(AMarkerPath) then
    raise EMxError.Create('UPDATE_FAIL',
      'Marker file not found: ' + AMarkerPath, 500);
  Ini := TIniFile.Create(AMarkerPath);
  try
    Result.OldBuild    := Ini.ReadInteger('Update', 'OldBuild',    -1);
    Result.NewBuild    := Ini.ReadInteger('Update', 'NewBuild',    -1);
    Result.ZipPath     := Ini.ReadString ('Update', 'ZipPath',     '');
    Result.StartedAt   := Ini.ReadString ('Update', 'StartedAt',   '');
    Result.FinishStage := Ini.ReadString ('Update', 'FinishStage', '');
    Result.RetryCount  := Ini.ReadInteger('Update', 'RetryCount',  0);
  finally
    Ini.Free;
  end;
end;

procedure ResetPostUpdateIfNeeded(var AInfo: TMxUpdateInfo);
begin
  if AInfo.State = usPostUpdateOk then
    AInfo.State := usIdle;
end;

procedure MxSelfUpdate_LoadConfig(const AIniPath: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(AIniPath);
  try
    gConfig.Enabled               := Ini.ReadBool   ('SelfUpdate', 'Enabled',               True);
    gConfig.GithubRepo            := Ini.ReadString ('SelfUpdate', 'GithubRepo',            'MicrotronX/mxLore');
    gConfig.CheckCacheMinutes     := Ini.ReadInteger('SelfUpdate', 'CheckCacheMinutes',     60);
    gConfig.OldFileRetentionHours := Ini.ReadInteger('SelfUpdate', 'OldFileRetentionHours', 24);
    gConfig.MaxFinishRetries      := Ini.ReadInteger('SelfUpdate', 'MaxFinishRetries',      3);
  finally
    Ini.Free;
  end;
end;

function MxSelfUpdate_Config: TMxSelfUpdateConfig;
begin
  Result := gConfig;
end;

function MxSelfUpdate_Check(AForce: Boolean): TMxUpdateInfo;
var
  Http: THTTPClient;
  Url: string;
  Response: IHTTPResponse;
  Json: TJSONValue;
  Obj, Asset: TJSONObject;
  AssetsArr: TJSONArray;
  Digest, TagName: string;
  LatestBuild: Integer;
  Uri: TURI;
begin
  if (not AForce) and gHasCheckInfo and
     (MinutesBetween(Now, gLastCheckTime) < gConfig.CheckCacheMinutes) then
  begin
    Result := gLastCheckInfo;
    ResetPostUpdateIfNeeded(Result);
    Exit;
  end;

  if not gConfig.Enabled then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.State := usIdle;
    Result.ErrorMessage := 'disabled';
    Exit;
  end;

  FillChar(Result, SizeOf(Result), 0);
  Result.CurrentBuild  := MXAI_BUILD;
  Result.LastCheckedAt := Now;

  Url := Format('https://api.github.com/repos/%s/releases/latest',
                [gConfig.GithubRepo]);

  Uri := TURI.Create(Url);
  if not IsHostAllowed(Uri.Host) then
  begin
    Result.State := usError;
    Result.ErrorMessage := 'host not allowed: ' + Uri.Host;
    Exit;
  end;

  Http := THTTPClient.Create;
  try
    Http.UserAgent := Format('mxLoreMCP/build-%d', [MXAI_BUILD]);
    Http.Accept    := 'application/vnd.github+json';
    Http.HandleRedirects := True;
    try
      Response := Http.Get(Url);
    except
      on E: Exception do
      begin
        Result.State := usError;
        Result.ErrorMessage := 'UPDATE_FAIL: ' + E.Message;
        Exit;
      end;
    end;

    if Response.StatusCode = 403 then
    begin
      if gHasCheckInfo then
      begin
        Result := gLastCheckInfo;
        Result.ErrorMessage := 'github rate-limit, returning cached';
        Exit;
      end;
      Result.State := usError;
      Result.ErrorMessage := 'github rate-limit';
      Exit;
    end;

    if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then
    begin
      Result.State := usError;
      Result.ErrorMessage := Format('UPDATE_FAIL: http %d', [Response.StatusCode]);
      Exit;
    end;

    Json := TJSONObject.ParseJSONValue(Response.ContentAsString);
    if not (Json is TJSONObject) then
    begin
      if Assigned(Json) then Json.Free;
      Result.State := usError;
      Result.ErrorMessage := 'UPDATE_FAIL: json parse';
      Exit;
    end;

    try
      Obj := TJSONObject(Json);
      TagName              := Obj.GetValue<string>('tag_name', '');
      Result.LatestTag     := TagName;
      Result.ReleaseName   := Obj.GetValue<string>('name', '');
      LatestBuild          := ParseTagName(TagName);
      Result.LatestBuild   := LatestBuild;

      if LatestBuild < 0 then
      begin
        Result.State := usError;
        Result.ErrorMessage := 'Tag format not recognized: ' + TagName;
      end
      else
      begin
        Result.State := CompareBuild(MXAI_BUILD, LatestBuild);

        if Obj.TryGetValue<TJSONArray>('assets', AssetsArr) and
           (AssetsArr.Count > 0) then
        begin
          Asset := AssetsArr.Items[0] as TJSONObject;
          Result.ZipUrl := Asset.GetValue<string>('browser_download_url', '');
          Digest := Asset.GetValue<string>('digest', '');
          if Digest.StartsWith('sha256:', True) then
            Result.ZipSha256 := Digest.Substring(7)
          else
            Result.ZipSha256 := '';
        end;
      end;
    finally
      Json.Free;
    end;
  finally
    Http.Free;
  end;

  gLastCheckInfo := Result;
  gLastCheckTime := Now;
  gHasCheckInfo  := True;
end;

function ResolveCompanionSha256(const AInfo: TMxUpdateInfo): string;
var
  Http: THTTPClient;
  Url, TxtUrl, ZipName, Hex, Line, AssetName: string;
  Response: IHTTPResponse;
  Json: TJSONValue;
  Obj, Asset: TJSONObject;
  AssetsArr: TJSONArray;
  I: Integer;
  Lines, Parts: TArray<string>;
begin
  Result := '';
  Url := Format('https://api.github.com/repos/%s/releases/latest',
                [gConfig.GithubRepo]);
  Http := THTTPClient.Create;
  try
    Http.Accept := 'application/vnd.github+json';
    Response := Http.Get(Url);
    if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then Exit;
    Json := TJSONObject.ParseJSONValue(Response.ContentAsString);
    if not (Json is TJSONObject) then Exit;
    try
      Obj := TJSONObject(Json);
      if not Obj.TryGetValue<TJSONArray>('assets', AssetsArr) then Exit;
      ZipName := ExtractFileName(AInfo.ZipUrl);
      TxtUrl := '';
      for I := 0 to AssetsArr.Count - 1 do
      begin
        Asset := AssetsArr.Items[I] as TJSONObject;
        AssetName := Asset.GetValue<string>('name', '');
        if SameText(AssetName, 'SHA256SUMS.txt') or
           SameText(AssetName, ZipName + '.sha256') then
        begin
          TxtUrl := Asset.GetValue<string>('browser_download_url', '');
          Break;
        end;
      end;
      if TxtUrl = '' then Exit;

      Response := Http.Get(TxtUrl);
      if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then Exit;
      Lines := Response.ContentAsString.Split([#10]);
      for Line in Lines do
      begin
        Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
        if Length(Parts) >= 1 then
        begin
          Hex := Parts[0].Trim;
          if (Length(Hex) = 64) and
             ((Length(Parts) = 1) or SameText(Parts[High(Parts)], ZipName)) then
          begin
            Result := Hex;
            Exit;
          end;
        end;
      end;
    finally
      Json.Free;
    end;
  finally
    Http.Free;
  end;
end;

function MxSelfUpdate_DownloadZip(var AInfo: TMxUpdateInfo): string;
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  FileName, LocalPath: string;
  Stream: TFileStream;
  Uri: TURI;
begin
  Result := '';
  if AInfo.ZipUrl = '' then
    raise EMxError.Create('DOWNLOAD_FAIL', 'no zip url', 500);

  if not DirectoryExists(StagingDir) then
    ForceDirectories(StagingDir);

  FileName := ExtractFileName(AInfo.ZipUrl);
  LocalPath := TPath.Combine(StagingDir, FileName);
  AInfo.State := usDownloading;

  Http := THTTPClient.Create;
  try
    Http.UserAgent := Format('mxLoreMCP/build-%d', [MXAI_BUILD]);
    Http.HandleRedirects := True;

    // Upfront host check on the initial URL. Redirects stay inside the TLS-
    // trusted chain (github.com -> objects.githubusercontent.com, both in
    // ALLOWED_HOSTS). Post-redirect final-host check omitted: IHTTPResponse
    // has no portable FinalURL property in Delphi 12; relying on upfront
    // check + TLS cert trust.
    Uri := TURI.Create(AInfo.ZipUrl);
    if not IsHostAllowed(Uri.Host) then
    begin
      AInfo.State := usError;
      raise EMxError.Create('DOWNLOAD_FAIL',
        'host not allowed: ' + Uri.Host, 500);
    end;

    Stream := TFileStream.Create(LocalPath, fmCreate);
    try
      Response := Http.Get(AInfo.ZipUrl, Stream);
    finally
      Stream.Free;
    end;

    if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then
    begin
      TFile.Delete(LocalPath);
      AInfo.State := usError;
      raise EMxError.Create('DOWNLOAD_FAIL',
        Format('http %d', [Response.StatusCode]), 500);
    end;

    if AInfo.ZipSha256 = '' then
      AInfo.ZipSha256 := ResolveCompanionSha256(AInfo);

    if AInfo.ZipSha256 = '' then
    begin
      TFile.Delete(LocalPath);
      AInfo.State := usError;
      raise EMxError.Create('INTEGRITY_FAIL',
        'No SHA-256 available (neither digest nor companion asset)', 500);
    end;

    if not VerifySHA256(LocalPath, AInfo.ZipSha256) then
    begin
      WriteLn(ErrOutput, '[CRITICAL] SHA-256 MISMATCH on downloaded zip: ',
        LocalPath);
      TFile.Delete(LocalPath);
      AInfo.State := usError;
      raise EMxError.Create('INTEGRITY_FAIL', 'SHA-256 mismatch', 500);
    end;

    Result := LocalPath;
  finally
    Http.Free;
  end;
end;

{$IFDEF MSWINDOWS}
function MoveFileWithRetry(const ASrc, ADst: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to 3 do
  begin
    if MoveFileEx(PChar(ASrc), PChar(ADst),
         MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      Exit(True);
    if I < 3 then Sleep(50);
  end;
  Result := False;
end;

procedure RotateLiveFilesToOld(AOldBuild: Integer);
const
  Candidates: array[0..2] of string = (
    'mxLoreMCP.exe',
    'mxLoreMCPGui.exe',
    'libmariadb32.dll'
  );
var
  ExeDir, Suffix, Src: string;
  Pairs: array of TRenamePair;
  I, J: Integer;
begin
  ExeDir := ExtractFilePath(ParamStr(0));
  Suffix := Format('.old-%d', [AOldBuild]);

  SetLength(Pairs, 0);
  for I := Low(Candidates) to High(Candidates) do
  begin
    Src := TPath.Combine(ExeDir, Candidates[I]);
    if not TFile.Exists(Src) then Continue;
    SetLength(Pairs, Length(Pairs) + 1);
    Pairs[High(Pairs)].Src := Src;
    Pairs[High(Pairs)].Dst := Src + Suffix;
  end;

  for I := 0 to High(Pairs) do
  begin
    if not MoveFileWithRetry(Pairs[I].Src, Pairs[I].Dst) then
    begin
      for J := 0 to I - 1 do
        MoveFileWithRetry(Pairs[J].Dst, Pairs[J].Src);
      raise EMxError.Create('RENAME_FAIL',
        Format('Cannot rename %s (GetLastError=%d)',
          [Pairs[I].Src, GetLastError]), 500);
    end;
  end;
end;

procedure ExtractOnlyMxLoreMCPExe(const AZipPath, ADestDir: string);
var
  Zip: TZipFile;
  I: Integer;
  Bytes: TBytes;
  OutPath: string;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(AZipPath, zmRead);
    for I := 0 to Zip.FileCount - 1 do
    begin
      if SameText(ExtractFileName(Zip.FileNames[I]), 'mxLoreMCP.exe') then
      begin
        Zip.Read(I, Bytes);
        OutPath := TPath.Combine(ADestDir, 'mxLoreMCP.exe');
        TFile.WriteAllBytes(OutPath, Bytes);
        Exit;
      end;
    end;
    raise EMxError.Create('UPDATE_FAIL',
      'mxLoreMCP.exe not found in release zip', 500);
  finally
    Zip.Free;
  end;
end;

procedure MxSelfUpdate_InstallAndRestart;
var
  Info: TMxUpdateInfo;
  ZipPath, ExeDir, CmdLine: string;
  Marker: TMxUpdateMarker;
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  if not gConfig.Enabled then
    raise EMxError.Create('FORBIDDEN', 'self-update disabled in INI', 403);

  Info := MxSelfUpdate_Check(False);
  if Info.State <> usUpdateAvailable then
    raise EMxError.Create('UPDATE_FAIL',
      'no update available (state=' +
      GetEnumName(TypeInfo(TMxUpdateState), Ord(Info.State)) + ')', 409);

  ZipPath := MxSelfUpdate_DownloadZip(Info);

  Marker.OldBuild    := MXAI_BUILD;
  Marker.NewBuild    := Info.LatestBuild;
  Marker.ZipPath     := ZipPath;
  Marker.StartedAt   := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now);
  Marker.FinishStage := 'pending';
  Marker.RetryCount  := 0;
  WriteMarker(MarkerFilePath, Marker);

  Info.State := usSwapping;
  gLastCheckInfo := Info;

  try
    RotateLiveFilesToOld(MXAI_BUILD);
  except
    on E: EMxError do
    begin
      Info.State := usError;
      Info.ErrorMessage := E.Message;
      gLastCheckInfo := Info;
      raise;
    end;
  end;

  ExeDir := ExtractFilePath(ParamStr(0));
  try
    ExtractOnlyMxLoreMCPExe(ZipPath, ExeDir);
  except
    on E: Exception do
    begin
      MoveFileWithRetry(
        TPath.Combine(ExeDir, Format('mxLoreMCP.exe.old-%d', [MXAI_BUILD])),
        TPath.Combine(ExeDir, 'mxLoreMCP.exe'));
      Info.State := usError;
      Info.ErrorMessage := 'UPDATE_FAIL: extract: ' + E.Message;
      gLastCheckInfo := Info;
      raise EMxError.Create('UPDATE_FAIL', E.Message, 500);
    end;
  end;

  CmdLine := Format('"%s" --finish-update=%s',
    [TPath.Combine(ExeDir, 'mxLoreMCP.exe'), ZipPath]);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  FillChar(PI, SizeOf(PI), 0);

  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
       CREATE_NEW_PROCESS_GROUP, nil, nil, SI, PI) then
  begin
    Info.State := usError;
    Info.ErrorMessage := Format('SPAWN_FAIL: CreateProcess failed %d',
      [GetLastError]);
    gLastCheckInfo := Info;
    raise EMxError.Create('SPAWN_FAIL',
      Format('CreateProcess failed: %d', [GetLastError]), 500);
  end;
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);

  if Assigned(gStopProc) then gStopProc();
  Sleep(200);
  Halt(0);
end;
{$ELSE}
procedure MxSelfUpdate_InstallAndRestart;
begin
  raise EMxError.Create('UPDATE_FAIL', 'Self-Update requires Windows', 500);
end;
{$ENDIF}

procedure MxSelfUpdate_CleanupOldFiles;
var
  ExeDir, F: string;
  Files: TArray<string>;
  Age: TDateTime;
begin
  ExeDir := ExtractFilePath(ParamStr(0));

  Files := TDirectory.GetFiles(ExeDir, '*.old-*');
  for F in Files do
  begin
    Age := TFile.GetLastWriteTime(F);
    if HoursBetween(Now, Age) >= gConfig.OldFileRetentionHours then
      try TFile.Delete(F); except end;
  end;

  if DirectoryExists(StagingDir) then
  begin
    Files := TDirectory.GetFiles(StagingDir, 'mxLore-build-*.zip');
    for F in Files do
    begin
      Age := TFile.GetLastWriteTime(F);
      if HoursBetween(Now, Age) >= gConfig.OldFileRetentionHours then
        try TFile.Delete(F); except end;
    end;
  end;
end;

procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
var
  Marker: TMxUpdateMarker;
  MarkerPath, ExeDir, EntryName, TargetPath: string;
  Zip: TZipFile;
  I: Integer;
  Bytes: TBytes;
begin
  MarkerPath := MarkerFilePath;
  if not TFile.Exists(MarkerPath) then
  begin
    WriteLn('[WARN] MxSelfUpdate_FinishUpdate called but marker not found');
    Exit;
  end;

  Marker := ReadMarker(MarkerPath);
  Inc(Marker.RetryCount);
  WriteMarker(MarkerPath, Marker);

  if Marker.RetryCount > gConfig.MaxFinishRetries then
  begin
    WriteLn(ErrOutput, Format(
      '[CRITICAL] Update stuck after %d retries - manual recovery required',
      [gConfig.MaxFinishRetries]));
    gLastCheckInfo.State := usError;
    gLastCheckInfo.ErrorMessage := Format(
      'Update stuck after %d retries - manual recovery required',
      [gConfig.MaxFinishRetries]);
    gHasCheckInfo := True;
    Exit;
  end;

  if not TFile.Exists(AZipPath) then
  begin
    WriteLn(ErrOutput, 'finish-update: zip not found: ', AZipPath);
    gLastCheckInfo.State := usError;
    gLastCheckInfo.ErrorMessage := 'zip missing: ' + AZipPath;
    gHasCheckInfo := True;
    Exit;
  end;

  ExeDir := ExtractFilePath(ParamStr(0));
  Marker.FinishStage := 'extracting';
  WriteMarker(MarkerPath, Marker);

  Zip := TZipFile.Create;
  try
    Zip.Open(AZipPath, zmRead);
    for I := 0 to Zip.FileCount - 1 do
    begin
      EntryName := Zip.FileNames[I];
      if SameText(ExtractFileName(EntryName), 'mxLoreMCP.exe') then Continue;
      if SameText(ExtractFileName(EntryName), 'mxLoreMCP.ini') then Continue;

      if not IsPathWithin(ExeDir, EntryName) then
        raise EMxError.Create('PATH_TRAVERSAL', EntryName, 400);

      TargetPath := TPath.GetFullPath(TPath.Combine(ExeDir, EntryName));

      if EntryName.EndsWith('/') or EntryName.EndsWith('\') then
      begin
        ForceDirectories(TargetPath);
        Continue;
      end;

      ForceDirectories(ExtractFilePath(TargetPath));
      Zip.Read(I, Bytes);
      TFile.WriteAllBytes(TargetPath, Bytes);
    end;
  finally
    Zip.Free;
  end;

  Marker.FinishStage := 'done';
  WriteMarker(MarkerPath, Marker);
  TFile.Delete(MarkerPath);

  gLastCheckInfo.State        := usPostUpdateOk;
  gLastCheckInfo.CurrentBuild := Marker.NewBuild;
  gLastCheckInfo.LatestBuild  := Marker.NewBuild;
  gHasCheckInfo := True;

  MxSelfUpdate_CleanupOldFiles;
end;

var
  gTestCount  : Integer = 0;
  gTestFailed : Integer = 0;

procedure TAssert(ACondition: Boolean; const AName: string);
begin
  Inc(gTestCount);
  if ACondition then
    WriteLn('  PASS  ', AName)
  else
  begin
    Inc(gTestFailed);
    WriteLn('  FAIL  ', AName);
  end;
end;

procedure RunParseTagNameTests;
begin
  TAssert(ParseTagName('build-88')   =  88, 'ParseTagName build-88');
  TAssert(ParseTagName('build-0088') =  88, 'ParseTagName build-0088');
  TAssert(ParseTagName('v2.4.0')     = -1,  'ParseTagName v2.4.0 rejected');
  TAssert(ParseTagName('build-')     = -1,  'ParseTagName build- rejected');
  TAssert(ParseTagName('Build-88')   = -1,  'ParseTagName Build-88 case-sensitive');
  TAssert(ParseTagName('')           = -1,  'ParseTagName empty');
end;

procedure RunCompareBuildTests;
begin
  TAssert(CompareBuild(87, 88) = usUpdateAvailable, 'CompareBuild 87<88 update');
  TAssert(CompareBuild(88, 88) = usIdle,            'CompareBuild 88=88 idle');
  TAssert(CompareBuild(89, 88) = usIdle,            'CompareBuild dev-build safety');
  TAssert(CompareBuild(0,  88) = usUpdateAvailable, 'CompareBuild zero current');
end;

procedure RunVerifySHA256Tests;
const
  EmptySha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  ZeroSha  = '0000000000000000000000000000000000000000000000000000000000000000';
var
  TmpFile: string;
begin
  TmpFile := TPath.Combine(TPath.GetTempPath, 'mxsu_test_empty.bin');
  TFile.WriteAllBytes(TmpFile, []);
  try
    TAssert(    VerifySHA256(TmpFile, EmptySha), 'VerifySHA256 empty file match');
    TAssert(not VerifySHA256(TmpFile, ZeroSha),  'VerifySHA256 empty file mismatch');
    TAssert(not VerifySHA256(TmpFile, 'garbage'),'VerifySHA256 garbage hash rejected');
  finally
    TFile.Delete(TmpFile);
  end;
end;

procedure RunIsPathWithinTests;
const
  Base = 'C:\app\';
begin
  TAssert(    IsPathWithin(Base, 'admin\www\index.html'),            'within subdir ok');
  TAssert(    IsPathWithin(Base, 'mxLoreMCP.exe'),                   'within root file ok');
  TAssert(not IsPathWithin(Base, '..\evil.exe'),                     'parent traversal rejected');
  TAssert(not IsPathWithin(Base, '..\..\Windows\system32\evil.exe'), 'double parent rejected');
  TAssert(not IsPathWithin(Base, 'C:\Windows\evil.exe'),             'absolute path rejected');
  TAssert(not IsPathWithin(Base, '\evil.exe'),                       'leading backslash rejected');
  TAssert(not IsPathWithin(Base, '/evil.exe'),                       'leading forwardslash rejected');
  TAssert(not IsPathWithin(Base, 'admin\..\..\evil.exe'),            'embedded parent rejected');
  TAssert(not IsPathWithin(Base, 'ok'#0'bad.exe'),                   'NULL byte rejected');
  TAssert(not IsPathWithin(Base, 'evil:stream'),                     'colon rejected');
end;

procedure RunMarkerFileTests;
var
  TmpFile: string;
  Rec, ReadRec: TMxUpdateMarker;
begin
  TmpFile := TPath.Combine(TPath.GetTempPath, 'mxsu_marker_test.ini');
  try
    Rec.OldBuild    := 87;
    Rec.NewBuild    := 88;
    Rec.ZipPath     := 'update-staging/mxLore-build-88.zip';
    Rec.StartedAt   := '2026-04-14T10:45:00Z';
    Rec.FinishStage := 'pending';
    Rec.RetryCount  := 0;

    WriteMarker(TmpFile, Rec);
    TAssert(TFile.Exists(TmpFile), 'marker file written');

    ReadRec := ReadMarker(TmpFile);
    TAssert(ReadRec.OldBuild    = 87,                                   'marker OldBuild');
    TAssert(ReadRec.NewBuild    = 88,                                   'marker NewBuild');
    TAssert(ReadRec.ZipPath     = 'update-staging/mxLore-build-88.zip', 'marker ZipPath');
    TAssert(ReadRec.StartedAt   = '2026-04-14T10:45:00Z',               'marker StartedAt');
    TAssert(ReadRec.FinishStage = 'pending',                            'marker FinishStage');
    TAssert(ReadRec.RetryCount  = 0,                                    'marker RetryCount');
  finally
    if TFile.Exists(TmpFile) then TFile.Delete(TmpFile);
  end;
end;

procedure RunResetPostUpdateStateTests;
var
  Info: TMxUpdateInfo;
begin
  Info.State := usPostUpdateOk;
  ResetPostUpdateIfNeeded(Info);
  TAssert(Info.State = usIdle, 'usPostUpdateOk -> usIdle on reset');

  Info.State := usUpdateAvailable;
  ResetPostUpdateIfNeeded(Info);
  TAssert(Info.State = usUpdateAvailable, 'usUpdateAvailable not touched');

  Info.State := usError;
  ResetPostUpdateIfNeeded(Info);
  TAssert(Info.State = usError, 'usError not touched');
end;

procedure RunFinishUpdateIntegrationTest;
var
  TestDir, ZipPath, MarkerPath, HelloPath: string;
  Zip: TZipFile;
  Content: TBytes;
  Marker: TMxUpdateMarker;
begin
  if GetEnvironmentVariable('MXSU_INTEGRATION_TEST') = '' then Exit;

  TestDir := TPath.Combine(TPath.GetTempPath, 'mxsu_int_' +
    FormatDateTime('yyyymmddhhnnss', Now));
  ForceDirectories(TestDir);
  try
    ZipPath := TPath.Combine(TestDir, 'test-build-99.zip');
    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      Content := TEncoding.UTF8.GetBytes('hello from build 99');
      Zip.Add(Content, 'admin/www/hello-build99.txt');
      Content := TEncoding.UTF8.GetBytes('bad');
      Zip.Add(Content, '../../evil.txt');
      Zip.Close;
    finally
      Zip.Free;
    end;

    Marker.OldBuild    := 98;
    Marker.NewBuild    := 99;
    Marker.ZipPath     := ZipPath;
    Marker.StartedAt   := '2026-04-14T00:00:00Z';
    Marker.FinishStage := 'pending';
    Marker.RetryCount  := 0;
    MarkerPath := MarkerFilePath;
    WriteMarker(MarkerPath, Marker);

    try
      MxSelfUpdate_FinishUpdate(ZipPath);
      TAssert(False, 'finish should have raised PATH_TRAVERSAL');
    except
      on E: EMxError do
        TAssert(E.Code = 'PATH_TRAVERSAL',
          'finish raised PATH_TRAVERSAL on ../../evil.txt');
    end;

    if TFile.Exists(MarkerPath) then TFile.Delete(MarkerPath);
    HelloPath := TPath.Combine(ExtractFilePath(ParamStr(0)),
      'admin' + PathDelim + 'www' + PathDelim + 'hello-build99.txt');
    if TFile.Exists(HelloPath) then TFile.Delete(HelloPath);
  finally
    try TDirectory.Delete(TestDir, True); except end;
  end;
end;

procedure RunCleanupOldFilesIntegrationTest;
var
  TestDir, OldFile, NewFile: string;
  StaleTime: TDateTime;
  Saved: TMxSelfUpdateConfig;
begin
  if GetEnvironmentVariable('MXSU_INTEGRATION_TEST') = '' then Exit;

  TestDir := ExtractFilePath(ParamStr(0));
  Saved := gConfig;
  gConfig.OldFileRetentionHours := 1;

  OldFile := TPath.Combine(TestDir, 'mxLoreMCP.exe.old-99');
  NewFile := TPath.Combine(TestDir, 'mxLoreMCP.exe.old-100');

  TFile.WriteAllBytes(OldFile, [1, 2, 3]);
  TFile.WriteAllBytes(NewFile, [4, 5, 6]);

  StaleTime := IncHour(Now, -2);
  TFile.SetLastWriteTime(OldFile, StaleTime);

  try
    MxSelfUpdate_CleanupOldFiles;
    TAssert(not TFile.Exists(OldFile), 'cleanup deleted stale .old-99');
    TAssert(    TFile.Exists(NewFile), 'cleanup kept fresh .old-100');
  finally
    if TFile.Exists(OldFile) then TFile.Delete(OldFile);
    if TFile.Exists(NewFile) then TFile.Delete(NewFile);
    gConfig := Saved;
  end;
end;

function MxSelfUpdate_RunSelfTests: Integer;
begin
  gTestCount  := 0;
  gTestFailed := 0;
  WriteLn('=== mx.Logic.SelfUpdate self-tests ===');
  RunParseTagNameTests;
  RunCompareBuildTests;
  RunVerifySHA256Tests;
  RunIsPathWithinTests;
  RunMarkerFileTests;
  RunResetPostUpdateStateTests;
  RunFinishUpdateIntegrationTest;
  RunCleanupOldFilesIntegrationTest;
  WriteLn(Format('=== %d tests, %d failed ===', [gTestCount, gTestFailed]));
  if gTestFailed > 0 then Result := 1 else Result := 0;
end;

end.
