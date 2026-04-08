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

end.
