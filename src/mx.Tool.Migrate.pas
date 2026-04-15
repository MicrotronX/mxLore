unit mx.Tool.Migrate;

interface

uses
  System.SysUtils, System.JSON, System.IOUtils, System.Classes, System.Types,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function HandleMigrateProject(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  System.RegularExpressions, System.StrUtils,
  mx.Tool.Write;

// ---------------------------------------------------------------------------
// Helper: Parse status from markdown content
// ---------------------------------------------------------------------------
function ParseContentStatus(const AContent: string): string;
var
  Match: TMatch;
  Raw: string;
begin
  Result := 'active'; // Default for migrated docs

  // Pattern 1: **Status:** value (colon inside bold — most common)
  Match := TRegEx.Match(AContent, '\*\*Status:\*\*\s*(\w[\w\s,/-]*)');
  if not Match.Success then
    // Pattern 2: **Status**: value (colon outside bold)
    Match := TRegEx.Match(AContent, '\*\*Status\*\*:\s*(\w[\w\s,/-]*)');
  if not Match.Success then
    // Pattern 3: **Status** value (no colon)
    Match := TRegEx.Match(AContent, '\*\*Status\*\*\s+(\w+)');
  if not Match.Success then
    // Pattern 4: | Status | value | (table format)
    Match := TRegEx.Match(AContent, '\|\s*Status\s*\|\s*([^|]+)\|');
  if not Match.Success then
    // Pattern 5: Status: value (plain, without bold)
    Match := TRegEx.Match(AContent, '^Status:\s*(\w+)', [roMultiLine]);
  if not Match.Success then
    // Pattern 6: YAML frontmatter — status: value
    Match := TRegEx.Match(AContent, '^status:\s*(\w+)', [roMultiLine, roIgnoreCase]);

  if Match.Success then
  begin
    Raw := Trim(Match.Groups[1].Value).ToLower;
    // Strip trailing punctuation/whitespace
    Raw := Raw.TrimRight([' ', ',', '.', #13, #10]);
    // Map source status to DB enum
    if MatchStr(Raw, ['accepted', 'approved']) then
      Result := 'active'
    else if MatchStr(Raw, ['completed', 'done', 'implemented']) then
      Result := 'archived'
    else if MatchStr(Raw, ['proposed', 'draft']) then
      Result := 'draft'
    else if MatchStr(Raw, ['superseded', 'deprecated', 'rejected']) then
      Result := 'superseded'
    else if MatchStr(Raw, ['active', 'in_progress', 'in-progress']) then
      Result := 'active'
    else if MatchStr(Raw, ['archived']) then
      Result := 'archived';
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Map filename prefix to doc_type
// ---------------------------------------------------------------------------
function MapDocType(const AFileName: string): string;
begin
  if AFileName.StartsWith('PLAN-', True) then
    Result := 'plan'
  else if AFileName.StartsWith('SPEC-', True) then
    Result := 'spec'
  else if AFileName.StartsWith('ADR-', True) then
    Result := 'decision'
  else if AFileName.Contains('session-notes') or AFileName.Contains('session-note')
      or AFileName.Contains('-session-') then
    Result := 'session_note'
  else if AFileName.StartsWith('workflow-log', True) then
    Result := 'workflow_log'
  else
    Result := 'reference';
end;

// ---------------------------------------------------------------------------
// Helper: Extract H1 title from markdown content
// ---------------------------------------------------------------------------
function ExtractH1Title(const AContent: string): string;
var
  Lines: TArray<string>;
  I: Integer;
  Line: string;
begin
  Result := '';
  Lines := AContent.Split([#10]);
  for I := 0 to Length(Lines) - 1 do
  begin
    Line := Lines[I].TrimRight([#13, ' ']);
    if Line.StartsWith('# ') then
    begin
      Result := Line.Substring(2).Trim;
      Exit;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Generate slug from filename (strip extension and prefix path)
// ---------------------------------------------------------------------------
function SlugFromFileName(const AFileName: string): string;
begin
  Result := TPath.GetFileNameWithoutExtension(AFileName);
  Result := Result.ToLower;
end;

// ---------------------------------------------------------------------------
// Helper: Read file content with ANSI auto-detection
// ---------------------------------------------------------------------------
function ReadFileContent(const APath: string): string;
var
  Stream: TStreamReader;
begin
  // TStreamReader auto-detects BOM; fallback to ANSI if no BOM
  Stream := TStreamReader.Create(APath, TEncoding.Default, True);
  try
    Result := Stream.ReadToEnd;
  finally
    Stream.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_migrate_project — Import docs/*.md files into DB (Spec A.1-10)
// ---------------------------------------------------------------------------
function HandleMigrateProject(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug, BasePath, DocsPath: string;
  ProjectId: Integer;
  Imported, Skipped, Errors: Integer;
  Details: TJSONArray;
  Files: TStringList;
  FilePath, FileName, DocType, DocStatus, Title, Slug, Content, Summary1, Summary2: string;
  DocId: Integer;
  Data, DetailObj: TJSONObject;
  SearchPatterns: array of string;
  Pattern, Dir: string;
  FoundFiles: TStringDynArray;
  I: Integer;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  BasePath := AParams.GetValue<string>('path', '');

  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  if BasePath = '' then
    raise EMxValidation.Create('Parameter "path" is required');

  // Normalize path separators (TMS double-escape workaround: callers use forward slashes)
  BasePath := StringReplace(BasePath, '/', '\', [rfReplaceAll]);
  DocsPath := TPath.Combine(BasePath, 'docs');

  if not TDirectory.Exists(DocsPath) then
    raise EMxValidation.Create('docs/ directory not found at: ' + DocsPath);

  // Resolve project_id
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug +
        '. Register first via mx_init_project.');
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  // ACL: write access required
  if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alWrite);

  Imported := 0;
  Skipped := 0;
  Errors := 0;
  Details := TJSONArray.Create;
  Files := TStringList.Create;
  try
    // Collect ALL *.md files from docs/ and all subdirectories
    // doc_type is determined by MapDocType based on filename prefix
    FoundFiles := TDirectory.GetFiles(DocsPath, '*.md', TSearchOption.soAllDirectories);
    for I := 0 to Length(FoundFiles) - 1 do
      Files.Add(FoundFiles[I]);

    // Skip index.md and status.md files
    for I := Files.Count - 1 downto 0 do
    begin
      FileName := TPath.GetFileName(Files[I]);
      if SameText(FileName, 'index.md') or SameText(FileName, 'status.md') then
        Files.Delete(I);
    end;

    // Process each file
    for I := 0 to Files.Count - 1 do
    begin
      FilePath := Files[I];
      FileName := TPath.GetFileName(FilePath);

      try
        Content := ReadFileContent(FilePath);
        DocType := MapDocType(FileName);
        DocStatus := ParseContentStatus(Content);
        Title := ExtractH1Title(Content);
        if Title = '' then
          Title := TPath.GetFileNameWithoutExtension(FileName);
        Slug := GenerateSlug(Title);
        if Slug = '' then
          Slug := SlugFromFileName(FileName);

        // Auto-generate summaries
        Summary1 := ExtractFirstSentence(Content);
        Summary2 := ExtractFirstSentences(Content, 3);

        // Duplicate check: project_id + doc_type + slug
        Qry := AContext.CreateQuery(
          'SELECT id FROM documents WHERE project_id = :pid ' +
          '  AND doc_type = :dtype AND slug = :slug AND status <> ''deleted''');
        try
          Qry.ParamByName('pid').AsInteger := ProjectId;
          Qry.ParamByName('dtype').AsString := DocType;
          Qry.ParamByName('slug').AsString := Slug;
          Qry.Open;
          if not Qry.IsEmpty then
          begin
            Inc(Skipped);
            DetailObj := TJSONObject.Create;
            DetailObj.AddPair('file', FileName);
            DetailObj.AddPair('action', 'skipped');
            DetailObj.AddPair('reason', 'duplicate');
            Details.AddElement(DetailObj);
            Continue;
          end;
        finally
          Qry.Free;
        end;

        // INSERT document
        AContext.StartTransaction;
        try
          Qry := AContext.CreateQuery(
            'INSERT INTO documents (project_id, doc_type, slug, title, content, ' +
            '  summary_l1, summary_l2, status, created_by) ' +
            'VALUES (:proj_id, :doc_type, :slug, :title, :content, ' +
            '  :summary_l1, :summary_l2, :status, ''migration'')');
          try
            Qry.ParamByName('proj_id').AsInteger := ProjectId;
            Qry.ParamByName('doc_type').AsString := DocType;
            Qry.ParamByName('slug').AsString := Slug;
            Qry.ParamByName('title').AsString := Title;
            BindLargeText(Qry.ParamByName('content'), Content);
            // Bug#2738: clamp to VARCHAR(500) — migration path can exceed
            Qry.ParamByName('summary_l1').AsString := ClampSummary(Summary1);
            Qry.ParamByName('summary_l2').AsString := Summary2;
            Qry.ParamByName('status').AsString := DocStatus;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;

          // Get doc_id for revision
          Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS id');
          try
            Qry.Open;
            DocId := Qry.FieldByName('id').AsInteger;
          finally
            Qry.Free;
          end;

          // INSERT initial revision
          Qry := AContext.CreateQuery(
            'INSERT INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
            '  changed_by, change_reason) ' +
            'VALUES (:doc_id, 1, :content, :summary_l2, ''migration'', ''Imported from file'')');
          try
            Qry.ParamByName('doc_id').AsInteger := DocId;
            BindLargeText(Qry.ParamByName('content'), Content);
            Qry.ParamByName('summary_l2').AsString := Summary2;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;

          AContext.Commit;
        except
          AContext.Rollback;
          raise;
        end;

        Inc(Imported);
        DetailObj := TJSONObject.Create;
        DetailObj.AddPair('file', FileName);
        DetailObj.AddPair('action', 'imported');
        DetailObj.AddPair('doc_type', DocType);
        DetailObj.AddPair('doc_id', TJSONNumber.Create(DocId));
        Details.AddElement(DetailObj);

      except
        on E: Exception do
        begin
          Inc(Errors);
          DetailObj := TJSONObject.Create;
          DetailObj.AddPair('file', FileName);
          DetailObj.AddPair('action', 'error');
          DetailObj.AddPair('reason', E.Message);
          Details.AddElement(DetailObj);
        end;
      end;
    end;

    // Auto-Relations: scan imported docs for cross-references (ADR-NNNN, PLAN-xxx, SPEC-xxx)
    var RelCount := 0;
    if Imported > 1 then
    begin
      // Collect all imported doc_ids with their types and titles
      var ImportedDocs := TList<TPair<Integer, string>>.Create; // doc_id → title
      try
        for var J := 0 to Details.Count - 1 do
        begin
          var Det := Details.Items[J] as TJSONObject;
          if Det.GetValue<string>('action', '') = 'imported' then
            ImportedDocs.Add(TPair<Integer, string>.Create(
              Det.GetValue<Integer>('doc_id', 0),
              Det.GetValue<string>('file', '')));
        end;

        // For each pair, check if one's filename appears in the other's content
        for var A := 0 to ImportedDocs.Count - 1 do
        begin
          var AId := ImportedDocs[A].Key;
          var AFile := TPath.GetFileNameWithoutExtension(ImportedDocs[A].Value);
          for var B := A + 1 to ImportedDocs.Count - 1 do
          begin
            var BId := ImportedDocs[B].Key;
            var BFile := TPath.GetFileNameWithoutExtension(ImportedDocs[B].Value);
            // Check if A references B or B references A by filename
            var ContentA := '';
            var ContentB := '';
            Qry := AContext.CreateQuery(
              'SELECT id, content FROM documents WHERE id IN (:a, :b)');
            try
              Qry.ParamByName('a').AsInteger := AId;
              Qry.ParamByName('b').AsInteger := BId;
              Qry.Open;
              while not Qry.Eof do
              begin
                if Qry.FieldByName('id').AsInteger = AId then
                  ContentA := Qry.FieldByName('content').AsString
                else
                  ContentB := Qry.FieldByName('content').AsString;
                Qry.Next;
              end;
            finally
              Qry.Free;
            end;

            var HasRef := False;
            // A's content mentions B's filename (e.g. "PLAN-xxx" in an ADR)
            if (ContentA <> '') and (Pos(BFile, ContentA) > 0) then
              HasRef := True;
            // B's content mentions A's filename
            if (ContentB <> '') and (Pos(AFile, ContentB) > 0) then
              HasRef := True;

            if HasRef then
            begin
              try
                Qry := AContext.CreateQuery(
                  'INSERT IGNORE INTO doc_relations (source_doc_id, target_doc_id, relation_type) ' +
                  'VALUES (:src, :tgt, ''references'')');
                try
                  Qry.ParamByName('src').AsInteger := AId;
                  Qry.ParamByName('tgt').AsInteger := BId;
                  Qry.ExecSQL;
                  Inc(RelCount);
                finally
                  Qry.Free;
                end;
              except
                on E: Exception do
                  AContext.Logger.Log(mlWarning, '[mx_migrate_project] Auto-relation INSERT failed: ' + E.Message);
              end;
            end;
          end;
        end;
      finally
        ImportedDocs.Free;
      end;
    end;

    // Build response
    Data := TJSONObject.Create;
    try
      Data.AddPair('imported', TJSONNumber.Create(Imported));
      Data.AddPair('skipped', TJSONNumber.Create(Skipped));
      Data.AddPair('errors', TJSONNumber.Create(Errors));
      Data.AddPair('relations_created', TJSONNumber.Create(RelCount));
      Data.AddPair('total_files', TJSONNumber.Create(Files.Count));
      Data.AddPair('details', Details);
      Details := nil; // Ownership transferred to Data
      Result := MxSuccessResponse(Data);
    except
      Data.Free;
      raise;
    end;
  finally
    Files.Free;
    Details.Free; // Only freed if not transferred (nil-safe)
  end;
end;

end.
