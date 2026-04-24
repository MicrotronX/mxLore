unit mx.Logic.ProjectImport;

// FR#3896 — Project Import: parse an .mxbundle ZIP container, decrypt the
// payload via mx.Crypto.Bundle, and insert projects + docs + revisions + tags
// + relations + ACL + env-vars into the local DB. Handles slug-collisions
// (skip/rename-new-slug/overwrite) and developer-ID remapping (source → local).
//
// Transactional: single FireDAC transaction covers the entire Execute; any
// error rolls back the whole import. On collision=overwrite, existing docs
// are updated in place. On collision=rename-new-slug, slug is suffixed.
// On collision=skip, the project and all its children are omitted.
//
// Two-phase protocol (aligned with REST endpoint shape):
//   Phase A — ReadManifest + Decrypt + ResolveConflicts + ResolveDevMapping
//             return inspection data to UI for user confirmation
//   Phase B — Execute applies the import with confirmed conflictPlan + devMap

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  mx.Types, mx.Data.Pool, mx.Crypto.Bundle,
  mx.Logic.ProjectExport;  // for TMxBundleCryptoMode (single-source-of-truth)

type
  TMxConflictResolution = (crSkip, crRenameNewSlug, crOverwrite);

  TMxProjectConflict = record
    SourceSlug:   string;
    SourceName:   string;
    SourceId:     Integer;     // ID inside the bundle, NOT local
    LocalId:      Integer;     // existing local project ID (0 if none)
    LocalName:    string;      // existing local project name
    Resolution:   TMxConflictResolution;
    NewSlug:      string;      // for crRenameNewSlug — suggested or user-picked
  end;

  TMxDeveloperInfo = record
    SourceId:   Integer;       // dev id in the bundle
    Name:       string;
    Email:      string;
  end;

  TMxManifestInfo = record
    SchemaVersion: Integer;
    MxLoreBuild:   Integer;
    ExportDate:    string;
    OriginServer:  string;
    CryptoMode:    TMxBundleCryptoMode;
    Algorithm:     string;
    Kdf:           string;
    Iterations:    Integer;
    Salt:          TBytes;
    Iv:            TBytes;
    AuthTag:       TBytes;
    Aad:           TBytes;
    KeyId:         Integer;
    KeyPrefix:     string;
    DeveloperName: string;
    Warnings:      TArray<string>;
  end;

  TMxImportSession = record
    ManifestJson:  TJSONObject; // retained; caller frees after Execute
    DecryptedPayload: TJSONObject; // retained; caller frees after Execute
    Conflicts:     TArray<TMxProjectConflict>;
    Developers:    TArray<TMxDeveloperInfo>;
    DevMap:        TDictionary<Integer, Integer>; // source_dev_id → local_dev_id; -1 = drop
    Manifest:      TMxManifestInfo;
  end;

  TMxImportSummary = record
    ProjectsCreated:   Integer;
    ProjectsUpdated:   Integer;
    ProjectsSkipped:   Integer;
    ProjectsRenamed:   Integer;
    DocsInserted:      Integer;
    DocsUpdated:       Integer;
    RevisionsInserted: Integer;
    TagsInserted:      Integer;
    RelationsInserted: Integer;
    AclInserted:       Integer;
    AclSkipped:        Integer;   // dev-mapping drop
    EnvVarsInserted:   Integer;
    Warnings:          TArray<string>;
  end;

  TMxProjectImporter = class
  private
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;

    function ReadBundleFiles(const ABundle: TBytes;
      out AManifestBytes, APayloadCiphertext: TBytes): Boolean;
    function ParseManifest(const AManifestBytes: TBytes): TJSONObject;
    function ManifestToInfo(AManifest: TJSONObject): TMxManifestInfo;

    function BuildConflictList(AContext: IMxDbContext;
      APayload: TJSONObject): TArray<TMxProjectConflict>;
    function ExtractDeveloperList(
      APayload: TJSONObject): TArray<TMxDeveloperInfo>;
    function AutoMapDevelopersByEmail(AContext: IMxDbContext;
      const ASourceDevs: TArray<TMxDeveloperInfo>): TDictionary<Integer, Integer>;

    function RemapDeveloperId(const ASession: TMxImportSession;
      ASourceId: Integer; AFallbackId: Integer): Integer;

    function InsertProject(AContext: IMxDbContext; ARow: TJSONObject;
      const ANewSlug: string; ACreatorFallback: Integer;
      const ASession: TMxImportSession): Integer;
    procedure UpdateProject(AContext: IMxDbContext; ALocalId: Integer;
      ARow: TJSONObject; ACreatorFallback: Integer;
      const ASession: TMxImportSession);

    function InsertDocument(AContext: IMxDbContext; ALocalProjectId: Integer;
      ARow: TJSONObject): Integer;
    procedure UpdateDocumentIfExists(AContext: IMxDbContext;
      ALocalProjectId: Integer; ARow: TJSONObject;
      var ALocalDocId: Integer; var AUpdated: Boolean);
  public
    constructor Create(APool: TMxConnectionPool; ALogger: IMxLogger);

    /// Parse manifest (cleartext header) from a bundle's ZIP container.
    function ReadManifest(const ABundle: TBytes; out AManifest: TMxManifestInfo;
      out AManifestJson: TJSONObject; out APayloadCiphertext: TBytes): Boolean;

    /// Decrypt the bundle payload with the given secret. Raises EMxCryptoAuthFail
    /// if the key/passphrase is wrong or the bundle was tampered with.
    function Decrypt(const ACiphertext, AAssocData: TBytes;
      const AManifest: TMxManifestInfo; const ASecret: string): TJSONObject;

    /// Build conflict list for UI Phase 3 (slug collisions with local projects).
    function ResolveConflicts(AContext: IMxDbContext;
      APayload: TJSONObject): TArray<TMxProjectConflict>;

    /// Build developer list + email-auto-match map for UI Phase 4.
    procedure ResolveDevMapping(AContext: IMxDbContext;
      APayload: TJSONObject; out ADevelopers: TArray<TMxDeveloperInfo>;
      out ADevMap: TDictionary<Integer, Integer>);

    /// Phase 5: transactional apply. Caller supplies a session assembled from
    /// the earlier phases plus user decisions.
    function Execute(const ASession: TMxImportSession;
      AImportingDevId: Integer): TMxImportSummary;
  end;

