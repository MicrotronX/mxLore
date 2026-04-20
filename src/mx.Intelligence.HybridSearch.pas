unit mx.Intelligence.HybridSearch;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math,
  Data.DB, FireDAC.Comp.Client,
  mx.Types, mx.Config, mx.Intelligence.Embedding;

type
  TMxHybridResult = record
    DocId: Integer;
    KeywordScore: Double;
    VectorScore: Double;
    FinalScore: Double;
  end;

  TMxHybridSearch = class
  private
    FEmbeddingClient: TMxEmbeddingClient;
    FConfig: TMxConfig;
    FLogger: IMxLogger;
  public
    constructor Create(AEmbeddingClient: TMxEmbeddingClient;
      AConfig: TMxConfig; ALogger: IMxLogger);
    destructor Destroy; override;
    property EmbeddingClient: TMxEmbeddingClient read FEmbeddingClient;

    /// <summary>
    /// Takes keyword results (doc_id → score), runs vector search,
    /// merges via Union + Re-Ranking. Returns merged doc_ids sorted by final_score.
    /// Falls back to keyword-only on any error.
    /// </summary>
    function MergeResults(AConn: TFDCustomConnection;
      const AKeywordDocIds: TArray<Integer>;
      const AKeywordScores: TArray<Double>;
      const AQuery: string;
      ALimit: Integer;
      const AProjectFilter: string = ''): TArray<TMxHybridResult>;
  end;

var
  /// Set by TMxServerBoot. Nil if EmbeddingEnabled=0.
  GHybridSearch: TMxHybridSearch;

implementation

{ TMxHybridSearch }

constructor TMxHybridSearch.Create(AEmbeddingClient: TMxEmbeddingClient;
  AConfig: TMxConfig; ALogger: IMxLogger);
begin
  inherited Create;
  FEmbeddingClient := AEmbeddingClient;
  FConfig := AConfig;
  FLogger := ALogger;
end;

destructor TMxHybridSearch.Destroy;
begin
  FEmbeddingClient.Free;
  inherited;
end;

function TMxHybridSearch.MergeResults(AConn: TFDCustomConnection;
  const AKeywordDocIds: TArray<Integer>;
  const AKeywordScores: TArray<Double>;
  const AQuery: string;
  ALimit: Integer;
  const AProjectFilter: string): TArray<TMxHybridResult>;
var
  QueryEmbedding: TArray<Single>;
  Qry: TFDQuery;
  I, DocId, Idx: Integer;
  VecScore, MaxKeyword: Double;
  Merged: TArray<TMxHybridResult>;
  MergedCount: Integer;
  Found: Boolean;
  TempResult: TMxHybridResult;
