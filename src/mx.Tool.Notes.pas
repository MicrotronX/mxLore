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
function HandleListNotes(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  mx.Tool.Write;

const
  BODY_SOFT_LIMIT = 2000;
  BODY_HARD_LIMIT = 8000;
  DEPTH_HARD_LIMIT = 10;
  DEPTH_WARN_THRESHOLD = 5;
  REVIEW_TAGS: array[0..3] of string = (
    'review-comment', 'review-question', 'review-approval', 'review-block');

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
    Qry.ParamByName('slug').AsString := ProjectSlug;
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
            '  depth, root_parent_doc_id) ' +
            'VALUES (:proj_id, :slug, :title, :content, ''note'', ''draft'', ' +
            '  :depth, :root_parent)');
          try
            Qry.ParamByName('proj_id').AsInteger := ProjectId;
            Qry.ParamByName('slug').AsString := Slug;
            Qry.ParamByName('title').AsString := Title;
            BindLargeText(Qry.ParamByName('content'), Body);
            Qry.ParamByName('depth').AsInteger := Depth;
            Qry.ParamByName('root_parent').AsInteger := RootParentDocId;
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
            Qry.ParamByName('tag').AsString := TJSONString(TagVal).Value;
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
      Qry.ParamByName('slug').AsString := ProjectSlug;
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
      Qry.ParamByName('slug').AsString := ProjectSlug;
    if Tag <> '' then
      Qry.ParamByName('tag').AsString := Tag;
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

end.
