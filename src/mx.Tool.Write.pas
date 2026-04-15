unit mx.Tool.Write;

interface

uses
  System.SysUtils, System.JSON, System.Variants, System.DateUtils,
  System.StrUtils,
  Data.DB,
  FireDAC.Comp.Client, FireDAC.Stan.Error, FireDAC.Stan.Param,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function GenerateSlug(const ATitle: string): string;
function ExtractFirstSentence(const AText: string): string;
function ExtractFirstSentences(const AText: string; ACount: Integer): string;

// Clamps a string to MaxLen char-count (utf8mb4). Ellipsis suffix on truncate.
// Bug#2889: defect class of Bug#2738 — VARCHAR columns must be clamped at the
// bind site because direct-input callers can exceed declared column size.
function ClampVarchar(const S: string; MaxLen: Integer): string;

// Thin wrappers over ClampVarchar for the docs/doc_revisions VARCHAR columns.
// Each wrapper encodes the column's declared length as a self-documenting
// call site: "this bind target is VARCHAR(N)".
function ClampSummary(const S: string): string;       // docs.summary_l1 VARCHAR(500), Bug#2738
function ClampTitle(const S: string): string;         // docs.title VARCHAR(255), Bug#2889
function ClampSlug(const S: string): string;          // docs.slug VARCHAR(100), Bug#2889
function ClampChangeReason(const S: string): string;  // doc_revisions.change_reason VARCHAR(500), Bug#2889

// Bind a large text value (typically a doc body) to a TFDParam so that
// FireDAC accepts strings beyond the default 32767-byte parameter limit.
// FireDAC's default Param.Size is 32767 (FConnDefParams.MaxStringSize) and
// setting DataType := ftWideMemo alone does NOT lift it — Size must be set
// explicitly as well. We allocate at least 1 MB to absorb future growth
// without forcing reparameterisation each call.
procedure BindLargeText(AParam: TFDParam; const AValue: string);

