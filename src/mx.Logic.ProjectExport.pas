unit mx.Logic.ProjectExport;

// FR#3896 — Project Export: build an encrypted multi-project bundle (.mxbundle)
// from a list of project IDs. Scope = everything needed to continue the project
// on a new mxLore server (docs, revisions, tags, relations, ACL, env-vars,
// developer stubs). Excluded: sessions, agent_messages, tool_call_log,
// ai_batches, events, client_keys (security), developer.password_hash.
//
// Crypto: AES-256-GCM via mx.Crypto.Bundle (CNG/BCrypt, no external dep).
// KDF: PBKDF2-HMAC-SHA256 via mx.Crypto.MxDeriveKey (200k api_key / 600k passphrase).
// Packaging: ZIP container with `manifest.json` (cleartext) + `payload.enc` (encrypted JSON).

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  mx.Types, mx.Data.Pool, mx.Crypto.Bundle;

type
  TMxBundleCryptoMode = (bcmApiKey, bcmPassphrase);

  TMxExportOptions = record
    IncludeRevisions: Boolean;   // default true
    IncludeEnvVars:   Boolean;   // default true
    IncludeAcl:       Boolean;   // default true
    CryptoMode:       TMxBundleCryptoMode;
    Secret:           string;    // raw API key OR passphrase
    Iterations:       Integer;   // 0 = use default (200k api_key / 600k passphrase)
    KeyId:            Integer;   // api_key mode: client_keys.id used (0 = none)
    KeyPrefix:        string;    // api_key mode: client_keys.key_prefix (for hint)
    DeveloperName:    string;    // api_key mode: developer who owns the key
    OriginServer:     string;    // e.g. "mxLore@hostname" (free-text label)
    MxLoreBuild:      Integer;   // from mx.Types.MXAI_BUILD
    ProjectIds:       TArray<Integer>;
  end;

  TMxExportResult = record
    Bundle:            TBytes;   // ZIP container bytes (ready for download)
    ProjectCount:      Integer;
    DocCount:          Integer;
    RevisionCount:     Integer;
    RelationCount:     Integer;
    AclCount:          Integer;
    EnvVarCount:       Integer;
    DeveloperStubCount:Integer;
    DroppedRelations:  TArray<string>;  // cross-bundle rels dropped
    Warnings:          TArray<string>;
  end;

  TMxProjectExporter = class
  private
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;

    function CollectProjects(AContext: IMxDbContext;
      const AIds: TArray<Integer>): TJSONArray;
    function CollectDocuments(AContext: IMxDbContext;
      const AProjectIds: TArray<Integer>; out ADocIds: TArray<Integer>): TJSONArray;
    function CollectRevisions(AContext: IMxDbContext;
      const ADocIds: TArray<Integer>): TJSONArray;
    function CollectTags(AContext: IMxDbContext;
      const ADocIds: TArray<Integer>): TJSONArray;
    function CollectDocRelations(AContext: IMxDbContext;
      const ADocIds: TArray<Integer>;
      var ADroppedRelations: TArray<string>): TJSONArray;
    function CollectProjectRelations(AContext: IMxDbContext;
      const AProjectIds: TArray<Integer>;
      var ADroppedRelations: TArray<string>): TJSONArray;
    function CollectAcl(AContext: IMxDbContext;
      const AProjectIds: TArray<Integer>;
      out ADeveloperIds: TArray<Integer>): TJSONArray;
    function CollectEnvVars(AContext: IMxDbContext;
      const AProjectIds: TArray<Integer>): TJSONArray;
    function CollectDeveloperStubs(AContext: IMxDbContext;
      const ADeveloperIds: TArray<Integer>;
      const ADocCreators: TJSONArray): TJSONArray;

    function PackageBundle(const AManifest: TJSONObject;
      const APayload: TBytes;
      const AIv, ACiphertext, AAuthTag: TBytes): TBytes;
  public
    constructor Create(APool: TMxConnectionPool; ALogger: IMxLogger);
    function BuildBundle(const AOptions: TMxExportOptions): TMxExportResult;
  end;

