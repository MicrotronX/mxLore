unit mx.Proxy.Log;

interface

type
  TMxLogLevel = (llInfo, llDebug);

procedure LogInit;
procedure SetLogLevel(ALevel: TMxLogLevel); overload;
procedure SetLogLevel(const ALevelName: string); overload;
procedure Log(const S: string);
procedure LogDebug(const S: string);

implementation

uses
  System.SysUtils, System.Classes, Winapi.Windows;

var
  GLogPath: string = '';
  GLogLock: TRTLCriticalSection;
  GLogInited: Boolean = False;
  GLogLevel: TMxLogLevel = llInfo;

function GetExeDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  GetModuleFileName(0, Buf, Length(Buf));
  Result := ExtractFilePath(Buf);
end;

procedure LogInit;
begin
  if GLogInited then Exit;
  InitializeCriticalSection(GLogLock);
  GLogPath := GetExeDir + 'mxMCPProxy.log';
  GLogInited := True;
end;

procedure SetLogLevel(ALevel: TMxLogLevel);
begin
  GLogLevel := ALevel;
end;

procedure SetLogLevel(const ALevelName: string);
var
  Lower: string;
begin
  Lower := LowerCase(Trim(ALevelName));
  if (Lower = 'debug') or (Lower = 'trace') or (Lower = 'verbose') then
    GLogLevel := llDebug
  else
    GLogLevel := llInfo;
end;

procedure WriteToFile(const Line: string);
var
  F: THandle;
  Bytes: TBytes;
  BytesWritten: DWORD;
begin
  if GLogPath = '' then Exit;
  Bytes := TEncoding.UTF8.GetBytes(Line + #13#10);
  if Length(Bytes) = 0 then Exit;
  F := CreateFile(PChar(GLogPath), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
                  nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if F = INVALID_HANDLE_VALUE then Exit;
  try
    SetFilePointer(F, 0, nil, FILE_END);
    WriteFile(F, Bytes[0], Length(Bytes), BytesWritten, nil);
    FlushFileBuffers(F);
  finally
    CloseHandle(F);
  end;
end;

procedure EmitLine(const S: string);
var
  Stamp, Line: string;
begin
  if not GLogInited then LogInit;
  Stamp := FormatDateTime('hh:nn:ss.zzz', Now);
  Line := Stamp + ' ' + S;

  // stderr write OUTSIDE the critsec. If CC is not draining stderr and the
  // pipe buffer fills, WriteLn blocks — we must not hold GLogLock while that
  // happens, otherwise the poll thread's Log() call would deadlock.
  try
    WriteLn(ErrOutput, S);
    Flush(ErrOutput);
  except
  end;

  // Only the file write needs serialization across threads.
  EnterCriticalSection(GLogLock);
  try
    try
      WriteToFile(Line);
    except
    end;
  finally
    LeaveCriticalSection(GLogLock);
  end;
end;

procedure Log(const S: string);
begin
  EmitLine(S);
end;

procedure LogDebug(const S: string);
begin
  if GLogLevel <> llDebug then Exit;
  EmitLine(S);
end;

initialization

finalization
  if GLogInited then
    DeleteCriticalSection(GLogLock);

end.