begin
  // Start with keyword results as baseline
  SetLength(Merged, Length(AKeywordDocIds) + ALimit);
  MergedCount := 0;

  // Normalize keyword scores to 0..1
  MaxKeyword := 0;
  for I := 0 to High(AKeywordScores) do
    if AKeywordScores[I] > MaxKeyword then
      MaxKeyword := AKeywordScores[I];
  if MaxKeyword = 0 then
    MaxKeyword := 1;

  // Add keyword results
  for I := 0 to High(AKeywordDocIds) do
  begin
    Merged[MergedCount].DocId := AKeywordDocIds[I];
    Merged[MergedCount].KeywordScore := AKeywordScores[I] / MaxKeyword;
    Merged[MergedCount].VectorScore := 0;
    Merged[MergedCount].FinalScore := 0;
    Inc(MergedCount);
  end;

  // Try vector search
  if not Assigned(FEmbeddingClient) then
  begin
    // No embedding client — return keyword-only
    SetLength(Merged, MergedCount);
    for I := 0 to MergedCount - 1 do
      Merged[I].FinalScore := Merged[I].KeywordScore;
    Result := Merged;
    Exit;
  end;

  QueryEmbedding := FEmbeddingClient.GetEmbedding(AQuery);
  if Length(QueryEmbedding) = 0 then
  begin
    // Embedding failed — return keyword-only
    SetLength(Merged, MergedCount);
    for I := 0 to MergedCount - 1 do
      Merged[I].FinalScore := Merged[I].KeywordScore;
    Result := Merged;
    Exit;
  end;

  // Vector search via MariaDB VEC_DISTANCE_COSINE
  // Build vector literal: VEC_FromText('[1.0,2.0,...]')
  // Build vector literal with dot decimal separator (not locale-dependent)
  var FmtSettings: TFormatSettings;
  FmtSettings := TFormatSettings.Create;
  FmtSettings.DecimalSeparator := '.';
  var VecLiteral: string;
  VecLiteral := '[';
  for I := 0 to High(QueryEmbedding) do
  begin
    if I > 0 then VecLiteral := VecLiteral + ',';
    VecLiteral := VecLiteral + FloatToStr(QueryEmbedding[I], FmtSettings);
  end;
  VecLiteral := VecLiteral + ']';

  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := AConn;
    Qry.SQL.Text :=
      'SELECT id, VEC_DISTANCE_COSINE(embedding, VEC_FromText(' +
      QuotedStr(VecLiteral) + ')) AS distance ' +
      'FROM documents ' +
      'WHERE embedding IS NOT NULL' +
      ' AND doc_type IN (''' +
        StringReplace(FConfig.EmbeddingDocTypes, ',', ''',''', [rfReplaceAll]) + ''')';
    if AProjectFilter <> '' then
      Qry.SQL.Text := Qry.SQL.Text +
        ' AND project_id = (SELECT id FROM projects WHERE slug = :pf)';
    Qry.SQL.Text := Qry.SQL.Text +
      ' ORDER BY distance ASC LIMIT ' + IntToStr(ALimit * 2);
    if AProjectFilter <> '' then
      Qry.ParamByName('pf').AsWideString :=AProjectFilter;

    try
      Qry.Open;
    except
      on E: Exception do
      begin
        // VEC_DISTANCE_COSINE not available or other SQL error — keyword-only
        FLogger.Log(mlWarning,
          'Hybrid search vector query failed: ' + E.ClassName + ': ' + E.Message);
        SetLength(Merged, MergedCount);
        for I := 0 to MergedCount - 1 do
          Merged[I].FinalScore := Merged[I].KeywordScore;
        Result := Merged;
        Exit;
      end;
    end;

    // Merge vector results with keyword results
    while not Qry.Eof do
    begin
      DocId := Qry.FieldByName('id').AsInteger;
      VecScore := Max(0, 1.0 - Qry.FieldByName('distance').AsFloat); // distance → similarity, clamped [0,1]

      // Check if already in merged list (from keyword results)
      Found := False;
      for I := 0 to MergedCount - 1 do
      begin
        if Merged[I].DocId = DocId then
        begin
          Merged[I].VectorScore := VecScore;
          Found := True;
          Break;
        end;
      end;

      // New doc (vector-only, no keyword match)
      if not Found then
      begin
        if MergedCount >= Length(Merged) then
          SetLength(Merged, MergedCount + ALimit);
        Merged[MergedCount].DocId := DocId;
        Merged[MergedCount].KeywordScore := 0;
        Merged[MergedCount].VectorScore := VecScore;
        Inc(MergedCount);
      end;

      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  // Calculate final scores
  SetLength(Merged, MergedCount);
  for I := 0 to MergedCount - 1 do
    Merged[I].FinalScore :=
      (Merged[I].KeywordScore * FConfig.KeywordWeight) +
      (Merged[I].VectorScore * FConfig.SemanticWeight);

  // Sort by FinalScore descending (simple bubble sort, N is small)
  for I := 0 to MergedCount - 2 do
    for Idx := I + 1 to MergedCount - 1 do
      if Merged[Idx].FinalScore > Merged[I].FinalScore then
      begin
        TempResult := Merged[I];
        Merged[I] := Merged[Idx];
        Merged[Idx] := TempResult;
      end;

  // Apply limit
  if MergedCount > ALimit then
    SetLength(Merged, ALimit);

  Result := Merged;
end;

end.
