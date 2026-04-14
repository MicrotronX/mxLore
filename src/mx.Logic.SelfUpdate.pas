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

function  MxSelfUpdate_Check(AForce: Boolean = False): TMxUpdateInfo;
procedure MxSelfUpdate_InstallAndRestart;
procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
procedure MxSelfUpdate_CleanupOldFiles;

function  MxSelfUpdate_RunSelfTests: Integer;

implementation

uses
  System.IniFiles, System.RegularExpressions, System.IOUtils, System.Hash,
  System.StrUtils, mx.Errors;

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
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.State := usIdle;
end;

procedure MxSelfUpdate_InstallAndRestart;
begin
  raise Exception.Create('not implemented');
end;

procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
begin
end;

procedure MxSelfUpdate_CleanupOldFiles;
begin
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
  WriteLn(Format('=== %d tests, %d failed ===', [gTestCount, gTestFailed]));
  if gTestFailed > 0 then Result := 1 else Result := 0;
end;

end.
