unit mx.Admin.Api.Intelligence;

// FR#3294 (doc#3294) / SPEC#3583 — Admin-UI Intelligence-Page Status.
// Single endpoint GET /api/intelligence/status returns whether Semantic
// Search is active + reason enum when inactive, so the Intelligence page
// can render a top-banner pointing the admin at the missing config.
//
// Detection-Order (short-circuit):
//   (a) MariaDB VECTOR support  -> no_mariadb_vector
//   (b) INI EmbeddingApiKey + EmbeddingUrl + EmbeddingModel gesetzt
//                                 -> no_api_key
//   (c) embedded_docs > 0        -> no_embeddings   (Info-Level banner)
//   (d) sonst                     -> ok
//
// VECTOR-detection: we check for the `documents.embedding` column in
// information_schema. sql/043 auto-migrate only adds it when MariaDB
// supports VECTOR (>=11.6). Column-existence is therefore the tightest
// proxy for "this server can do semantic search".

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Config;

procedure HandleGetIntelligenceStatus(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server;

procedure HandleGetIntelligenceStatus(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json: TJSONObject;
  MariaDBVector: Boolean;
  EmbeddedDocs, TotalDocs: Integer;
  SemanticActive: Boolean;
  Reason: string;
  ConfigComplete: Boolean;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    // (a) VECTOR support proxy: documents.embedding column existence.
    MariaDBVector := False;
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS c FROM information_schema.columns ' +
      'WHERE table_schema = DATABASE() ' +
      '  AND table_name = ''documents'' ' +
      '  AND column_name = ''embedding''');
    try
      Qry.Open;
      MariaDBVector := Qry.FieldByName('c').AsInteger > 0;
    finally
      Qry.Free;
    end;

    // (b) INI config completeness.
    ConfigComplete :=
      AConfig.EmbeddingEnabled and
      (Trim(AConfig.EmbeddingApiKey) <> '') and
      (Trim(AConfig.EmbeddingUrl)    <> '') and
      (Trim(AConfig.EmbeddingModel)  <> '');

    // (c) Embedded-docs + total-docs count (same scope as embedding-stats).
    EmbeddedDocs := 0;
    TotalDocs    := 0;
    if MariaDBVector then
    begin
      Qry := Ctx.CreateQuery(
        'SELECT COUNT(*) AS total, ' +
        '  SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END) AS embedded ' +
        'FROM documents WHERE status <> ''deleted''');
      try
        Qry.Open;
        TotalDocs    := Qry.FieldByName('total').AsInteger;
        EmbeddedDocs := Qry.FieldByName('embedded').AsInteger;
      finally
        Qry.Free;
      end;
    end
    else
    begin
      // Still give total-docs so the banner can show absolute numbers.
      Qry := Ctx.CreateQuery(
        'SELECT COUNT(*) AS total FROM documents WHERE status <> ''deleted''');
      try
        Qry.Open;
        TotalDocs := Qry.FieldByName('total').AsInteger;
      finally
        Qry.Free;
      end;
    end;

    // Short-circuit decision tree.
    if not MariaDBVector then
    begin
      Reason := 'no_mariadb_vector';
      SemanticActive := False;
    end
    else if not ConfigComplete then
    begin
      Reason := 'no_api_key';
      SemanticActive := False;
    end
    else if EmbeddedDocs = 0 then
    begin
      Reason := 'no_embeddings';
      SemanticActive := False;   // Info-Level banner, still inactive.
    end
    else
    begin
      Reason := 'ok';
      SemanticActive := True;
    end;

    Json.AddPair('semantic_active', TJSONBool.Create(SemanticActive));
    Json.AddPair('reason',          Reason);
    // Field is the provider endpoint URL, not a provider-name (mxDesignChecker
    // WARN#2). INI has `EmbeddingUrl` / `EmbeddingModel`, no EmbeddingProvider
    // property — caller should display this as the provider endpoint.
    Json.AddPair('provider_url',    AConfig.EmbeddingUrl);
    Json.AddPair('model',           AConfig.EmbeddingModel);
    Json.AddPair('embedded_docs',   TJSONNumber.Create(EmbeddedDocs));
    Json.AddPair('total_docs',      TJSONNumber.Create(TotalDocs));
    Json.AddPair('mariadb_vector',  TJSONBool.Create(MariaDBVector));

    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
