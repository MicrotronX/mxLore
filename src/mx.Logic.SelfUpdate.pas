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

function  MxSelfUpdate_Check(AForce: Boolean = False): TMxUpdateInfo;
procedure MxSelfUpdate_InstallAndRestart;
procedure MxSelfUpdate_FinishUpdate(const AZipPath: string);
procedure MxSelfUpdate_CleanupOldFiles;

function  MxSelfUpdate_RunSelfTests: Integer;

implementation

uses
  System.IniFiles;

var
  gConfig: TMxSelfUpdateConfig;

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

function MxSelfUpdate_RunSelfTests: Integer;
begin
  gTestCount  := 0;
  gTestFailed := 0;
  WriteLn('=== mx.Logic.SelfUpdate self-tests ===');
  WriteLn(Format('=== %d tests, %d failed ===', [gTestCount, gTestFailed]));
  if gTestFailed > 0 then Result := 1 else Result := 0;
end;

end.
