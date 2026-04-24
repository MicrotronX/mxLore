unit mx.Crypto.Bundle;

// AES-256-GCM authenticated encryption for FR#3896 Project Export/Import bundles.
// Uses Windows CNG (bcrypt.dll) — same provider already used in mx.Crypto.pas
// for BCryptGenRandom, so no new external dependency.
//
// Key length: 32 bytes (AES-256). IV length: 12 bytes (GCM standard).
// Auth tag:   16 bytes (GCM standard, full-strength).
//
// Callers derive the 32-byte key via PBKDF2 (see mx.Crypto.PBKDF2_SHA256).

interface

uses
  System.SysUtils;

const
  MX_BUNDLE_KEY_LEN = 32;   // AES-256 key size
  MX_BUNDLE_IV_LEN  = 12;   // GCM recommended nonce size
  MX_BUNDLE_TAG_LEN = 16;   // GCM full-strength authentication tag

type
  /// <summary>Authentication-tag mismatch on decrypt — wrong key/IV or tampered bundle.</summary>
  EMxCryptoAuthFail = class(Exception);
  /// <summary>Any other crypto-layer failure (CNG API error, invalid sizes, etc.).</summary>
  EMxCryptoError    = class(Exception);

/// <summary>Encrypts APlaintext with AES-256-GCM. Caller supplies a fresh IV
/// (12 bytes; generate via MxBundleRandomBytes). Returns ciphertext and 16-byte
/// auth tag in the out params. AAssocData (AAD) is optional extra-authenticated-
/// data — use for manifest-header binding. Caller-owned IV lets the caller bind
/// it into AAD BEFORE encrypting (avoids chicken-and-egg with GCM-output-IV).</summary>
procedure MxBundleEncrypt(const APlaintext, AKey, AIv: TBytes;
  out ACiphertext, AAuthTag: TBytes;
  const AAssocData: TBytes = nil);

/// <summary>Decrypts AES-256-GCM ciphertext. Raises EMxCryptoAuthFail on wrong key
/// / wrong AAD / tampered ciphertext. AAssocData must match the AAD used at encrypt.</summary>
function MxBundleDecrypt(const ACiphertext, AKey, AIv, AAuthTag: TBytes;
  const AAssocData: TBytes = nil): TBytes;

/// <summary>Generates N cryptographically-secure random bytes via BCryptGenRandom.</summary>
function MxBundleRandomBytes(ALen: Integer): TBytes;

implementation

uses
  Winapi.Windows;

// ---------------------------------------------------------------------------
// Windows CNG (bcrypt.dll) minimal interop — only what we need for AES-GCM.
// ---------------------------------------------------------------------------

const
  STATUS_SUCCESS           = 0;
  STATUS_AUTH_TAG_MISMATCH = Integer($C000A002);  // NTSTATUS for GCM tag fail

  BCRYPT_AES_ALGORITHM   : PWideChar = 'AES';
  BCRYPT_CHAINING_MODE   : PWideChar = 'ChainingMode';
  BCRYPT_CHAIN_MODE_GCM  : PWideChar = 'ChainingModeGCM';
  BCRYPT_OBJECT_LENGTH   : PWideChar = 'ObjectLength';

  BCRYPT_AUTH_MODE_INFO_VERSION = 1;

  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;

type
  BCRYPT_ALG_HANDLE = Pointer;
  BCRYPT_KEY_HANDLE = Pointer;

  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = record
    cbSize:        ULONG;
    dwInfoVersion: ULONG;
    pbNonce:       PByte;
    cbNonce:       ULONG;
    pbAuthData:    PByte;
    cbAuthData:    ULONG;
    pbTag:         PByte;
    cbTag:         ULONG;
    pbMacContext:  PByte;
    cbMacContext:  ULONG;
    cbAAD:         ULONG;
    cbData:        UInt64;
    dwFlags:       ULONG;
  end;

