unit mx.Logic.Projects;

interface

uses
  System.SysUtils, System.Generics.Collections,
  FireDAC.Comp.Client,
  mx.Types, mx.Data.Pool;

type
  TMxMergeConflict = record
    DocType: string;
    Slug: string;
    SourceProjectId: Integer;
    SourceProjectName: string;
  end;

  TMxProjectManager = class
  private
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
  public
    constructor Create(APool: TMxConnectionPool; ALogger: IMxLogger);
    procedure UpdateProject(AId: Integer; const AName: string;
      ACreatorId: Integer = -1);
    procedure SoftDelete(AId: Integer);
    function CheckMergeConflicts(const ASourceIds: TArray<Integer>;
      ATargetId: Integer): TArray<TMxMergeConflict>;
    procedure MergeTo(const ASourceIds: TArray<Integer>;
      ATargetId: Integer; out AMovedDocs: Integer);
  end;

implementation

uses
  Data.DB;

{ TMxProjectManager }

constructor TMxProjectManager.Create(APool: TMxConnectionPool;
  ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
end;

procedure TMxProjectManager.UpdateProject(AId: Integer; const AName: string;
  ACreatorId: Integer = -1);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  SQL: string;
  OldCreatorId: Integer;
  DevExists: Boolean;
begin
  if AName.Trim.IsEmpty then
    raise Exception.Create('name_required');

  Ctx := FPool.AcquireContext;
  Ctx.StartTransaction;
  try
    // FR#4015 (Session 281 late-find): remember prior creator so we can
    // detect a real change and sync ACL below. SELECT must happen inside
    // the transaction to avoid TOCTOU with concurrent updates.
    OldCreatorId := -1;
    if ACreatorId >= 0 then
    begin
      Qry := Ctx.CreateQuery(
        'SELECT created_by_developer_id FROM projects WHERE id = :id');
      try
        Qry.ParamByName('id').AsInteger := AId;
        Qry.Open;
        if (not Qry.IsEmpty) and
           (not Qry.FieldByName('created_by_developer_id').IsNull) then
          OldCreatorId := Qry.FieldByName('created_by_developer_id').AsInteger;
      finally
        Qry.Free;
      end;
    end;

    SQL := 'UPDATE projects SET name = :name';
    if ACreatorId >= 0 then
      SQL := SQL + ', created_by_developer_id = :creator';
    SQL := SQL + ' WHERE id = :id';

    Qry := Ctx.CreateQuery(SQL);
    try
      Qry.ParamByName('name').AsWideString :=AName.Trim;
      Qry.ParamByName('id').AsInteger := AId;
      if ACreatorId >= 0 then
        Qry.ParamByName('creator').AsInteger := ACreatorId;
      Qry.ExecSQL;

      if Qry.RowsAffected = 0 then
        raise Exception.Create('project_not_found');
    finally
      Qry.Free;
    end;

    // FR#4015 (Session 281 late-find) — sync ACL when creator changes:
    // auto-grant read-write so the new creator immediately has team-
    // membership on their project (mirrors HandleInitProject path in
    // mx.Tool.Write.Meta). ON DUPLICATE KEY UPDATE dev=dev preserves
    // any pre-existing explicit assignment (won't downgrade 'admin' to
    // 'read-write') and only suppresses the dup-key error; FK/trunc/
    // deadlock still surface. Dev-exists pre-check defends against an
    // orphaned creator_id (dev soft-deleted) to avoid FK-violation
    // crash; silent-skip is logged via mlWarning for diagnosability.
    if (ACreatorId > 0) and (ACreatorId <> OldCreatorId) then
    begin
      DevExists := False;
      Qry := Ctx.CreateQuery(
        'SELECT 1 FROM developers WHERE id = :dev_id LIMIT 1');
      try
        Qry.ParamByName('dev_id').AsInteger := ACreatorId;
        Qry.Open;
        DevExists := not Qry.IsEmpty;
      finally
        Qry.Free;
      end;

      if DevExists then
      begin
        Qry := Ctx.CreateQuery(
          'INSERT INTO developer_project_access ' +
          '(developer_id, project_id, access_level) ' +
          'VALUES (:dev_id, :proj_id, ''read-write'') ' +
          'ON DUPLICATE KEY UPDATE developer_id = developer_id');
        try
          Qry.ParamByName('dev_id').AsInteger := ACreatorId;
          Qry.ParamByName('proj_id').AsInteger := AId;
          Qry.ExecSQL;
        finally
          Qry.Free;
        end;
      end
      else
      begin
        if Assigned(FLogger) then
          FLogger.Log(mlWarning,
            Format('Creator-change auto-grant skipped: dev %d not found (project %d)',
                   [ACreatorId, AId]));
      end;
    end;

    Ctx.Commit;
  except
    Ctx.Rollback;
    raise;
  end;

  FLogger.Log(mlInfo, 'Project updated: ID ' + IntToStr(AId));
end;

procedure TMxProjectManager.SoftDelete(AId: Integer);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  Ctx := FPool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'UPDATE projects SET is_active = FALSE, deleted_at = NOW() ' +
    'WHERE id = :id AND is_active = TRUE');
  try
    Qry.ParamByName('id').AsInteger := AId;
    Qry.ExecSQL;

    if Qry.RowsAffected = 0 then
      raise Exception.Create('project_not_found');
  finally
    Qry.Free;
  end;

  FLogger.Log(mlInfo, 'Project soft-deleted: ID ' + IntToStr(AId));
end;

function TMxProjectManager.CheckMergeConflicts(
  const ASourceIds: TArray<Integer>; ATargetId: Integer): TArray<TMxMergeConflict>;
var
  Ctx: IMxDbContext;
  Qry, TempQry: TFDQuery;
  I: Integer;
  Conflict: TMxMergeConflict;
  Conflicts: TList<TMxMergeConflict>;
  HasSources: Boolean;
