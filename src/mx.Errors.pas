unit mx.Errors;

interface

uses
  System.SysUtils, System.JSON, FireDAC.Stan.Error;

type
  EMxError = class(Exception)
  public
    Code: string;
    HttpStatus: Integer;
    constructor Create(const ACode, AMessage: string; AHttpStatus: Integer = 500);
  end;

  EMxNotFound   = class(EMxError)
    constructor Create(const AMessage: string);
  end;

  EMxConflict   = class(EMxError)
    constructor Create(const AMessage: string);
  end;

  EMxAuthError  = class(EMxError)
    constructor Create(const AMessage: string);
  end;

  EMxValidation = class(EMxError)
    constructor Create(const AMessage: string);
  end;

  EMxInternal   = class(EMxError)
    constructor Create(const AMessage: string);
  end;

function MxErrorResponse(const ACode, AMessage: string): TJSONObject;
function MxSuccessResponse(const AData: TJSONValue;
  ATokensUsed: Integer = 0): TJSONObject;
function MapDBError(E: EFDDBEngineException): TJSONObject;

// FR#2936/Plan#3266 M3.9 — RFC7807 application/problem+json builder for
// HTTP-level error responses (auth failures, rate-limits). Used by
// mx.MCP.Server + mx.Admin.Server to replace ad-hoc {"error":"..."} bodies.
// Spec#3194 v3 §I9: namespaced `mxlore` extension carries three flat fields:
// `reason` (Spec §I9 domain-code, drives type-URI), `suggested_action`
// (Spec enum: retry/rotate/request_access/contact_admin/none), and
// `decision_basis` (AC-27 non-functional slot, always emitted — may be
// empty string for v1 per spec).
//   AReason:          Spec §I9 domain-code (matches AR_* consts); drives
//                     type URI and body.mxlore.reason. Empty → about:blank.
//   ATitle:           short human sentence, stable across locales (EN)
//   ADetail:          longer human explanation (locale-negotiable in future)
//   AStatus:          HTTP status code (401 / 403 / 404 / 409 / 429 / 500)
//   ASuggestedAction: RFC7807-ext enum from Spec §I9, empty='none'
//   ADecisionBasis:   AC-27 non-functional slot, default empty per v1
//   AInstance:        URI-ref identifying the specific occurrence (optional)
function MxRfc7807Response(const AReason, ATitle, ADetail: string;
  AStatus: Integer; const ASuggestedAction: string = '';
  const ADecisionBasis: string = '';
  const AInstance: string = ''): TJSONObject;

implementation

{ EMxError }

constructor EMxError.Create(const ACode, AMessage: string; AHttpStatus: Integer);
begin
  inherited Create(AMessage);
  Code := ACode;
  HttpStatus := AHttpStatus;
end;

{ EMxNotFound }

constructor EMxNotFound.Create(const AMessage: string);
begin
  inherited Create('NOT_FOUND', AMessage, 404);
end;

{ EMxConflict }

constructor EMxConflict.Create(const AMessage: string);
begin
  inherited Create('CONFLICT', AMessage, 409);
end;

{ EMxAuthError }

constructor EMxAuthError.Create(const AMessage: string);
begin
  inherited Create('UNAUTHORIZED', AMessage, 401);
end;

{ EMxValidation }

constructor EMxValidation.Create(const AMessage: string);
begin
  inherited Create('VALIDATION_ERROR', AMessage, 400);
end;

{ EMxInternal }

constructor EMxInternal.Create(const AMessage: string);
begin
  inherited Create('INTERNAL', AMessage, 500);
end;

{ Helper functions }

function MxErrorResponse(const ACode, AMessage: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('status', 'error');
  Result.AddPair('code', ACode);
  Result.AddPair('message', AMessage);
end;

function MxSuccessResponse(const AData: TJSONValue;
  ATokensUsed: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('status', 'ok');
  Result.AddPair('data', AData);
  if ATokensUsed > 0 then
    Result.AddPair('tokens_used', TJSONNumber.Create(ATokensUsed));
  Result.AddPair('warnings', TJSONArray.Create);
end;

function MapDBError(E: EFDDBEngineException): TJSONObject;
begin
  case E.Kind of
    ekUKViolated:
      Result := MxErrorResponse('DUPLICATE', 'Entry already exists');
    ekFKViolated:
      Result := MxErrorResponse('REFERENCE_ERROR', 'Referenced object not found');
    ekRecordLocked:
      Result := MxErrorResponse('LOCKED', 'Record is locked');
  else
    Result := MxErrorResponse('DB_ERROR', E.Message);
  end;
end;

function MxRfc7807Response(const AReason, ATitle, ADetail: string;
  AStatus: Integer; const ASuggestedAction: string;
  const ADecisionBasis: string; const AInstance: string): TJSONObject;
var
  TypeUri, SuggestedAction: string;
  Ext: TJSONObject;
begin
  // Use mxlore-namespaced URI so clients can distinguish mxLore-specific
  // problem types from generic HTTP ones. Fallback to about:blank when
  // AReason is empty (shouldn't happen in production paths).
  if AReason <> '' then
    TypeUri := 'https://mxlore.dev/errors/' + LowerCase(AReason)
  else
    TypeUri := 'about:blank';

  // Spec §I9 ASuggestedAction enum: retry / rotate / request_access /
  // contact_admin / none. Default 'none' when caller passes empty —
  // keeps the field stable-shape for client-side switch/case.
  if ASuggestedAction <> '' then
    SuggestedAction := ASuggestedAction
  else
    SuggestedAction := 'none';

  Result := TJSONObject.Create;
  Result.AddPair('type',   TypeUri);
  Result.AddPair('title',  ATitle);
  Result.AddPair('status', TJSONNumber.Create(AStatus));
  Result.AddPair('detail', ADetail);
  if AInstance <> '' then
    Result.AddPair('instance', AInstance);

  // Namespaced extension per RFC7807 §3.2 + Spec §I9. Clients that don't
  // recognise the `mxlore` key ignore it without breaking; clients that
  // DO can consume reason + suggested_action for i18n / UI hints, and
  // decision_basis is reserved per AC-27 (always emitted, may be empty).
  Ext := TJSONObject.Create;
  Ext.AddPair('reason',           AReason);
  Ext.AddPair('suggested_action', SuggestedAction);
  Ext.AddPair('decision_basis',   ADecisionBasis);
  Result.AddPair('mxlore', Ext);
end;

end.
