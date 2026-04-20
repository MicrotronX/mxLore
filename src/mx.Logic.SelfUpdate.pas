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
    // Bug#3052 Approach C (Plan#3082 M2): cap how many .old-<N> mirror
    // directories CleanupOldFiles retains regardless of age. Oldest
    // beyond this count are deleted even if still within retention.
    MaxOldMirrors        : Integer;
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
procedure MxSelfUpdate_SetErrorState(const AMessage: string);
// C7b: read-side of the transient error channel. Admin BuildStatusJson
// needs to surface the last install-failure text because the cached
// gLastCheckInfo is not mutated by SetErrorState.
procedure MxSelfUpdate_GetLastError(out AText: string; out AAt: TDateTime;
  out AHas: Boolean);
// W6: child FinishUpdate error persistence. Child writes a small sibling
// file (update.error) from its dpr except branch; next parent boot reads
// it, calls SetErrorState, then deletes the file. Keeps the admin UI
// from silently eating a failed install on the child side.
procedure MxSelfUpdate_WriteChildError(const AMessage: string);
procedure MxSelfUpdate_ConsumePersistedChildError;

// Diagnostic append-logger for the self-update flow. Writes to
// <ExeDir>/update.log with process-id prefix so parent + detached child
// can interleave cleanly. Silent on I/O failure.
procedure UpdateLog(const AMsg: string);

function  MxSelfUpdate_Check(AForce: Boolean = False): TMxUpdateInfo;
function  MxSelfUpdate_DownloadZip(var AInfo: TMxUpdateInfo): string;
procedure MxSelfUpdate_InstallAndRestart;
procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
procedure MxSelfUpdate_CleanupOldFiles;

function  MxSelfUpdate_RunSelfTests: Integer;

implementation

uses
  System.Classes, System.IniFiles, System.RegularExpressions, System.IOUtils,
  System.Hash, System.StrUtils, System.DateUtils, System.SyncObjs,
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
  // C1: lock + transient error channel. Errors go here so a transient
  // SetErrorState call does not poison the cached successful check
  // result (previously every failed install wiped gLastCheckInfo).
  gLastCheckLock : TCriticalSection;
  gLastErrorText : string;
  gLastErrorTime : TDateTime;
  gHasLastError  : Boolean = False;
  // M3 Task 8 (Bug#3052): serialize MxSelfUpdate_InstallAndRestart so a
  // double-click in the admin UI (or a parallel API hit) cannot race
  // two rotate/extract passes against the same .old-<N> slots.
  // TryEnter -> 409 Conflict if already held. Single-process scope;
  // cross-process protection would need a named mutex, out of M3.
  gInstallLock   : TCriticalSection;

procedure MxSelfUpdate_RegisterStopProc(AProc: TMxSelfUpdateStopProc);
begin
  gStopProc := AProc;
end;

procedure MxSelfUpdate_SetErrorState(const AMessage: string);
begin
  gLastCheckLock.Enter;
  try
    gLastErrorText := AMessage;
    gLastErrorTime := Now;
    gHasLastError  := True;
    // C7b: also flip the cached state so admin UI transitions out of
    // usSwapping into usError even without reading the separate channel.
    if gHasCheckInfo then
    begin
      gLastCheckInfo.State        := usError;
      gLastCheckInfo.ErrorMessage := AMessage;
    end;
  finally
    gLastCheckLock.Leave;
  end;
end;

procedure MxSelfUpdate_GetLastError(out AText: string; out AAt: TDateTime;
  out AHas: Boolean);
begin
  gLastCheckLock.Enter;
  try
    AText := gLastErrorText;
    AAt   := gLastErrorTime;
    AHas  := gHasLastError;
  finally
    gLastCheckLock.Leave;
  end;
end;

function ChildErrorFilePath: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'update.error');
end;

procedure MxSelfUpdate_WriteChildError(const AMessage: string);
var
  Path, Line: string;
begin
  Path := ChildErrorFilePath;
  Line := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now) + ' ' + AMessage;
  try
    TFile.WriteAllText(Path, Line, TEncoding.UTF8);
  except
    // Persistence is best-effort. Log hook is the user-facing fallback.
  end;
end;

procedure MxSelfUpdate_ConsumePersistedChildError;
var
  Path, Content: string;
begin
  Path := ChildErrorFilePath;
  if not TFile.Exists(Path) then Exit;
  try
    Content := TFile.ReadAllText(Path, TEncoding.UTF8).Trim;
  except
    Content := '';
  end;
  try
    TFile.Delete(Path);
  except
    // leaving the file means next boot surfaces it again; acceptable.
  end;
  if Content <> '' then
    MxSelfUpdate_SetErrorState('CHILD_FINISH_FAIL: ' + Content);
end;

function StagingDir: string;
begin
  Result := IncludeTrailingPathDelimiter(
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'update-staging'));
end;

function UpdateLogPath: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'update.log');
end;

// Diagnostic log for the self-update flow. Appends to bin/update.log so
// both the parent (Admin API install handler thread) and the child
// (--finish-update boot branch before Logger init) can write to the
// same file. Thread-safe via short open-append-close cycles with shared
// read. Silent on I/O failure so logging never breaks the update path.
procedure UpdateLog(const AMsg: string);
var
  Path, Line: string;
  F: TFileStream;
  Bytes: TBytes;
begin
  Path := UpdateLogPath;
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz ', Now) +
          '[pid=' + IntToStr(GetCurrentProcessId) + '] ' + AMsg + #13#10;
  try
    Bytes := TEncoding.UTF8.GetBytes(Line);
    if TFile.Exists(Path) then
      F := TFileStream.Create(Path, fmOpenWrite or fmShareDenyNone)
    else
      F := TFileStream.Create(Path, fmCreate or fmShareDenyNone);
    try
      F.Seek(0, soEnd);
      if Length(Bytes) > 0 then
        F.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      F.Free;
    end;
  except
    // swallow all logging errors — diagnostic must never break the update
  end;
end;

// URL-aware filename extraction. System.SysUtils.ExtractFileName on Windows
// only splits on '\' and ':', not on '/', so on a full https URL it returns
// the URL tail including '//host/...'. We parse via TURI and take the last
// path segment. Fallback 'update.zip' if path is empty.
function UrlFileName(const AUrl: string): string;
var
  Uri: TURI;
  UriPath: string;
  LastSlash: Integer;
begin
  Result := '';
  try
    Uri := TURI.Create(AUrl);
    UriPath := Uri.Path;
    if UriPath <> '' then
    begin
      LastSlash := LastDelimiter('/', UriPath);
      if LastSlash > 0 then
        Result := Copy(UriPath, LastSlash + 1, MaxInt)
      else
        Result := UriPath;
    end;
  except
    Result := '';
  end;
  if Result = '' then
    Result := 'update.zip';
end;

// Zip entries use '/' as separator even on Windows. ExtractFileName won't
// split them. This helper returns the last '/' or '\' segment so Skip
// checks for mxLoreMCP.exe / mxLoreMCP.ini work regardless of wrapper dir.
function ZipEntryBaseName(const AEntry: string): string;
var
  I: Integer;
