unit mx.Crypto;

interface

uses
  System.SysUtils;

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

/// <summary>
///   Constant-time byte comparison. Always iterates over all bytes to avoid
///   revealing information via timing side-channel. Returns False immediately
///   if lengths differ (length disclosure is acceptable for fixed-size tokens).
/// </summary>
function ConstantTimeEqualBytes(const A, B: TBytes): Boolean;

/// <summary>
///   Constant-time string comparison (UTF-8 bytes). Use for invite tokens,
///   API keys, HMACs — any secret where timing leaks must be prevented.
/// </summary>
function ConstantTimeEqualStrings(const A, B: string): Boolean;

/// <summary>
///   Generates AByteCount cryptographically secure random bytes and returns
///   them as a lowercase hex string (length = AByteCount * 2). Uses Windows
///   BCryptGenRandom (BCRYPT_USE_SYSTEM_PREFERRED_RNG). Raises on failure —
///   callers must not fall back to non-CSPRNG.
/// </summary>
function MxGenerateRandomHex(AByteCount: Integer): string;

implementation

uses
  System.Hash, System.NetEncoding, Winapi.Windows;

const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte;
  cbBuffer: ULONG; dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

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
  Status: Integer;
begin
  SetLength(Result, ALen);
  Status := BCryptGenRandom(nil, @Result[0], ALen,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if Status <> 0 then
    raise Exception.CreateFmt(
      'RandomSalt: BCryptGenRandom failed (NTSTATUS 0x%.8x)', [Status]);
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

    Result := ConstantTimeEqualBytes(ComputedKey, StoredKey);
  end
  else
  begin
    // Legacy: plain SHA256. Normalize both sides to lowercase hex, then
    // compare in constant time to prevent timing side-channel on login.
    ComputedSHA256 := LowerCase(THashSHA2.GetHashString(ARawKey, SHA256));
    Result := ConstantTimeEqualStrings(ComputedSHA256, LowerCase(AStoredHash));
  end;
end;

function ConstantTimeEqualBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
  Diff: Byte;
begin
  // Length disclosure is acceptable — token lengths are fixed or public.
  if Length(A) <> Length(B) then
    Exit(False);
  Diff := 0;
  for I := 0 to High(A) do
    Diff := Diff or (A[I] xor B[I]);
  Result := (Diff = 0);
end;

function ConstantTimeEqualStrings(const A, B: string): Boolean;
var
  BytesA, BytesB: TBytes;
begin
  BytesA := TEncoding.UTF8.GetBytes(A);
  BytesB := TEncoding.UTF8.GetBytes(B);
  Result := ConstantTimeEqualBytes(BytesA, BytesB);
end;

function MxGenerateRandomHex(AByteCount: Integer): string;
var
  Buf: TBytes;
  Status: Integer;
begin
  if AByteCount <= 0 then
    raise EArgumentException.Create('MxGenerateRandomHex: byte count must be > 0');
  SetLength(Buf, AByteCount);
  Status := BCryptGenRandom(nil, @Buf[0], AByteCount,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if Status <> 0 then
    raise Exception.CreateFmt(
      'MxGenerateRandomHex: BCryptGenRandom failed (NTSTATUS 0x%.8x)', [Status]);
  Result := BytesToHex(Buf);
end;

end.