implementation

uses
  System.DateUtils, System.NetEncoding, System.Zip, System.IOUtils,
  System.Hash, System.StrUtils,
  Data.DB, FireDAC.Comp.Client,
  mx.Crypto;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function B64Decode(const S: string): TBytes;
begin
  Result := TNetEncoding.Base64.DecodeStringToBytes(S);
end;

function JsonStr(O: TJSONObject; const Key: string; const ADefault: string = ''): string;
var
  V: TJSONValue;
begin
  if O = nil then Exit(ADefault);
  V := O.GetValue(Key);
  if (V = nil) or (V is TJSONNull) then Exit(ADefault);
  Result := V.Value;
end;

function JsonInt(O: TJSONObject; const Key: string; ADefault: Integer = 0): Integer;
var
  V: TJSONValue;
begin
  if O = nil then Exit(ADefault);
  V := O.GetValue(Key);
  if (V = nil) or (V is TJSONNull) then Exit(ADefault);
  if V is TJSONNumber then Exit((V as TJSONNumber).AsInt);
  Result := StrToIntDef(V.Value, ADefault);
end;

function JsonBool(O: TJSONObject; const Key: string; ADefault: Boolean = False): Boolean;
var
  V: TJSONValue;
begin
  if O = nil then Exit(ADefault);
  V := O.GetValue(Key);
  if (V = nil) or (V is TJSONNull) then Exit(ADefault);
  if V is TJSONBool then Exit((V as TJSONBool).AsBoolean);
  Result := SameText(V.Value, 'true');
end;

function JsonFloat(O: TJSONObject; const Key: string; ADefault: Double = 0): Double;
var
  V: TJSONValue;
begin
  if O = nil then Exit(ADefault);
  V := O.GetValue(Key);
  if (V = nil) or (V is TJSONNull) then Exit(ADefault);
  if V is TJSONNumber then Exit((V as TJSONNumber).AsDouble);
  Result := StrToFloatDef(V.Value, ADefault);
end;

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

