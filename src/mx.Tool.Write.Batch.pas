unit mx.Tool.Write.Batch;

interface

uses
  System.SysUtils, System.JSON, System.StrUtils,
  Data.DB,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors;

function HandleBatchCreate(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleBatchUpdate(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

uses
  mx.Tool.Write,
  mx.Logic.AccessControl;

// ---------------------------------------------------------------------------
// mx_batch_create — Create multiple documents in a single transaction
// ---------------------------------------------------------------------------
function HandleBatchCreate(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ItemsStr: string;
  ItemsArr: TJSONArray;
  ItemObj: TJSONObject;
  ItemVal: TJSONValue;
  I, ProjectId, DocId: Integer;
  ProjectSlug, DocType, Title, Content, Summary1, Summary2,
    CreatedBy, Slug, TagStr, Status: string;
  ResultArr: TJSONArray;
  ResultItem: TJSONObject;
  TagsVal: TJSONValue;
  TagsArr: TJSONArray;
  J: Integer;
  Data: TJSONObject;
begin
  ItemsStr := AParams.GetValue<string>('items', '');
  if ItemsStr = '' then
    raise EMxValidation.Create('Parameter "items" is required');

  ItemVal := TJSONObject.ParseJSONValue(ItemsStr);
  if (ItemVal = nil) or not (ItemVal is TJSONArray) then
  begin
    ItemVal.Free;
    raise EMxValidation.Create('Parameter "items" must be a valid JSON array string');
  end;

  ItemsArr := TJSONArray(ItemVal);
  try
    if ItemsArr.Count = 0 then
      raise EMxValidation.Create('Parameter "items" must not be empty');

    ResultArr := TJSONArray.Create;
    try
      AContext.StartTransaction;
      try
        for I := 0 to ItemsArr.Count - 1 do
        begin
          if not (ItemsArr.Items[I] is TJSONObject) then
            raise EMxValidation.CreateFmt('Item at index %d is not a JSON object', [I]);
          ItemObj := TJSONObject(ItemsArr.Items[I]);

          // Extract fields
          ProjectSlug := ItemObj.GetValue<string>('project', '');
          DocType := ItemObj.GetValue<string>('doc_type', '');
          Title := ItemObj.GetValue<string>('title', '');
          Content := ItemObj.GetValue<string>('content', '');
          CreatedBy := ItemObj.GetValue<string>('created_by', 'mcp');
          Status := ItemObj.GetValue<string>('status', 'draft');

          // Validate status
          if not MatchStr(Status, ['draft', 'active', 'completed',
              'superseded', 'archived', 'reported', 'confirmed', 'fixed', 'rejected', 'accepted',
              'proposed', 'approved', 'implemented', 'resolved',
              'open', 'in_progress', 'done', 'deferred']) then
            raise EMxValidation.CreateFmt('Item %d: invalid status "%s"', [I, Status]);

          // Validate required fields
          if ProjectSlug = '' then
            raise EMxValidation.CreateFmt('Item %d: "project" is required', [I]);
          if DocType = '' then
            raise EMxValidation.CreateFmt('Item %d: "doc_type" is required', [I]);
          if not MatchStr(DocType, ['plan', 'spec', 'decision', 'status',
              'workflow_log', 'session_note', 'finding', 'reference', 'snippet',
              'note', 'bugreport', 'feature_request', 'todo', 'assumption', 'lesson']) then
            raise EMxValidation.CreateFmt('Item %d: invalid doc_type "%s"', [I, DocType]);
          if Title = '' then
            raise EMxValidation.CreateFmt('Item %d: "title" is required', [I]);

          // Auto-Summary
          Summary1 := '';
          Summary2 := '';
          if Content <> '' then
          begin
            Summary1 := ExtractFirstSentence(Content);
            Summary2 := ExtractFirstSentences(Content, 3);
          end;

          // Generate slug
          Slug := GenerateSlug(Title);
          if Slug = '' then
            Slug := 'doc-' + FormatDateTime('yyyymmdd-hhnnss', Now);

          // Resolve project_id
          Qry := AContext.CreateQuery(
            'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
          try
            Qry.ParamByName('slug').AsString := ProjectSlug;
            Qry.Open;
            if Qry.IsEmpty then
              raise EMxNotFound.CreateFmt('Item %d: project not found: %s', [I, ProjectSlug]);
            ProjectId := Qry.FieldByName('id').AsInteger;
          finally
            Qry.Free;
          end;

          // ACL: check write access to target project
          if not AContext.AccessControl.CheckProject(ProjectId, alWrite) then
            raise EMxAccessDenied.Create(ProjectSlug, alWrite);

          // INSERT document
          Qry := AContext.CreateQuery(
            'INSERT INTO documents (project_id, doc_type, slug, title, content, ' +
            '  summary_l1, summary_l2, status, created_by) ' +
            'VALUES (:proj_id, :doc_type, :slug, :title, :content, ' +
            '  :summary_l1, :summary_l2, :status, :created_by)');
          try
            Qry.ParamByName('proj_id').AsInteger := ProjectId;
            Qry.ParamByName('doc_type').AsString := DocType;
            Qry.ParamByName('slug').AsString := Slug;
            Qry.ParamByName('title').AsString := Title;
            Qry.ParamByName('content').DataType := ftWideMemo;
            Qry.ParamByName('content').AsString := Content;
            Qry.ParamByName('summary_l1').AsString := Summary1;
            Qry.ParamByName('summary_l2').AsString := Summary2;
            Qry.ParamByName('status').AsString := Status;
            Qry.ParamByName('created_by').AsString := CreatedBy;
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

          // INSERT initial revision
          Qry := AContext.CreateQuery(
            'INSERT INTO doc_revisions (doc_id, revision, content, summary_l2, ' +
            '  changed_by, change_reason) ' +
            'VALUES (:doc_id, 1, :content, :summary_l2, :changed_by, ''Initial version'')');
          try
            Qry.ParamByName('doc_id').AsInteger := DocId;
            Qry.ParamByName('content').DataType := ftWideMemo;
            Qry.ParamByName('content').AsString := Content;
            Qry.ParamByName('summary_l2').AsString := Summary2;
            Qry.ParamByName('changed_by').AsString := CreatedBy;
            Qry.ExecSQL;
          finally
            Qry.Free;
          end;

          // Handle optional tags
          TagsVal := ItemObj.GetValue('tags');
          if (TagsVal <> nil) and (TagsVal is TJSONArray) then
          begin
            TagsArr := TJSONArray(TagsVal);
            for J := 0 to TagsArr.Count - 1 do
            begin
              if not (TagsArr.Items[J] is TJSONString) then
                Continue;
              TagStr := Trim(TagsArr.Items[J].Value);
              if (TagStr = '') or (Length(TagStr) > 50) then
                Continue;

              Qry := AContext.CreateQuery(
                'INSERT IGNORE INTO doc_tags (doc_id, tag) VALUES (:doc_id, :tag)');
              try
                Qry.ParamByName('doc_id').AsInteger := DocId;
                Qry.ParamByName('tag').AsString := TagStr;
                Qry.ExecSQL;
              finally
                Qry.Free;
              end;
            end;
          end;

          // Add result item
          ResultItem := TJSONObject.Create;
          ResultItem.AddPair('doc_id', TJSONNumber.Create(DocId));
          ResultItem.AddPair('slug', Slug);
          ResultItem.AddPair('success', TJSONBool.Create(True));
          ResultArr.AddElement(ResultItem);
        end;

        AContext.Commit;
      except
        on E: Exception do
        begin
          AContext.Rollback;
          if (E is EMxValidation) or (E is EMxNotFound) or (E is EMxAccessDenied) then
            raise
          else
            raise EMxValidation.CreateFmt('Batch create failed at index %d: %s',
              [I, E.Message]);
        end;
      end;

      Data := TJSONObject.Create;
      try
        Data.AddPair('created', TJSONNumber.Create(ResultArr.Count));
        Data.AddPair('results', ResultArr);
        ResultArr := nil; // ownership transferred to Data
        Result := MxSuccessResponse(Data);
      except
        Data.Free;
        raise;
      end;
    finally
      ResultArr.Free; // only frees if not nil (i.e. not transferred)
    end;
  finally
    ItemsArr.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_batch_update — Update multiple documents in a single transaction
// ---------------------------------------------------------------------------
function HandleBatchUpdate(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Qry: TFDQuery;
  ItemsStr: string;
  ItemsArr: TJSONArray;
  ItemObj: TJSONObject;
  ItemVal: TJSONValue;
  I: Integer;
  DocId, NextRevision: Integer;
  Content, Status, ChangeReason, ChangedBy, Summary1, Summary2: string;
  SetParts: string;
  ResultArr: TJSONArray;
  ResultItem: TJSONObject;
  Data: TJSONObject;
begin
  ItemsStr := AParams.GetValue<string>('items', '');
  if ItemsStr = '' then
    raise EMxValidation.Create('Parameter "items" is required');

  ItemVal := TJSONObject.ParseJSONValue(ItemsStr);
  if (ItemVal = nil) or not (ItemVal is TJSONArray) then
  begin
    ItemVal.Free;
    raise EMxValidation.Create('Parameter "items" must be a valid JSON array string');
  end;

  ItemsArr := TJSONArray(ItemVal);
  try
    if ItemsArr.Count = 0 then
      raise EMxValidation.Create('Parameter "items" must not be empty');

    ResultArr := TJSONArray.Create;
    try
      AContext.StartTransaction;
      try
        for I := 0 to ItemsArr.Count - 1 do
        begin
          if not (ItemsArr.Items[I] is TJSONObject) then
            raise EMxValidation.CreateFmt('Item at index %d is not a JSON object', [I]);
          ItemObj := TJSONObject(ItemsArr.Items[I]);

          // Extract fields
          DocId := ItemObj.GetValue<Integer>('doc_id', 0);
          if DocId = 0 then
            raise EMxValidation.CreateFmt('Item %d: "doc_id" is required', [I]);

          Content := ItemObj.GetValue<string>('content', '');
          Status := ItemObj.GetValue<string>('status', '');
          ChangeReason := ItemObj.GetValue<string>('change_reason', '');
          ChangedBy := ItemObj.GetValue<string>('changed_by', 'mcp');
          Summary1 := ItemObj.GetValue<string>('summary_l1', '');
          Summary2 := ItemObj.GetValue<string>('summary_l2', '');

          // Validate status if provided
          if (Status <> '') and not MatchStr(Status, ['draft', 'active', 'completed',
              'superseded', 'archived', 'reported', 'confirmed', 'fixed', 'rejected', 'accepted',
              'proposed', 'approved', 'implemented', 'resolved',
              'open', 'in_progress', 'done', 'deferred']) then
            raise EMxValidation.CreateFmt('Item %d: invalid status "%s"', [I, Status]);

          // Build dynamic SET clause
          SetParts := '';
          if Content <> '' then
            SetParts := SetParts + 'content = :content, ';
          if Status <> '' then
            SetParts := SetParts + 'status = :status, ';

          // Optional summaries: only update if explicitly provided by caller.
          // Without explicit summaries, existing DB values are preserved.
          // FTS index covers content directly, so search remains functional.
          if Summary1 <> '' then
            SetParts := SetParts + 'summary_l1 = :summary_l1, ';
          if Summary2 <> '' then
            SetParts := SetParts + 'summary_l2 = :summary_l2, ';

          if SetParts = '' then
            raise EMxValidation.CreateFmt('Item %d: no fields to update', [I]);

          // Remove trailing comma+space
          SetParts := Copy(SetParts, 1, Length(SetParts) - 2);

          // Verify document exists + ACL check
          Qry := AContext.CreateQuery(
            'SELECT d.project_id, p.slug AS project_slug ' +
            'FROM documents d JOIN projects p ON d.project_id = p.id ' +
            'WHERE d.id = :id AND d.status <> ''deleted''');
          try
            Qry.ParamByName('id').AsInteger := DocId;
            Qry.Open;
            if Qry.IsEmpty then
              raise EMxNotFound.CreateFmt('Item %d: document not found: %d', [I, DocId]);

            // ACL: check write access to the document's project
            if not AContext.AccessControl.CheckProject(
              Qry.FieldByName('project_id').AsInteger, alWrite) then
              raise EMxAccessDenied.Create(
                Qry.FieldByName('project_slug').AsString, alWrite);
          finally
            Qry.Free;
          end;

          // UPDATE document
          Qry := AContext.CreateQuery(
            'UPDATE documents SET ' + SetParts + ' WHERE id = :id');
          try
            Qry.ParamByName('id').AsInteger := DocId;
            if Content <> '' then
            begin
              Qry.ParamByName('content').DataType := ftWideMemo;
              Qry.ParamByName('content').AsString := Content;
            end;
            if Summary1 <> '' then
              Qry.ParamByName('summary_l1').AsString := Summary1;
            if Summary2 <> '' then
              Qry.ParamByName('summary_l2').AsString := Summary2;
            if Status <> '' then
              Qry.ParamByName('status').AsString := Status;
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
              Qry.ParamByName('content').DataType := ftWideMemo;
              Qry.ParamByName('content').AsString := Content;
              Qry.ParamByName('summary_l2').AsString := Summary2;
              Qry.ParamByName('changed_by').AsString := ChangedBy;
              Qry.ParamByName('reason').AsString := ChangeReason;
              Qry.ExecSQL;
            finally
              Qry.Free;
            end;
          end;

          // Add result item
          ResultItem := TJSONObject.Create;
          ResultItem.AddPair('doc_id', TJSONNumber.Create(DocId));
          ResultItem.AddPair('success', TJSONBool.Create(True));
          ResultArr.AddElement(ResultItem);
        end;

        AContext.Commit;
      except
        on E: Exception do
        begin
          AContext.Rollback;
          if (E is EMxValidation) or (E is EMxNotFound) or (E is EMxAccessDenied) then
            raise
          else
            raise EMxValidation.CreateFmt('Batch update failed at index %d: %s',
              [I, E.Message]);
        end;
      end;

      Data := TJSONObject.Create;
      try
        Data.AddPair('updated', TJSONNumber.Create(ResultArr.Count));
        Data.AddPair('results', ResultArr);
        ResultArr := nil; // ownership transferred to Data
        Result := MxSuccessResponse(Data);
      except
        Data.Free;
        raise;
      end;
    finally
      ResultArr.Free;
    end;
  finally
    ItemsArr.Free;
  end;
end;

end.
