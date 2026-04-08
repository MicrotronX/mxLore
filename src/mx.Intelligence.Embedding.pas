unit mx.Intelligence.Embedding;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math,
  System.Net.HttpClient, System.Net.URLClient,
  mx.Types, mx.Config;

type
  TMxEmbeddingClient = class
  private
    FConfig: TMxConfig;
    FLogger: IMxLogger;
  public
    constructor Create(AConfig: TMxConfig; ALogger: IMxLogger);

    /// <summary>
    /// Calls the configured embedding API and returns the vector.
    /// Returns nil on any error (graceful, no exception).
    /// </summary>
    function GetEmbedding(const AText: string): TArray<Single>;

    /// <summary>
    /// Builds the embedding input string from title, tags, and content.
    /// Truncates content to AMaxChars.
    /// </summary>
    class function BuildEmbeddingInput(const ATitle, ATags, AContent: string;
      AMaxChars: Integer): string;

  end;

implementation

{ TMxEmbeddingClient }

constructor TMxEmbeddingClient.Create(AConfig: TMxConfig; ALogger: IMxLogger);
begin
  inherited Create;
  FConfig := AConfig;
  FLogger := ALogger;
end;

function TMxEmbeddingClient.GetEmbedding(const AText: string): TArray<Single>;
var
  Http: THTTPClient;
  ReqBody, RespStr: string;
  ReqStream: TStringStream;
  Response: IHTTPResponse;
  JsonResp, DataItem: TJSONObject;
  DataArr, EmbArr: TJSONArray;
  I: Integer;
begin
  Result := nil;
  if AText.Trim.IsEmpty then
    Exit;

  Http := THTTPClient.Create;
  try
    try
      Http.ConnectionTimeout := 5000;
      Http.ResponseTimeout := FConfig.EmbeddingTimeoutMs;

      var ReqJson := TJSONObject.Create;
      try
        ReqJson.AddPair('input', AText);
        ReqJson.AddPair('model', FConfig.EmbeddingModel);
        ReqJson.AddPair('dimensions', TJSONNumber.Create(FConfig.EmbeddingDimensions));
        ReqBody := ReqJson.ToJSON;
      finally
        ReqJson.Free;
      end;

      ReqStream := TStringStream.Create(ReqBody, TEncoding.UTF8);
      try
        Response := Http.Post(FConfig.EmbeddingUrl, ReqStream, nil,
          [TNetHeader.Create('Content-Type', 'application/json'),
           TNetHeader.Create('Authorization', 'Bearer ' + FConfig.EmbeddingApiKey)]);

        if Response.StatusCode <> 200 then
        begin
          FLogger.Log(mlDebug,
            'Embedding API returned ' + IntToStr(Response.StatusCode) +
            ' (URL: ' + FConfig.EmbeddingUrl + ')');
          Exit;
        end;

        RespStr := Response.ContentAsString(TEncoding.UTF8);
        JsonResp := TJSONObject.ParseJSONValue(RespStr) as TJSONObject;
        if JsonResp = nil then
          Exit;
        try
          DataArr := JsonResp.GetValue<TJSONArray>('data');
          if (DataArr = nil) or (DataArr.Count = 0) then
            Exit;

          DataItem := DataArr.Items[0] as TJSONObject;
          EmbArr := DataItem.GetValue<TJSONArray>('embedding');
          if EmbArr = nil then
            Exit;

          SetLength(Result, EmbArr.Count);
          for I := 0 to EmbArr.Count - 1 do
            Result[I] := EmbArr.Items[I].AsType<Double>;
        finally
          JsonResp.Free;
        end;
      finally
        ReqStream.Free;
      end;
    except
      on E: Exception do
      begin
        // Security: NEVER log E.Message — may contain Bearer token from headers
        FLogger.Log(mlWarning,
          'Embedding API error: ' + E.ClassName +
          ' (URL: ' + FConfig.EmbeddingUrl + ')');
        Result := nil;
      end;
    end;
  finally
    Http.Free;
  end;
end;

class function TMxEmbeddingClient.BuildEmbeddingInput(
  const ATitle, ATags, AContent: string; AMaxChars: Integer): string;
var
  Content: string;
begin
  if AMaxChars > 0 then
    Content := Copy(AContent, 1, AMaxChars)
  else
    Content := AContent;

  Result := 'Title: ' + ATitle;
  if ATags <> '' then
    Result := Result + ' | Tags: ' + ATags;
  if Content <> '' then
    Result := Result + ' | Content: ' + Content;
end;

end.
