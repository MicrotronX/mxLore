unit mx.Tool.Notes;

// FR#2936/Plan#3266 M2.4 — Review-Note creation with alComment ACL floor,
// tag-whitelist, hybrid parent-relation (relations + root_parent_doc_id + depth),
// body soft/hard limits, depth recursion-guard.
//
// Legacy HandleListNotes retained for backward compatibility (not registered
// as MCP tool — mx_list_notes removed in B6.2, use mx_search).
//
// Scope: doc_type='note' ONLY with tag in the review-* whitelist.
// General note creation stays in mx_create_doc (alReadWrite floor).

interface

uses
  System.SysUtils, System.StrUtils, System.Variants, System.JSON, Data.DB,
  FireDAC.Comp.Client, FireDAC.Stan.Error,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function HandleCreateNote(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleUpdateNote(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleListNotes(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  System.DateUtils, System.SyncObjs, System.Generics.Collections,
  mx.Tool.Write;

const
  BODY_SOFT_LIMIT = 2000;
  BODY_HARD_LIMIT = 8000;
  DEPTH_HARD_LIMIT = 10;
  DEPTH_WARN_THRESHOLD = 5;
  REVIEW_TAGS: array[0..3] of string = (
    'review-comment', 'review-question', 'review-approval', 'review-block');

  // FR#2936/Plan#3266 M2.7: Token-Bucket per developer.
  // 50 writes per 10h, in-memory (single-instance v1 — see Spec#3194 Non-Goal
  // and Plan#3266 RF-3 for multi-instance carry-forward).
  RATE_LIMIT_WINDOW_SEC = 10 * 3600;
  RATE_LIMIT_MAX_WRITES = 50;

type
  TNoteBucket = record
    FirstWriteAt: TDateTime;
    Count: Integer;
  end;

var
  gNoteBuckets    : TDictionary<Integer, TNoteBucket>;
  gNoteBucketLock : TCriticalSection;

// Atomic check + increment. Anonymous/internal callers (CallerId=0) bypass.
// Raises EMxError 'rate_limit_exceeded' if bucket is full inside the rolling
// window. Window resets when first write is older than RATE_LIMIT_WINDOW_SEC.
procedure CheckAndConsumeNoteBucket(ACallerDevId: Integer);
var
  Bucket  : TNoteBucket;
  Found   : Boolean;
  AgeSec  : Int64;
begin
  if ACallerDevId <= 0 then Exit;  // anonymous/internal bypass
  gNoteBucketLock.Enter;
  try
    Found := gNoteBuckets.TryGetValue(ACallerDevId, Bucket);
    if Found then
    begin
      AgeSec := SecondsBetween(Now, Bucket.FirstWriteAt);
      if AgeSec > RATE_LIMIT_WINDOW_SEC then
      begin
        // Window expired — reset the bucket.
        Bucket.FirstWriteAt := Now;
        Bucket.Count := 0;
      end;
    end
    else
    begin
      Bucket.FirstWriteAt := Now;
      Bucket.Count := 0;
    end;

    if Bucket.Count >= RATE_LIMIT_MAX_WRITES then
      // mxBugChecker WARN#2: HTTP 429 Too Many Requests, not the default 500.
      raise EMxError.Create('rate_limit_exceeded',
        Format('Note write rate-limit exceeded (%d / %dh per developer). Try again later.',
          [RATE_LIMIT_MAX_WRITES, RATE_LIMIT_WINDOW_SEC div 3600]),
        429);

    Inc(Bucket.Count);
    gNoteBuckets.AddOrSetValue(ACallerDevId, Bucket);
  finally
    gNoteBucketLock.Leave;
  end;
end;

// ---------------------------------------------------------------------------
// HandleCreateNote — Review-Note with alComment ACL floor.
// ---------------------------------------------------------------------------
function HandleCreateNote(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Title, Body, ProjectSlug, Slug, BaseSlug, Tag: string;
  TagsArr, Warnings: TJSONArray;
  ProjectId, DocId, Attempt, ParentDocId, RootParentDocId, Depth,
    ParentDepth, ParentProjectId, BodyLen, I: Integer;
  Qry: TFDQuery;
  TagVal: TJSONValue;
  AuthCtx: TAuthContext;
  AuthRes: TAuthResult;
  HasValidTag: Boolean;
begin
  // --- Extract parameters
  Title := '';
  Body := '';
  ProjectSlug := '';
  ParentDocId := 0;

  if AParams.GetValue('title') <> nil then
    Title := AParams.GetValue<string>('title', '');
  if AParams.GetValue('body') <> nil then
    Body := AParams.GetValue<string>('body', '');
  if (Body = '') and (AParams.GetValue('content') <> nil) then
    Body := AParams.GetValue<string>('content', '');
  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '');
  if AParams.GetValue('parent_doc_id') <> nil then
    ParentDocId := AParams.GetValue<Integer>('parent_doc_id', 0);

  TagsArr := nil;
  if (AParams.GetValue('tags') <> nil) and (AParams.GetValue('tags') is TJSONArray) then
    TagsArr := AParams.GetValue('tags') as TJSONArray;

  // --- Basic validation
  if Title.Trim = '' then
    raise EMxError.Create('missing_title', 'title is required');
  if Body.Trim = '' then
    raise EMxError.Create('missing_body', 'body (or content) is required');
  if ProjectSlug = '' then
    raise EMxError.Create('missing_project', 'project is required');
  if ParentDocId = 0 then
    raise EMxError.Create('missing_parent',
      'parent_doc_id is required (review-note must attach to an existing doc)');

  BodyLen := Length(Body);
  if BodyLen > BODY_HARD_LIMIT then
    raise EMxError.Create('body_too_large',
      Format('body exceeds hard limit (%d > %d chars)', [BodyLen, BODY_HARD_LIMIT]));

  // --- Tag-Whitelist: at least one review-* tag required
  HasValidTag := False;
  if TagsArr <> nil then
  begin
    for I := 0 to TagsArr.Count - 1 do
    begin
      if TagsArr.Items[I] is TJSONString then
      begin
        Tag := TJSONString(TagsArr.Items[I]).Value;
        if MatchStr(Tag, REVIEW_TAGS) then
        begin
          HasValidTag := True;
          Break;
        end;
      end;
    end;
  end;
  if not HasValidTag then
    raise EMxError.Create('missing_review_tag',
      'tags must include one of: review-comment, review-question, review-approval, review-block');

  // --- Resolve project
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsWideString :=ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('project_not_found', 'Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  // --- Authorize (alComment floor via MASTER_MAP; Plan#3266 CI rule: new handlers
  //     use Authorize, not direct CheckProject).
  AuthCtx.Tool := 'mx_create_note';
  AuthCtx.CallerId := AContext.AccessControl.GetDeveloperId;
  AuthCtx.ProjectId := ProjectId;
  AuthCtx.RequiredLevel := alComment;
  AuthRes := Authorize(AuthCtx, AContext);
  if not AuthRes.Allowed then
    raise EMxAccessDenied.Create(ProjectSlug, alComment);

  // --- M2.7 Token-Bucket: 50 writes / 10h per developer (in-memory v1).
  CheckAndConsumeNoteBucket(AuthCtx.CallerId);

  // --- Parent resolution + depth/root-parent computation
  Qry := AContext.CreateQuery(
    'SELECT project_id, depth, root_parent_doc_id ' +
    'FROM documents WHERE id = :id AND status <> ''deleted''');
  try
    Qry.ParamByName('id').AsInteger := ParentDocId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('parent_not_found',
        'Parent document not found: ' + IntToStr(ParentDocId));
    ParentProjectId := Qry.FieldByName('project_id').AsInteger;
    if ParentProjectId <> ProjectId then
      raise EMxError.Create('parent_cross_project',
        'Parent document is in a different project (cross-project review prohibited)');
    ParentDepth := Qry.FieldByName('depth').AsInteger;
    if not Qry.FieldByName('root_parent_doc_id').IsNull and (ParentDepth > 0) then
      RootParentDocId := Qry.FieldByName('root_parent_doc_id').AsInteger
    else
      RootParentDocId := ParentDocId;
  finally
    Qry.Free;
  end;

  Depth := ParentDepth + 1;
  if Depth > DEPTH_HARD_LIMIT then
    raise EMxError.Create('depth_limit_exceeded',
      Format('Note depth %d exceeds hard limit %d (flatten the thread)',
        [Depth, DEPTH_HARD_LIMIT]));

  // --- Slug generation
  BaseSlug := GenerateSlug(Title);
  if Length(BaseSlug) > 100 then
    BaseSlug := Copy(BaseSlug, 1, 100);
  Slug := BaseSlug;

  // --- Collect warnings (non-fatal)
  Warnings := TJSONArray.Create;
  try
    if BodyLen > BODY_SOFT_LIMIT then
      Warnings.Add(Format('body exceeds soft limit (%d > %d chars) — consider splitting',
        [BodyLen, BODY_SOFT_LIMIT]));
    if Depth >= DEPTH_WARN_THRESHOLD then
      Warnings.Add(Format('thread depth %d is high (>= %d) — consider flattening',
        [Depth, DEPTH_WARN_THRESHOLD]));

    AContext.StartTransaction;
    try
      // --- INSERT document with slug-collision retry loop
      DocId := 0;
      for Attempt := 0 to 9 do
      begin
        if Attempt > 0 then
          Slug := BaseSlug + '-' + IntToStr(Attempt + 1);
        try
          Qry := AContext.CreateQuery(
            'INSERT INTO documents (project_id, slug, title, content, doc_type, status, ' +
            '  depth, root_parent_doc_id, created_by_developer_id) ' +
            'VALUES (:proj_id, :slug, :title, :content, ''note'', ''draft'', ' +
            '  :depth, :root_parent, :dev_id)');
          try
            Qry.ParamByName('proj_id').AsInteger := ProjectId;
            Qry.ParamByName('slug').AsWideString :=Slug;
            Qry.ParamByName('title').AsWideString :=Title;
            BindLargeText(Qry.ParamByName('content'), Body);
            Qry.ParamByName('depth').AsInteger := Depth;
            Qry.ParamByName('root_parent').AsInteger := RootParentDocId;
            // FR#2936/Plan#3266 M2.5 prereq — author-FK for Edit-Window match.
            if AuthCtx.CallerId > 0 then
              Qry.ParamByName('dev_id').AsInteger := AuthCtx.CallerId
            else
              Qry.ParamByName('dev_id').Clear;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;
          Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS id');
          try
            Qry.Open;
            DocId := Qry.FieldByName('id').AsInteger;
          finally
            Qry.Free;
          end;
          Break;
        except
          on E: EFDDBEngineException do
            if (E.Kind = ekUKViolated) and (Attempt < 9) then
              Continue
            else
              raise;
        end;
      end;

      // --- Insert tags (all of them — not just the review-* one)
      for I := 0 to TagsArr.Count - 1 do
      begin
        TagVal := TagsArr.Items[I];
        if TagVal is TJSONString then
        begin
          Qry := AContext.CreateQuery(
            'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
          try
            Qry.ParamByName('doc_id').AsInteger := DocId;
            Qry.ParamByName('tag').AsWideString :=TJSONString(TagVal).Value;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;
        end;
      end;

      // --- Hybrid parent-relation: insert review-on relation
      //     (denormalized depth + root_parent_doc_id already set on the note row above)
      Qry := AContext.CreateQuery(
        'INSERT INTO doc_relations (source_doc_id, target_doc_id, relation_type) ' +
        'VALUES (:src, :tgt, ''review-on'')');
      try
        Qry.ParamByName('src').AsInteger := DocId;
        Qry.ParamByName('tgt').AsInteger := ParentDocId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      AContext.Commit;
    except
      AContext.Rollback;
      raise;
    end;

    Result := TJSONObject.Create;
    Result.AddPair('ok', TJSONBool.Create(True));
    Result.AddPair('doc_id', TJSONNumber.Create(DocId));
    Result.AddPair('slug', Slug);
    Result.AddPair('depth', TJSONNumber.Create(Depth));
    Result.AddPair('root_parent_doc_id', TJSONNumber.Create(RootParentDocId));
    Result.AddPair('parent_doc_id', TJSONNumber.Create(ParentDocId));
    if Warnings.Count > 0 then
      Result.AddPair('warnings', Warnings)
    else
      Warnings.Free;
  except
    Warnings.Free;
    raise;
  end;
end;

// Helper: comma-list of field-names that change in an update — used in audit
// `change_reason`. Order is title, body, tags. Returns 'none' when all flags
// are False (defensive — caller should never invoke with no change at all).
function ChangeFieldList(AHasTitle, AHasBody, AHasTags: Boolean): string;
begin
  Result := '';
  if AHasTitle then Result := 'title';
  if AHasBody then
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + 'body';
  end;
  if AHasTags then
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + 'tags';
  end;
  if Result = '' then Result := 'none';
end;

// ---------------------------------------------------------------------------
// HandleUpdateNote — Edit existing review-note within Edit-Window.
//
// Edit-Window logic (Plan#3266 M2.5):
//   age = NOW - documents.created_at
//   age > 24h        -> reject 'note_locked' (hard-lock, no one)
//   admin (IsAdmin)  -> allow within 24h
//   author + age<=60min -> allow
//   else             -> reject 'edit_window_expired' (suggest mx_create_note reply)
//
// Author identification uses created_by_developer_id FK (sql/048).
// Allowed update fields: title, content (alias body), tags. Other fields
// (doc_type, status, project, parent) are immutable to preserve thread invariants.
// ---------------------------------------------------------------------------
function HandleUpdateNote(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  DocId, AgeSeconds, AuthorDevId, ProjectId, BodyLen,
    NextRevision, I: Integer;
  Title, Body, Tag, DocType, ProjectSlug, Status: string;
  HasTitle, HasBody, HasTags, HasValidTag, IsAdmin, IsAuthor, AuthorIsNull: Boolean;
  TagsArr, Warnings: TJSONArray;
  Qry: TFDQuery;
  TagVal: TJSONValue;
  AuthCtx: TAuthContext;
  AuthRes: TAuthResult;
  CallerDevId: Integer;
  UpdateSQL: string;
begin
  // --- Extract parameters
  if AParams.GetValue('doc_id') = nil then
    raise EMxError.Create('missing_doc_id', 'doc_id is required');
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId <= 0 then
    raise EMxError.Create('invalid_doc_id', 'doc_id must be a positive integer');

  HasTitle := AParams.GetValue('title') <> nil;
  HasBody := (AParams.GetValue('body') <> nil) or (AParams.GetValue('content') <> nil);
  HasTags := (AParams.GetValue('tags') <> nil) and
             (AParams.GetValue('tags') is TJSONArray);

  if not (HasTitle or HasBody or HasTags) then
    raise EMxError.Create('no_changes',
      'at least one of title, body/content, tags must be provided');

  Title := '';
  Body := '';
  if HasTitle then
    Title := AParams.GetValue<string>('title', '');
  if HasBody then
  begin
    if AParams.GetValue('body') <> nil then
      Body := AParams.GetValue<string>('body', '')
    else
      Body := AParams.GetValue<string>('content', '');
  end;

  TagsArr := nil;
  if HasTags then
    TagsArr := AParams.GetValue('tags') as TJSONArray;

  if HasTitle and (Title.Trim = '') then
    raise EMxError.Create('invalid_title', 'title may not be empty');
  if HasBody and (Body.Trim = '') then
    raise EMxError.Create('invalid_body', 'body/content may not be empty');

  if HasBody then
  begin
    BodyLen := Length(Body);
    if BodyLen > BODY_HARD_LIMIT then
      raise EMxError.Create('body_too_large',
        Format('body exceeds hard limit (%d > %d chars)',
          [BodyLen, BODY_HARD_LIMIT]));
  end
  else
    BodyLen := 0;

  // --- Tag re-validation (only when tags are being replaced)
  if HasTags then
  begin
    HasValidTag := False;
    for I := 0 to TagsArr.Count - 1 do
      if TagsArr.Items[I] is TJSONString then
      begin
        Tag := TJSONString(TagsArr.Items[I]).Value;
        if MatchStr(Tag, REVIEW_TAGS) then
        begin
          HasValidTag := True;
          Break;
        end;
      end;
    if not HasValidTag then
      raise EMxError.Create('missing_review_tag',
        'tags must include one of: review-comment, review-question, review-approval, review-block');
  end;

  // --- Lookup target doc + Edit-Window data
  Qry := AContext.CreateQuery(
    'SELECT d.project_id, d.doc_type, d.status, ' +
    '  d.created_by_developer_id, p.slug AS project_slug, ' +
    '  TIMESTAMPDIFF(SECOND, d.created_at, NOW()) AS age_seconds ' +
    'FROM documents d ' +
    'JOIN projects p ON p.id = d.project_id ' +
    'WHERE d.id = :id');
  try
    Qry.ParamByName('id').AsInteger := DocId;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('doc_not_found',
        'Document not found: ' + IntToStr(DocId));
    ProjectId := Qry.FieldByName('project_id').AsInteger;
    DocType := Qry.FieldByName('doc_type').AsString;
    Status := Qry.FieldByName('status').AsString;
    AuthorIsNull := Qry.FieldByName('created_by_developer_id').IsNull;
    if AuthorIsNull then
      AuthorDevId := 0
    else
      AuthorDevId := Qry.FieldByName('created_by_developer_id').AsInteger;
    ProjectSlug := Qry.FieldByName('project_slug').AsString;
    AgeSeconds := Qry.FieldByName('age_seconds').AsInteger;
  finally
    Qry.Free;
  end;

  if DocType <> 'note' then
    raise EMxError.Create('not_a_note',
      Format('mx_update_note can only edit notes (doc_type=note), got "%s" — use mx_update_doc instead',
        [DocType]));
  if Status = 'deleted' then
    raise EMxError.Create('doc_deleted', 'Cannot update a deleted document');

  // --- Authorize (alComment floor — caller must at least be commenter on the project)
  AuthCtx.Tool := 'mx_update_note';
  CallerDevId := AContext.AccessControl.GetDeveloperId;
  AuthCtx.CallerId := CallerDevId;
  AuthCtx.ProjectId := ProjectId;
  AuthCtx.RequiredLevel := alComment;
  AuthRes := Authorize(AuthCtx, AContext);
  if not AuthRes.Allowed then
    raise EMxAccessDenied.Create(ProjectSlug, alComment);

  // --- M2.7 Token-Bucket: shared with create-path (50 writes / 10h per dev).
  CheckAndConsumeNoteBucket(CallerDevId);

  // --- Edit-Window enforcement
  IsAdmin := AContext.AccessControl.IsAdmin;
  IsAuthor := (not AuthorIsNull) and (AuthorDevId > 0) and (AuthorDevId = CallerDevId);

  // 24h hard-lock — applies to everyone, even admins
  if AgeSeconds > 24 * 3600 then
    raise EMxError.Create('note_locked',
      Format('Note is locked: age %d s > 24h hard-lock. Reply with mx_create_note instead.',
        [AgeSeconds]));

  // Within 24h: admin always allowed (moderation window)
  if not IsAdmin then
  begin
    // Non-admin: must be author AND within 60min
    if not IsAuthor then
      raise EMxError.Create('not_author',
        'Only the original author or an admin may edit this note within 24h');
    if AgeSeconds > 60 * 60 then
      raise EMxError.Create('edit_window_expired',
        Format('Author edit-window expired (age %d s > 60min). Reply with mx_create_note instead.',
          [AgeSeconds]));
  end;

  // mxBugChecker WARN#1: row-lock the document for the entire transaction so
  // concurrent updates serialise on MAX(revision)+1 and tag-replacement.
  // mxDesignChecker WARN#1: log every admin edit past their own 60min window
  // (or where caller is not author) as 'admin-edit', not 'author-edit'.
  // mxDesignChecker INFO#3: tag-only edits also create a revision row for audit.
  Warnings := TJSONArray.Create;
  try
    AContext.StartTransaction;
    try
      // Serialisation lock — concurrent edits to same note now wait for commit.
      Qry := AContext.CreateQuery(
        'SELECT 1 FROM documents WHERE id = :id FOR UPDATE');
      try
        Qry.ParamByName('id').AsInteger := DocId;
        Qry.Open;
      finally
        Qry.Free;
      end;

      // --- UPDATE document (only when title or content changes)
      if HasTitle or HasBody then
      begin
        UpdateSQL := 'UPDATE documents SET ';
        if HasTitle then
          UpdateSQL := UpdateSQL + 'title = :title';
        if HasTitle and HasBody then
          UpdateSQL := UpdateSQL + ', ';
        if HasBody then
          UpdateSQL := UpdateSQL + 'content = :content';
        UpdateSQL := UpdateSQL + ' WHERE id = :id';

        Qry := AContext.CreateQuery(UpdateSQL);
        try
          Qry.ParamByName('id').AsInteger := DocId;
          if HasTitle then
            Qry.ParamByName('title').AsWideString :=Title;
          if HasBody then
            BindLargeText(Qry.ParamByName('content'), Body);
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      end;

      // --- Tag replacement: DELETE all then INSERT new set
      if HasTags then
      begin
        Qry := AContext.CreateQuery(
          'DELETE FROM doc_tags WHERE doc_id = :id');
        try
          Qry.ParamByName('id').AsInteger := DocId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
        for I := 0 to TagsArr.Count - 1 do
        begin
          TagVal := TagsArr.Items[I];
          if TagVal is TJSONString then
          begin
            Qry := AContext.CreateQuery(
              'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
            try
              Qry.ParamByName('doc_id').AsInteger := DocId;
              Qry.ParamByName('tag').AsWideString :=TJSONString(TagVal).Value;
              Qry.ExecSQL;
            finally
              Qry.Free;
            end;
          end;
        end;
      end;

      // --- Audit-trail: one revision row per edit (covers title, body, tags-only).
      Qry := AContext.CreateQuery(
        'SELECT COALESCE(MAX(revision), 0) + 1 AS next_rev ' +
        'FROM doc_revisions WHERE doc_id = :id');
      try
        Qry.ParamByName('id').AsInteger := DocId;
        Qry.Open;
        NextRevision := Qry.FieldByName('next_rev').AsInteger;
      finally
        Qry.Free;
      end;

      Qry := AContext.CreateQuery(
        'INSERT INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
        '  changed_by, change_reason) ' +
        'VALUES (:doc_id, :rev, :content, NULL, :changed_by, :reason)');
      try
        Qry.ParamByName('doc_id').AsInteger := DocId;
        Qry.ParamByName('rev').AsInteger := NextRevision;
        if HasBody then
          BindLargeText(Qry.ParamByName('content'), Body)
        else
        begin
          // Lesson#2930: FireDAC needs a DataType hint before Clear (otherwise
          // raises -335 "Datentyp des Parameters ist unbekannt").
          Qry.ParamByName('content').DataType := ftWideMemo;
          Qry.ParamByName('content').Clear;
        end;
        Qry.ParamByName('changed_by').AsWideString :='mx_update_note';
        // Audit label: admin-moderation = caller is admin AND (not the author OR past
        // own 60min window). Pure author-edit = caller is author within own window.
        if IsAdmin and ((not IsAuthor) or (AgeSeconds > 60 * 60)) then
          Qry.ParamByName('reason').AsWideString :=
            Format('admin-edit by dev_id=%d (age %d s, fields: %s)',
              [CallerDevId, AgeSeconds, ChangeFieldList(HasTitle, HasBody, HasTags)])
        else
          Qry.ParamByName('reason').AsWideString :=
            Format('author-edit (age %d s, fields: %s)',
              [AgeSeconds, ChangeFieldList(HasTitle, HasBody, HasTags)]);
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      AContext.Commit;
    except
      AContext.Rollback;
      raise;
    end;

    // --- Build response
    if HasBody and (BodyLen > BODY_SOFT_LIMIT) then
      Warnings.Add(Format('body exceeds soft limit (%d > %d chars) - consider splitting',
        [BodyLen, BODY_SOFT_LIMIT]));

    Result := TJSONObject.Create;
    Result.AddPair('ok', TJSONBool.Create(True));
    Result.AddPair('doc_id', TJSONNumber.Create(DocId));
    Result.AddPair('age_seconds', TJSONNumber.Create(AgeSeconds));
    Result.AddPair('revision', TJSONNumber.Create(NextRevision));
    Result.AddPair('edited_by',
      IfThen(IsAdmin and ((not IsAuthor) or (AgeSeconds > 60 * 60)),
        'admin', 'author'));
    if Warnings.Count > 0 then
      Result.AddPair('warnings', Warnings)
    else
      Warnings.Free;
  except
    Warnings.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// HandleListNotes — legacy read-side for notes/bugreports/feature-requests.
// Kept for internal callers; not registered as MCP tool (use mx_search instead).
// ---------------------------------------------------------------------------
function HandleListNotes(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  ProjectSlug, Tag, SQL: string;
  Limit, DocId: Integer;
  Qry, TagQry: TFDQuery;
  Arr: TJSONArray;
  Obj: TJSONObject;
  TagArr: TJSONArray;
  ProjectId: Integer;
begin
  ProjectSlug := '';
  Tag := '';
  Limit := 50;

  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '');
  if AParams.GetValue('tag') <> nil then
    Tag := AParams.GetValue<string>('tag', '');
  if AParams.GetValue('limit') <> nil then
    Limit := AParams.GetValue<Integer>('limit', 50);
  if Limit < 1 then Limit := 1;
  if Limit > 200 then Limit := 200;

  SQL := 'SELECT d.id, d.project_id, d.title, d.slug, d.status, p.slug AS project_slug, ' +
    'd.created_at, d.updated_at ' +
    'FROM documents d JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.doc_type IN (''note'', ''bugreport'', ''feature_request'') AND d.status != ''deleted''';

  if ProjectSlug <> '' then
  begin
    Qry := AContext.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug');
    try
      Qry.ParamByName('slug').AsWideString :=ProjectSlug;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxError.Create('project_not_found', 'Project not found: ' + ProjectSlug);
      ProjectId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;
    if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
      raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);
    SQL := SQL + ' AND p.slug = :slug';
  end;

  if Tag <> '' then
    SQL := SQL + ' AND EXISTS (SELECT 1 FROM doc_tags dt WHERE dt.doc_id = d.id AND FIND_IN_SET(dt.tag, :tag) > 0)';

  SQL := SQL + ' ORDER BY d.updated_at DESC LIMIT :lim';

  Qry := AContext.CreateQuery(SQL);
  try
    if ProjectSlug <> '' then
      Qry.ParamByName('slug').AsWideString :=ProjectSlug;
    if Tag <> '' then
      Qry.ParamByName('tag').AsWideString :=Tag;
    Qry.ParamByName('lim').AsInteger := Limit;
    Qry.Open;

    Arr := TJSONArray.Create;
    try
      while not Qry.Eof do
      begin
        DocId := Qry.FieldByName('id').AsInteger;

        if ProjectSlug = '' then
        begin
          var PId := Qry.FieldByName('project_id').AsInteger;
          if not AContext.AccessControl.CheckProject(PId, alReadOnly) then
          begin
            Qry.Next;
            Continue;
          end;
        end;

        Obj := TJSONObject.Create;
        try
          Obj.AddPair('id', TJSONNumber.Create(DocId));
          Obj.AddPair('title', Qry.FieldByName('title').AsString);
          Obj.AddPair('slug', Qry.FieldByName('slug').AsString);
          Obj.AddPair('status', Qry.FieldByName('status').AsString);
          Obj.AddPair('project', Qry.FieldByName('project_slug').AsString);
          Obj.AddPair('created_at', Qry.FieldByName('created_at').AsString);
          Obj.AddPair('updated_at', Qry.FieldByName('updated_at').AsString);

          TagArr := TJSONArray.Create;
          TagQry := AContext.CreateQuery(
            'SELECT tag FROM doc_tags WHERE doc_id = :id ORDER BY tag');
          try
            TagQry.ParamByName('id').AsInteger := DocId;
            TagQry.Open;
            while not TagQry.Eof do
            begin
              TagArr.Add(TagQry.FieldByName('tag').AsString);
              TagQry.Next;
            end;
          finally
            TagQry.Free;
          end;
          Obj.AddPair('tags', TagArr);

          Arr.AddElement(Obj);
        except
          Obj.Free;
          raise;
        end;
        Qry.Next;
      end;

      Result := TJSONObject.Create;
      Result.AddPair('notes', Arr);
    except
      Arr.Free;
      raise;
    end;
  finally
    Qry.Free;
  end;
end;

initialization
  gNoteBuckets    := TDictionary<Integer, TNoteBucket>.Create;
  gNoteBucketLock := TCriticalSection.Create;

finalization
  // mxBugChecker WARN#3: free in inverse acquisition order — destroy the
  // dictionary BEFORE the lock that protects it (otherwise a late-thread
  // Enter would AV on a freed lock then operate on a freed dict).
  gNoteBuckets.Free;
  gNoteBucketLock.Free;

end.
