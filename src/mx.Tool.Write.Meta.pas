unit mx.Tool.Write.Meta;

interface

uses
  System.SysUtils, System.JSON, System.Variants, System.StrUtils, System.DateUtils,
  Data.DB,
  FireDAC.Comp.Client, FireDAC.Stan.Error,
  mx.Types, mx.Errors;

function HandleAddTags(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleRemoveTags(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleAddRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleRemoveRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleInitProject(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleNextAdrNumber(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  mx.Tool.Write,
  mx.Logic.AccessControl;

// ---------------------------------------------------------------------------
// mx_init_project — Register a project
// ---------------------------------------------------------------------------
function HandleInitProject(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  Slug, Name, Path, SvnUrl: string;
  ProjectId, CallerDevId: Integer;
  Data: TJSONObject;
begin
  Slug := AParams.GetValue<string>('slug', '');
  Name := AParams.GetValue<string>('project_name', '');
  Path := AParams.GetValue<string>('path', '');
  SvnUrl := AParams.GetValue<string>('svn_url', '');

  if Slug = '' then
    raise EMxValidation.Create('Parameter "slug" is required');
  if Name = '' then
    raise EMxValidation.Create('Parameter "name" is required');
  if Slug = '_global' then
    raise EMxValidation.Create('Reserved slug');

  CallerDevId := AContext.AccessControl.GetDeveloperId;
  if CallerDevId <= 0 then
    raise EMxAuthError.Create('Authentication required');

  AContext.StartTransaction;
  try
    // Bug#2228: only revive soft-deleted projects owned by the caller.
    Qry := AContext.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug AND is_active = FALSE ' +
      '  AND created_by_developer_id = :caller_dev_id');
    try
      Qry.ParamByName('slug').AsWideString :=Slug;
      Qry.ParamByName('caller_dev_id').AsInteger := CallerDevId;
      Qry.Open;
      if not Qry.IsEmpty then
        ProjectId := Qry.FieldByName('id').AsInteger
      else
        ProjectId := 0;
    finally
      Qry.Free;
    end;

    if ProjectId > 0 then
    begin
      Qry := AContext.CreateQuery(
        'UPDATE projects SET is_active = TRUE, deleted_at = NULL, ' +
        '  name = :name, path = :path WHERE id = :id');
      try
        Qry.ParamByName('name').AsWideString :=Name;
        Qry.ParamByName('path').AsWideString :=Path;
        Qry.ParamByName('id').AsInteger := ProjectId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    end
    else
    begin
      // Bug#2228: pre-check whether slug is taken globally so that we can
      // return a clean EMxConflict instead of a MariaDB
      // "Duplicate entry '<slug>' for key 'uq_project_slug'" error that
      // would leak the slug name and let callers enumerate foreign projects.
      Qry := AContext.CreateQuery(
        'SELECT 1 FROM projects WHERE slug = :slug LIMIT 1');
      try
        Qry.ParamByName('slug').AsWideString :=Slug;
        Qry.Open;
        if not Qry.IsEmpty then
          raise EMxConflict.Create('Slug unavailable');
      finally
        Qry.Free;
      end;

      Qry := AContext.CreateQuery(
        'INSERT INTO projects (slug, name, path, svn_url, created_by, created_by_developer_id) ' +
        'VALUES (:slug, :name, :path, :svn_url, :created_by, :created_by_dev_id)');
      try
        Qry.ParamByName('slug').AsWideString :=Slug;
        Qry.ParamByName('name').AsWideString :=Name;
        Qry.ParamByName('path').AsWideString :=Path;
        if SvnUrl <> '' then
          Qry.ParamByName('svn_url').AsWideString :=SvnUrl
        else
        begin
          Qry.ParamByName('svn_url').DataType := ftString;
          Qry.ParamByName('svn_url').Value := Null;
        end;
        Qry.ParamByName('created_by').AsWideString :=AContext.AccessControl.GetDeveloperName;
        Qry.ParamByName('created_by_dev_id').AsInteger := CallerDevId;
        try
          Qry.ExecSQL;
        except
          // Race fallback: another tx inserted the same slug between our
          // pre-check and ExecSQL. Re-raise as clean EMxConflict so the
          // MariaDB error with the slug name never reaches the caller.
          on E: EFDDBEngineException do
            if E.Kind = ekUKViolated then
              raise EMxConflict.Create('Slug unavailable')
            else
              raise;
        end;
      finally
        Qry.Free;
      end;

      Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS id');
      try
        Qry.Open;
        ProjectId := Qry.FieldByName('id').AsInteger;
      finally
        Qry.Free;
      end;
    end;

    Qry := AContext.CreateQuery(
      'INSERT IGNORE INTO developer_project_access ' +
      '(developer_id, project_id, access_level) VALUES (:dev_id, :proj_id, :level)');
    try
      Qry.ParamByName('dev_id').AsInteger := CallerDevId;
      Qry.ParamByName('proj_id').AsInteger := ProjectId;
      Qry.ParamByName('level').AsWideString :='write';
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    if (Path <> '') and (MxGetThreadAuth.KeyId > 0) then
    begin
      Qry := AContext.CreateQuery(
        'INSERT INTO developer_environments (client_key_id, project_id, env_key, env_value) ' +
        'VALUES (:key_id, :proj_id, ''project_path'', :val) ' +
        'ON DUPLICATE KEY UPDATE env_value = :val2');
      try
        Qry.ParamByName('key_id').AsInteger := MxGetThreadAuth.KeyId;
        Qry.ParamByName('proj_id').AsInteger := ProjectId;
        Qry.ParamByName('val').AsWideString :=Path;
        Qry.ParamByName('val2').AsWideString :=Path;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;
    end;

    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('project_id', TJSONNumber.Create(ProjectId));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_add_tags — Add tags to a document
// ---------------------------------------------------------------------------
function HandleAddTags(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, I, Added: Integer;
  TagsVal: TJSONValue;
  TagsArr: TJSONArray;
  Tag: string;
  Data: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  TagsVal := AParams.GetValue('tags');
  if (TagsVal = nil) or not (TagsVal is TJSONArray) then
    raise EMxValidation.Create('Parameter "tags" must be a JSON array');
  TagsArr := TJSONArray(TagsVal);
  if TagsArr.Count = 0 then
    raise EMxValidation.Create('Parameter "tags" must not be empty');

  Added := 0;
  AContext.StartTransaction;
  try
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));

      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alReadWrite) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alReadWrite);
    finally
      Qry.Free;
    end;

    for I := 0 to TagsArr.Count - 1 do
    begin
      if not (TagsArr.Items[I] is TJSONString) then
        Continue;
      Tag := Trim(TagsArr.Items[I].Value);
      if Tag = '' then
        Continue;
      if Length(Tag) > 50 then
        raise EMxValidation.Create('Tag too long (max 50 chars): ' + Tag);

      Qry := AContext.CreateQuery(
        'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
      try
        Qry.ParamByName('doc_id').AsInteger := DocId;
        Qry.ParamByName('tag').AsWideString :=Tag;
        Qry.ExecSQL;
        Added := Added + Qry.RowsAffected;
      finally
        Qry.Free;
      end;
    end;
    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('added', TJSONNumber.Create(Added));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_remove_tags — Remove tags from a document
// ---------------------------------------------------------------------------
function HandleRemoveTags(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  DocId, I, Removed: Integer;
  TagsVal: TJSONValue;
  TagsArr: TJSONArray;
  Tag: string;
  Data: TJSONObject;
begin
  DocId := AParams.GetValue<Integer>('doc_id', 0);
  if DocId = 0 then
    raise EMxValidation.Create('Parameter "doc_id" is required');

  TagsVal := AParams.GetValue('tags');
  if (TagsVal = nil) or not (TagsVal is TJSONArray) then
    raise EMxValidation.Create('Parameter "tags" must be a JSON array');
  TagsArr := TJSONArray(TagsVal);
  if TagsArr.Count = 0 then
    raise EMxValidation.Create('Parameter "tags" must not be empty');

  Removed := 0;
  AContext.StartTransaction;
  try
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := DocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Document not found: ' + IntToStr(DocId));

      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alReadWrite) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alReadWrite);
    finally
      Qry.Free;
    end;

    for I := 0 to TagsArr.Count - 1 do
    begin
      if not (TagsArr.Items[I] is TJSONString) then
        Continue;
      Tag := Trim(TagsArr.Items[I].Value);
      if Tag = '' then
        Continue;

      Qry := AContext.CreateQuery(
        'DELETE FROM doc_tags WHERE doc_id = :doc_id AND tag = :tag');
      try
        Qry.ParamByName('doc_id').AsInteger := DocId;
        Qry.ParamByName('tag').AsWideString :=Tag;
        Qry.ExecSQL;
        Removed := Removed + Qry.RowsAffected;
      finally
        Qry.Free;
      end;
    end;
    AContext.Commit;
  except
    AContext.Rollback;
    raise;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('removed', TJSONNumber.Create(Removed));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_add_relation — Create a relation between two documents
// ---------------------------------------------------------------------------
function HandleAddRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  SourceDocId, TargetDocId, RelationId: Integer;
  RelationType: string;
  Data: TJSONObject;
begin
  SourceDocId := AParams.GetValue<Integer>('source_doc_id', 0);
  TargetDocId := AParams.GetValue<Integer>('target_doc_id', 0);
  RelationType := AParams.GetValue<string>('relation_type', '');

  if SourceDocId = 0 then
    raise EMxValidation.Create('Parameter "source_doc_id" is required');
  if TargetDocId = 0 then
    raise EMxValidation.Create('Parameter "target_doc_id" is required');
  if RelationType = '' then
    raise EMxValidation.Create('Parameter "relation_type" is required');

  if not MatchStr(RelationType, ['leads_to', 'implements', 'contradicts',
      'depends_on', 'supersedes', 'references', 'caused_by',
      'rejected_in_favor_of', 'assumes', 'review-on', 'promoted_from']) then
    raise EMxValidation.Create('Invalid relation_type: ' + RelationType +
      '. Must be one of: leads_to, implements, contradicts, depends_on, supersedes, references, caused_by, rejected_in_favor_of, assumes, review-on, promoted_from');

  if SourceDocId = TargetDocId then
    raise EMxValidation.Create('source_doc_id and target_doc_id must be different');

  AContext.StartTransaction;
  try
    Qry := AContext.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := SourceDocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Source document not found: ' + IntToStr(SourceDocId));

      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alReadWrite) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alReadWrite);
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery(
      'SELECT d.id, d.project_id, p.slug AS project_slug ' +
      'FROM documents d JOIN projects p ON d.project_id = p.id ' +
      'WHERE d.id = :id AND d.status <> ''deleted''');
    try
      Qry.ParamByName('id').AsInteger := TargetDocId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Target document not found: ' + IntToStr(TargetDocId));

      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alReadOnly) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alReadOnly);
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery(
      'INSERT INTO doc_relations (source_doc_id, target_doc_id, relation_type) ' +
      'VALUES (:source, :target, :rel_type)');
    try
      Qry.ParamByName('source').AsInteger := SourceDocId;
      Qry.ParamByName('target').AsInteger := TargetDocId;
      Qry.ParamByName('rel_type').AsWideString :=RelationType;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery('SELECT LAST_INSERT_ID() AS id');
    try
      Qry.Open;
      RelationId := Qry.FieldByName('id').AsInteger;
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
    Data.AddPair('relation_id', TJSONNumber.Create(RelationId));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_remove_relation — Remove a relation between documents
