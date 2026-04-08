unit mx.Crypto;

interface

/// <summary>
///   PBKDF2-HMAC-SHA256 key derivation and verification.
///   Hash format: pbkdf2:iterations:salt_hex:hash_hex
/// </summary>

/// <summary>Hashes a raw key using PBKDF2-HMAC-SHA256 with random salt</summary>
function MxHashKey(const ARawKey: string): string;

/// <summary>Verifies a raw key against a stored hash (PBKDF2 or legacy SHA256)</summary>
function MxVerifyKey(const ARawKey, AStoredHash: string): Boolean;

/// <summary>Returns True if hash uses PBKDF2 format</summary>
function MxIsPBKDF2(const AHash: string): Boolean;

implementation

uses
  System.SysUtils, System.Hash, System.NetEncoding;

const
  PBKDF2_ITERATIONS = 100000;
  PBKDF2_SALT_LEN   = 16;  // 16 bytes = 128 bit
  PBKDF2_KEY_LEN    = 32;  // 32 bytes = 256 bit
  PBKDF2_PREFIX     = 'pbkdf2:';

function BytesToHex(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + IntToHex(ABytes[I], 2);
  Result := LowerCase(Result);
end;

function HexToBytes(const AHex: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AHex) div 2);
  for I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(AHex, I * 2 + 1, 2));
end;

function RandomSalt(ALen: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ALen);
  for I := 0 to ALen - 1 do
    Result[I] := Random(256);
end;

function XorBytes(const A, B: TBytes): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I] xor B[I];
end;

function PBKDF2_SHA256(const APassword, ASalt: TBytes;
  AIterations, AKeyLen: Integer): TBytes;
var
  BlockCount, I, J, K: Integer;
  U, T, SaltBlock: TBytes;
  Block: array[0..3] of Byte;
begin
  // PBKDF2 per RFC 2898
  BlockCount := (AKeyLen + 31) div 32; // SHA256 = 32 bytes per block
  SetLength(Result, 0);

  for I := 1 to BlockCount do
  begin
    // Salt || INT(i) big-endian
    SetLength(SaltBlock, Length(ASalt) + 4);
    Move(ASalt[0], SaltBlock[0], Length(ASalt));
    Block[0] := Byte(I shr 24);
    Block[1] := Byte(I shr 16);
    Block[2] := Byte(I shr 8);
    Block[3] := Byte(I);
    Move(Block[0], SaltBlock[Length(ASalt)], 4);

    // U1 = HMAC-SHA256(password, salt || INT(i))
    U := THashSHA2.GetHMACAsBytes(SaltBlock, APassword);
    T := Copy(U);

    // U2..Uc
    for J := 2 to AIterations do
    begin
      U := THashSHA2.GetHMACAsBytes(U, APassword);
      T := XorBytes(T, U);
    end;

    Result := Result + T;
  end;

  SetLength(Result, AKeyLen);
end;

function MxIsPBKDF2(const AHash: string): Boolean;
begin
  Result := AHash.StartsWith(PBKDF2_PREFIX, True);
end;

function MxHashKey(const ARawKey: string): string;
var
  Salt, DerivedKey, KeyBytes: TBytes;
begin
  Randomize;
  Salt := RandomSalt(PBKDF2_SALT_LEN);
  KeyBytes := TEncoding.UTF8.GetBytes(ARawKey);
  DerivedKey := PBKDF2_SHA256(KeyBytes, Salt, PBKDF2_ITERATIONS, PBKDF2_KEY_LEN);
  Result := PBKDF2_PREFIX + IntToStr(PBKDF2_ITERATIONS) + ':' +
    BytesToHex(Salt) + ':' + BytesToHex(DerivedKey);
end;

function MxVerifyKey(const ARawKey, AStoredHash: string): Boolean;
var
  Parts: TArray<string>;
  Iterations: Integer;
  Salt, StoredKey, ComputedKey, KeyBytes: TBytes;
  ComputedSHA256: string;
begin
  if MxIsPBKDF2(AStoredHash) then
  begin
    // Format: pbkdf2:iterations:salt_hex:hash_hex
    Parts := AStoredHash.Substring(Length(PBKDF2_PREFIX)).Split([':']);
    if Length(Parts) <> 3 then
      Exit(False);

    Iterations := StrToIntDef(Parts[0], 0);
    if Iterations <= 0 then
      Exit(False);

    Salt := HexToBytes(Parts[1]);
    StoredKey := HexToBytes(Parts[2]);
    KeyBytes := TEncoding.UTF8.GetBytes(ARawKey);
    ComputedKey := PBKDF2_SHA256(KeyBytes, Salt, Iterations, Length(StoredKey));

    // Constant-time comparison
    Result := (Length(ComputedKey) = Length(StoredKey));
    if Result then
      for var I := 0 to High(StoredKey) do
        if ComputedKey[I] <> StoredKey[I] then
          Result := False;
  end
  else
  begin
    // Legacy: plain SHA256
    ComputedSHA256 := THashSHA2.GetHashString(ARawKey, SHA256);
    Result := SameText(ComputedSHA256, AStoredHash);
  end;
end;

end.
