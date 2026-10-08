unit mx.Data.Params;

// Data-layer parameter helpers. Lives below Logic/Intelligence/Tools so
// every layer can bind large text without depending on a Tool unit.

interface

uses
  Data.DB,
  FireDAC.Stan.Param;

// FireDAC accepts strings beyond the default 32767-byte parameter limit.
// FireDAC's default Param.Size is 32767 (FConnDefParams.MaxStringSize) and
// setting DataType := ftWideMemo alone does NOT lift it — Size must be set
// explicitly as well. We allocate at least 1 MB to absorb future growth
// without forcing reparameterisation each call.
procedure BindLargeText(AParam: TFDParam; const AValue: string);

implementation

const
  // Minimum allocation for large-text params. Most doc bodies are a few KB,
  // but specs/plans/lessons can grow above 100 KB. 1 MB ceiling keeps memory
  // bounded for normal docs while leaving headroom for large ones.
  cLargeTextMinSize = 1024 * 1024;

procedure BindLargeText(AParam: TFDParam; const AValue: string);
var
  RequiredSize: Integer;
begin
  AParam.DataType := ftWideMemo;
  RequiredSize := Length(AValue) + 1024;
  if RequiredSize < cLargeTextMinSize then
    RequiredSize := cLargeTextMinSize;
  AParam.Size := RequiredSize;
  // Bug#3345 fix (Session 267): .AsString on ftWideMemo unexpectedly routed
  // through AnsiString(ACP=cp1252 on German Windows), dropping U+2192/U+2713
  // /U+26A0 etc. to '?'. .AsWideString binds via Param.Value as WideString
  // end-to-end — verified lossless for all BMP codepoints. The HEX probe on
  // doc#3492 showed literal 0x3F bytes stored; after the fix the same body
  // stores 0xE2 0x86 0x92 for '→'.
  AParam.AsWideString := AValue;
end;

end.