// CRUD (Create/Update/Delete) + Summaries — core document operations
function HandleCreateDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleUpdateDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleDeleteDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleRefreshSummaries(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  mx.Data.Graph;

const
  // documents.slug is VARCHAR(100) — see sql/setup.sql
  cMaxSlugLength = 100;
  // Minimum allocation for large-text params. Most doc bodies are a few KB,
  // but specs/plans/lessons can grow above 100 KB. 1 MB ceiling keeps memory
  // bounded for normal docs while leaving headroom for large ones.
  cLargeTextMinSize = 1024 * 1024;

procedure BindLargeText(AParam: TFDParam; const AValue: string);
var
  RequiredSize: Integer;
begin
  AParam.DataType := ftWideMemo;
  RequiredSize := Length(AValue) + 1024;
  if RequiredSize < cLargeTextMinSize then
    RequiredSize := cLargeTextMinSize;
  AParam.Size := RequiredSize;
  AParam.AsString := AValue;
end;

// ---------------------------------------------------------------------------
// Helper: Generate slug from title
// ---------------------------------------------------------------------------
function TransliterateChar(C: Char): string;
begin
  case C of
    #$00E4, #$00C4: Result := 'ae';  // ä, Ä
    #$00F6, #$00D6: Result := 'oe';  // ö, Ö
    #$00FC, #$00DC: Result := 'ue';  // ü, Ü
    #$00DF:         Result := 'ss';  // ß
    #$00E9, #$00E8, #$00EA, #$00EB,
    #$00C9, #$00C8, #$00CA, #$00CB: Result := 'e';  // é, è, ê, ë
    #$00E0, #$00E1, #$00E2, #$00E3,
    #$00C0, #$00C1, #$00C2, #$00C3: Result := 'a';  // à, á, â, ã
    #$00F2, #$00F3, #$00F4, #$00F5,
    #$00D2, #$00D3, #$00D4, #$00D5: Result := 'o';  // ò, ó, ô, õ
    #$00F9, #$00FA, #$00FB,
    #$00D9, #$00DA, #$00DB:         Result := 'u';  // ù, ú, û
    #$00EC, #$00ED, #$00EE, #$00EF,
    #$00CC, #$00CD, #$00CE, #$00CF: Result := 'i';  // ì, í, î, ï
    #$00F1, #$00D1:                 Result := 'n';  // ñ, Ñ
    #$00E7, #$00C7:                 Result := 'c';  // ç, Ç
  else
    Result := '';
  end;
end;

function GenerateSlug(const ATitle: string): string;
var
  I: Integer;
  C: Char;
  Trans: string;
begin
  Result := '';
  for I := 1 to Length(ATitle) do
  begin
    C := ATitle[I];
    if CharInSet(C, ['a'..'z', '0'..'9', '-']) then
      Result := Result + C
    else if CharInSet(C, ['A'..'Z']) then
      Result := Result + Char(Ord(C) + 32)
    else if (C = ' ') or (C = '_') then
      Result := Result + '-'
    else
    begin
      Trans := TransliterateChar(C);
      if Trans <> '' then
        Result := Result + Trans;
    end;
  end;
  // Collapse multiple hyphens
  while Pos('--', Result) > 0 do
    Result := StringReplace(Result, '--', '-', [rfReplaceAll]);
  Result := Trim(Result);
  if Result.StartsWith('-') then
    Result := Result.Substring(1);
  if Result.EndsWith('-') then
    Result := Result.Substring(0, Length(Result) - 1);
  // Bug#2261: cap to DB column width so long titles no longer raise
  // "Data too long for column 'slug'".
  if Length(Result) > cMaxSlugLength then
  begin
    Result := Copy(Result, 1, cMaxSlugLength);
    if Result.EndsWith('-') then
      Result := Result.Substring(0, Length(Result) - 1);
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Find first content line (skip headers, frontmatter, metadata)
// ---------------------------------------------------------------------------
function FindFirstContentLine(const AText: string): string;
var
  Lines: TArray<string>;
  I: Integer;
  Line: string;
  InCodeBlock: Boolean;
begin
  Result := '';
  Lines := AText.Split([#10]);
  InCodeBlock := False;
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I].TrimRight([#13, ' ']);
    // Skip code blocks (```...```)
    if Line.StartsWith('```') then
    begin
      InCodeBlock := not InCodeBlock;
      Continue;
    end;
    if InCodeBlock then Continue;
    // Skip empty lines, markdown headers, frontmatter, blockquotes, tables
    if (Line = '') or Line.StartsWith('#') or Line.StartsWith('---') or
       Line.StartsWith('> ') or Line.StartsWith('|') then
      Continue;
    // Skip bold metadata lines like **Status:** or **Slug:**
    if Line.StartsWith('**') and (Pos(':**', Line) > 0) then
      Continue;
    // Skip checklists and bullet lists (not prose)
    if Line.StartsWith('- [ ]') or Line.StartsWith('- [x]') or
       Line.StartsWith('- [X]') then
      Continue;
    Result := Line;
    Exit;
  end;
  // Fallback: if only structured content, use first bullet as summary
  InCodeBlock := False;
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I].TrimRight([#13, ' ']);
    if Line.StartsWith('```') then
    begin
      InCodeBlock := not InCodeBlock;
      Continue;
    end;
    if InCodeBlock then Continue;
    if (Line <> '') and (Line.StartsWith('- ') or Line.StartsWith('* ') or
       Line.StartsWith('1.')) then
    begin
      // Strip bullet prefix for cleaner summary
      if Line.StartsWith('- ') then Result := Copy(Line, 3, MaxInt)
      else if Line.StartsWith('* ') then Result := Copy(Line, 3, MaxInt)
      else Result := Line;
      Result := Trim(Result);
      Exit;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Helpers: VARCHAR input clamps for docs/doc_revisions bind sites
// Bug#2738 Phase 4 (summary) + Bug#2889 (title/slug/change_reason)
// ---------------------------------------------------------------------------
function ClampVarchar(const S: string; MaxLen: Integer): string;
begin
  if (MaxLen < 4) or (Length(S) <= MaxLen) then
    Result := S
  else
    Result := Copy(S, 1, MaxLen - 3) + '...';
end;

function ClampSummary(const S: string): string;
begin
  Result := ClampVarchar(S, 500);
end;

function ClampTitle(const S: string): string;
begin
  Result := ClampVarchar(S, 255);
end;

function ClampSlug(const S: string): string;
begin
  Result := ClampVarchar(S, 100);
end;

function ClampChangeReason(const S: string): string;
begin
  Result := ClampVarchar(S, 500);
end;

// ---------------------------------------------------------------------------
// Helper: Extract first sentence from text (skips markdown preamble)
// ---------------------------------------------------------------------------
function ExtractFirstSentence(const AText: string): string;
var
  Line, S: string;
  DotPos, SearchFrom: Integer;
  Parts: TArray<string>;
  K: Integer;
begin
  Result := '';
  if AText = '' then
    Exit;
  Line := FindFirstContentLine(AText);
  if Line = '' then
  begin
    // Fallback: use first non-empty line
    Parts := AText.Split([#10]);
    for K := 0 to High(Parts) do
    begin
      S := Parts[K].TrimRight([#13, ' ']);
      if S <> '' then
      begin
        Line := S;
        Break;
      end;
    end;
  end;
  if Line = '' then Exit;
  // Extract up to first sentence boundary (skip numbered list markers like "1. ")
  DotPos := 0;
  SearchFrom := 1;
  repeat
    DotPos := PosEx('. ', Line, SearchFrom);
    if DotPos > 0 then
    begin
      // Skip if preceded by digit (numbered list: "1. ", "12. ")
      if (DotPos >= 2) and (Line[DotPos - 1] >= '0') and (Line[DotPos - 1] <= '9') then
      begin
        SearchFrom := DotPos + 2;
        DotPos := 0;
        Continue;
      end;
      Break;
    end;
  until DotPos <= 0;
  if DotPos > 0 then
    Result := Copy(Line, 1, DotPos)
  else
    Result := Line;
  Result := Trim(Result);
  if Length(Result) > 500 then
    Result := Copy(Result, 1, 497) + '...';
end;

// ---------------------------------------------------------------------------
// Helper: Skip markdown preamble (headers, frontmatter, metadata)
// ---------------------------------------------------------------------------
function SkipMarkdownPreamble(const AText: string): string;
var
  Lines: TArray<string>;
  I, StartIdx: Integer;
  Line: string;
  InCodeBlock: Boolean;
begin
  Lines := AText.Split([#10]);
  StartIdx := 0;
  InCodeBlock := False;
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I].TrimRight([#13, ' ']);
    // Skip code blocks
    if Line.StartsWith('```') then
    begin
      InCodeBlock := not InCodeBlock;
      Continue;
    end;
    if InCodeBlock then Continue;
    if (Line = '') or Line.StartsWith('#') or Line.StartsWith('---') or
       Line.StartsWith('> ') or Line.StartsWith('|') then
      Continue;
    if Line.StartsWith('**') and (Pos(':**', Line) > 0) then
      Continue;
    if Line.StartsWith('- [ ]') or Line.StartsWith('- [x]') or
       Line.StartsWith('- [X]') then
      Continue;
    StartIdx := I;
    Break;
  end;
  Result := '';
  InCodeBlock := False;
  for I := StartIdx to High(Lines) do
  begin
    Line := Lines[I].TrimRight([#13, ' ']);
    // Don't include code blocks in summary text
    if Line.StartsWith('```') then
    begin
      InCodeBlock := not InCodeBlock;
      Continue;
    end;
    if InCodeBlock then Continue;
    if I > StartIdx then
      Result := Result + #10;
    Result := Result + Lines[I];
  end;
end;

// ---------------------------------------------------------------------------
// Helper: Extract first N sentences from text (skips markdown preamble)
// ---------------------------------------------------------------------------
function ExtractFirstSentences(const AText: string; ACount: Integer): string;
var
  ContentText: string;
  I, SentenceCount: Integer;
  C: Char;
begin
  Result := '';
  if AText = '' then
    Exit;
  ContentText := SkipMarkdownPreamble(AText);
  if ContentText = '' then
    ContentText := AText; // Fallback
  SentenceCount := 0;
  for I := 1 to Length(ContentText) do
  begin
    C := ContentText[I];
    // Stop at paragraph boundary
    if (C = #10) and (I < Length(ContentText)) and (ContentText[I + 1] = #10) then
    begin
      Result := Result + C;
      Break;
    end;
    Result := Result + C;
    if (C = '.') and (I < Length(ContentText)) then
    begin
      if CharInSet(ContentText[I + 1], [' ', #10, #13]) then
      begin
        Inc(SentenceCount);
        if SentenceCount >= ACount then
          Break;
      end;
    end;
  end;
  Result := Trim(Result);
  // Cap at 2000 chars
  if Length(Result) > 2000 then
    Result := Copy(Result, 1, 1997) + '...';
end;

// ---------------------------------------------------------------------------
// mx_create_doc — Create a document with initial revision
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Helper: Notify related projects about high-signal document changes
// Non-blocking: failures are logged but never propagate to the caller.
// ---------------------------------------------------------------------------
procedure NotifyRelatedProjects(AContext: IMxDbContext;
  AProjectId: Integer; ADocId: Integer;
  const ADocType, ATitle, AChangeReason, AProjectSlug: string);
var
  Qry: TFDQuery;
  TargetId, SessionId, DevId: Integer;
begin
  // Only notify for high-signal doc types
  if not MatchStr(ADocType, ['spec', 'plan', 'decision']) then
    Exit;
  try
    SessionId := 0;
    DevId := MxGetThreadAuth.DeveloperId;
    // Get caller's active session
    Qry := AContext.CreateQuery(
      'SELECT id FROM sessions WHERE project_id = :pid AND ended_at IS NULL ' +
      'ORDER BY started_at DESC LIMIT 1');
    try
      Qry.ParamByName('pid').AsInteger := AProjectId;
      Qry.Open;
      if not Qry.IsEmpty then
        SessionId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;

    // Find all related projects (both directions)
    Qry := AContext.CreateQuery(
      'SELECT CASE WHEN source_project_id = :pid THEN target_project_id ' +
      '  ELSE source_project_id END AS related_id ' +
      'FROM project_relations ' +
      'WHERE source_project_id = :pid2 OR target_project_id = :pid3');
    try
      Qry.ParamByName('pid').AsInteger := AProjectId;
      Qry.ParamByName('pid2').AsInteger := AProjectId;
      Qry.ParamByName('pid3').AsInteger := AProjectId;
      Qry.Open;
      while not Qry.Eof do
      begin
        TargetId := Qry.FieldByName('related_id').AsInteger;
        // Deduplicate: remove older pending notification for same doc
        var DelQry := AContext.CreateQuery(
          'DELETE FROM agent_messages WHERE ref_doc_id = :did ' +
          'AND target_project_id = :tid AND status = ''pending'' ' +
          'AND message_type = ''info''');
        try
          DelQry.ParamByName('did').AsInteger := ADocId;
          DelQry.ParamByName('tid').AsInteger := TargetId;
          DelQry.ExecSQL;
        finally
          DelQry.Free;
        end;
        // Build payload as proper JSON (safe escaping)
        var PayloadObj := TJSONObject.Create;
        try
          PayloadObj.AddPair('type', 'doc_changed');
          PayloadObj.AddPair('doc_id', TJSONNumber.Create(ADocId));
          PayloadObj.AddPair('doc_type', ADocType);
          PayloadObj.AddPair('title', ATitle);
          PayloadObj.AddPair('change_reason', AChangeReason);
          PayloadObj.AddPair('project', AProjectSlug);
          // Insert new notification (TTL 30 days)
          var InsQry := AContext.CreateQuery(
            'INSERT INTO agent_messages ' +
            '(sender_session_id, sender_project_id, sender_developer_id, ' +
            ' target_project_id, message_type, payload, ref_doc_id, ' +
            ' priority, expires_at) ' +
            'VALUES (:sid, :spid, :did, :tpid, ''info'', :payload, :rdid, ' +
            ' ''normal'', DATE_ADD(NOW(), INTERVAL 30 DAY))');
          try
            if SessionId > 0 then
              InsQry.ParamByName('sid').AsInteger := SessionId
            else
              InsQry.ParamByName('sid').AsInteger := 0;
            InsQry.ParamByName('spid').AsInteger := AProjectId;
            InsQry.ParamByName('did').AsInteger := DevId;
            InsQry.ParamByName('tpid').AsInteger := TargetId;
            InsQry.ParamByName('payload').AsString := PayloadObj.ToJSON;
            InsQry.ParamByName('rdid').AsInteger := ADocId;
            InsQry.ExecSQL;
          finally
            InsQry.Free;
          end;
        finally
          PayloadObj.Free;
        end;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
  except
    on E: Exception do
      AContext.Logger.Log(mlWarning,
        '[NotifyRelatedProjects] Failed for doc ' + IntToStr(ADocId) +
        ': ' + E.Message);
  end;
end;

function HandleCreateDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug, DocType, Title, Content, Summary1, Summary2,
    CreatedBy, Status, LessonData: string;
  Slug, BaseSlug, SuffixStr: string;
  ProjectId, DocId, MaxAdrNum, I, Attempt: Integer;
  Data: TJSONObject;
  TagsArr: TJSONArray;
  TagVal: TJSONValue;
  Inserted: Boolean;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  DocType := AParams.GetValue<string>('doc_type', '');
  Title := AParams.GetValue<string>('title', '');
  Content := AParams.GetValue<string>('content', '');
  // B6.1: body alias for mx_create_note compat
  if Content = '' then
    Content := AParams.GetValue<string>('body', '');
  Summary1 := AParams.GetValue<string>('summary_l1', '');
  Summary2 := AParams.GetValue<string>('summary_l2', '');
  CreatedBy := AParams.GetValue<string>('created_by', 'mcp');
  Status := AParams.GetValue<string>('status', 'draft');
  LessonData := AParams.GetValue<string>('lesson_data', '');
  TagsArr := nil;
  if AParams.GetValue('tags') is TJSONArray then
    TagsArr := AParams.GetValue('tags') as TJSONArray;

  // Auto-Summary: generate L1/L2 from content if not provided (Spec D.19)
  if (Content <> '') and (Summary1 = '') then
    Summary1 := ExtractFirstSentence(Content);
  if (Content <> '') and (Summary2 = '') then
    Summary2 := ExtractFirstSentences(Content, 3);

  // Validate status if provided
  if not MatchStr(Status, ['draft', 'active', 'completed',
      'superseded', 'archived', 'reported', 'confirmed', 'fixed', 'rejected', 'accepted',
      'proposed', 'approved', 'implemented', 'resolved',
      'open', 'in_progress', 'done', 'deferred']) then
    raise EMxValidation.CreateFmt('Invalid status "%s"', [Status]);

  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');
  if DocType = '' then
    raise EMxValidation.Create('Parameter "doc_type" is required');
  if not MatchStr(DocType, ['plan', 'spec', 'decision', 'status',
      'workflow_log', 'session_note', 'finding', 'reference', 'snippet',
      'note', 'bugreport', 'feature_request', 'todo', 'assumption', 'lesson']) then
    raise EMxValidation.CreateFmt('Invalid doc_type "%s". Allowed: plan, spec, decision, status, workflow_log, session_note, finding, reference, snippet, note, bugreport, feature_request, todo, assumption, lesson', [DocType]);
  if Title = '' then
    raise EMxValidation.Create('Parameter "title" is required');

  // Generate slug from title
  Slug := GenerateSlug(Title);
  if Slug = '' then
    Slug := 'doc-' + FormatDateTime('yyyymmdd-hhnnss', Now);

  // Resolve project_id
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  // ACL: check write access to target project
  if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alWrite);

  // B6.6: Auto-ADR number for doc_type=decision
  if DocType = 'decision' then
  begin
    Qry := AContext.CreateQuery(
      'SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(slug, ''-'', 2), ''-'', -1) ' +
      '  AS UNSIGNED)), 0) AS max_num ' +
      'FROM documents WHERE project_id = :pid AND doc_type = ''decision'' ' +
      '  AND status <> ''deleted''');
    try
      Qry.ParamByName('pid').AsInteger := ProjectId;
      Qry.Open;
      MaxAdrNum := Qry.FieldByName('max_num').AsInteger + 1;
    finally
      Qry.Free;
    end;
    // Prepend ADR number to slug if not already present.
    // Reserve 13 chars: 'adr-NNNN-' (9) + '-99' collision suffix (3) + safety (1).
    if Pos('adr-', LowerCase(Slug)) <> 1 then
    begin
      if Length(Slug) > (cMaxSlugLength - 13) then
        Slug := Copy(Slug, 1, cMaxSlugLength - 13);
      Slug := Format('adr-%4.4d-%s', [MaxAdrNum, Slug]);
    end;
  end;

  // Bug#2262: retry-with-suffix on slug collision — callers no longer need to
  // pre-check via mx_search, which is unreliable for date-based queries.
  BaseSlug := Slug;
  DocId := 0;
  Inserted := False;

  AContext.StartTransaction;
  try
    for Attempt := 0 to 9 do
    begin
      if Attempt = 0 then
        Slug := BaseSlug
      else
      begin
        SuffixStr := '-' + IntToStr(Attempt + 1);
        if Length(BaseSlug) + Length(SuffixStr) > cMaxSlugLength then
          Slug := Copy(BaseSlug, 1, cMaxSlugLength - Length(SuffixStr)) + SuffixStr
        else
          Slug := BaseSlug + SuffixStr;
      end;

      try
        // INSERT document (with lesson_data for doc_type=lesson)
        Qry := AContext.CreateQuery(
          'INSERT INTO documents (project_id, doc_type, slug, title, content, ' +
          '  summary_l1, summary_l2, status, created_by, lesson_data) ' +
          'VALUES (:proj_id, :doc_type, :slug, :title, :content, ' +
          '  :summary_l1, :summary_l2, :status, :created_by, :lesson_data)');
        try
          Qry.ParamByName('proj_id').AsInteger := ProjectId;
          Qry.ParamByName('doc_type').AsString := DocType;
          Qry.ParamByName('slug').AsString := ClampSlug(Slug);
          Qry.ParamByName('title').AsString := ClampTitle(Title);
          BindLargeText(Qry.ParamByName('content'), Content);
          // Bug#2738: clamp to VARCHAR(500) — direct input path can exceed
          Qry.ParamByName('summary_l1').AsString := ClampSummary(Summary1);
          Qry.ParamByName('summary_l2').AsString := Summary2;
          Qry.ParamByName('status').AsString := Status;
          Qry.ParamByName('created_by').AsString := CreatedBy;
          if LessonData <> '' then
            Qry.ParamByName('lesson_data').AsString := LessonData
          else
          begin
            Qry.ParamByName('lesson_data').DataType := ftString;
            Qry.ParamByName('lesson_data').Clear;
          end;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;

        // Get doc_id
        Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS id');
        try
          Qry.Open;
          DocId := Qry.FieldByName('id').AsInteger;
        finally
          Qry.Free;
        end;

        Inserted := True;
        Break;
      except
        on E: EFDDBEngineException do
          if (E.Kind = ekUKViolated) and (Attempt < 9) then
            Continue
          else
            raise;
      end;
    end;

    if not Inserted then
      raise EMxValidation.CreateFmt(
        'Slug collision: could not find a free slug after 10 attempts (base="%s")',
        [BaseSlug]);

    // INSERT initial revision
    Qry := AContext.CreateQuery(
      'INSERT INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
      '  changed_by, change_reason) ' +
      'VALUES (:doc_id, 1, :content, :summary_l2, :changed_by, ''Initial version'')');
    try
      Qry.ParamByName('doc_id').AsInteger := DocId;
      BindLargeText(Qry.ParamByName('content'), Content);
      Qry.ParamByName('summary_l2').AsString := Summary2;
      Qry.ParamByName('changed_by').AsString := CreatedBy;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // B6.1: Tags (absorbed from mx_create_note)
    if (TagsArr <> nil) and (TagsArr.Count > 0) then
    begin
      Qry := AContext.CreateQuery(
        'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
      try
        for I := 0 to TagsArr.Count - 1 do
        begin
          TagVal := TagsArr.Items[I];
          if TagVal.Value <> '' then
          begin
            Qry.ParamByName('doc_id').AsInteger := DocId;
            Qry.ParamByName('tag').AsString := LowerCase(Trim(TagVal.Value));
            Qry.ExecSQL;
          end;
        end;
      finally
        Qry.Free;
      end;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  // Graph-Population for lessons (Phase 2: create nodes+edges for applies_to)
  if (DocType = 'lesson') and (LessonData <> '') then
  begin
    try
      var ParsedVal := TJSONObject.ParseJSONValue(LessonData);
      var LessonJson: TJSONObject := nil;
      if (ParsedVal <> nil) and (ParsedVal is TJSONObject) then
        LessonJson := TJSONObject(ParsedVal)
      else
        ParsedVal.Free;
      try
        if LessonJson <> nil then
        begin
          var LessonNodeId := TMxGraphData.FindOrCreateNode(AContext,
            'lesson', Title, ProjectId, DocId);
          // applies_to_files → file nodes + edges
          var FilesVal := LessonJson.GetValue('applies_to_files');
          var FilesArr: TJSONArray := nil;
          if (FilesVal <> nil) and (FilesVal is TJSONArray) then
            FilesArr := TJSONArray(FilesVal);
          if (FilesArr <> nil) and (FilesArr.Count > 0) then
          begin
            for var K := 0 to FilesArr.Count - 1 do
            begin
              var FilePath := FilesArr.Items[K].Value;
              if FilePath <> '' then
              begin
                var FileNodeId := TMxGraphData.FindOrCreateNode(AContext,
                  'file', FilePath, ProjectId);
                TMxGraphData.FindOrCreateEdge(AContext,
                  LessonNodeId, FileNodeId, 'applies_to', 1.0);
              end;
            end;
          end;
          // applies_to_functions → function nodes + edges
          var FuncsVal := LessonJson.GetValue('applies_to_functions');
          var FuncsArr: TJSONArray := nil;
          if (FuncsVal <> nil) and (FuncsVal is TJSONArray) then
            FuncsArr := TJSONArray(FuncsVal);
          if (FuncsArr <> nil) and (FuncsArr.Count > 0) then
          begin
            for var M := 0 to FuncsArr.Count - 1 do
            begin
              var FuncName := FuncsArr.Items[M].Value;
              if FuncName <> '' then
              begin
                var FuncNodeId := TMxGraphData.FindOrCreateNode(AContext,
                  'function', FuncName, ProjectId);
                TMxGraphData.FindOrCreateEdge(AContext,
                  LessonNodeId, FuncNodeId, 'applies_to', 1.0);
              end;
            end;
          end;
        end;
      finally
        LessonJson.Free;
      end;
    except
      on E: Exception do
        AContext.Logger.Log(mlDebug, 'Lesson graph population skipped: ' + E.Message);
    end;
  end;

  // Auto-notify related projects (non-blocking, after commit)
  NotifyRelatedProjects(AContext, ProjectId, DocId, DocType, Title,
    'New document created', ProjectSlug);

  Data := TJSONObject.Create;
  try
    Data.AddPair('doc_id', TJSONNumber.Create(DocId));
    Data.AddPair('slug', Slug);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_update_doc — Update document with optimistic locking
// ---------------------------------------------------------------------------
function HandleUpdateDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, ProjectId: Integer;
  Title, Content, Status, DocType, Summary1, Summary2,
    ChangeReason, ChangedBy, ExpectedUpdatedAt, NewUpdatedAt,
    ProjectSlug, CurrentDocType, CurrentTitle, NewProject: string;
  NewProjectId: Integer;
  CurrentUpdatedAt, ExpectedDT: TDateTime;
  SetParts: string;
  NextRevision: Integer;
  Fmt: TFormatSettings;
  Data: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  Title := AParams.GetValue<string>('title', '');
  Content := AParams.GetValue<string>('content', '');
  Status := AParams.GetValue<string>('status', '');
  DocType := AParams.GetValue<string>('doc_type', '');
  Summary1 := AParams.GetValue<string>('summary_l1', '');
  Summary2 := AParams.GetValue<string>('summary_l2', '');
  ChangeReason := AParams.GetValue<string>('change_reason', '');
  ChangedBy := AParams.GetValue<string>('changed_by', 'mcp');
  ExpectedUpdatedAt := AParams.GetValue<string>('expected_updated_at', '');
  var Verified := AParams.GetValue<Boolean>('verified', False);
  NewProject := AParams.GetValue<string>('project', '');
  NewProjectId := 0;

  // Validate status if provided
  if (Status <> '') and not MatchStr(Status, ['draft', 'active', 'completed',
      'superseded', 'archived', 'reported', 'confirmed', 'fixed', 'rejected', 'accepted',
      'proposed', 'approved', 'implemented', 'resolved',
      'open', 'in_progress', 'done', 'deferred']) then
    raise EMxValidation.CreateFmt('Invalid status "%s"', [Status]);

  // Validate doc_type if provided (Bug #352)
  if (DocType <> '') and not MatchStr(DocType, ['plan', 'spec', 'decision', 'status',
      'workflow_log', 'session_note', 'finding', 'reference', 'snippet',
      'note', 'bugreport', 'feature_request', 'todo', 'assumption', 'lesson']) then
    raise EMxValidation.CreateFmt('Invalid doc_type "%s"', [DocType]);

  // Build dynamic SET clause (before transaction)
  SetParts := '';
  if Title <> '' then
    SetParts := SetParts + 'title = :title, ';
  if Content <> '' then
    SetParts := SetParts + 'content = :content, ';
  if Status <> '' then
    SetParts := SetParts + 'status = :status, ';
  if DocType <> '' then
    SetParts := SetParts + 'doc_type = :doc_type, ';
  if Summary1 <> '' then
    SetParts := SetParts + 'summary_l1 = :summary_l1, ';
  if Summary2 <> '' then
    SetParts := SetParts + 'summary_l2 = :summary_l2, ';

  // Project move: add to SET, resolve inside transaction
  if NewProject <> '' then
    SetParts := SetParts + 'project_id = :project_id, ';
  // Confidence: verified=true → 1.00, content change → 0.80
  if Verified then
    SetParts := SetParts + 'confidence = 1.00, '
  else if Content <> '' then
    SetParts := SetParts + 'confidence = 0.80, ';

  if SetParts = '' then
    raise EMxValidation.Create('No fields to update');

  // Validate expected_updated_at format before starting transaction
  if ExpectedUpdatedAt <> '' then
  begin
    Fmt := TFormatSettings.Create;
    Fmt.DateSeparator := '-';
    Fmt.TimeSeparator := ':';
    Fmt.ShortDateFormat := 'yyyy-mm-dd';
    Fmt.LongTimeFormat := 'hh:nn:ss';
    if not TryStrToDateTime(ExpectedUpdatedAt, ExpectedDT, Fmt) then
      raise EMxValidation.Create('Invalid expected_updated_at format (use yyyy-mm-dd hh:nn:ss)');
  end;

  // Remove trailing comma+space
  SetParts := Copy(SetParts, 1, Length(SetParts) - 2);

  AContext.StartTransaction;
  try
    // Verify document exists, get project for ACL, check optimistic locking
    Qry := AContext.CreateQuery(
      'SELECT d.project_id, p.slug AS project_slug, d.updated_at, ' +
      '  d.doc_type AS current_doc_type, d.title AS current_title ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));
      ProjectId := Qry.FieldByName('project_id').AsInteger;
      ProjectSlug := Qry.FieldByName('project_slug').AsString;
      CurrentUpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
      CurrentDocType := Qry.FieldByName('current_doc_type').AsString;
      CurrentTitle := Qry.FieldByName('current_title').AsString;

      // ACL: check write access to the document's project
      if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
        raise EMxAccessDenied.Create(ProjectSlug, alWrite);
    finally
      Qry.Free;
    end;

    // Resolve target project for move (inside TX, needs write ACL on target)
    if NewProject <> '' then
    begin
      Qry := AContext.CreateQuery(
        'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
      try
        Qry.ParamByName('slug').AsString := NewProject;
        Qry.Open;
        if Qry.IsEmpty then
          raise EMxNotFound.Create('Target project not found: ' + NewProject);
        NewProjectId := Qry.FieldByName('id').AsInteger;
      finally
        Qry.Free;
      end;
      if not AContext.AccessControl.CheckProject(NewProjectId, alWrite) then
        raise EMxAccessDenied.Create(NewProject, alWrite);
      if NewProjectId = ProjectId then
        raise EMxValidation.Create('Document is already in project "' + NewProject + '"');
    end;

    // Optimistic locking check (inside TX)
    if ExpectedUpdatedAt <> '' then
    begin
      if Abs(CurrentUpdatedAt - ExpectedDT) > (1 / SecsPerDay) then
        raise EMxConflict.Create('Document was modified since last read');
    end;

    // UPDATE document
    Qry := AContext.CreateQuery(
      'UPDATE documents SET ' + SetParts + ' WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      if Title <> '' then
        Qry.ParamByName('title').AsString := ClampTitle(Title);
      if Content <> '' then
        BindLargeText(Qry.ParamByName('content'), Content);
      if Status <> '' then
        Qry.ParamByName('status').AsString := Status;
      if DocType <> '' then
        Qry.ParamByName('doc_type').AsString := DocType;
      if Summary1 <> '' then
        // Bug#2738: clamp to VARCHAR(500) — direct input path can exceed
        Qry.ParamByName('summary_l1').AsString := ClampSummary(Summary1);
      if Summary2 <> '' then
        Qry.ParamByName('summary_l2').AsString := Summary2;
      if NewProject <> '' then
        Qry.ParamByName('project_id').AsInteger := NewProjectId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // INSERT revision if content changed
    if Content <> '' then
    begin
      // Get next revision number
      Qry := AContext.CreateQuery(
        'SELECT IFNULL(MAX(revision), 0) + 1 AS next_rev ' +
        'FROM doc_revisions WHERE doc_id = :doc_id');
      try
        Qry.ParamByName('doc_id').AsInteger := DocId;
        Qry.Open;
        NextRevision := Qry.FieldByName('next_rev').AsInteger;
      finally
        Qry.Free;
      end;

      Qry := AContext.CreateQuery(
        'INSERT INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
        '  changed_by, change_reason) ' +
        'VALUES (:doc_id, :rev, :content, :summary_l2, :changed_by, :reason)');
      try
        Qry.ParamByName('doc_id').AsInteger := DocId;
        Qry.ParamByName('rev').AsInteger := NextRevision;
        BindLargeText(Qry.ParamByName('content'), Content);
        Qry.ParamByName('summary_l2').AsString := Summary2;
        Qry.ParamByName('changed_by').AsString := ChangedBy;
        Qry.ParamByName('reason').AsString := ClampChangeReason(ChangeReason);
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    end;

    // Get updated_at inside transaction (ISO format)
    Qry := AContext.CreateQuery(
      'SELECT DATE_FORMAT(updated_at, ''%Y-%m-%d %H:%i:%s'') AS updated_at_iso ' +
      'FROM documents WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      NewUpdatedAt := Qry.FieldByName('updated_at_iso').AsString;
    finally
      Qry.Free;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  // Auto-notify related projects (non-blocking, after commit)
  var NotifyDocType := CurrentDocType;
  if DocType <> '' then NotifyDocType := DocType;
  var NotifyTitle := CurrentTitle;
  if Title <> '' then NotifyTitle := Title;
  NotifyRelatedProjects(AContext, ProjectId, DocId, NotifyDocType,
    NotifyTitle, ChangeReason, ProjectSlug);
  // Also notify target project's related projects on doc-move
  if NewProject <> '' then
    NotifyRelatedProjects(AContext, NewProjectId, DocId, NotifyDocType,
      NotifyTitle, 'Document moved from ' + ProjectSlug, NewProject);

  Data := TJSONObject.Create;
  try
    Data.AddPair('success', TJSONBool.Create(True));
    Data.AddPair('updated_at', NewUpdatedAt);
    if NewProject <> '' then
      Data.AddPair('moved_to', NewProject);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_delete_doc — Soft-delete a document
// ---------------------------------------------------------------------------
function HandleDeleteDoc(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId: Integer;
  Data: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  AContext.StartTransaction;
  try
    // Verify document exists, get project for ACL
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Document not found or already deleted: ' +
          IntToStr(DocId));

      // ACL: check write access to the document's project
      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alWrite) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alWrite);
    finally
      Qry.Free;
    end;

    // Soft-delete
    Qry := AContext.CreateQuery(
      'UPDATE documents SET status = ''deleted'' WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('success', TJSONBool.Create(True));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// Tags, Relations, InitProject, NextAdr → mx.Tool.Write.Meta
// BatchCreate, BatchUpdate → mx.Tool.Write.Batch

// Tags, Relations, InitProject, NextAdr → mx.Tool.Write.Meta
// BatchCreate, BatchUpdate → mx.Tool.Write.Batch

// ---------------------------------------------------------------------------
// mx_refresh_summaries — Re-generate summaries for all docs in a project
// ---------------------------------------------------------------------------
function HandleRefreshSummaries(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry, UpdQry: TFDQuery;
  ProjectSlug, Content, OldL1, NewL1, NewL2: string;
  ProjectId, Updated, Skipped, DocId: Integer;
  Data: TJSONObject;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsString := ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
  if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alWrite);
  Updated := 0;
  Skipped := 0;
  Qry := AContext.CreateQuery(
    'SELECT id, summary_l1, content FROM documents ' +
    'WHERE project_id = :pid AND status <> ''deleted'' AND content <> ''''');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.Open;
    while not Qry.Eof do
    begin
      DocId := Qry.FieldByName('id').AsInteger;
      OldL1 := Qry.FieldByName('summary_l1').AsString;
      Content := Qry.FieldByName('content').AsString;
      NewL1 := ExtractFirstSentence(Content);
      NewL2 := ExtractFirstSentences(Content, 3);
      if (NewL1 <> '') and (NewL1 <> OldL1) then
      begin
        UpdQry := AContext.CreateQuery(
          'UPDATE documents SET summary_l1 = :l1, summary_l2 = :l2 WHERE id = :id');
        try
          // Bug#2738: clamp to VARCHAR(500) — ExtractFirstSentence already
          // clamps but belt-and-suspenders for the direct-input path shape
          UpdQry.ParamByName('l1').AsString := ClampSummary(NewL1);
          UpdQry.ParamByName('l2').AsString := NewL2;
          UpdQry.ParamByName('id').AsInteger := DocId;
          UpdQry.ExecSQL;
          Inc(Updated);
        finally
          UpdQry.Free;
        end;
      end
      else
        Inc(Skipped);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  Data := TJSONObject.Create;
  try
    Data.AddPair('updated', TJSONNumber.Create(Updated));
    Data.AddPair('skipped', TJSONNumber.Create(Skipped));
    Data.AddPair('project', ProjectSlug);
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

end.
