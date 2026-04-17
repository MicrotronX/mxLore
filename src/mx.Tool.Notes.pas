unit mx.Tool.Notes;

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

// ---------------------------------------------------------------------------
// HandleCreateNote
// ---------------------------------------------------------------------------
function HandleCreateNote(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Title, Body, ProjectSlug, Status, Slug, BaseSlug, DocType: string;
  TagsArr: TJSONArray;
  ProjectId, DocId, Attempt: Integer;
  Qry: TFDQuery;
  I: Integer;
  TagVal: TJSONValue;
  LessonData: string;
begin
  // Extract parameters
  Title := '';
  Body := '';
  ProjectSlug := '_global';
  Status := 'draft';
  DocType := 'note';
  LessonData := '';

  if AParams.GetValue('title') <> nil then
    Title := AParams.GetValue<string>('title', '');
  if AParams.GetValue('body') <> nil then
    Body := AParams.GetValue<string>('body', '');
  if AParams.GetValue('project') <> nil then
    ProjectSlug := AParams.GetValue<string>('project', '_global');
  if AParams.GetValue('status') <> nil then
    Status := AParams.GetValue<string>('status', 'draft');
  if AParams.GetValue('doc_type') <> nil then
    DocType := AParams.GetValue<string>('doc_type', 'note');

  // Validate
  if Title.Trim = '' then
    raise EMxError.Create('missing_title', 'title is required');
  if Body.Trim = '' then
    raise EMxError.Create('missing_body', 'body is required');
  if not MatchStr(DocType, ['note', 'bugreport', 'feature_request', 'todo', 'assumption', 'lesson']) then
    raise EMxError.Create('invalid_doc_type', 'doc_type must be note, bugreport, feature_request, todo, assumption or lesson');
  if not MatchStr(Status, ['draft', 'active', 'completed',
      'superseded', 'archived', 'reported', 'confirmed', 'fixed', 'rejected', 'accepted',
      'proposed', 'approved', 'implemented', 'resolved',
      'open', 'in_progress', 'done', 'deferred']) then
    raise EMxError.Create('invalid_status', 'Invalid status value');

  // Generate slug
  BaseSlug := GenerateSlug(Title);
  if Length(BaseSlug) > 100 then
    BaseSlug := Copy(BaseSlug, 1, 100);
  Slug := BaseSlug;

  // Resolve project
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

  // ACL check
  if not AContext.AccessControl.CheckProject(ProjectId, alReadWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadWrite);

  // Lesson data (optional, only for doc_type=lesson)
  if AParams.GetValue('lesson_data') <> nil then
    LessonData := AParams.GetValue<string>('lesson_data', '');

  // Tags extraction
  TagsArr := nil;
  if (AParams.GetValue('tags') <> nil) and (AParams.GetValue('tags') is TJSONArray) then
    TagsArr := AParams.GetValue('tags') as TJSONArray;

  AContext.StartTransaction;
  try
    // Insert document with slug collision handling
    DocId := 0;
    for Attempt := 0 to 9 do
    begin
      if Attempt > 0 then
        Slug := BaseSlug + '-' + IntToStr(Attempt + 1);
      try
        Qry := AContext.CreateQuery(
          'INSERT INTO documents (project_id, slug, title, content, doc_type, status, lesson_data) ' +
          'VALUES (:proj_id, :slug, :title, :content, :doc_type, :status, :lesson_data)');
        try
          Qry.ParamByName('proj_id').AsInteger := ProjectId;
          Qry.ParamByName('slug').AsString := Slug;
          Qry.ParamByName('title').AsString := Title;
          BindLargeText(Qry.ParamByName('content'), Body);
          Qry.ParamByName('doc_type').AsString := DocType;
          Qry.ParamByName('status').AsString := Status;
          if (LessonData <> '') and (DocType = 'lesson') then
            Qry.ParamByName('lesson_data').AsString := LessonData
          else
          begin
            Qry.ParamByName('lesson_data').DataType := ftString;
            Qry.ParamByName('lesson_data').Value := Null;
          end;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
        // Get inserted ID
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

    // Insert tags
    if (TagsArr <> nil) and (DocId > 0) then
    begin
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
end;

// ---------------------------------------------------------------------------
// HandleListNotes
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

  // Build query
  SQL := 'SELECT d.id, d.project_id, d.title, d.slug, d.status, p.slug AS project_slug, ' +
    'd.created_at, d.updated_at ' +
    'FROM documents d JOIN projects p ON d.project_id = p.id ' +
    'WHERE d.doc_type IN (''note'', ''bugreport'', ''feature_request'') AND d.status != ''deleted''';

  if ProjectSlug <> '' then
  begin
    // Resolve and ACL-check
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

        // ACL filter for non-project-specific queries
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

          // Load tags for this note
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