begin
  Conflicts := TList<TMxMergeConflict>.Create;
  try
    Ctx := FPool.AcquireContext;

    // Insert source IDs into temp table for parameterized IN-query
    TempQry := Ctx.CreateQuery(
      'CREATE TEMPORARY TABLE IF NOT EXISTS tmp_merge_sources (id INT PRIMARY KEY)');
    try
      TempQry.ExecSQL;
    finally
      TempQry.Free;
    end;

    TempQry := Ctx.CreateQuery('DELETE FROM tmp_merge_sources');
    try
      TempQry.ExecSQL;
    finally
      TempQry.Free;
    end;

    HasSources := False;
    for I := 0 to High(ASourceIds) do
    begin
      if ASourceIds[I] = ATargetId then Continue;
      TempQry := Ctx.CreateQuery(
        'INSERT IGNORE INTO tmp_merge_sources (id) VALUES (:id)');
      try
        TempQry.ParamByName('id').AsInteger := ASourceIds[I];
        TempQry.ExecSQL;
        HasSources := True;
      finally
        TempQry.Free;
      end;
    end;

    if not HasSources then
    begin
      Result := nil;
      Exit;
    end;

    // Find doc_type+slug that exist in both source and target
    Qry := Ctx.CreateQuery(
      'SELECT sd.doc_type, sd.slug, sd.project_id AS source_project_id, ' +
      '  p.name AS source_project_name ' +
      'FROM documents sd ' +
      'JOIN projects p ON sd.project_id = p.id ' +
      'JOIN tmp_merge_sources tms ON sd.project_id = tms.id ' +
      'WHERE sd.status != ''deleted'' ' +
      '  AND EXISTS (SELECT 1 FROM documents td ' +
      '    WHERE td.project_id = :target ' +
      '    AND td.doc_type = sd.doc_type ' +
      '    AND td.slug = sd.slug ' +
      '    AND td.status != ''deleted'') ' +
      'ORDER BY p.name, sd.doc_type, sd.slug');
    try
      Qry.ParamByName('target').AsInteger := ATargetId;
      Qry.Open;

      while not Qry.Eof do
      begin
        Conflict.DocType := Qry.FieldByName('doc_type').AsString;
        Conflict.Slug := Qry.FieldByName('slug').AsString;
        Conflict.SourceProjectId := Qry.FieldByName('source_project_id').AsInteger;
        Conflict.SourceProjectName := Qry.FieldByName('source_project_name').AsString;
        Conflicts.Add(Conflict);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    Result := Conflicts.ToArray;
  finally
    Conflicts.Free;
  end;
end;

procedure TMxProjectManager.MergeTo(const ASourceIds: TArray<Integer>;
  ATargetId: Integer; out AMovedDocs: Integer);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  I, SourceId: Integer;
begin
  AMovedDocs := 0;
  Ctx := FPool.AcquireContext;
  Ctx.StartTransaction;
  try
    for I := 0 to High(ASourceIds) do
    begin
      SourceId := ASourceIds[I];
      if SourceId = ATargetId then Continue;

      // Move non-deleted documents to target project
      Qry := Ctx.CreateQuery(
        'UPDATE documents SET project_id = :target ' +
        'WHERE project_id = :source AND status != ''deleted''');
      try
        Qry.ParamByName('target').AsInteger := ATargetId;
        Qry.ParamByName('source').AsInteger := SourceId;
        Qry.ExecSQL;
        AMovedDocs := AMovedDocs + Qry.RowsAffected;
      finally
        Qry.Free;
      end;

      // Merge project access (highest level wins).
      // Subquery-wrap isolates the SELECT so MariaDB doesn't flag
      // `access_level` ambiguous between source-table and UPDATE-target.
      // 4-level ACL (FR#3360 build 110): read < comment < read-write.
      // Legacy 'write' rows are treated as 'read-write' for the merge.
      Qry := Ctx.CreateQuery(
        'INSERT INTO developer_project_access ' +
        '  (developer_id, project_id, access_level) ' +
        'SELECT tmp.dev_id, :target, tmp.lvl FROM ( ' +
        '  SELECT developer_id AS dev_id, access_level AS lvl ' +
        '  FROM developer_project_access WHERE project_id = :source ' +
        ') AS tmp ' +
        'ON DUPLICATE KEY UPDATE access_level = ' +
        '  CASE ' +
        '    WHEN VALUES(access_level) IN (''read-write'', ''write'') ' +
        '      OR developer_project_access.access_level IN (''read-write'', ''write'') ' +
        '    THEN ''read-write'' ' +
        '    WHEN VALUES(access_level) = ''comment'' ' +
        '      OR developer_project_access.access_level = ''comment'' ' +
        '    THEN ''comment'' ' +
        '    ELSE ''read'' ' +
        '  END');
      try
        Qry.ParamByName('target').AsInteger := ATargetId;
        Qry.ParamByName('source').AsInteger := SourceId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      // Remove old project access
      Qry := Ctx.CreateQuery(
        'DELETE FROM developer_project_access WHERE project_id = :source');
      try
        Qry.ParamByName('source').AsInteger := SourceId;
        Qry.ExecSQL;
      finally
        Qry.Free;
      end;

      // Soft-delete source project
      Qry := Ctx.CreateQuery(
        'UPDATE projects SET is_active = FALSE, deleted_at = NOW() ' +
        'WHERE id = :source');
      try
        Qry.ParamByName('source').AsInteger := SourceId;
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

  FLogger.Log(mlInfo, 'Projects merged into target ID ' + IntToStr(ATargetId) +
    ', moved ' + IntToStr(AMovedDocs) + ' documents');
end;

end.