// ---------------------------------------------------------------------------
function HandleRemoveRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  RelationId: Integer;
  Data: TJSONObject;
begin
  RelationId := AParams.GetValue<Integer>('relation_id', 0);
  if RelationId = 0 then
    raise EMxValidation.Create('Parameter "relation_id" is required');

  AContext.StartTransaction;
  try
    Qry := AContext.CreateQuery(
      'SELECT dr.id, d.project_id, p.slug AS project_slug ' +
      'FROM doc_relations dr ' +
      'JOIN documents d ON d.id = dr.source_doc_id ' +
      'JOIN projects p ON p.id = d.project_id ' +
      'WHERE dr.id = :id');
    try
      Qry.ParamByName('id').AsInteger := RelationId;
      Qry.Open;
      if Qry.IsEmpty then
        raise EMxNotFound.Create('Relation not found: ' + IntToStr(RelationId));

      if not AContext.AccessControl.CheckProject(
        Qry.FieldByName('project_id').AsInteger, alReadWrite) then
        raise EMxAccessDenied.Create(
          Qry.FieldByName('project_slug').AsString, alReadWrite);
    finally
      Qry.Free;
    end;

    Qry := AContext.CreateQuery(
      'DELETE FROM doc_relations WHERE id = :id');
    try
      Qry.ParamByName('id').AsInteger := RelationId;
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

// ---------------------------------------------------------------------------
// mx_next_adr_number — Get next free ADR number for a project
// ---------------------------------------------------------------------------
function HandleNextAdrNumber(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ProjectSlug: string;
  ProjectId, MaxNum: Integer;
  Data: TJSONObject;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  if ProjectSlug = '' then
    raise EMxValidation.Create('Parameter "project" is required');

  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsWideString :=ProjectSlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create('Project not found: ' + ProjectSlug);
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;

  if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

  Qry := AContext.CreateQuery(
    'SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(slug, ''-'', 2), ''-'', -1) ' +
    '  AS UNSIGNED)), 0) AS max_num ' +
    'FROM documents WHERE project_id = :pid AND doc_type = ''decision'' ' +
    '  AND status <> ''deleted''');
  try
    Qry.ParamByName('pid').AsInteger := ProjectId;
    Qry.Open;
    MaxNum := Qry.FieldByName('max_num').AsInteger;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('next_number', TJSONNumber.Create(MaxNum + 1));
    Data.AddPair('formatted', Format('ADR-%4.4d', [MaxNum + 1]));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

end.