const
  MX_EXPORT_SCHEMA_VERSION = 1;
  MX_EXPORT_SALT_LEN       = 16;
  MX_EXPORT_DEFAULT_ITERATIONS_API_KEY    = 200000;
  MX_EXPORT_DEFAULT_ITERATIONS_PASSPHRASE = 600000;

implementation

uses
  System.DateUtils, System.NetEncoding, System.Zip,
  Data.DB, FireDAC.Comp.Client,
  mx.Crypto;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function IntArrayToCsv(const A: TArray<Integer>): string;
var
  I: Integer;
begin
  if Length(A) = 0 then
    Exit('-1'); // harmless placeholder — caller must skip empty arrays
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(A[I]);
  end;
end;

function B64Encode(const A: TBytes): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(A);
end;

function JsonNullableString(AField: TField): TJSONValue;
begin
  if AField.IsNull then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(AField.AsWideString);
end;

function JsonNullableInt(AField: TField): TJSONValue;
begin
  if AField.IsNull then
    Result := TJSONNull.Create
  else
    Result := TJSONNumber.Create(AField.AsInteger);
end;

function JsonNullableDateTime(AField: TField): TJSONValue;
begin
  if AField.IsNull then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(DateToISO8601(AField.AsDateTime, False));
end;

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

constructor TMxProjectExporter.Create(APool: TMxConnectionPool;
  ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
end;

// ---------------------------------------------------------------------------
// Collectors
// ---------------------------------------------------------------------------

function TMxProjectExporter.CollectProjects(AContext: IMxDbContext;
  const AIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
begin
  Result := TJSONArray.Create;
  Qry := AContext.CreateQuery(
    'SELECT id, slug, name, path, svn_url, briefing, dna, project_rules, ' +
    'is_active, created_at, updated_at, created_by, created_by_developer_id ' +
    'FROM projects WHERE id IN (' + IntArrayToCsv(AIds) + ')');
  try
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('id',         TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Row.AddPair('slug',       Qry.FieldByName('slug').AsWideString);
      Row.AddPair('name',       Qry.FieldByName('name').AsWideString);
      Row.AddPair('path',       Qry.FieldByName('path').AsWideString);
      Row.AddPair('svn_url',    JsonNullableString(Qry.FieldByName('svn_url')));
      Row.AddPair('briefing',   JsonNullableString(Qry.FieldByName('briefing')));
      Row.AddPair('dna',        JsonNullableString(Qry.FieldByName('dna')));
      Row.AddPair('project_rules', JsonNullableString(Qry.FieldByName('project_rules')));
      Row.AddPair('is_active',  TJSONBool.Create(Qry.FieldByName('is_active').AsBoolean));
      Row.AddPair('created_at', JsonNullableDateTime(Qry.FieldByName('created_at')));
      Row.AddPair('updated_at', JsonNullableDateTime(Qry.FieldByName('updated_at')));
      Row.AddPair('created_by', JsonNullableString(Qry.FieldByName('created_by')));
      Row.AddPair('created_by_developer_id',
        JsonNullableInt(Qry.FieldByName('created_by_developer_id')));
      Result.AddElement(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxProjectExporter.CollectDocuments(AContext: IMxDbContext;
  const AProjectIds: TArray<Integer>;
  out ADocIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
  Ids: TList<Integer>;
begin
  Result := TJSONArray.Create;
  Ids := TList<Integer>.Create;
  try
    Qry := AContext.CreateQuery(
      'SELECT id, project_id, doc_type, slug, title, status, summary_l1, ' +
      'summary_l2, content, metadata, relevance_score, token_estimate, ' +
      'created_at, updated_at, created_by, confidence, lesson_data, ' +
      'violation_count, success_count ' +
      'FROM documents WHERE project_id IN (' +
      IntArrayToCsv(AProjectIds) + ')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id',             TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('project_id',     TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
        Row.AddPair('doc_type',       Qry.FieldByName('doc_type').AsWideString);
        Row.AddPair('slug',           Qry.FieldByName('slug').AsWideString);
        Row.AddPair('title',          Qry.FieldByName('title').AsWideString);
        Row.AddPair('status',         Qry.FieldByName('status').AsWideString);
        Row.AddPair('summary_l1',     JsonNullableString(Qry.FieldByName('summary_l1')));
        Row.AddPair('summary_l2',     JsonNullableString(Qry.FieldByName('summary_l2')));
        Row.AddPair('content',        JsonNullableString(Qry.FieldByName('content')));
        Row.AddPair('metadata',       JsonNullableString(Qry.FieldByName('metadata')));
        Row.AddPair('relevance_score',TJSONNumber.Create(Qry.FieldByName('relevance_score').AsFloat));
        Row.AddPair('token_estimate', TJSONNumber.Create(Qry.FieldByName('token_estimate').AsInteger));
        Row.AddPair('created_at',     JsonNullableDateTime(Qry.FieldByName('created_at')));
        Row.AddPair('updated_at',     JsonNullableDateTime(Qry.FieldByName('updated_at')));
        Row.AddPair('created_by',     JsonNullableString(Qry.FieldByName('created_by')));
        Row.AddPair('confidence',     TJSONNumber.Create(Qry.FieldByName('confidence').AsFloat));
        Row.AddPair('lesson_data',    JsonNullableString(Qry.FieldByName('lesson_data')));
        Row.AddPair('violation_count',TJSONNumber.Create(Qry.FieldByName('violation_count').AsInteger));
        Row.AddPair('success_count',  TJSONNumber.Create(Qry.FieldByName('success_count').AsInteger));
        Result.AddElement(Row);
        Ids.Add(Qry.FieldByName('id').AsInteger);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    ADocIds := Ids.ToArray;
  finally
    Ids.Free;
  end;
end;

function TMxProjectExporter.CollectRevisions(AContext: IMxDbContext;
  const ADocIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
begin
  Result := TJSONArray.Create;
  if Length(ADocIds) = 0 then Exit;
  Qry := AContext.CreateQuery(
    'SELECT id, doc_id, revision, content, summary_l2, changed_by, ' +
    'changed_at, change_reason FROM doc_revisions WHERE doc_id IN (' +
    IntArrayToCsv(ADocIds) + ') ORDER BY doc_id, revision');
  try
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('id',            TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Row.AddPair('doc_id',        TJSONNumber.Create(Qry.FieldByName('doc_id').AsInteger));
      Row.AddPair('revision',      TJSONNumber.Create(Qry.FieldByName('revision').AsInteger));
      Row.AddPair('content',       JsonNullableString(Qry.FieldByName('content')));
      Row.AddPair('summary_l2',    JsonNullableString(Qry.FieldByName('summary_l2')));
      Row.AddPair('changed_by',    JsonNullableString(Qry.FieldByName('changed_by')));
      Row.AddPair('changed_at',    JsonNullableDateTime(Qry.FieldByName('changed_at')));
      Row.AddPair('change_reason', JsonNullableString(Qry.FieldByName('change_reason')));
      Result.AddElement(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxProjectExporter.CollectTags(AContext: IMxDbContext;
  const ADocIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
begin
  Result := TJSONArray.Create;
  if Length(ADocIds) = 0 then Exit;
  Qry := AContext.CreateQuery(
    'SELECT doc_id, tag FROM doc_tags WHERE doc_id IN (' +
    IntArrayToCsv(ADocIds) + ')');
  try
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('doc_id', TJSONNumber.Create(Qry.FieldByName('doc_id').AsInteger));
      Row.AddPair('tag',    Qry.FieldByName('tag').AsWideString);
      Result.AddElement(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxProjectExporter.CollectDocRelations(AContext: IMxDbContext;
  const ADocIds: TArray<Integer>;
  var ADroppedRelations: TArray<string>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
  InSet: TDictionary<Integer, Boolean>;
  SrcId, TgtId: Integer;
  Dropped: TList<string>;
begin
  Result := TJSONArray.Create;
  if Length(ADocIds) = 0 then Exit;

  // Build a fast membership-test set for doc_ids.
  InSet := TDictionary<Integer, Boolean>.Create;
  Dropped := TList<string>.Create;
  try
    for SrcId in ADocIds do
      InSet.AddOrSetValue(SrcId, True);

    // Query relations where the SOURCE is in our doc-set. Filter: target must
    // also be in-set to include the relation; otherwise it is a cross-bundle
    // relation that must be dropped per OQ-5 drop+warn.
    Qry := AContext.CreateQuery(
      'SELECT id, source_doc_id, target_doc_id, relation_type, created_at ' +
      'FROM doc_relations WHERE source_doc_id IN (' +
      IntArrayToCsv(ADocIds) + ')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        SrcId := Qry.FieldByName('source_doc_id').AsInteger;
        TgtId := Qry.FieldByName('target_doc_id').AsInteger;
        if not InSet.ContainsKey(TgtId) then
        begin
          Dropped.Add(Format('doc_relation #%d: source=%d → target=%d (%s) — target out of bundle',
            [Qry.FieldByName('id').AsInteger, SrcId, TgtId,
             Qry.FieldByName('relation_type').AsWideString]));
        end
        else
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id',             TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('source_doc_id',  TJSONNumber.Create(SrcId));
          Row.AddPair('target_doc_id',  TJSONNumber.Create(TgtId));
          Row.AddPair('relation_type',  Qry.FieldByName('relation_type').AsWideString);
          Row.AddPair('created_at',     JsonNullableDateTime(Qry.FieldByName('created_at')));
          Result.AddElement(Row);
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    ADroppedRelations := ADroppedRelations + Dropped.ToArray;
  finally
    Dropped.Free;
    InSet.Free;
  end;
end;

function TMxProjectExporter.CollectProjectRelations(AContext: IMxDbContext;
  const AProjectIds: TArray<Integer>;
  var ADroppedRelations: TArray<string>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
  InSet: TDictionary<Integer, Boolean>;
  SrcId, TgtId, Pid: Integer;
  Dropped: TList<string>;
begin
  Result := TJSONArray.Create;
  if Length(AProjectIds) = 0 then Exit;

  InSet := TDictionary<Integer, Boolean>.Create;
  Dropped := TList<string>.Create;
  try
    for Pid in AProjectIds do
      InSet.AddOrSetValue(Pid, True);

    Qry := AContext.CreateQuery(
      'SELECT id, source_project_id, target_project_id, relation_type, created_at ' +
      'FROM project_relations WHERE source_project_id IN (' +
      IntArrayToCsv(AProjectIds) + ') OR target_project_id IN (' +
      IntArrayToCsv(AProjectIds) + ')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        SrcId := Qry.FieldByName('source_project_id').AsInteger;
        TgtId := Qry.FieldByName('target_project_id').AsInteger;
        if (not InSet.ContainsKey(SrcId)) or (not InSet.ContainsKey(TgtId)) then
        begin
          Dropped.Add(Format('project_relation #%d: %d → %d (%s) — partner out of bundle',
            [Qry.FieldByName('id').AsInteger, SrcId, TgtId,
             Qry.FieldByName('relation_type').AsWideString]));
        end
        else
        begin
          Row := TJSONObject.Create;
          Row.AddPair('id',                TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Row.AddPair('source_project_id', TJSONNumber.Create(SrcId));
          Row.AddPair('target_project_id', TJSONNumber.Create(TgtId));
          Row.AddPair('relation_type',     Qry.FieldByName('relation_type').AsWideString);
          Row.AddPair('created_at',        JsonNullableDateTime(Qry.FieldByName('created_at')));
          Result.AddElement(Row);
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    ADroppedRelations := ADroppedRelations + Dropped.ToArray;
  finally
    Dropped.Free;
    InSet.Free;
  end;
end;

function TMxProjectExporter.CollectAcl(AContext: IMxDbContext;
  const AProjectIds: TArray<Integer>;
  out ADeveloperIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
  DevIds: TDictionary<Integer, Boolean>;
  Dev: Integer;
begin
  Result := TJSONArray.Create;
  DevIds := TDictionary<Integer, Boolean>.Create;
  try
    Qry := AContext.CreateQuery(
      'SELECT id, developer_id, project_id, access_level, granted_at ' +
      'FROM developer_project_access WHERE project_id IN (' +
      IntArrayToCsv(AProjectIds) + ')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Dev := Qry.FieldByName('developer_id').AsInteger;
        DevIds.AddOrSetValue(Dev, True);
        Row := TJSONObject.Create;
        Row.AddPair('id',           TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('developer_id', TJSONNumber.Create(Dev));
        Row.AddPair('project_id',   TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
        Row.AddPair('access_level', Qry.FieldByName('access_level').AsWideString);
        Row.AddPair('granted_at',   JsonNullableDateTime(Qry.FieldByName('granted_at')));
        Result.AddElement(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    ADeveloperIds := DevIds.Keys.ToArray;
  finally
    DevIds.Free;
  end;
end;

function TMxProjectExporter.CollectEnvVars(AContext: IMxDbContext;
  const AProjectIds: TArray<Integer>): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
begin
  Result := TJSONArray.Create;
  if Length(AProjectIds) = 0 then Exit;
  // Note: env_value is stored plaintext in developer_environments per current
  // schema. The bundle re-encrypts it transitively via the outer AES-GCM
  // payload.enc — no per-row crypto here. On import the target server sees
  // plaintext inside the decrypted payload, same as local storage semantics.
  Qry := AContext.CreateQuery(
    'SELECT id, client_key_id, project_id, env_key, env_value, created_at, ' +
    'updated_at FROM developer_environments WHERE project_id IN (' +
    IntArrayToCsv(AProjectIds) + ')');
  try
    Qry.Open;
    while not Qry.Eof do
    begin
      Row := TJSONObject.Create;
      Row.AddPair('id',            TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
      Row.AddPair('client_key_id', TJSONNumber.Create(Qry.FieldByName('client_key_id').AsInteger));
      Row.AddPair('project_id',    TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
      Row.AddPair('env_key',       Qry.FieldByName('env_key').AsWideString);
      Row.AddPair('env_value',     Qry.FieldByName('env_value').AsWideString);
      Row.AddPair('created_at',    JsonNullableDateTime(Qry.FieldByName('created_at')));
      Row.AddPair('updated_at',    JsonNullableDateTime(Qry.FieldByName('updated_at')));
      Result.AddElement(Row);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
end;

function TMxProjectExporter.CollectDeveloperStubs(AContext: IMxDbContext;
  const ADeveloperIds: TArray<Integer>;
  const ADocCreators: TJSONArray): TJSONArray;
var
  Qry: TFDQuery;
  Row: TJSONObject;
  AllIds: TDictionary<Integer, Boolean>;
  I: Integer;
  V: TJSONValue;
  N: Integer;
begin
  // Merge developer_ids from ACL + projects.created_by_developer_id. Stub-row:
  // (id, name, email) only. Never export password_hash/client_keys/anything
  // authn-related.
  Result := TJSONArray.Create;
  AllIds := TDictionary<Integer, Boolean>.Create;
  try
    for I := 0 to High(ADeveloperIds) do
      AllIds.AddOrSetValue(ADeveloperIds[I], True);

    if Assigned(ADocCreators) then
    begin
      for I := 0 to ADocCreators.Count - 1 do
      begin
        V := ADocCreators.Items[I];
        if V is TJSONNumber then
        begin
          N := (V as TJSONNumber).AsInt;
          if N > 0 then
            AllIds.AddOrSetValue(N, True);
        end;
      end;
    end;

    if AllIds.Count = 0 then Exit;

    Qry := AContext.CreateQuery(
      'SELECT id, name, email, role, is_active FROM developers WHERE id IN (' +
      IntArrayToCsv(AllIds.Keys.ToArray) + ')');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id',        TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('name',      Qry.FieldByName('name').AsWideString);
        Row.AddPair('email',     JsonNullableString(Qry.FieldByName('email')));
        Row.AddPair('role',      JsonNullableString(Qry.FieldByName('role')));
        Row.AddPair('is_active', TJSONBool.Create(Qry.FieldByName('is_active').AsBoolean));
        Result.AddElement(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  finally
    AllIds.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Packaging
// ---------------------------------------------------------------------------

function TMxProjectExporter.PackageBundle(const AManifest: TJSONObject;
  const APayload: TBytes;
  const AIv, ACiphertext, AAuthTag: TBytes): TBytes;
var
  Zip: TZipFile;
  MS: TMemoryStream;
  ManifestBytes: TBytes;
  ManifestJson: string;
  PayloadStream, ManifestStream: TBytesStream;
begin
  ManifestJson := AManifest.ToJSON;
  ManifestBytes := TEncoding.UTF8.GetBytes(ManifestJson);

  MS := TMemoryStream.Create;
  Zip := TZipFile.Create;
  try
    Zip.Open(MS, zmWrite);

    ManifestStream := TBytesStream.Create(ManifestBytes);
    try
      Zip.Add(ManifestStream, 'manifest.json', zcDeflate);
    finally
      ManifestStream.Free;
    end;

    PayloadStream := TBytesStream.Create(ACiphertext);
    try
      Zip.Add(PayloadStream, 'payload.enc', zcStored);
    finally
      PayloadStream.Free;
    end;

    Zip.Close;

    SetLength(Result, MS.Size);
    if MS.Size > 0 then
      Move(MS.Memory^, Result[0], MS.Size);
  finally
    Zip.Free;
    MS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main entry
// ---------------------------------------------------------------------------

function TMxProjectExporter.BuildBundle(const AOptions: TMxExportOptions): TMxExportResult;
var
  Ctx: IMxDbContext;
  Payload, Manifest, CryptoBlock, KeyHint: TJSONObject;
  JsonProjects, JsonDocs, JsonRevs, JsonTags, JsonDocRels,
    JsonProjRels, JsonAcl, JsonEnv, JsonDevs: TJSONArray;
  DocIds, DeveloperIds: TArray<Integer>;
  DroppedRels: TArray<string>;
  DocCreatorIds: TJSONArray;
  PayloadJson: string;
  PayloadBytes, Salt, DerivedKey, Iv, Ciphertext, AuthTag, AssocData: TBytes;
  Iterations: Integer;
  ProjectsList, WarnArr: TJSONArray;
  Counts: TJSONObject;
  I: Integer;
  TmpObj: TJSONObject;
  ModeStr: string;
begin
  if Length(AOptions.ProjectIds) = 0 then
    raise EMxCryptoError.Create('BuildBundle: no project ids');
  if AOptions.Secret = '' then
    raise EMxCryptoError.Create('BuildBundle: secret (key/passphrase) is empty');

  SetLength(DroppedRels, 0);

  Ctx := FPool.AcquireContext;

  // Exception-safety: Payload + Manifest allocated up-front; every sub-tree
  // is AddPair'd as soon as it's built so any subsequent raise cascades
  // through .Free on the owning parent. Raw locals (DocCreatorIds,
  // ProjectsList, WarnArr, Counts, CryptoBlock, KeyHint) are either freed
  // explicitly or AddPair'd — never left dangling on the exception path.
  Payload := TJSONObject.Create;
  Manifest := TJSONObject.Create;
  try
    // ---- 1. Collect all rows ----
    JsonProjects := CollectProjects(Ctx, AOptions.ProjectIds);
    Payload.AddPair('projects', JsonProjects);

    JsonDocs := CollectDocuments(Ctx, AOptions.ProjectIds, DocIds);
    Payload.AddPair('documents', JsonDocs);

    if AOptions.IncludeRevisions then
      JsonRevs := CollectRevisions(Ctx, DocIds)
    else
      JsonRevs := TJSONArray.Create;
    Payload.AddPair('doc_revisions', JsonRevs);

    JsonTags := CollectTags(Ctx, DocIds);
    Payload.AddPair('doc_tags', JsonTags);

    JsonDocRels := CollectDocRelations(Ctx, DocIds, DroppedRels);
    Payload.AddPair('doc_relations', JsonDocRels);

    JsonProjRels := CollectProjectRelations(Ctx, AOptions.ProjectIds, DroppedRels);
    Payload.AddPair('project_relations', JsonProjRels);

    if AOptions.IncludeAcl then
      JsonAcl := CollectAcl(Ctx, AOptions.ProjectIds, DeveloperIds)
    else
    begin
      JsonAcl := TJSONArray.Create;
      SetLength(DeveloperIds, 0);
    end;
    Payload.AddPair('developer_project_access', JsonAcl);

    if AOptions.IncludeEnvVars then
      JsonEnv := CollectEnvVars(Ctx, AOptions.ProjectIds)
    else
      JsonEnv := TJSONArray.Create;
    Payload.AddPair('developer_environments', JsonEnv);

    DocCreatorIds := TJSONArray.Create;
    try
      for I := 0 to JsonProjects.Count - 1 do
      begin
        TmpObj := JsonProjects.Items[I] as TJSONObject;
        if TmpObj.GetValue('created_by_developer_id') is TJSONNumber then
          DocCreatorIds.AddElement(TJSONNumber.Create(
            (TmpObj.GetValue('created_by_developer_id') as TJSONNumber).AsInt));
      end;
      JsonDevs := CollectDeveloperStubs(Ctx, DeveloperIds, DocCreatorIds);
    finally
      DocCreatorIds.Free;
    end;
    Payload.AddPair('developers', JsonDevs);

    Payload.AddPair('schema_version', TJSONNumber.Create(MX_EXPORT_SCHEMA_VERSION));

    // ---- 2. Serialize + encrypt ----

    PayloadJson := Payload.ToJSON;
    PayloadBytes := TEncoding.UTF8.GetBytes(PayloadJson);

    Salt := MxBundleRandomBytes(MX_EXPORT_SALT_LEN);

    if AOptions.Iterations > 0 then
      Iterations := AOptions.Iterations
    else if AOptions.CryptoMode = bcmApiKey then
      Iterations := MX_EXPORT_DEFAULT_ITERATIONS_API_KEY
    else
      Iterations := MX_EXPORT_DEFAULT_ITERATIONS_PASSPHRASE;

    DerivedKey := MxDeriveKey(AOptions.Secret, Salt, Iterations, MX_BUNDLE_KEY_LEN);

    if AOptions.CryptoMode = bcmApiKey then
      ModeStr := 'api_key'
    else
      ModeStr := 'passphrase';

    // AAD binds the ciphertext to ALL security-critical manifest params
    // (mode + iterations + schema-version + base64(salt) + base64(iv)). Any
    // post-encrypt edit of those manifest fields invalidates the GCM tag.
    // key_hint + projects-preview + warnings are cleartext metadata, not
    // security-critical — bound via schema-version only.
    // Pre-generate IV so AAD can bind it before the single AES-GCM pass.
    Iv := MxBundleRandomBytes(MX_BUNDLE_IV_LEN);

    AssocData := TEncoding.UTF8.GetBytes(
      Format('mxLore-bundle;v=%d;mode=%s;iter=%d;salt=%s;iv=%s',
        [MX_EXPORT_SCHEMA_VERSION, ModeStr, Iterations,
         B64Encode(Salt), B64Encode(Iv)]));

    MxBundleEncrypt(PayloadBytes, DerivedKey, Iv, Ciphertext, AuthTag, AssocData);

    // ---- 3. Build manifest (cleartext) ----

    Manifest.AddPair('schema_version', TJSONNumber.Create(MX_EXPORT_SCHEMA_VERSION));
    Manifest.AddPair('mxlore_build',   TJSONNumber.Create(AOptions.MxLoreBuild));
    Manifest.AddPair('export_date',    DateToISO8601(Now, False));
    Manifest.AddPair('origin_server',  AOptions.OriginServer);

    CryptoBlock := TJSONObject.Create;
    Manifest.AddPair('encryption', CryptoBlock);
    CryptoBlock.AddPair('mode',       ModeStr);
    CryptoBlock.AddPair('algorithm',  'AES-256-GCM');
    CryptoBlock.AddPair('kdf',        'PBKDF2-HMAC-SHA256');
    CryptoBlock.AddPair('iterations', TJSONNumber.Create(Iterations));
    CryptoBlock.AddPair('salt',       B64Encode(Salt));
    CryptoBlock.AddPair('iv',         B64Encode(Iv));
    CryptoBlock.AddPair('auth_tag',   B64Encode(AuthTag));
    CryptoBlock.AddPair('aad',        TEncoding.UTF8.GetString(AssocData));

    if AOptions.CryptoMode = bcmApiKey then
    begin
      KeyHint := TJSONObject.Create;
      Manifest.AddPair('key_hint', KeyHint);
      KeyHint.AddPair('key_id',         TJSONNumber.Create(AOptions.KeyId));
      KeyHint.AddPair('key_prefix',     AOptions.KeyPrefix);
      KeyHint.AddPair('developer_name', AOptions.DeveloperName);
    end;

    ProjectsList := TJSONArray.Create;
    Manifest.AddPair('projects', ProjectsList);
    for I := 0 to JsonProjects.Count - 1 do
    begin
      TmpObj := TJSONObject.Create;
      ProjectsList.AddElement(TmpObj);
      TmpObj.AddPair('slug', (JsonProjects.Items[I] as TJSONObject).GetValue('slug').Value);
      TmpObj.AddPair('name', (JsonProjects.Items[I] as TJSONObject).GetValue('name').Value);
    end;

    WarnArr := TJSONArray.Create;
    Manifest.AddPair('warnings', WarnArr);
    for I := 0 to High(DroppedRels) do
      WarnArr.AddElement(TJSONString.Create(DroppedRels[I]));

    Counts := TJSONObject.Create;
    Manifest.AddPair('counts', Counts);
    Counts.AddPair('documents',                TJSONNumber.Create(JsonDocs.Count));
    Counts.AddPair('doc_revisions',            TJSONNumber.Create(JsonRevs.Count));
    Counts.AddPair('doc_tags',                 TJSONNumber.Create(JsonTags.Count));
    Counts.AddPair('doc_relations',            TJSONNumber.Create(JsonDocRels.Count));
    Counts.AddPair('project_relations',        TJSONNumber.Create(JsonProjRels.Count));
    Counts.AddPair('developer_project_access', TJSONNumber.Create(JsonAcl.Count));
    Counts.AddPair('developer_environments',   TJSONNumber.Create(JsonEnv.Count));
    Counts.AddPair('developers',               TJSONNumber.Create(JsonDevs.Count));

    // ---- 4. Package into ZIP ----

    Result.Bundle := PackageBundle(Manifest, PayloadBytes, Iv, Ciphertext, AuthTag);
    Result.ProjectCount       := JsonProjects.Count;
    Result.DocCount           := JsonDocs.Count;
    Result.RevisionCount      := JsonRevs.Count;
    Result.RelationCount      := JsonDocRels.Count + JsonProjRels.Count;
    Result.AclCount           := JsonAcl.Count;
    Result.EnvVarCount        := JsonEnv.Count;
    Result.DeveloperStubCount := JsonDevs.Count;
    Result.DroppedRelations   := DroppedRels;
    SetLength(Result.Warnings, 0);
  finally
    Payload.Free;
    Manifest.Free;
  end;

  if Assigned(FLogger) then
    FLogger.Log(mlInfo, Format(
      '[ProjectExport] Built bundle: %d projects, %d docs, %d revs, %d rels, %d ACL, %d env. Dropped rels: %d.',
      [Result.ProjectCount, Result.DocCount, Result.RevisionCount,
       Result.RelationCount, Result.AclCount, Result.EnvVarCount,
       Length(Result.DroppedRelations)]));
end;

end.
