unit mx.Log;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  mx.Types;

type
  TLogEntryProc = TProc<TDateTime, TMxLogLevel, string>;

  TStructuredLogger = class(TInterfacedObject, IMxLogger)
  private
    FLock: TCriticalSection;
    FFileStream: TStreamWriter;
    FMinLevel: TMxLogLevel;
    FConsoleOutput: Boolean;
    FOnLogEntry: TLogEntryProc;
    function LevelToString(ALevel: TMxLogLevel): string;
    function BuildLogLine(ALevel: TMxLogLevel; const AMsg: string;
                          AData: TJSONObject): string;
  public
    constructor Create(const ALogFile: string; const ALogLevel: string;
                       AConsoleOutput: Boolean = True);
    destructor Destroy; override;
    procedure Log(ALevel: TMxLogLevel; const AMsg: string;
                  AData: TJSONObject = nil);
    class procedure RotateIfNeeded(const ALogFile: string;
      AMaxSize: Int64; AKeepFiles: Integer); static;
    property ConsoleOutput: Boolean read FConsoleOutput write FConsoleOutput;
    property OnLogEntry: TLogEntryProc read FOnLogEntry write FOnLogEntry;
  end;

  TMxNullLogger = class(TInterfacedObject, IMxLogger)
    procedure Log(ALevel: TMxLogLevel; const AMsg: string;
                  AData: TJSONObject = nil);
  end;

implementation

uses
  System.DateUtils, System.IOUtils;

constructor TStructuredLogger.Create(const ALogFile: string;
  const ALogLevel: string; AConsoleOutput: Boolean);
var
  LogDir: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FConsoleOutput := AConsoleOutput;

  // Parse log level
  if SameText(ALogLevel, 'DEBUG') then FMinLevel := mlDebug
  else if SameText(ALogLevel, 'WARNING') then FMinLevel := mlWarning
  else if SameText(ALogLevel, 'ERROR') then FMinLevel := mlError
  else FMinLevel := mlInfo;

  // Ensure log directory exists
  LogDir := ExtractFilePath(ALogFile);
  if (LogDir <> '') and not DirectoryExists(LogDir) then
    ForceDirectories(LogDir);

  // Log rotation: max 5MB per file, keep 5 rotated files
  RotateIfNeeded(ALogFile, 5 * 1024 * 1024, 5);

  // Open log file (append, shared read access so external tools can read)
  if FileExists(ALogFile) then
    FFileStream := TStreamWriter.Create(
      TFileStream.Create(ALogFile, fmOpenReadWrite or fmShareDenyWrite),
      TEncoding.UTF8)
  else
    FFileStream := TStreamWriter.Create(
      TFileStream.Create(ALogFile, fmCreate or fmShareDenyWrite),
      TEncoding.UTF8);
  FFileStream.OwnStream;
  FFileStream.BaseStream.Seek(0, soEnd);
  FFileStream.AutoFlush := True;
end;

destructor TStructuredLogger.Destroy;
begin
  // Acquire lock to ensure no writer is active (W4)
  if Assigned(FLock) then
    FLock.Enter;
  try
    FreeAndNil(FFileStream);
  finally
    if Assigned(FLock) then
    begin
      FLock.Leave;
      FreeAndNil(FLock);
    end;
  end;
  inherited;
end;

function TStructuredLogger.LevelToString(ALevel: TMxLogLevel): string;
const
  Names: array[TMxLogLevel] of string =
    ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL');
begin
  Result := Names[ALevel];
end;

function TStructuredLogger.BuildLogLine(ALevel: TMxLogLevel;
  const AMsg: string; AData: TJSONObject): string;
var
  Line: TJSONObject;
  Pair: TJSONPair;
begin
  Line := TJSONObject.Create;
  try
    Line.AddPair('ts', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      TTimeZone.Local.ToUniversalTime(Now)));
    Line.AddPair('level', LevelToString(ALevel));
    Line.AddPair('msg', AMsg);

    // Merge extra data fields into log line
    if Assigned(AData) then
      for Pair in AData do
        Line.AddPair(TJSONPair(Pair.Clone));

    Result := Line.ToJSON;
  finally
    Line.Free;
  end;
end;

procedure TStructuredLogger.Log(ALevel: TMxLogLevel; const AMsg: string;
  AData: TJSONObject);
var
  Line: string;
  NotifyProc: TLogEntryProc;
begin
  if ALevel < FMinLevel then
    Exit;

  Line := BuildLogLine(ALevel, AMsg, AData);

  FLock.Enter;
  try
    // Write to file
    FFileStream.WriteLine(Line);

    // Write to console (only when not GUI mode)
    if FConsoleOutput then
    begin
      if ALevel >= mlError then
        WriteLn(ErrOutput, Line)
      else
        WriteLn(Line);
    end;

    // Copy observer reference under lock
    NotifyProc := FOnLogEntry;
  finally
    FLock.Leave;
  end;

  // Notify observer OUTSIDE lock (deadlock prevention)
  if Assigned(NotifyProc) then
    NotifyProc(Now, ALevel, AMsg);
end;

class procedure TStructuredLogger.RotateIfNeeded(const ALogFile: string;
  AMaxSize: Int64; AKeepFiles: Integer);
var
  I: Integer;
  OldName, NewName: string;
begin
  if not FileExists(ALogFile) then
    Exit;
  if TFile.GetSize(ALogFile) < AMaxSize then
    Exit;

  // Shift existing rotated files: .5 -> delete, .4 -> .5, .3 -> .4, ...
  for I := AKeepFiles downto 1 do
  begin
    OldName := ALogFile + '.' + IntToStr(I);
    if I = AKeepFiles then
    begin
      if FileExists(OldName) then
        TFile.Delete(OldName);
    end
    else
    begin
      NewName := ALogFile + '.' + IntToStr(I + 1);
      if FileExists(OldName) then
        TFile.Move(OldName, NewName);
    end;
  end;

  // Rotate current log -> .1
  TFile.Move(ALogFile, ALogFile + '.1');
end;

{ TMxNullLogger }

procedure TMxNullLogger.Log(ALevel: TMxLogLevel; const AMsg: string;
  AData: TJSONObject);
begin
  // No-op
end;

end.
