unit mx.Tool.ProjectRelation;

interface

uses
  System.SysUtils, System.StrUtils, System.JSON,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Data.Pool, mx.Logic.AccessControl;

function HandleAddProjectRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleRemoveProjectRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// Helper: Resolve project slug to ID with ACL check
// ---------------------------------------------------------------------------
function ResolveProject(AContext: IMxDbContext; const ASlug: string;
  ALevel: TAccessLevel; const ARole: string): Integer;
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
  try
    Qry.ParamByName('slug').AsWideString :=ASlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxNotFound.Create(ARole + ' project not found: ' + ASlug);
    Result := Qry.FieldByName('id').AsInteger;
    if not AContext.AccessControl.CheckProject(Result, ALevel) then
      raise EMxAccessDenied.Create(ASlug, ALevel);
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_add_project_relation
// ---------------------------------------------------------------------------
function HandleAddProjectRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  SourceSlug, TargetSlug, RelationType: string;
  SourceId, TargetId, RelationId: Integer;
  Data: TJSONObject;
begin
  SourceSlug := AParams.GetValue<string>('source_project', '');
  TargetSlug := AParams.GetValue<string>('target_project', '');
  RelationType := AParams.GetValue<string>('relation_type', '');

  if SourceSlug = '' then
    raise EMxValidation.Create('Parameter "source_project" is required');
  if TargetSlug = '' then
    raise EMxValidation.Create('Parameter "target_project" is required');
  if RelationType = '' then
    raise EMxValidation.Create('Parameter "relation_type" is required');

  if not MatchStr(RelationType, ['depends_on', 'related_to']) then
    raise EMxValidation.Create('Invalid relation_type: ' + RelationType +
      '. Must be one of: depends_on, related_to');

  if SameText(SourceSlug, TargetSlug) then
    raise EMxValidation.Create('source_project and target_project must be different');

  AContext.StartTransaction;
  try
    // Resolve slugs to IDs with ACL (write on source, read on target)
    SourceId := ResolveProject(AContext, SourceSlug, alReadWrite, 'Source');
    TargetId := ResolveProject(AContext, TargetSlug, alReadOnly, 'Target');

    // INSERT relation
    Qry := AContext.CreateQuery(
      'INSERT INTO project_relations (source_project_id, target_project_id, relation_type) ' +
      'VALUES (:source, :target, :rel_type)');
    try
      Qry.ParamByName('source').AsInteger := SourceId;
      Qry.ParamByName('target').AsInteger := TargetId;
      Qry.ParamByName('rel_type').AsWideString :=RelationType;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    // Get auto-generated ID
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
// mx_remove_project_relation
// ---------------------------------------------------------------------------
function HandleRemoveProjectRelation(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  SourceSlug, TargetSlug, RelationType: string;
  SourceId, TargetId, Affected: Integer;
  Data: TJSONObject;
begin
  SourceSlug := AParams.GetValue<string>('source_project', '');
  TargetSlug := AParams.GetValue<string>('target_project', '');
  RelationType := AParams.GetValue<string>('relation_type', '');

  if SourceSlug = '' then
    raise EMxValidation.Create('Parameter "source_project" is required');
  if TargetSlug = '' then
    raise EMxValidation.Create('Parameter "target_project" is required');
  if RelationType = '' then
    raise EMxValidation.Create('Parameter "relation_type" is required');

  // Resolve slugs (write on source, read on target)
  SourceId := ResolveProject(AContext, SourceSlug, alReadWrite, 'Source');
  TargetId := ResolveProject(AContext, TargetSlug, alReadOnly, 'Target');

  Qry := AContext.CreateQuery(
    'DELETE FROM project_relations ' +
    'WHERE source_project_id = :source AND target_project_id = :target ' +
    '  AND relation_type = :rel_type');
  try
    Qry.ParamByName('source').AsInteger := SourceId;
    Qry.ParamByName('target').AsInteger := TargetId;
    Qry.ParamByName('rel_type').AsWideString :=RelationType;
    Qry.ExecSQL;
    Affected := Qry.RowsAffected;
  finally
    Qry.Free;
  end;

  if Affected = 0 then
    raise EMxNotFound.Create('Relation not found');

  Data := TJSONObject.Create;
  try
    Data.AddPair('deleted', TJSONBool.Create(True));
    Result := MxSuccessResponse(Data);
  except
    Data.Free;
    raise;
  end;
end;

end.