function BCryptOpenAlgorithmProvider(var phAlgorithm: BCRYPT_ALG_HANDLE;
  pszAlgId, pszImplementation: PWideChar; dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptCloseAlgorithmProvider(hAlgorithm: BCRYPT_ALG_HANDLE;
  dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptSetProperty(hObject: Pointer; pszProperty: PWideChar;
  pbInput: PByte; cbInput: ULONG; dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptGetProperty(hObject: Pointer; pszProperty: PWideChar;
  pbOutput: PByte; cbOutput: ULONG; var pcbResult: ULONG;
  dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptGenerateSymmetricKey(hAlgorithm: BCRYPT_ALG_HANDLE;
  var phKey: BCRYPT_KEY_HANDLE; pbKeyObject: PByte; cbKeyObject: ULONG;
  pbSecret: PByte; cbSecret: ULONG; dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptDestroyKey(hKey: BCRYPT_KEY_HANDLE): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptEncrypt(hKey: BCRYPT_KEY_HANDLE; pbInput: PByte;
  cbInput: ULONG; pPaddingInfo: Pointer; pbIV: PByte; cbIV: ULONG;
  pbOutput: PByte; cbOutput: ULONG; var pcbResult: ULONG;
  dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptDecrypt(hKey: BCRYPT_KEY_HANDLE; pbInput: PByte;
  cbInput: ULONG; pPaddingInfo: Pointer; pbIV: PByte; cbIV: ULONG;
  pbOutput: PByte; cbOutput: ULONG; var pcbResult: ULONG;
  dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte;
  cbBuffer: ULONG; dwFlags: ULONG): Integer;
  stdcall; external 'bcrypt.dll';

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function WideStrByteLen(P: PWideChar): ULONG;
// Returns (wide-char-count + NUL) * 2 — byte length BCryptSetProperty expects.
var
  L: Integer;
begin
  L := 0;
  while P[L] <> #0 do
    Inc(L);
  Result := (ULONG(L) + 1) * SizeOf(WideChar);
end;

procedure RaiseNT(const AWhat: string; AStatus: Integer);
begin
  raise EMxCryptoError.CreateFmt('%s failed (NTSTATUS 0x%.8x)',
    [AWhat, AStatus]);
end;

function MxBundleRandomBytes(ALen: Integer): TBytes;
var
  Status: Integer;
begin
  if ALen <= 0 then
    raise EMxCryptoError.Create('MxBundleRandomBytes: ALen must be > 0');
  SetLength(Result, ALen);
  Status := BCryptGenRandom(nil, @Result[0], ALen,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if Status <> STATUS_SUCCESS then
    RaiseNT('BCryptGenRandom', Status);
end;

// ---------------------------------------------------------------------------
// Encrypt
// ---------------------------------------------------------------------------

procedure MxBundleEncrypt(const APlaintext, AKey, AIv: TBytes;
  out ACiphertext, AAuthTag: TBytes;
  const AAssocData: TBytes = nil);
var
  hAlg:          BCRYPT_ALG_HANDLE;
  hKey:          BCRYPT_KEY_HANDLE;
  KeyObject:     TBytes;
  KeyObjectLen:  ULONG;
  ResultLen:     ULONG;
  AuthInfo:      BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
  Status:        Integer;
  PInput:        PByte;
  PAAD:          PByte;
begin
  if Length(AKey) <> MX_BUNDLE_KEY_LEN then
    raise EMxCryptoError.CreateFmt(
      'MxBundleEncrypt: Key must be %d bytes (got %d)',
      [MX_BUNDLE_KEY_LEN, Length(AKey)]);
  if Length(AIv) <> MX_BUNDLE_IV_LEN then
    raise EMxCryptoError.CreateFmt(
      'MxBundleEncrypt: IV must be %d bytes (got %d)',
      [MX_BUNDLE_IV_LEN, Length(AIv)]);

  SetLength(AAuthTag, MX_BUNDLE_TAG_LEN);

  Status := BCryptOpenAlgorithmProvider(hAlg, BCRYPT_AES_ALGORITHM, nil, 0);
  if Status <> STATUS_SUCCESS then
    RaiseNT('BCryptOpenAlgorithmProvider', Status);
  try
    Status := BCryptSetProperty(hAlg, BCRYPT_CHAINING_MODE,
      PByte(BCRYPT_CHAIN_MODE_GCM),
      WideStrByteLen(BCRYPT_CHAIN_MODE_GCM), 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptSetProperty(GCM)', Status);

    Status := BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH,
      PByte(@KeyObjectLen), SizeOf(KeyObjectLen), ResultLen, 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptGetProperty(ObjectLength)', Status);

    SetLength(KeyObject, KeyObjectLen);

    Status := BCryptGenerateSymmetricKey(hAlg, hKey,
      @KeyObject[0], KeyObjectLen,
      @AKey[0], Length(AKey), 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptGenerateSymmetricKey', Status);
    try
      FillChar(AuthInfo, SizeOf(AuthInfo), 0);
      AuthInfo.cbSize        := SizeOf(AuthInfo);
      AuthInfo.dwInfoVersion := BCRYPT_AUTH_MODE_INFO_VERSION;
      AuthInfo.pbNonce       := @AIv[0];
      AuthInfo.cbNonce       := Length(AIv);
      if Length(AAssocData) > 0 then
      begin
        PAAD := @AAssocData[0];
        AuthInfo.pbAuthData := PAAD;
        AuthInfo.cbAuthData := Length(AAssocData);
      end;
      AuthInfo.pbTag := @AAuthTag[0];
      AuthInfo.cbTag := MX_BUNDLE_TAG_LEN;

      if Length(APlaintext) > 0 then
        PInput := @APlaintext[0]
      else
        PInput := nil;

      // Size-query pass
      ResultLen := 0;
      Status := BCryptEncrypt(hKey, PInput, Length(APlaintext),
        @AuthInfo, nil, 0, nil, 0, ResultLen, 0);
      if Status <> STATUS_SUCCESS then
        RaiseNT('BCryptEncrypt(size-query)', Status);

      SetLength(ACiphertext, ResultLen);

      // Actual encrypt pass
      Status := BCryptEncrypt(hKey, PInput, Length(APlaintext),
        @AuthInfo, nil, 0, @ACiphertext[0], ResultLen, ResultLen, 0);
      if Status <> STATUS_SUCCESS then
        RaiseNT('BCryptEncrypt', Status);

      SetLength(ACiphertext, ResultLen);
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

// ---------------------------------------------------------------------------
// Decrypt
// ---------------------------------------------------------------------------

function MxBundleDecrypt(const ACiphertext, AKey, AIv, AAuthTag: TBytes;
  const AAssocData: TBytes = nil): TBytes;
var
  hAlg:          BCRYPT_ALG_HANDLE;
  hKey:          BCRYPT_KEY_HANDLE;
  KeyObject:     TBytes;
  KeyObjectLen:  ULONG;
  ResultLen:     ULONG;
  AuthInfo:      BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
  Status:        Integer;
  PInput:        PByte;
  PTag:          PByte;
  PAAD:          PByte;
  LocalTag:      TBytes;
begin
  if Length(AKey) <> MX_BUNDLE_KEY_LEN then
    raise EMxCryptoError.CreateFmt(
      'MxBundleDecrypt: Key must be %d bytes (got %d)',
      [MX_BUNDLE_KEY_LEN, Length(AKey)]);
  if Length(AIv) <> MX_BUNDLE_IV_LEN then
    raise EMxCryptoError.CreateFmt(
      'MxBundleDecrypt: IV must be %d bytes (got %d)',
      [MX_BUNDLE_IV_LEN, Length(AIv)]);
  if Length(AAuthTag) <> MX_BUNDLE_TAG_LEN then
    raise EMxCryptoError.CreateFmt(
      'MxBundleDecrypt: AuthTag must be %d bytes (got %d)',
      [MX_BUNDLE_TAG_LEN, Length(AAuthTag)]);

  // Copy the tag into a local mutable buffer — CNG may write through pbTag
  // on failure, and we don't want to mutate a caller's const array.
  SetLength(LocalTag, MX_BUNDLE_TAG_LEN);
  Move(AAuthTag[0], LocalTag[0], MX_BUNDLE_TAG_LEN);

  Status := BCryptOpenAlgorithmProvider(hAlg, BCRYPT_AES_ALGORITHM, nil, 0);
  if Status <> STATUS_SUCCESS then
    RaiseNT('BCryptOpenAlgorithmProvider', Status);
  try
    Status := BCryptSetProperty(hAlg, BCRYPT_CHAINING_MODE,
      PByte(BCRYPT_CHAIN_MODE_GCM),
      WideStrByteLen(BCRYPT_CHAIN_MODE_GCM), 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptSetProperty(GCM)', Status);

    Status := BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH,
      PByte(@KeyObjectLen), SizeOf(KeyObjectLen), ResultLen, 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptGetProperty(ObjectLength)', Status);

    SetLength(KeyObject, KeyObjectLen);

    Status := BCryptGenerateSymmetricKey(hAlg, hKey,
      @KeyObject[0], KeyObjectLen,
      @AKey[0], Length(AKey), 0);
    if Status <> STATUS_SUCCESS then
      RaiseNT('BCryptGenerateSymmetricKey', Status);
    try
      FillChar(AuthInfo, SizeOf(AuthInfo), 0);
      AuthInfo.cbSize        := SizeOf(AuthInfo);
      AuthInfo.dwInfoVersion := BCRYPT_AUTH_MODE_INFO_VERSION;
      AuthInfo.pbNonce       := @AIv[0];
      AuthInfo.cbNonce       := Length(AIv);
      if Length(AAssocData) > 0 then
      begin
        PAAD := @AAssocData[0];
        AuthInfo.pbAuthData := PAAD;
        AuthInfo.cbAuthData := Length(AAssocData);
      end;
      PTag := @LocalTag[0];
      AuthInfo.pbTag := PTag;
      AuthInfo.cbTag := MX_BUNDLE_TAG_LEN;

      if Length(ACiphertext) > 0 then
        PInput := @ACiphertext[0]
      else
        PInput := nil;

      ResultLen := 0;
      Status := BCryptDecrypt(hKey, PInput, Length(ACiphertext),
        @AuthInfo, nil, 0, nil, 0, ResultLen, 0);
      if Status <> STATUS_SUCCESS then
        RaiseNT('BCryptDecrypt(size-query)', Status);

      SetLength(Result, ResultLen);

      Status := BCryptDecrypt(hKey, PInput, Length(ACiphertext),
        @AuthInfo, nil, 0, @Result[0], ResultLen, ResultLen, 0);
      if Status = STATUS_AUTH_TAG_MISMATCH then
        raise EMxCryptoAuthFail.Create(
          'Bundle decryption failed — wrong key/passphrase or tampered bundle');
      if Status <> STATUS_SUCCESS then
        RaiseNT('BCryptDecrypt', Status);

      SetLength(Result, ResultLen);
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

end.
