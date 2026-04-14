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

procedure MxSelfUpdate_LoadConfig(const AIniPath: string);
function  MxSelfUpdate_Config: TMxSelfUpdateConfig;

function  ParseTagName(const ATag: string): Integer;
function  CompareBuild(ACurrent, ALatest: Integer): TMxUpdateState;

function  MxSelfUpdate_Check(AForce: Boolean = False): TMxUpdateInfo;
procedure MxSelfUpdate_InstallAndRestart;
procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
procedure MxSelfUpdate_CleanupOldFiles;

function  MxSelfUpdate_RunSelfTests: Integer;

implementation

uses
  System.IniFiles, System.RegularExpressions;

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

function MxSelfUpdate_RunSelfTests: Integer;
begin
  gTestCount  := 0;
  gTestFailed := 0;
  WriteLn('=== mx.Logic.SelfUpdate self-tests ===');
  RunParseTagNameTests;
  RunCompareBuildTests;
  WriteLn(Format('=== %d tests, %d failed ===', [gTestCount, gTestFailed]));
  if gTestFailed > 0 then Result := 1 else Result := 0;
end;

end.