begin
  I := LastDelimiter('/\', AEntry);
  if I > 0 then
    Result := Copy(AEntry, I + 1, MaxInt)
  else
    Result := AEntry;
end;

// Some release ZIPs wrap all entries in a single top-level dir like
// mxLore-v2.4.1-win64/. For in-place self-update we want to extract INTO
// the current install dir, not under a wrapper. If ALL entries share a
// common first segment, strip it; otherwise return the entry unchanged.
function StripZipWrapperDir(const AEntry, AWrapperPrefix: string): string;
begin
  if (AWrapperPrefix <> '') and
     AEntry.StartsWith(AWrapperPrefix, True) then
    Result := Copy(AEntry, Length(AWrapperPrefix) + 1, MaxInt)
  else
    Result := AEntry;
end;

// Scans zip entries and returns the common top-level directory prefix
// (e.g. 'mxLore-v2.4.1-win64/') or '' if entries are already flat.
// W10: iterate all entries and require EVERY entry to share the same
// top-level folder. FileNames[0] is no longer trusted as the canonical
// sample — the first entry could be a loose file or the entries could
// be listed in any order.
function DetectZipWrapperPrefix(const AZip: TZipFile): string;
var
  I, SlashPos: Integer;
  Entry, Candidate: string;
begin
  Result := '';
  if AZip.FileCount = 0 then Exit;
  Candidate := '';
  for I := 0 to AZip.FileCount - 1 do
  begin
    Entry := AZip.FileNames[I];
    if Entry = '' then Continue;
    SlashPos := Pos('/', Entry);
    if SlashPos <= 1 then
      // at least one flat entry -> zip has no uniform wrapper
      Exit;
    if Candidate = '' then
      Candidate := Copy(Entry, 1, SlashPos) // includes trailing '/'
    else if not Entry.StartsWith(Candidate, True) then
      // two different top-level folders -> no uniform wrapper
      Exit;
  end;
  Result := Candidate;
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
      Result := -1
    else if Result > 9999999 then
      // M3 Task 10 (Bug#3052): clamp absurd build numbers that pass
      // TryStrToInt (up to 2^31) but cannot be a real release tag.
      // Silent sentinel, matches existing "unparseable" contract.
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
const
  DEFAULT_REPO = 'MicrotronX/mxLore';
var
  Ini: TIniFile;
  RawRepo: string;
begin
  Ini := TIniFile.Create(AIniPath);
  try
    gConfig.Enabled               := Ini.ReadBool   ('SelfUpdate', 'Enabled',               True);
    RawRepo                       := Ini.ReadString ('SelfUpdate', 'GithubRepo',            DEFAULT_REPO);
    // W8: reject malformed owner/repo so ResolveAssetUrl cannot build a
    // bogus api.github.com URL from INI typos. Regex matches GitHub's
    // own slug rules (word chars, dot, hyphen on both sides).
    if TRegEx.IsMatch(RawRepo, '^[\w.-]+/[\w.-]+$') then
      gConfig.GithubRepo := RawRepo
    else
      gConfig.GithubRepo := DEFAULT_REPO;
    gConfig.CheckCacheMinutes     := Ini.ReadInteger('SelfUpdate', 'CheckCacheMinutes',     60);
    gConfig.OldFileRetentionHours := Ini.ReadInteger('SelfUpdate', 'OldFileRetentionHours', 24);
    gConfig.MaxFinishRetries      := Ini.ReadInteger('SelfUpdate', 'MaxFinishRetries',      3);
    // Bug#3052 Approach C (Plan#3082 M2): default 3 mirrors. Clamp at >=1
    // so a pathological INI value of 0 does not wipe the only rollback
    // snapshot left on disk.
    gConfig.MaxOldMirrors         := Ini.ReadInteger('SelfUpdate', 'MaxOldMirrors',         3);
    if gConfig.MaxOldMirrors < 1 then
      gConfig.MaxOldMirrors := 1;
  finally
    Ini.Free;
  end;
  // W6: surface any error the last child FinishUpdate recorded before it
  // died, so the admin UI shows the failure on the next parent boot.
  MxSelfUpdate_ConsumePersistedChildError;
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
  UsedCache: Boolean;
begin
  UsedCache := False;
  gLastCheckLock.Enter;
  try
    if (not AForce) and gHasCheckInfo and
       (MinutesBetween(Now, gLastCheckTime) < gConfig.CheckCacheMinutes) then
    begin
      Result := gLastCheckInfo;
      UsedCache := True;
    end;
  finally
    gLastCheckLock.Leave;
  end;
  if UsedCache then
  begin
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
      gLastCheckLock.Enter;
      try
        if gHasCheckInfo then
        begin
          Result := gLastCheckInfo;
          Result.ErrorMessage := 'github rate-limit, returning cached';
          UsedCache := True;
        end;
      finally
        gLastCheckLock.Leave;
      end;
      if UsedCache then Exit;
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

    Json := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
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

        // W9: do not blindly pick assets[0] — scan for the first entry
        // whose name ends in .zip AND reports size>0. Prevents picking a
        // stray .sha256 / .sig / zero-byte placeholder that GitHub
        // happens to list before the real release ZIP.
        if Obj.TryGetValue<TJSONArray>('assets', AssetsArr) then
        begin
          var AssetIdx: Integer;
          var AssetName: string;
          var AssetSize: Int64;
          for AssetIdx := 0 to AssetsArr.Count - 1 do
          begin
            Asset := AssetsArr.Items[AssetIdx] as TJSONObject;
            AssetName := Asset.GetValue<string>('name', '');
            AssetSize := Asset.GetValue<Int64>('size', 0);
            if AssetName.ToLower.EndsWith('.zip') and (AssetSize > 0) then
            begin
              Result.ZipUrl := Asset.GetValue<string>('browser_download_url', '');
              Digest := Asset.GetValue<string>('digest', '');
              if Digest.StartsWith('sha256:', True) then
                Result.ZipSha256 := Digest.Substring(7)
              else
                Result.ZipSha256 := '';
              Break;
            end;
          end;
        end;
      end;
    finally
      Json.Free;
    end;
  finally
    Http.Free;
  end;

  gLastCheckLock.Enter;
  try
    gLastCheckInfo := Result;
    gLastCheckTime := Now;
    gHasCheckInfo  := True;
  finally
    gLastCheckLock.Leave;
  end;
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
    Json := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
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
      Lines := Response.ContentAsString(TEncoding.UTF8).Split([#10]);
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

  FileName := UrlFileName(AInfo.ZipUrl);
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

    // M3 Task 12b (Bug#3052): network exceptions mid-download leave a
    // partial .zip behind; the HTTP-status error path below already
    // deletes it, but the raise path did not. Clean up the partial
    // file and re-raise so callers see the original network error.
    Stream := TFileStream.Create(LocalPath, fmCreate);
    try
      try
        Response := Http.Get(AInfo.ZipUrl, Stream);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        if TFile.Exists(LocalPath) then
        try TFile.Delete(LocalPath); except end;
        raise;
      end;
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
// M3 Task 9 (Bug#3052): extend retry window past AV-scan hold. Defender
// can lock a freshly written file for 200-500ms after close; the previous
// 3x/50ms loop (~100ms total) lost that race. 5 attempts with exponential
// backoff [50,100,250,500] give ~900ms headroom and log each miss.
const
  Delays: array[0..3] of Integer = (50, 100, 250, 500);
var
  I: Integer;
  LastErr: DWORD;
begin
  for I := 0 to 4 do
  begin
    if MoveFileEx(PChar(ASrc), PChar(ADst),
         MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      Exit(True);
    // Capture GetLastError immediately into a local so any intervening
    // RTL call (Format arg evaluation order, future refactor) cannot
    // clobber the thread-local error slot before we log it.
    LastErr := GetLastError;
    if I < 4 then
    begin
      UpdateLog(Format('WARN MoveFileWithRetry attempt=%d err=%d src=%s',
        [I + 1, LastErr, ASrc]));
      Sleep(Delays[I]);
    end;
  end;
  Result := False;
end;

// Bug#3052 Approach C (Plan#3082 M2) Helper B: classify release-scoped
// paths that must NEVER rotate into the mirror tree or be garbage-
// collected by CleanupOldFiles. Rules:
//   - User state files: *.ini, *.db, *.sqlite (case-insensitive).
//   - Runtime-only dirs (as a path prefix relative to ExeDir):
//     .claude\, logs\, bin\, backups\.
//   - The mirror tree itself: any path whose first segment starts
//     with '.old-' (prevents recursing into the snapshots we just
//     wrote).
function IsExcludedPath(const AExeDir, AAbsolutePath: string): Boolean;
var
  Ext, Rel, Lower, FirstSeg: string;
  SlashPos: Integer;
begin
  Result := False;
  if AAbsolutePath = '' then Exit(True);

  Ext := ExtractFileExt(AAbsolutePath);
  if SameText(Ext, '.ini')    then Exit(True);
  if SameText(Ext, '.db')     then Exit(True);
  if SameText(Ext, '.sqlite') then Exit(True);

  // Relative path (ExeDir already ends with a separator).
  if StartsText(AExeDir, AAbsolutePath) then
    Rel := Copy(AAbsolutePath, Length(AExeDir) + 1, MaxInt)
  else
    Rel := AAbsolutePath;

  // Normalise to backslashes so StartsText prefix checks work uniformly.
  Rel := StringReplace(Rel, '/', '\', [rfReplaceAll]);
  Lower := LowerCase(Rel);

  if StartsText('.claude\', Lower) then Exit(True);
  if StartsText('logs\',    Lower) then Exit(True);
  if StartsText('bin\',     Lower) then Exit(True);
  if StartsText('backups\', Lower) then Exit(True);

  // Skip mirror tree by prefix — any .old-<N> dir and anything nested.
  SlashPos := Pos('\', Lower);
  if SlashPos > 0 then
    FirstSeg := Copy(Lower, 1, SlashPos - 1)
  else
    FirstSeg := Lower;
  if StartsText('.old-', FirstSeg) then Exit(True);
end;

// Bug#3052 Approach C (Plan#3082 M2) Helper A1: enumerate the root
// release-scoped files that must stay FLAT (rotated per-file with
// '<file>.old-<N>' suffix in ExeDir). Windows can only atomic-rename
// a running EXE inside the same directory, so these cannot go into
// the mirror tree. Only returns files that actually exist and are
// not filtered by IsExcludedPath.
function EnumerateReleaseScopedRootFiles(const AExeDir: string): TArray<string>;
const
  RootFiles: array[0..7] of string = (
    'mxLoreMCP.exe',
    'mxLoreMCPGui.exe',
    'mxMCPProxy.exe',
    'libmariadb32.dll',
    'README.md',
    'LICENSE.txt',
    'iis-url-rewrite-rule.xml',
    'mxLoreMCP.ini.example'
  );
var
  List: TStringList;
  I: Integer;
  Full: string;
begin
  List := TStringList.Create;
  try
    List.Sorted := False;
    for I := Low(RootFiles) to High(RootFiles) do
    begin
      Full := TPath.Combine(AExeDir, RootFiles[I]);
      if TFile.Exists(Full) and (not IsExcludedPath(AExeDir, Full)) then
        List.Add(Full);
    end;
    SetLength(Result, List.Count);
    for I := 0 to List.Count - 1 do
      Result[I] := List[I];
  finally
    List.Free;
  end;
end;

// Bug#3052 Approach C (Plan#3082 M2) Helper A2: enumerate every
// release-scoped file under the 5 recursive subdirs. These rotate
// into the mirror tree '<ExeDir>\.old-<N>\<relpath>'. Every candidate
// is filtered through IsExcludedPath so user state (.ini, .db,
// logs\, backups\, .old-*\) never enters rotation.
function EnumerateReleaseScopedSubdirFiles(const AExeDir: string): TArray<string>;
const
  RecursiveDirs: array[0..4] of string = (
    'sql',
    'admin\www',
    'lib',
    'claude-setup',
    'docs'
  );
var
  List: TStringList;
  I, J: Integer;
  SubDir: string;
  SubFiles: TArray<string>;
begin
  List := TStringList.Create;
  try
    List.Sorted := False;
    for I := Low(RecursiveDirs) to High(RecursiveDirs) do
    begin
      SubDir := TPath.Combine(AExeDir, RecursiveDirs[I]);
      if not DirectoryExists(SubDir) then Continue;
      try
        SubFiles := TDirectory.GetFiles(SubDir, '*',
          TSearchOption.soAllDirectories);
      except
        SubFiles := nil;
      end;
      for J := 0 to High(SubFiles) do
      begin
        if IsExcludedPath(AExeDir, SubFiles[J]) then Continue;
        List.Add(SubFiles[J]);
      end;
    end;
    SetLength(Result, List.Count);
    for I := 0 to List.Count - 1 do
      Result[I] := List[I];
  finally
    List.Free;
  end;
end;

// Bug#3052 Approach C (Plan#3082 M2): reserve a free mirror-root
// directory name INSIDE ExeDir. Primary slot is
// '<ExeDir>\.old-<N>'; fallbacks are '<ExeDir>\.old-<N>-2', '-3',
// ..., up to -99. Raises RESERVE_OLD_MIRROR_EXHAUSTED if the cap is
// reached. Keeping the mirror inside ExeDir (rather than beside it)
// matches the IsExcludedPath rule 'first segment starts with .old-'
// so RotateLiveFilesToOld does not recurse into its own snapshot.
function ReserveOldMirrorRoot(const AExeDir: string; AOldBuild: Integer): string;
var
  Suffix: Integer;
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(AExeDir);
  Result := Format('%s.old-%d', [Base, AOldBuild]);
  Suffix := 2;
  while DirectoryExists(Result) or TFile.Exists(Result) do
  begin
    Result := Format('%s.old-%d-%d', [Base, AOldBuild, Suffix]);
    Inc(Suffix);
    if Suffix > 99 then
      raise EMxError.Create('RESERVE_OLD_MIRROR_EXHAUSTED', AExeDir, 500);
  end;
end;

// Bug#3052 Approach C (Plan#3082 M2): split-layout rotation.
// Root files (running exe + siblings) stay FLAT with per-file
// '<file>.old-<AOldBuild>' suffix beside the original — Windows can
// only atomic-rename a running EXE in the same directory. Subdir
// files (sql\, admin\www\, lib\, claude-setup\, docs\) rotate into
// a single mirror tree '<ExeDir>\.old-<AOldBuild>\<relpath>' so
// CleanupOldFiles can age out an entire snapshot atomically and
// rollback has an authoritative source.
//
// Atomicity: if any file-move fails, every prior move is reversed
// back to the live slot before raising RENAME_FAIL. Matches the
// pre-M2 contract — callers see either all-or-nothing.
procedure RotateLiveFilesToOld(AOldBuild: Integer);
var
  ExeDir, ExeDirNoTrail, MirrorRoot, Src, RelPath, Dst: string;
  RootFiles, SubdirFiles: TArray<string>;
  Pairs: array of TRenamePair;
  I, J: Integer;
begin
  ExeDir := ExtractFilePath(ParamStr(0));
  ExeDirNoTrail := ExcludeTrailingPathDelimiter(ExeDir);

  // Part A: enumerate root files (flat rotation — per-file suffix).
  RootFiles := EnumerateReleaseScopedRootFiles(ExeDir);
  UpdateLog(Format('M2 rotate: %d root files enumerated', [Length(RootFiles)]));

  SetLength(Pairs, 0);
  for I := 0 to High(RootFiles) do
  begin
    Src := RootFiles[I];
    if not TFile.Exists(Src) then Continue;
    Dst := Format('%s.old-%d', [Src, AOldBuild]);
    SetLength(Pairs, Length(Pairs) + 1);
    Pairs[High(Pairs)].Src := Src;
    Pairs[High(Pairs)].Dst := Dst;
  end;

  // Part B: enumerate subdir files (mirror-tree rotation).
  SubdirFiles := EnumerateReleaseScopedSubdirFiles(ExeDir);
  UpdateLog(Format('M2 rotate: %d subdir files enumerated',
    [Length(SubdirFiles)]));

  if Length(SubdirFiles) > 0 then
  begin
    MirrorRoot := ReserveOldMirrorRoot(ExeDir, AOldBuild);
    UpdateLog(Format('M2 rotate: mirror root=%s', [MirrorRoot]));
    try
      ForceDirectories(MirrorRoot);
    except
      on E: Exception do
        raise EMxError.Create('RENAME_FAIL',
          Format('Cannot create mirror root %s: %s: %s',
            [MirrorRoot, E.ClassName, E.Message]), 500);
    end;

    for I := 0 to High(SubdirFiles) do
    begin
      Src := SubdirFiles[I];
      if not TFile.Exists(Src) then Continue;
      // Compute path relative to ExeDir. StartsText guard covers the
      // (shouldn't-happen) case where TDirectory.GetFiles returned a
      // fully-unrelated absolute path.
      if StartsText(ExeDir, Src) then
        RelPath := Copy(Src, Length(ExeDir) + 1, MaxInt)
      else if StartsText(ExeDirNoTrail, Src) then
        RelPath := Copy(Src, Length(ExeDirNoTrail) + 2, MaxInt)
      else
        Continue;
      if RelPath = '' then Continue;
      Dst := TPath.Combine(MirrorRoot, RelPath);
      SetLength(Pairs, Length(Pairs) + 1);
      Pairs[High(Pairs)].Src := Src;
      Pairs[High(Pairs)].Dst := Dst;
    end;
  end;

  // Single atomic loop — any failure reverses prior moves.
  for I := 0 to High(Pairs) do
  begin
    // Ensure the parent dir exists before move (only matters for mirror
    // subdir entries; root files always have ExeDir as parent which
    // already exists).
    try
      ForceDirectories(ExtractFilePath(Pairs[I].Dst));
    except
      on E: Exception do
      begin
        for J := 0 to I - 1 do
          MoveFileWithRetry(Pairs[J].Dst, Pairs[J].Src);
        raise EMxError.Create('RENAME_FAIL',
          Format('Cannot create parent dir for %s: %s: %s',
            [Pairs[I].Dst, E.ClassName, E.Message]), 500);
      end;
    end;
    if not MoveFileWithRetry(Pairs[I].Src, Pairs[I].Dst) then
    begin
      for J := 0 to I - 1 do
        MoveFileWithRetry(Pairs[J].Dst, Pairs[J].Src);
      raise EMxError.Create('RENAME_FAIL',
        Format('Cannot rename %s -> %s (GetLastError=%d)',
          [Pairs[I].Src, Pairs[I].Dst, GetLastError]), 500);
    end;
  end;
  UpdateLog(Format('M2 rotate: OK %d files moved (root+mirror)',
    [Length(Pairs)]));
end;

// Returns the basename of the currently running process executable —
// either 'mxLoreMCP.exe' (console build) or 'mxLoreMCPGui.exe' (GUI build).
// Self-Update must restart the SAME variant the user was running.
function RunningExeBasename: string;
begin
  Result := ExtractFileName(ParamStr(0));
end;

// C7c / Bug#3052 Approach C (Plan#3082 M2): split-layout rollback.
// Mirrors the two-part rotation in RotateLiveFilesToOld:
//   Part A: walk the flat root list and, for every '<root>.old-<N>'
//           beside ExeDir, MoveFileWithRetry it back — BUT only if
//           the live slot is empty (skip-if-live-exists semantics,
//           matches the original pre-M2 behaviour). This keeps the
//           code path simple and lets the user handle manual
//           rollback of partial-extract remnants via README guidance.
//   Part B: walk '<ExeDir>\.old-<N>\' recursively and apply the same
//           skip-if-live-exists rule for each mirrored subdir file.
//
// Per-file try/except + UpdateLog so a single failure does not stop
// the rest. After the walk a best-effort TDirectory.Delete cleans up
// the now-mostly-empty mirror tree.
procedure RollbackLiveFilesFromOld(AOldBuild: Integer);
const
  RootNames: array[0..7] of string = (
    'mxLoreMCP.exe',
    'mxLoreMCPGui.exe',
    'mxMCPProxy.exe',
    'libmariadb32.dll',
    'README.md',
    'LICENSE.txt',
    'iis-url-rewrite-rule.xml',
    'mxLoreMCP.ini.example'
  );
var
  ExeDir, MirrorRoot, MirrorRootNoTrail, Src, RelPath, Dst: string;
  MirrorFiles: TArray<string>;
  I, K, Restored, Skipped: Integer;
begin
  ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Restored := 0;
  Skipped  := 0;

  // Part A: flat root files — walk canonical names, restore
  // '<root>.old-<AOldBuild>' back to '<root>' only when the live
  // slot is empty (original pre-M2 skip-if-live-exists semantics).
  for K := Low(RootNames) to High(RootNames) do
  begin
    Dst := TPath.Combine(ExeDir, RootNames[K]);
    Src := Format('%s.old-%d', [Dst, AOldBuild]);
    if not TFile.Exists(Src) then Continue;
    if TFile.Exists(Dst) then
    begin
      // Skip: live slot already has a (fresh) binary.
      Inc(Skipped);
      Continue;
    end;
    try
      if MoveFileWithRetry(Src, Dst) then
      begin
        Inc(Restored);
        UpdateLog(Format('C7c rollback: restored root %s', [RootNames[K]]));
      end
      else
      begin
        Inc(Skipped);
        UpdateLog(Format('C7c rollback: restore root %s FAILED GetLastError=%d',
          [RootNames[K], GetLastError]));
      end;
    except
      on E: Exception do
      begin
        Inc(Skipped);
        UpdateLog(Format('C7c rollback: restore root %s raised %s: %s',
          [RootNames[K], E.ClassName, E.Message]));
      end;
    end;
  end;

  // Part B: mirror-tree subdirs.
  MirrorRoot := Format('%s.old-%d', [ExeDir, AOldBuild]);
  if not DirectoryExists(MirrorRoot) then
  begin
    UpdateLog(Format('C7c rollback: mirror root missing (%s) — root-only pass',
      [MirrorRoot]));
    UpdateLog(Format('C7c rollback: done restored=%d skipped=%d',
      [Restored, Skipped]));
    Exit;
  end;

  MirrorRootNoTrail := ExcludeTrailingPathDelimiter(MirrorRoot);
  try
    MirrorFiles := TDirectory.GetFiles(MirrorRoot, '*',
      TSearchOption.soAllDirectories);
  except
    on E: Exception do
    begin
      UpdateLog(Format('C7c rollback: mirror enum failed %s: %s',
        [E.ClassName, E.Message]));
      UpdateLog(Format('C7c rollback: done restored=%d skipped=%d',
        [Restored, Skipped]));
      Exit;
    end;
  end;

  for I := 0 to High(MirrorFiles) do
  begin
    Src := MirrorFiles[I];
    if StartsText(MirrorRoot, Src) then
      RelPath := Copy(Src, Length(MirrorRoot) + 1, MaxInt)
    else if StartsText(MirrorRootNoTrail, Src) then
      RelPath := Copy(Src, Length(MirrorRootNoTrail) + 2, MaxInt)
    else
    begin
      Inc(Skipped);
      Continue;
    end;
    while (RelPath <> '') and
          ((RelPath[1] = '\') or (RelPath[1] = '/')) do
      RelPath := Copy(RelPath, 2, MaxInt);
    if RelPath = '' then
    begin
      Inc(Skipped);
      Continue;
    end;
    Dst := TPath.Combine(ExeDir, RelPath);
    if TFile.Exists(Dst) then
    begin
      // Skip: live slot already populated (e.g. fresh extract succeeded).
      Inc(Skipped);
      Continue;
    end;
    try
      ForceDirectories(ExtractFilePath(Dst));
      if MoveFileWithRetry(Src, Dst) then
      begin
        Inc(Restored);
        UpdateLog(Format('C7c rollback: restored %s', [RelPath]));
      end
      else
      begin
        Inc(Skipped);
        UpdateLog(Format('C7c rollback: restore %s FAILED GetLastError=%d',
          [RelPath, GetLastError]));
      end;
    except
      on E: Exception do
      begin
        Inc(Skipped);
        UpdateLog(Format('C7c rollback: restore %s raised %s: %s',
          [RelPath, E.ClassName, E.Message]));
      end;
    end;
  end;
  UpdateLog(Format('C7c rollback: done restored=%d skipped=%d',
    [Restored, Skipped]));

  // Best-effort: remove the now-mostly-empty mirror tree so
  // CleanupOldFiles does not need to visit it later. Any residual
  // file (skipped because live exists) keeps the tree around;
  // retention age-out will catch it.
  try
    TDirectory.Delete(MirrorRoot, True);
    UpdateLog(Format('C7c rollback: mirror root %s removed', [MirrorRoot]));
  except
    on E: Exception do
      UpdateLog(Format('C7c rollback: mirror root %s remove failed %s: %s',
        [MirrorRoot, E.ClassName, E.Message]));
  end;
end;

// C6: Pick a free .old-<N> slot for the given base path. If the primary
// slot (<base>.old-<N>) is already occupied from a previous update run,
// fall back to <base>.old-<N>(2), (3), ... up to 99. Raises if exhausted.
function ReserveOldSlot(const ABasePath: string; ANewBuild: Integer): string;
var
  Suffix: Integer;
begin
  Result := Format('%s.old-%d', [ABasePath, ANewBuild]);
  Suffix := 2;
  while TFile.Exists(Result) do
  begin
    Result := Format('%s.old-%d(%d)', [ABasePath, ANewBuild, Suffix]);
    Inc(Suffix);
    if Suffix > 99 then
      raise EMxError.Create('RESERVE_OLD_SLOT_EXHAUSTED', ABasePath, 500);
  end;
end;

// C6: Before FinishUpdate extracts the zip, move any existing mxLore binaries
// out of the way so the fresh bytes can be written. Windows allows renaming
// a running exe, but not overwriting it — hence the rename-before-extract.
// Called from FinishUpdate in both normal (child) and recovery (boot-hook)
// paths. Best-effort: a rename failure is logged but non-fatal; the extract
// loop will surface the lock error if it still cannot write.
//
// Bug#3052 Approach C (Plan#3082 M2): in the parent-does-everything path
// (InstallAndRestart -> RotateLiveFilesToOld -> FinishUpdate) this helper
// is now effectively a no-op, because RotateLiveFilesToOld has already
// vacated every live release-scoped file into the mirror tree and the
// live slots are empty. It is retained intact for the recovery boot path
// in mxLoreMCP.dpr which still invokes FinishUpdate directly on a marker
// file without a prior rotate, and for the ReserveOldSlot fall-back it
// wraps. Do not remove without auditing the dpr recovery branch.
procedure RenameLiveBinariesForExtraction(const AExeDir: string; ANewBuild: Integer);
const
  LiveBinaries: array[0..2] of string = (
    'mxLoreMCP.exe',
    'mxLoreMCPGui.exe',
    'libmariadb32.dll'
  );
var
  I: Integer;
  Src, Reserved, Failures: string;
begin
  Failures := '';
  for I := Low(LiveBinaries) to High(LiveBinaries) do
  begin
    Src := TPath.Combine(AExeDir, LiveBinaries[I]);
    if not TFile.Exists(Src) then Continue;
    try
      Reserved := ReserveOldSlot(Src, ANewBuild);
      if MoveFileWithRetry(Src, Reserved) then
        UpdateLog(Format('C6: renamed %s -> %s', [LiveBinaries[I], ExtractFileName(Reserved)]))
      else
      begin
        UpdateLog(Format('C6: rename %s FAILED GetLastError=%d', [LiveBinaries[I], GetLastError]));
        if Failures <> '' then Failures := Failures + ', ';
        Failures := Failures + LiveBinaries[I];
      end;
    except
      on E: Exception do
      begin
        UpdateLog(Format('C6: ReserveOldSlot/rename %s raised %s: %s', [LiveBinaries[I], E.ClassName, E.Message]));
        if Failures <> '' then Failures := Failures + ', ';
        Failures := Failures + LiveBinaries[I];
      end;
    end;
  end;
  // C7h: raise BEFORE the extract loop if any live binary could not be
  // vacated. Otherwise the follow-up TFile.WriteAllBytes surfaces as a
  // raw EInOutError 'sharing violation' with no attribution to the
  // rename step, and the admin UI sees a generic RTL exception instead
  // of a clear "exe still locked" message. Early raise lets C7c
  // rollback put everything back before the state diverges further.
  if Failures <> '' then
    raise EMxError.Create('UPDATE_FAIL',
      'live binary still locked: ' + Failures, 500);
end;

// C7f: ExtractOnlyRunningExe removed — parent now inlines FinishUpdate
// (ADR#2804 parent-does-everything). The former "prime the pump" step
// that extracted a single exe out of the release zip so CreateProcess
// could spawn it is gone: FinishUpdate already writes every binary
// during rotate+extract, so no separate single-file extract is needed.

// C2: detect whether this process runs under a user session (has a visible
// desktop) vs Windows Service Session 0 (non-interactive). CREATE_NEW_CONSOLE
// requires an interactive WindowStation; in Session 0 it fails and the child
// is left without stdio. Fall back to DETACHED_PROCESS + CREATE_NO_WINDOW.
// Imported directly (user32 function may not be exposed uniformly across
// Winapi.Windows versions we compile against).
function _MxGetUserObjectInformationW(hObj: THandle; nIndex: Integer;
  pvInfo: Pointer; nLength: DWORD; lpnLengthNeeded: PDWORD): BOOL;
  stdcall; external 'user32.dll' name 'GetUserObjectInformationW';
function _MxGetProcessWindowStation: THandle;
  stdcall; external 'user32.dll' name 'GetProcessWindowStation';

function IsUserInteractive: Boolean;
const
  UOI_NAME = 2;
var
  WinSta: THandle;
  Len: DWORD;
  Name: array[0..255] of WideChar;
begin
  Result := False;
  WinSta := _MxGetProcessWindowStation;
  if WinSta = 0 then Exit;
  Len := 0;
  if not _MxGetUserObjectInformationW(WinSta, UOI_NAME, @Name, SizeOf(Name), @Len) then
    Exit;
  // Interactive user session window stations are named "WinSta0".
  // Service Session 0 uses names like "Service-0x0-3e7$" etc.
  Result := SameText(string(PWideChar(@Name[0])), 'WinSta0');
end;

procedure MxSelfUpdate_InstallAndRestart;
var
  Info: TMxUpdateInfo;
  ZipPath, ExeDir, CmdLine, RunningExe: string;
  Marker: TMxUpdateMarker;
  SI: TStartupInfo;
  PI: TProcessInformation;
  CreateFlags: DWORD;
begin
  UpdateLog('=== InstallAndRestart ENTER ===');
  // M3 Task 8 (Bug#3052): prevent a second caller from racing rotate +
  // extract. TryEnter returns False if already held; we then refuse
  // with 409 Conflict. On success ExitProcess(0) kills the process so
  // the lock is released by OS cleanup; on any exception the except
  // branch releases it explicitly so subsequent callers can proceed.
  if not gInstallLock.TryEnter then
  begin
    UpdateLog('abort: install already running (gInstallLock busy)');
    raise EMxError.Create('UPDATE_FAIL', 'install already running', 409);
  end;
  try
  RunningExe := RunningExeBasename;
  UpdateLog('RunningExe (from ParamStr(0)) = ' + RunningExe);
  if not gConfig.Enabled then
  begin
    UpdateLog('abort: self-update disabled');
    raise EMxError.Create('FORBIDDEN', 'self-update disabled in INI', 403);
  end;

  Info := MxSelfUpdate_Check(False);
  UpdateLog(Format('Check state=%s current=%d latest=%d zip=%s sha=%s',
    [GetEnumName(TypeInfo(TMxUpdateState), Ord(Info.State)),
     Info.CurrentBuild, Info.LatestBuild, Info.ZipUrl, Info.ZipSha256]));
  if Info.State <> usUpdateAvailable then
    raise EMxError.Create('UPDATE_FAIL',
      'no update available (state=' +
      GetEnumName(TypeInfo(TMxUpdateState), Ord(Info.State)) + ')', 409);

  UpdateLog('Download START');
  ZipPath := MxSelfUpdate_DownloadZip(Info);
  UpdateLog('Download OK -> ' + ZipPath);

  Marker.OldBuild    := MXAI_BUILD;
  Marker.NewBuild    := Info.LatestBuild;
  Marker.ZipPath     := ZipPath;
  Marker.StartedAt   := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now);
  Marker.FinishStage := 'pending';
  Marker.RetryCount  := 0;
  WriteMarker(MarkerFilePath, Marker);
  UpdateLog('Marker written: ' + MarkerFilePath);

  Info.State := usSwapping;
  gLastCheckLock.Enter;
  try
    gLastCheckInfo := Info;
    gHasCheckInfo  := True;
  finally
    gLastCheckLock.Leave;
  end;

  UpdateLog('Rotate START (old build=' + IntToStr(MXAI_BUILD) + ')');
  try
    RotateLiveFilesToOld(MXAI_BUILD);
    UpdateLog('Rotate OK');
  except
    on E: EMxError do
    begin
      UpdateLog('Rotate FAIL: ' + E.Code + ': ' + E.Message);
      MxSelfUpdate_SetErrorState('ROTATE_FAIL: ' + E.Message);
      raise;
    end;
  end;

  ExeDir := ExtractFilePath(ParamStr(0));

  // C7a/ADR#2804 parent-does-everything: extract ALL entries (exe + dll
  // + html/js + sql) inline, then either spawn the restart (interactive
  // builds) or exit and let AlwaysUp restart us (service branch). The
  // previous design split "extract running exe" in the parent from
  // "extract the rest" in a detached child; AlwaysUp killed that child
  // as a duplicate, so the non-exe files never landed. Doing it all in
  // the parent closes that race.
  UpdateLog('FinishUpdate (inline) START');
  try
    MxSelfUpdate_FinishUpdate(ZipPath);
    UpdateLog('FinishUpdate (inline) OK');
  except
    on E: Exception do
    begin
      UpdateLog('FinishUpdate (inline) FAIL: ' + E.ClassName + ': ' + E.Message);
      // C7c full rollback: restore exe + sibling variant + libmariadb32
      // from their .old-<MXAI_BUILD> slots. Previously only the running
      // exe was restored, leaving the install non-bootable.
      RollbackLiveFilesFromOld(MXAI_BUILD);
      MxSelfUpdate_SetErrorState('UPDATE_FAIL: finish: ' + E.Message);
      raise EMxError.Create('UPDATE_FAIL', E.Message, 500);
    end;
  end;

  // C7a: non-interactive (Service Session 0, AlwaysUp) skips CreateProcess
  // entirely. AlwaysUp will observe our ExitProcess, wait its restart grace
  // period, then relaunch the monitored exe — which now points to the newly
  // extracted binary. No child spawn -> no AlwaysUp duplicate-kill race.
  if not IsUserInteractive then
  begin
    UpdateLog('Non-interactive branch: skipping CreateProcess, parent exit -> AlwaysUp restart');
    Sleep(1500);
    UpdateLog('Pre-ExitProcess(0) — parent terminating NOW (non-interactive)');
    // gInstallLock is intentionally NOT Leave'd here: ExitProcess kills
    // the process at kernel level; OS releases the CS handle. Finalization
    // never runs on this path — by design (see initialization block).
    ExitProcess(0);
  end;

  // C8 (Build 92): spawn a plain boot — no --finish-update flag. The parent
  // already did the full extraction inline (C7a), so the child has zero
  // update work left. Passing --finish-update caused a race where the child
  // tried to read the already-deleted marker and hung on the mutex loop for
  // ~5 minutes (Session 242 22:05 incident). Plain boot skips that branch
  // entirely and goes straight to normal Application.Run.
  CmdLine := Format('"%s"', [TPath.Combine(ExeDir, RunningExe)]);
  UpdateLog('CreateProcess cmd=' + CmdLine);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  // CREATE_NEW_CONSOLE (below) gives the child a valid stdin/stdout/stderr
  // so FireDAC.ConsoleUI.Wait + Delphi RTL console init don't abort.
  // STARTF_USESHOWWINDOW + SW_HIDE keep the console invisible.
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  FillChar(PI, SizeOf(PI), 0);

  CreateFlags := CREATE_NEW_CONSOLE or CREATE_NEW_PROCESS_GROUP;
  UpdateLog(Format('CreateFlags=0x%x interactive=True', [CreateFlags]));
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
       CreateFlags, nil, nil, SI, PI) then
  begin
    UpdateLog('CreateProcess FAIL GetLastError=' + IntToStr(GetLastError));
    MxSelfUpdate_SetErrorState(Format('SPAWN_FAIL: CreateProcess failed %d',
      [GetLastError]));
    // C7c: full rollback on spawn-fail. The extracted new binaries are
    // already in place at this point, but the old ones are still present
    // as .old-<MXAI_BUILD> and the rollback helper only restores slots
    // that are empty. So in this rare path the rotated files usually
    // stay in their .old-<N> form (extraction already wrote the live
    // slots) — the helper is idempotent and safe to call regardless.
    RollbackLiveFilesFromOld(MXAI_BUILD);
    raise EMxError.Create('SPAWN_FAIL',
      Format('CreateProcess failed: %d', [GetLastError]), 500);
  end;
  UpdateLog('CreateProcess OK ChildPID=' + IntToStr(PI.dwProcessId));
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  UpdateLog('Pre-ExitProcess sleep 1500');

  // Terminate parent via ExitProcess (Win32 kernel call).
  // We deliberately DO NOT call gStopProc or Halt — both are unsafe from
  // a background thread while Sparkle handlers/workers are still mid-
  // flight. Prior attempts triggered EOSError Code 5 + ntdll AV from
  // races between FAdminServer.Stop + Sparkle thread pool + logger.
  // ExitProcess kills the process at kernel level: all handles released,
  // no Delphi finalization, no thread unwinding. Child is DETACHED_PROCESS
  // so it survives; ports 8080/8081 are freed immediately.
  Sleep(1500);
  UpdateLog('Pre-ExitProcess(0) — parent terminating NOW');
  // gInstallLock is intentionally NOT Leave'd here: ExitProcess kills
  // the process at kernel level; OS releases the CS handle. Finalization
  // never runs on this path — by design (see initialization block).
  ExitProcess(0);
  except
    on E: Exception do
    begin
      // M3 Task 8 (Bug#3052): release install lock on any failure so a
      // retry from the admin UI can proceed. ExitProcess on the happy
      // path never reaches this, so we do NOT need a finally branch.
      gInstallLock.Leave;
      raise;
    end;
  end;
end;
{$ELSE}
procedure MxSelfUpdate_InstallAndRestart;
begin
  raise EMxError.Create('UPDATE_FAIL', 'Self-Update requires Windows', 500);
end;
{$ENDIF}

// Bug#3052 Approach C (Plan#3082 M2): age-out '<ExeDir>.old-<N>[-suffix]'
// mirror directories. Replaces the former flat-file '*.old-*' delete
// walk. Policy:
//   1. Enumerate every '.old-*' directory beside ExeDir.
//   2. Sort by LastWriteTime ascending (oldest first).
//   3. Delete entries where (beyond-cap) OR (age >= retention hours).
//      The cap (MaxOldMirrors, default 3) guarantees that even with a
//      long retention window the mirror surface cannot grow unbounded
//      after rapid back-to-back updates.
// Runs unconditionally on successful boot (callers unchanged).
// StagingDir zip cleanup is kept as-is — still purely age-gated.
procedure MxSelfUpdate_CleanupOldFiles;
type
  TMirrorEntry = record
    Path: string;
    Age : TDateTime;
  end;
var
  ExeDir, F: string;
  Mirrors: TArray<string>;
  Entries: array of TMirrorEntry;
  I, J, Keep, Cap: Integer;
  Tmp: TMirrorEntry;
  AgeHours: Integer;
  Files: TArray<string>;
  Age: TDateTime;
begin
  ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  // Mirror roots live INSIDE ExeDir as '<ExeDir>\.old-<N>[-suffix]'.
  // Enumerate them with the '.old-*' pattern.
  try
    Mirrors := TDirectory.GetDirectories(ExeDir, '.old-*');
  except
    Mirrors := nil;
  end;

  SetLength(Entries, Length(Mirrors));
  for I := 0 to High(Mirrors) do
  begin
    Entries[I].Path := Mirrors[I];
    try
      Entries[I].Age := TDirectory.GetLastWriteTime(Mirrors[I]);
    except
      // If we cannot stat the dir, treat it as ancient so it gets pruned.
      Entries[I].Age := 0;
    end;
  end;

  // Simple insertion sort — mirror count is at most a handful in practice.
  for I := 1 to High(Entries) do
  begin
    Tmp := Entries[I];
    J := I - 1;
    while (J >= 0) and (Entries[J].Age > Tmp.Age) do
    begin
      Entries[J + 1] := Entries[J];
      Dec(J);
    end;
    Entries[J + 1] := Tmp;
  end;

  Cap := gConfig.MaxOldMirrors;
  if Cap < 1 then Cap := 1;
  // Oldest first: anything with index < (Count - Cap) is beyond the cap
  // and must be deleted regardless of age.
  Keep := Length(Entries) - Cap;
  if Keep < 0 then Keep := 0;
  for I := 0 to High(Entries) do
  begin
    AgeHours := HoursBetween(Now, Entries[I].Age);
    if (I < Keep) or (AgeHours >= gConfig.OldFileRetentionHours) then
    begin
      try
        TDirectory.Delete(Entries[I].Path, True);
        UpdateLog(Format('M2 cleanup: removed mirror %s (age=%dh)',
          [Entries[I].Path, AgeHours]));
      except
        on E: Exception do
          UpdateLog(Format('M2 cleanup: remove %s failed %s: %s',
            [Entries[I].Path, E.ClassName, E.Message]));
      end;
    end;
  end;

  // Legacy flat '.old-*' files from pre-M2 installs: sweep them on the
  // same retention clock so mixed-boundary upgrades do not leave
  // orphans sitting in ExeDir forever.
  try
    Files := TDirectory.GetFiles(ExeDir, '*.old-*');
  except
    Files := nil;
  end;
  for F in Files do
  begin
    try
      Age := TFile.GetLastWriteTime(F);
    except
      Continue;
    end;
    if HoursBetween(Now, Age) >= gConfig.OldFileRetentionHours then
      try TFile.Delete(F); except end;
  end;

  if DirectoryExists(StagingDir) then
  begin
    // C7d: UrlFileName from the GitHub browser_download_url resolves to
    // 'mxLore-v<sem>-win64.zip' (build-release.sh convention), not
    // 'mxLore-build-<N>.zip'. Previous wildcard never matched -> staging
    // dir grew unbounded. Cast wider to every mxLore-*.zip.
    try
      Files := TDirectory.GetFiles(StagingDir, 'mxLore-*.zip');
    except
      Files := nil;
    end;
    for F in Files do
    begin
      try
        Age := TFile.GetLastWriteTime(F);
      except
        Continue;
      end;
      if HoursBetween(Now, Age) >= gConfig.OldFileRetentionHours then
        try TFile.Delete(F); except end;
    end;
  end;
end;

procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
var
  Marker: TMxUpdateMarker;
  MarkerPath, ExeDir, EntryName, StrippedEntry, TargetPath, WrapperPrefix: string;
  Zip: TZipFile;
  I: Integer;
  Bytes: TBytes;
begin
  UpdateLog('=== FinishUpdate ENTER zip=' + AZipPath + ' ===');
  MarkerPath := MarkerFilePath;
  if not TFile.Exists(MarkerPath) then
  begin
    UpdateLog('marker not found at ' + MarkerPath + ' — exit');
    WriteLn('[WARN] MxSelfUpdate_FinishUpdate called but marker not found');
    Exit;
  end;

  Marker := ReadMarker(MarkerPath);
  UpdateLog(Format('Marker read: Old=%d New=%d RetryCount=%d Stage=%s',
    [Marker.OldBuild, Marker.NewBuild, Marker.RetryCount, Marker.FinishStage]));
  // M3 Task 11 (Bug#3052): a truncated / zeroed marker (power-loss mid
  // write, disk corruption) must not trigger the retry loop — retries
  // would replay extraction with OldBuild=0/NewBuild=0 and write bogus
  // filenames. Delete the marker and raise so the caller rolls back;
  // manual recovery policy matches Spec#3079 rev 5.
  if (Marker.OldBuild <= 0) or (Marker.NewBuild <= 0) then
  begin
    UpdateLog(Format('Marker CORRUPT Old=%d New=%d — abort without retry',
      [Marker.OldBuild, Marker.NewBuild]));
    MxSelfUpdate_SetErrorState(Format(
      'Update marker corrupt (Old=%d New=%d) — manual recovery required',
      [Marker.OldBuild, Marker.NewBuild]));
    try TFile.Delete(MarkerPath); except end;
    raise EMxError.Create('UPDATE_MARKER_CORRUPT',
      Format('marker corrupt: Old=%d New=%d',
        [Marker.OldBuild, Marker.NewBuild]), 500);
  end;
  Inc(Marker.RetryCount);
  // C7e: WriteMarker can raise if the marker file slot is locked
  // (antivirus, concurrent scan). A raise here kills FinishUpdate with
  // the RetryCount not persisted, so the next boot replays the same
  // retry forever. Best-effort increment: log the failure and keep
  // going so the retry cap still triggers.
  try
    WriteMarker(MarkerPath, Marker);
  except
    on E: Exception do
      UpdateLog('C7e: WriteMarker (retry-count persist) failed: ' +
        E.ClassName + ': ' + E.Message);
  end;
  UpdateLog('RetryCount incremented to ' + IntToStr(Marker.RetryCount));

  if Marker.RetryCount > gConfig.MaxFinishRetries then
  begin
    UpdateLog('RetryCount exceeds MaxFinishRetries=' +
      IntToStr(gConfig.MaxFinishRetries) + ' — HALT');
    WriteLn(ErrOutput, Format(
      '[CRITICAL] Update stuck after %d retries - manual recovery required',
      [gConfig.MaxFinishRetries]));
    MxSelfUpdate_SetErrorState(Format(
      'Update stuck after %d retries - manual recovery required',
      [gConfig.MaxFinishRetries]));
    // C7e: delete the marker on retry-exhaust so the next boot does not
    // re-enter the recovery branch and spin. Best-effort — if deletion
    // itself fails the user needs manual cleanup anyway.
    try
      TFile.Delete(MarkerPath);
      UpdateLog('C7e: marker deleted after retry-exhaust');
    except
      on E: Exception do
        UpdateLog('C7e: marker delete after retry-exhaust failed: ' +
          E.ClassName + ': ' + E.Message);
    end;
    Exit;
  end;

  if not TFile.Exists(AZipPath) then
  begin
    UpdateLog('Zip missing at: ' + AZipPath);
    WriteLn(ErrOutput, 'finish-update: zip not found: ', AZipPath);
    MxSelfUpdate_SetErrorState('zip missing: ' + AZipPath);
    Exit;
  end;

  ExeDir := ExtractFilePath(ParamStr(0));
  UpdateLog('ExeDir=' + ExeDir);

  // C6: Rename running binaries (mxLoreMCP*.exe + libmariadb32.dll) to
  // .old-<NewBuild> before extracting, so file-locks cannot block the fresh
  // writes. Handles pre-existing .old-<NewBuild> slots via incrementing
  // (2), (3), ... suffix.
  RenameLiveBinariesForExtraction(ExeDir, Marker.NewBuild);

  Marker.FinishStage := 'extracting';
  WriteMarker(MarkerPath, Marker);
  UpdateLog('Marker stage=extracting persisted');

  Zip := TZipFile.Create;
  try
    Zip.Open(AZipPath, zmRead);
    UpdateLog('Zip opened, FileCount=' + IntToStr(Zip.FileCount));
    // build-release.sh wraps all entries under "mxLore-v*-win64/"; detect
    // the common top-level prefix and strip it so extraction lands in
    // ExeDir directly instead of ExeDir/mxLore-v*/.
    WrapperPrefix := DetectZipWrapperPrefix(Zip);
    UpdateLog('WrapperPrefix=' + WrapperPrefix);
    for I := 0 to Zip.FileCount - 1 do
    begin
      EntryName := Zip.FileNames[I];
      StrippedEntry := StripZipWrapperDir(EntryName, WrapperPrefix);
      if StrippedEntry = '' then Continue; // was the wrapper dir itself

      // Skip user config files — never overwrite user settings during update.
      // mxLoreMCP.ini holds the server config, mxMCPProxy.ini holds the
      // Claude Code client proxy config (often locked by a live Claude Code
      // session running the proxy from this repo's claude-setup/proxy/).
      if SameText(ZipEntryBaseName(StrippedEntry), 'mxLoreMCP.ini')  then Continue;
      if SameText(ZipEntryBaseName(StrippedEntry), 'mxMCPProxy.ini') then Continue;

      if not IsPathWithin(ExeDir, StrippedEntry) then
        raise EMxError.Create('PATH_TRAVERSAL', StrippedEntry, 400);

      TargetPath := TPath.GetFullPath(TPath.Combine(ExeDir, StrippedEntry));

      if StrippedEntry.EndsWith('/') or StrippedEntry.EndsWith('\') then
      begin
        ForceDirectories(TargetPath);
        Continue;
      end;

      ForceDirectories(ExtractFilePath(TargetPath));
      // M3 Task 12a (Bug#3052): disk-full / ACL / AV-lock mid-write
      // left a partial TargetPath behind. Delete the half-written
      // entry before re-raising so the outer Zip.Free in finally
      // gets a clean state and the caller's RollbackLiveFilesFromOld
      // (InstallAndRestart) is the only source of leftover state.
      try
        Zip.Read(I, Bytes);
        TFile.WriteAllBytes(TargetPath, Bytes);
      except
        on E: Exception do
        begin
          if TFile.Exists(TargetPath) then
          try TFile.Delete(TargetPath); except end;
          raise;
        end;
      end;
    end;
  finally
    Zip.Free;
  end;

  Marker.FinishStage := 'done';
  WriteMarker(MarkerPath, Marker);
  TFile.Delete(MarkerPath);
  UpdateLog('Marker stage=done -> deleted marker file');

  gLastCheckLock.Enter;
  try
    gLastCheckInfo.State        := usPostUpdateOk;
    gLastCheckInfo.CurrentBuild := Marker.NewBuild;
    gLastCheckInfo.LatestBuild  := Marker.NewBuild;
    gHasCheckInfo := True;
  finally
    gLastCheckLock.Leave;
  end;

  MxSelfUpdate_CleanupOldFiles;
  UpdateLog('=== FinishUpdate EXIT (success) ===');
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

initialization
  gLastCheckLock := TCriticalSection.Create;
  gInstallLock   := TCriticalSection.Create;

finalization
  FreeAndNil(gLastCheckLock);
  FreeAndNil(gInstallLock);

end.