constructor TMxProjectImporter.Create(APool: TMxConnectionPool; ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
end;

// ---------------------------------------------------------------------------
// ZIP + Manifest
// ---------------------------------------------------------------------------

function TMxProjectImporter.ReadBundleFiles(const ABundle: TBytes;
  out AManifestBytes, APayloadCiphertext: TBytes): Boolean;
var
  MS: TBytesStream;
  Zip: TZipFile;
  MStream, PStream: TStream;
  LocalHeader: TZipHeader;
begin
  Result := False;
  SetLength(AManifestBytes, 0);
  SetLength(APayloadCiphertext, 0);

  MS := TBytesStream.Create(ABundle);
  Zip := TZipFile.Create;
  try
    Zip.Open(MS, zmRead);

    Zip.Read('manifest.json', MStream, LocalHeader);
    try
      SetLength(AManifestBytes, MStream.Size);
      if MStream.Size > 0 then
        MStream.ReadBuffer(AManifestBytes[0], MStream.Size);
    finally
      MStream.Free;
    end;

    Zip.Read('payload.enc', PStream, LocalHeader);
    try
      SetLength(APayloadCiphertext, PStream.Size);
      if PStream.Size > 0 then
        PStream.ReadBuffer(APayloadCiphertext[0], PStream.Size);
    finally
      PStream.Free;
    end;

    Result := True;
  finally
    Zip.Free;
    MS.Free;
  end;
end;

function TMxProjectImporter.ParseManifest(const AManifestBytes: TBytes): TJSONObject;
var
  S: string;
  V: TJSONValue;
begin
  S := TEncoding.UTF8.GetString(AManifestBytes);
  V := TJSONObject.ParseJSONValue(S);
  if not (V is TJSONObject) then
  begin
    if V <> nil then V.Free;
    raise EMxCryptoError.Create('Bundle manifest is not a JSON object');
  end;
  Result := V as TJSONObject;
end;

function TMxProjectImporter.ManifestToInfo(AManifest: TJSONObject): TMxManifestInfo;
var
  Enc, KeyHint: TJSONObject;
  ModeStr: string;
  WarnsArr: TJSONArray;
  I: Integer;
begin
  Result := Default(TMxManifestInfo);
  Result.SchemaVersion := JsonInt(AManifest, 'schema_version', 0);
  Result.MxLoreBuild   := JsonInt(AManifest, 'mxlore_build', 0);
  Result.ExportDate    := JsonStr(AManifest, 'export_date', '');
  Result.OriginServer  := JsonStr(AManifest, 'origin_server', '');

  Enc := AManifest.GetValue('encryption') as TJSONObject;
  if Enc = nil then
    raise EMxCryptoError.Create('Manifest missing "encryption" block');

  ModeStr := JsonStr(Enc, 'mode', '');
  if SameText(ModeStr, 'api_key') then
    Result.CryptoMode := bcmApiKey
  else if SameText(ModeStr, 'passphrase') then
    Result.CryptoMode := bcmPassphrase
  else
    raise EMxCryptoError.CreateFmt('Unknown encryption.mode "%s"', [ModeStr]);

  Result.Algorithm  := JsonStr(Enc, 'algorithm', '');
  Result.Kdf        := JsonStr(Enc, 'kdf', '');
  Result.Iterations := JsonInt(Enc, 'iterations', 0);
  Result.Salt       := B64Decode(JsonStr(Enc, 'salt', ''));
  Result.Iv         := B64Decode(JsonStr(Enc, 'iv', ''));
  Result.AuthTag    := B64Decode(JsonStr(Enc, 'auth_tag', ''));
  // AAD is RECONSTRUCTED from the canonical crypto-params — we do NOT trust
  // the `aad` field from the manifest (which is only there for debugging).
  // Structural binding: any tamper with salt/iv/iter/mode/version breaks the
  // GCM tag on decrypt. Keeps OQ-10 "covers manifest via AAD" honest.
  Result.Aad := TEncoding.UTF8.GetBytes(
    Format('mxLore-bundle;v=%d;mode=%s;iter=%d;salt=%s;iv=%s',
      [Result.SchemaVersion, ModeStr, Result.Iterations,
       JsonStr(Enc, 'salt', ''), JsonStr(Enc, 'iv', '')]));

  if not SameText(Result.Algorithm, 'AES-256-GCM') then
    raise EMxCryptoError.CreateFmt(
      'Unsupported encryption algorithm "%s"', [Result.Algorithm]);

  KeyHint := AManifest.GetValue('key_hint') as TJSONObject;
  if KeyHint <> nil then
  begin
    Result.KeyId         := JsonInt(KeyHint, 'key_id', 0);
    Result.KeyPrefix     := JsonStr(KeyHint, 'key_prefix', '');
    Result.DeveloperName := JsonStr(KeyHint, 'developer_name', '');
  end;

  WarnsArr := AManifest.GetValue('warnings') as TJSONArray;
  if WarnsArr <> nil then
  begin
    SetLength(Result.Warnings, WarnsArr.Count);
    for I := 0 to WarnsArr.Count - 1 do
      Result.Warnings[I] := WarnsArr.Items[I].Value;
  end;
end;

function TMxProjectImporter.ReadManifest(const ABundle: TBytes;
  out AManifest: TMxManifestInfo; out AManifestJson: TJSONObject;
  out APayloadCiphertext: TBytes): Boolean;
var
  ManifestBytes: TBytes;
begin
  AManifestJson := nil;
  Result := ReadBundleFiles(ABundle, ManifestBytes, APayloadCiphertext);
  if not Result then Exit;
  AManifestJson := ParseManifest(ManifestBytes);
  AManifest := ManifestToInfo(AManifestJson);
end;

// ---------------------------------------------------------------------------
// Decrypt
// ---------------------------------------------------------------------------

function TMxProjectImporter.Decrypt(const ACiphertext, AAssocData: TBytes;
  const AManifest: TMxManifestInfo; const ASecret: string): TJSONObject;
var
  DerivedKey, Plaintext: TBytes;
  Json: string;
  V: TJSONValue;
begin
  if Length(AManifest.Salt) = 0 then
    raise EMxCryptoError.Create('Manifest has empty salt');
  if AManifest.Iterations <= 0 then
    raise EMxCryptoError.Create('Manifest has invalid iterations');

  DerivedKey := MxDeriveKey(ASecret, AManifest.Salt, AManifest.Iterations,
    MX_BUNDLE_KEY_LEN);

  Plaintext := MxBundleDecrypt(ACiphertext, DerivedKey,
    AManifest.Iv, AManifest.AuthTag, AAssocData);

  Json := TEncoding.UTF8.GetString(Plaintext);
  V := TJSONObject.ParseJSONValue(Json);
  if not (V is TJSONObject) then
  begin
    if V <> nil then V.Free;
    raise EMxCryptoError.Create('Decrypted payload is not a JSON object');
  end;
  Result := V as TJSONObject;
end;

// ---------------------------------------------------------------------------
// Conflicts + Dev Mapping
// ---------------------------------------------------------------------------

function TMxProjectImporter.BuildConflictList(AContext: IMxDbContext;
  APayload: TJSONObject): TArray<TMxProjectConflict>;
var
  Projects: TJSONArray;
  Row, Existing: TJSONObject;
  Qry: TFDQuery;
  I: Integer;
  C: TMxProjectConflict;
  List: TList<TMxProjectConflict>;
  Slug: string;
begin
  List := TList<TMxProjectConflict>.Create;
  try
    Projects := APayload.GetValue('projects') as TJSONArray;
    if Projects = nil then Exit(nil);

    for I := 0 to Projects.Count - 1 do
    begin
      Row := Projects.Items[I] as TJSONObject;
      Slug := JsonStr(Row, 'slug', '');
      if Slug = '' then Continue;

      C := Default(TMxProjectConflict);
      C.SourceSlug := Slug;
      C.SourceName := JsonStr(Row, 'name', '');
      C.SourceId   := JsonInt(Row, 'id', 0);
      C.Resolution := crRenameNewSlug;  // default per OQ-8
      C.NewSlug    := Slug + '-imported-' + FormatDateTime('yyyy-mm-dd', Now);

      Qry := AContext.CreateQuery(
        'SELECT id, name FROM projects WHERE slug = :slug');
      try
        Qry.ParamByName('slug').AsString := Slug;
        Qry.Open;
        if not Qry.IsEmpty then
        begin
          C.LocalId   := Qry.FieldByName('id').AsInteger;
          C.LocalName := Qry.FieldByName('name').AsWideString;
        end;
      finally
        Qry.Free;
      end;

      List.Add(C);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TMxProjectImporter.ExtractDeveloperList(
  APayload: TJSONObject): TArray<TMxDeveloperInfo>;
var
  Devs: TJSONArray;
  Row: TJSONObject;
  I: Integer;
  D: TMxDeveloperInfo;
  List: TList<TMxDeveloperInfo>;
begin
  List := TList<TMxDeveloperInfo>.Create;
  try
    Devs := APayload.GetValue('developers') as TJSONArray;
    if Devs = nil then Exit(nil);

    for I := 0 to Devs.Count - 1 do
    begin
      Row := Devs.Items[I] as TJSONObject;
      D := Default(TMxDeveloperInfo);
      D.SourceId := JsonInt(Row, 'id', 0);
      D.Name     := JsonStr(Row, 'name', '');
      D.Email    := JsonStr(Row, 'email', '');
      if D.SourceId > 0 then
        List.Add(D);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TMxProjectImporter.AutoMapDevelopersByEmail(AContext: IMxDbContext;
  const ASourceDevs: TArray<TMxDeveloperInfo>): TDictionary<Integer, Integer>;
var
  Qry: TFDQuery;
  I: Integer;
  LocalId: Integer;
begin
  Result := TDictionary<Integer, Integer>.Create;
  for I := 0 to High(ASourceDevs) do
  begin
    if ASourceDevs[I].Email = '' then Continue;
    Qry := AContext.CreateQuery(
      'SELECT id FROM developers WHERE email = :email AND is_active = 1 LIMIT 1');
    try
      Qry.ParamByName('email').AsString := ASourceDevs[I].Email;
      Qry.Open;
      if not Qry.IsEmpty then
      begin
        LocalId := Qry.FieldByName('id').AsInteger;
        Result.AddOrSetValue(ASourceDevs[I].SourceId, LocalId);
      end;
    finally
      Qry.Free;
    end;
  end;
end;

function TMxProjectImporter.ResolveConflicts(AContext: IMxDbContext;
  APayload: TJSONObject): TArray<TMxProjectConflict>;
begin
  Result := BuildConflictList(AContext, APayload);
end;

procedure TMxProjectImporter.ResolveDevMapping(AContext: IMxDbContext;
  APayload: TJSONObject; out ADevelopers: TArray<TMxDeveloperInfo>;
  out ADevMap: TDictionary<Integer, Integer>);
begin
  ADevelopers := ExtractDeveloperList(APayload);
  ADevMap     := AutoMapDevelopersByEmail(AContext, ADevelopers);
end;

function TMxProjectImporter.RemapDeveloperId(const ASession: TMxImportSession;
  ASourceId: Integer; AFallbackId: Integer): Integer;
begin
  if ASourceId <= 0 then Exit(AFallbackId);
  if (ASession.DevMap <> nil) and ASession.DevMap.ContainsKey(ASourceId) then
  begin
    Result := ASession.DevMap[ASourceId];
    if Result = -1 then Exit(-1);  // explicit drop
    if Result <= 0 then Exit(AFallbackId);
  end
  else
    Result := AFallbackId;
end;

// ---------------------------------------------------------------------------
// Project insert / update
// ---------------------------------------------------------------------------

function TMxProjectImporter.InsertProject(AContext: IMxDbContext;
  ARow: TJSONObject; const ANewSlug: string; ACreatorFallback: Integer;
  const ASession: TMxImportSession): Integer;
var
  Qry: TFDQuery;
  CreatorDevId: Integer;
  Slug: string;
begin
  if ANewSlug <> '' then
    Slug := ANewSlug
  else
    Slug := JsonStr(ARow, 'slug', '');

  CreatorDevId := RemapDeveloperId(ASession,
    JsonInt(ARow, 'created_by_developer_id', 0), ACreatorFallback);
  if CreatorDevId = -1 then CreatorDevId := ACreatorFallback;

  Qry := AContext.CreateQuery(
    'INSERT INTO projects (slug, name, path, svn_url, briefing, dna, ' +
    'project_rules, is_active, created_by, created_by_developer_id) ' +
    'VALUES (:slug, :name, :path, :svn_url, :briefing, :dna, :rules, ' +
    ':is_active, :created_by, :creator_dev)');
  try
    Qry.ParamByName('slug').AsString := Slug;
    Qry.ParamByName('name').AsWideString := JsonStr(ARow, 'name', '');
    Qry.ParamByName('path').AsString := JsonStr(ARow, 'path', '');
    Qry.ParamByName('svn_url').AsString := JsonStr(ARow, 'svn_url', '');
    Qry.ParamByName('briefing').AsWideString := JsonStr(ARow, 'briefing', '');
    Qry.ParamByName('dna').AsWideString := JsonStr(ARow, 'dna', '');
    Qry.ParamByName('rules').AsWideString := JsonStr(ARow, 'project_rules', '');
    if JsonBool(ARow, 'is_active', True) then
      Qry.ParamByName('is_active').AsInteger := 1
    else
      Qry.ParamByName('is_active').AsInteger := 0;
    Qry.ParamByName('created_by').AsString := JsonStr(ARow, 'created_by', 'import');
    if CreatorDevId > 0 then
      Qry.ParamByName('creator_dev').AsInteger := CreatorDevId
    else
      Qry.ParamByName('creator_dev').Clear;
    Qry.ExecSQL;
    Result := Qry.Connection.GetLastAutoGenValue('');
  finally
    Qry.Free;
  end;
end;

procedure TMxProjectImporter.UpdateProject(AContext: IMxDbContext;
  ALocalId: Integer; ARow: TJSONObject; ACreatorFallback: Integer;
  const ASession: TMxImportSession);
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'UPDATE projects SET name = :name, path = :path, svn_url = :svn_url, ' +
    'briefing = :briefing, dna = :dna, project_rules = :rules ' +
    'WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := ALocalId;
    Qry.ParamByName('name').AsWideString := JsonStr(ARow, 'name', '');
    Qry.ParamByName('path').AsString := JsonStr(ARow, 'path', '');
    Qry.ParamByName('svn_url').AsString := JsonStr(ARow, 'svn_url', '');
    Qry.ParamByName('briefing').AsWideString := JsonStr(ARow, 'briefing', '');
    Qry.ParamByName('dna').AsWideString := JsonStr(ARow, 'dna', '');
    Qry.ParamByName('rules').AsWideString := JsonStr(ARow, 'project_rules', '');
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Document insert
// ---------------------------------------------------------------------------

function TMxProjectImporter.InsertDocument(AContext: IMxDbContext;
  ALocalProjectId: Integer; ARow: TJSONObject): Integer;
var
  Qry: TFDQuery;
  MetaStr, LessonStr: string;
begin
  MetaStr   := JsonStr(ARow, 'metadata', '');
  LessonStr := JsonStr(ARow, 'lesson_data', '');

  Qry := AContext.CreateQuery(
    'INSERT INTO documents (project_id, doc_type, slug, title, status, ' +
    'summary_l1, summary_l2, content, metadata, relevance_score, ' +
    'token_estimate, created_by, confidence, lesson_data, ' +
    'violation_count, success_count) ' +
    'VALUES (:pid, :doc_type, :slug, :title, :status, :s1, :s2, :content, ' +
    ':metadata, :rel, :tokens, :created_by, :conf, :lesson, :vcnt, :scnt)');
  try
    Qry.ParamByName('pid').AsInteger := ALocalProjectId;
    Qry.ParamByName('doc_type').AsString := JsonStr(ARow, 'doc_type', 'note');
    Qry.ParamByName('slug').AsString := JsonStr(ARow, 'slug', '');
    Qry.ParamByName('title').AsWideString := JsonStr(ARow, 'title', '');
    Qry.ParamByName('status').AsString := JsonStr(ARow, 'status', 'active');
    Qry.ParamByName('s1').AsWideString := JsonStr(ARow, 'summary_l1', '');
    Qry.ParamByName('s2').AsWideString := JsonStr(ARow, 'summary_l2', '');
    Qry.ParamByName('content').AsWideString := JsonStr(ARow, 'content', '');
    // metadata + lesson_data carry CHECK(json_valid(...)) — empty string is
    // not valid JSON, must be NULL. FireDAC needs explicit DataType before
    // Clear/Value:=Null, otherwise "-335 Datentyp unbekannt" is raised.
    Qry.ParamByName('metadata').DataType := ftWideMemo;
    if MetaStr = '' then
      Qry.ParamByName('metadata').Clear
    else
      Qry.ParamByName('metadata').AsWideString := MetaStr;
    Qry.ParamByName('rel').AsFloat := JsonFloat(ARow, 'relevance_score', 50.0);
    Qry.ParamByName('tokens').AsInteger := JsonInt(ARow, 'token_estimate', 0);
    Qry.ParamByName('created_by').AsString := JsonStr(ARow, 'created_by', 'import');
    Qry.ParamByName('conf').AsFloat := JsonFloat(ARow, 'confidence', 0.5);
    Qry.ParamByName('lesson').DataType := ftWideMemo;
    if LessonStr = '' then
      Qry.ParamByName('lesson').Clear
    else
      Qry.ParamByName('lesson').AsWideString := LessonStr;
    Qry.ParamByName('vcnt').AsInteger := JsonInt(ARow, 'violation_count', 0);
    Qry.ParamByName('scnt').AsInteger := JsonInt(ARow, 'success_count', 0);
    Qry.ExecSQL;
    Result := Qry.Connection.GetLastAutoGenValue('');
  finally
    Qry.Free;
  end;
end;

procedure TMxProjectImporter.UpdateDocumentIfExists(AContext: IMxDbContext;
  ALocalProjectId: Integer; ARow: TJSONObject;
  var ALocalDocId: Integer; var AUpdated: Boolean);
var
  Qry: TFDQuery;
begin
  AUpdated := False;
  ALocalDocId := 0;

  // Look up by (project_id, doc_type, slug) — natural uniqueness key.
  Qry := AContext.CreateQuery(
    'SELECT id FROM documents ' +
    'WHERE project_id = :pid AND doc_type = :dt AND slug = :slug');
  try
    Qry.ParamByName('pid').AsInteger := ALocalProjectId;
    Qry.ParamByName('dt').AsString := JsonStr(ARow, 'doc_type', 'note');
    Qry.ParamByName('slug').AsString := JsonStr(ARow, 'slug', '');
    Qry.Open;
    if Qry.IsEmpty then Exit;
    ALocalDocId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  Qry := AContext.CreateQuery(
    'UPDATE documents SET title = :title, status = :status, ' +
    'summary_l1 = :s1, summary_l2 = :s2, content = :content, ' +
    'metadata = :metadata WHERE id = :id');
  try
    Qry.ParamByName('id').AsInteger := ALocalDocId;
    Qry.ParamByName('title').AsWideString := JsonStr(ARow, 'title', '');
    Qry.ParamByName('status').AsString := JsonStr(ARow, 'status', 'active');
    Qry.ParamByName('s1').AsWideString := JsonStr(ARow, 'summary_l1', '');
    Qry.ParamByName('s2').AsWideString := JsonStr(ARow, 'summary_l2', '');
    Qry.ParamByName('content').AsWideString := JsonStr(ARow, 'content', '');
    // CHECK(json_valid(metadata)) — empty string is not valid JSON → NULL.
    // Explicit DataType required before .Clear (FireDAC -335 otherwise).
    var MetaStr: string := JsonStr(ARow, 'metadata', '');
    Qry.ParamByName('metadata').DataType := ftWideMemo;
    if MetaStr = '' then
      Qry.ParamByName('metadata').Clear
    else
      Qry.ParamByName('metadata').AsWideString := MetaStr;
    Qry.ExecSQL;
    AUpdated := True;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Main Execute (transactional Phase 5)
// ---------------------------------------------------------------------------

function TMxProjectImporter.Execute(const ASession: TMxImportSession;
  AImportingDevId: Integer): TMxImportSummary;
var
  Ctx: IMxDbContext;
  Payload: TJSONObject;
  Projects, Docs, Revs, Tags, DocRels, ProjRels, Acl, Env: TJSONArray;
  ProjMap: TDictionary<Integer, Integer>; // source_project_id → local_id
  DocMap:  TDictionary<Integer, Integer>; // source_doc_id → local_id
  I: Integer;
  Row: TJSONObject;
  SourceId, LocalId, SourcePid, LocalPid, SourceDoc, LocalDoc: Integer;
  Conflict: TMxProjectConflict;
  ConflictFound: Boolean;
  SrcSlug: string;
  DoUpdate: Boolean;
  Qry: TFDQuery;
  DevId: Integer;
  Warns: TList<string>;
begin
  Result := Default(TMxImportSummary);
  Warns := TList<string>.Create;
  ProjMap := TDictionary<Integer, Integer>.Create;
  DocMap  := TDictionary<Integer, Integer>.Create;
  try
    Payload := ASession.DecryptedPayload;
    if Payload = nil then
      raise EMxCryptoError.Create('ImportExecute: payload is nil');

    Ctx := FPool.AcquireContext;
    Ctx.StartTransaction;
    try
      // --- Projects ---
      Projects := Payload.GetValue('projects') as TJSONArray;
      if Projects <> nil then
      for I := 0 to Projects.Count - 1 do
      begin
        Row := Projects.Items[I] as TJSONObject;
        SourceId := JsonInt(Row, 'id', 0);
        SrcSlug  := JsonStr(Row, 'slug', '');

        // Find conflict record for this source_slug
        ConflictFound := False;
        Conflict := Default(TMxProjectConflict);
        var J: Integer;
        for J := 0 to High(ASession.Conflicts) do
          if ASession.Conflicts[J].SourceSlug = SrcSlug then
          begin
            Conflict := ASession.Conflicts[J];
            ConflictFound := True;
            Break;
          end;

        if ConflictFound and (Conflict.LocalId > 0) then
        begin
          case Conflict.Resolution of
            crSkip:
            begin
              Inc(Result.ProjectsSkipped);
              Warns.Add(Format('Project "%s" skipped per conflict resolution.', [SrcSlug]));
              Continue;
            end;
            crOverwrite:
            begin
              UpdateProject(Ctx, Conflict.LocalId, Row, AImportingDevId, ASession);
              ProjMap.AddOrSetValue(SourceId, Conflict.LocalId);
              Inc(Result.ProjectsUpdated);
            end;
            crRenameNewSlug:
            begin
              LocalId := InsertProject(Ctx, Row, Conflict.NewSlug,
                AImportingDevId, ASession);
              ProjMap.AddOrSetValue(SourceId, LocalId);
              Inc(Result.ProjectsRenamed);
            end;
          end;
        end
        else
        begin
          // No collision — regular insert.
          LocalId := InsertProject(Ctx, Row, '', AImportingDevId, ASession);
          ProjMap.AddOrSetValue(SourceId, LocalId);
          Inc(Result.ProjectsCreated);
        end;
      end;

      // --- Documents ---
      Docs := Payload.GetValue('documents') as TJSONArray;
      if Docs <> nil then
      for I := 0 to Docs.Count - 1 do
      begin
        Row := Docs.Items[I] as TJSONObject;
        SourceDoc := JsonInt(Row, 'id', 0);
        SourcePid := JsonInt(Row, 'project_id', 0);

        if not ProjMap.TryGetValue(SourcePid, LocalPid) then Continue;

        // Collision resolution for docs: if (project, doc_type, slug) already
        // exists at this target project, we overwrite (covers crOverwrite at
        // project-level; crRenameNewSlug created a new project so no collision).
        UpdateDocumentIfExists(Ctx, LocalPid, Row, LocalDoc, DoUpdate);
        if not DoUpdate then
        begin
          LocalDoc := InsertDocument(Ctx, LocalPid, Row);
          Inc(Result.DocsInserted);
        end
        else
          Inc(Result.DocsUpdated);

        DocMap.AddOrSetValue(SourceDoc, LocalDoc);
      end;

      // --- Doc Revisions ---
      Revs := Payload.GetValue('doc_revisions') as TJSONArray;
      if Revs <> nil then
      for I := 0 to Revs.Count - 1 do
      begin
        Row := Revs.Items[I] as TJSONObject;
        SourceDoc := JsonInt(Row, 'doc_id', 0);
        if not DocMap.TryGetValue(SourceDoc, LocalDoc) then Continue;

        // Preserve local history: if (doc_id, revision) already exists (e.g.
        // overwrite-collision on a doc that was edited locally), KEEP local
        // revision untouched — source revision is lost on collision. Users
        // wanting full source history should use rename-new-slug which
        // produces a fresh doc with no collisions.
        Qry := Ctx.CreateQuery(
          'INSERT IGNORE INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
          'changed_by, change_reason) VALUES (:id, :rev, :c, :s, :by, :r)');
        try
          Qry.ParamByName('id').AsInteger := LocalDoc;
          Qry.ParamByName('rev').AsInteger := JsonInt(Row, 'revision', 1);
          Qry.ParamByName('c').AsWideString := JsonStr(Row, 'content', '');
          Qry.ParamByName('s').AsWideString := JsonStr(Row, 'summary_l2', '');
          Qry.ParamByName('by').AsString := JsonStr(Row, 'changed_by', 'import');
          Qry.ParamByName('r').AsString := JsonStr(Row, 'change_reason', 'imported');
          Qry.ExecSQL;
          Inc(Result.RevisionsInserted);
        finally
          Qry.Free;
        end;
      end;

      // --- Tags ---
      Tags := Payload.GetValue('doc_tags') as TJSONArray;
      if Tags <> nil then
      for I := 0 to Tags.Count - 1 do
      begin
        Row := Tags.Items[I] as TJSONObject;
        SourceDoc := JsonInt(Row, 'doc_id', 0);
        if not DocMap.TryGetValue(SourceDoc, LocalDoc) then Continue;

        Qry := Ctx.CreateQuery(
          'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:id, :t)');
        try
          Qry.ParamByName('id').AsInteger := LocalDoc;
          Qry.ParamByName('t').AsString := JsonStr(Row, 'tag', '');
          Qry.ExecSQL;
          Inc(Result.TagsInserted);
        finally
          Qry.Free;
        end;
      end;

      // --- Doc Relations ---
      DocRels := Payload.GetValue('doc_relations') as TJSONArray;
      if DocRels <> nil then
      for I := 0 to DocRels.Count - 1 do
      begin
        Row := DocRels.Items[I] as TJSONObject;
        var SrcDoc: Integer := JsonInt(Row, 'source_doc_id', 0);
        var TgtDoc: Integer := JsonInt(Row, 'target_doc_id', 0);
        var LocalSrc, LocalTgt: Integer;
        if not DocMap.TryGetValue(SrcDoc, LocalSrc) then Continue;
        if not DocMap.TryGetValue(TgtDoc, LocalTgt) then Continue;

        Qry := Ctx.CreateQuery(
          'INSERT IGNORE INTO doc_relations (source_doc_id, target_doc_id, ' +
          'relation_type) VALUES (:s, :t, :r)');
        try
          Qry.ParamByName('s').AsInteger := LocalSrc;
          Qry.ParamByName('t').AsInteger := LocalTgt;
          Qry.ParamByName('r').AsString := JsonStr(Row, 'relation_type', '');
          Qry.ExecSQL;
          Inc(Result.RelationsInserted);
        finally
          Qry.Free;
        end;
      end;

      // --- Project Relations ---
      ProjRels := Payload.GetValue('project_relations') as TJSONArray;
      if ProjRels <> nil then
      for I := 0 to ProjRels.Count - 1 do
      begin
        Row := ProjRels.Items[I] as TJSONObject;
        var SrcPid: Integer := JsonInt(Row, 'source_project_id', 0);
        var TgtPid: Integer := JsonInt(Row, 'target_project_id', 0);
        var LocalSrc, LocalTgt: Integer;
        if not ProjMap.TryGetValue(SrcPid, LocalSrc) then Continue;
        if not ProjMap.TryGetValue(TgtPid, LocalTgt) then Continue;

        Qry := Ctx.CreateQuery(
          'INSERT IGNORE INTO project_relations (source_project_id, ' +
          'target_project_id, relation_type) VALUES (:s, :t, :r)');
        try
          Qry.ParamByName('s').AsInteger := LocalSrc;
          Qry.ParamByName('t').AsInteger := LocalTgt;
          Qry.ParamByName('r').AsString := JsonStr(Row, 'relation_type', '');
          Qry.ExecSQL;
          Inc(Result.RelationsInserted);
        finally
          Qry.Free;
        end;
      end;

      // --- ACL ---
      Acl := Payload.GetValue('developer_project_access') as TJSONArray;
      if Acl <> nil then
      for I := 0 to Acl.Count - 1 do
      begin
        Row := Acl.Items[I] as TJSONObject;
        SourcePid := JsonInt(Row, 'project_id', 0);
        if not ProjMap.TryGetValue(SourcePid, LocalPid) then Continue;

        DevId := RemapDeveloperId(ASession,
          JsonInt(Row, 'developer_id', 0), AImportingDevId);
        if DevId = -1 then
        begin
          Inc(Result.AclSkipped);
          Continue;
        end;

        Qry := Ctx.CreateQuery(
          'INSERT IGNORE INTO developer_project_access (developer_id, ' +
          'project_id, access_level) VALUES (:d, :p, :a)');
        try
          Qry.ParamByName('d').AsInteger := DevId;
          Qry.ParamByName('p').AsInteger := LocalPid;
          Qry.ParamByName('a').AsString := JsonStr(Row, 'access_level', 'read');
          Qry.ExecSQL;
          Inc(Result.AclInserted);
        finally
          Qry.Free;
        end;
      end;

      // --- Env Vars ---
      // env_vars are keyed by client_key_id. We cannot remap client_key_ids
      // (client_keys are excluded from the bundle by design). For v1 we only
      // import env-vars whose source client_key belongs to a developer that
      // was remapped — we route them to the importing developer's first active
      // client_key on this server. This is best-effort; deployment will
      // typically reconfigure env-vars fresh on the target.
      Env := Payload.GetValue('developer_environments') as TJSONArray;
      if Env <> nil then
      begin
        // Find a default client_key_id for the importing dev
        var DefaultKeyId: Integer := 0;
        Qry := Ctx.CreateQuery(
          'SELECT id FROM client_keys WHERE developer_id = :d AND is_active = 1 ' +
          'ORDER BY id LIMIT 1');
        try
          Qry.ParamByName('d').AsInteger := AImportingDevId;
          Qry.Open;
          if not Qry.IsEmpty then
            DefaultKeyId := Qry.FieldByName('id').AsInteger;
        finally
          Qry.Free;
        end;

        if DefaultKeyId > 0 then
          for I := 0 to Env.Count - 1 do
          begin
            Row := Env.Items[I] as TJSONObject;
            SourcePid := JsonInt(Row, 'project_id', 0);
            if not ProjMap.TryGetValue(SourcePid, LocalPid) then Continue;

            Qry := Ctx.CreateQuery(
              'INSERT INTO developer_environments (client_key_id, project_id, ' +
              'env_key, env_value) VALUES (:k, :p, :ek, :ev) ' +
              'ON DUPLICATE KEY UPDATE env_value = VALUES(env_value)');
            try
              Qry.ParamByName('k').AsInteger := DefaultKeyId;
              Qry.ParamByName('p').AsInteger := LocalPid;
              Qry.ParamByName('ek').AsString := JsonStr(Row, 'env_key', '');
              Qry.ParamByName('ev').AsWideString := JsonStr(Row, 'env_value', '');
              Qry.ExecSQL;
              Inc(Result.EnvVarsInserted);
            finally
              Qry.Free;
            end;
          end
        else
          Warns.Add('Env-vars skipped: importing developer has no active client_key on this server.');
      end;

      // ---- Per-project import-audit note ----
      // Attach a `note` doc to each imported project so admins can trace the
      // origin without an external audit table. Runs inside the transaction
      // so rollback on any prior error drops the note too.
      var AuditNow: string := FormatDateTime('yyyy-mm-dd-hhnnss', Now);
      var AuditTitle: string := 'Imported ' + FormatDateTime('yyyy-mm-dd hh:nn', Now);
      var AuditContent: string;

      // Build content markdown once — same summary for all imported projects.
      AuditContent :=
        '# Project imported'                                                   + sLineBreak +
        ''                                                                     + sLineBreak +
        '**Imported at:** ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)        + sLineBreak +
        '**Importing developer:** #' + IntToStr(AImportingDevId)                + sLineBreak +
        '**Origin server:** ' + ASession.Manifest.OriginServer                  + sLineBreak +
        '**Export date:** ' + ASession.Manifest.ExportDate                      + sLineBreak +
        '**Source build:** ' + IntToStr(ASession.Manifest.MxLoreBuild)          + sLineBreak +
        '**Crypto:** ' + ASession.Manifest.Algorithm + ' / iter ' +
           IntToStr(ASession.Manifest.Iterations)                               + sLineBreak +
        ''                                                                     + sLineBreak +
        '## Resolution'                                                        + sLineBreak +
        '- Projects created (no collision): ' + IntToStr(Result.ProjectsCreated) + sLineBreak +
        '- Projects renamed (new slug): '     + IntToStr(Result.ProjectsRenamed) + sLineBreak +
        '- Projects overwritten: '            + IntToStr(Result.ProjectsUpdated) + sLineBreak +
        '- Projects skipped: '                + IntToStr(Result.ProjectsSkipped) + sLineBreak +
        ''                                                                     + sLineBreak +
        '## Totals'                                                            + sLineBreak +
        '- Documents: '   + IntToStr(Result.DocsInserted) + ' inserted, ' +
           IntToStr(Result.DocsUpdated) + ' updated' + sLineBreak +
        '- Revisions: '   + IntToStr(Result.RevisionsInserted) + sLineBreak +
        '- Tags: '        + IntToStr(Result.TagsInserted)      + sLineBreak +
        '- Relations: '   + IntToStr(Result.RelationsInserted) + sLineBreak +
        '- ACL entries: ' + IntToStr(Result.AclInserted) + ' (' +
           IntToStr(Result.AclSkipped) + ' dropped via dev-map)' + sLineBreak +
        '- Env-vars: '    + IntToStr(Result.EnvVarsInserted) + sLineBreak;

      // One audit note per imported local-project. Skip projects that were
      // dropped via `crSkip` (not present in ProjMap).
      for LocalPid in ProjMap.Values do
      begin
        Qry := Ctx.CreateQuery(
          'INSERT INTO documents (project_id, doc_type, slug, title, status, ' +
          'content, created_by) VALUES ' +
          '(:pid, ''note'', :slug, :title, ''active'', :content, :by)');
        try
          Qry.ParamByName('pid').AsInteger := LocalPid;
          Qry.ParamByName('slug').AsString := 'import-audit-' + AuditNow + '-' + IntToStr(LocalPid);
          Qry.ParamByName('title').AsWideString := AuditTitle;
          Qry.ParamByName('content').AsWideString := AuditContent;
          Qry.ParamByName('by').AsString := 'project-import';
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      end;

      Ctx.Commit;
    except
      Ctx.Rollback;
      raise;
    end;

    Result.Warnings := Warns.ToArray;

    if Assigned(FLogger) then
      FLogger.Log(mlInfo, Format(
        '[ProjectImport] Applied: +%d projects, %d updated, %d skipped, ' +
        '%d docs +%d updated, %d revs, %d rels, %d ACL (%d skipped), %d env.',
        [Result.ProjectsCreated, Result.ProjectsUpdated, Result.ProjectsSkipped,
         Result.DocsInserted, Result.DocsUpdated, Result.RevisionsInserted,
         Result.RelationsInserted, Result.AclInserted, Result.AclSkipped,
         Result.EnvVarsInserted]));
  finally
    ProjMap.Free;
    DocMap.Free;
    Warns.Free;
  end;
end;

end.
