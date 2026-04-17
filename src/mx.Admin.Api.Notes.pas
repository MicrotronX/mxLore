unit mx.Admin.Api.Notes;

// FR#2936/Plan#3266 M2.6 — admin-UI deep-thread alert.
// Surfaces review-notes whose depth (from sql/047) is at or above the
// warn-threshold (5). HandleCreateNote enforces hard-limit 10 + warn at 5
// at create-time; this endpoint provides the read-side dashboard view so
// admins can see when threads are getting unwieldy and intervene
// (typically by promoting the thread to a real spec/plan/decision).

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool;

procedure HandleListDeepThreads(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server;

const
  DEEP_THREAD_THRESHOLD = 5;  // matches HandleCreateNote DEPTH_WARN_THRESHOLD
  RESULT_LIMIT          = 50;

procedure HandleListDeepThreads(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Threads: TJSONArray;
  Item, Json: TJSONObject;
begin
  Ctx := APool.AcquireContext;
  // Self-join to surface the root-parent title alongside the deep note.
  // root_parent_doc_id is denormalised on the note row by HandleCreateNote.
  Qry := Ctx.CreateQuery(
    'SELECT d.id, d.title, d.depth, d.root_parent_doc_id, ' +
    '  d.created_at, p.title AS root_title, p.doc_type AS root_doc_type, ' +
    '  proj.id AS project_id, proj.slug AS project_slug ' +
    'FROM documents d ' +
    'LEFT JOIN documents p ON p.id = d.root_parent_doc_id ' +
    'JOIN projects proj ON proj.id = d.project_id ' +
    'WHERE d.doc_type = ''note'' ' +
    '  AND d.depth >= :threshold ' +
    '  AND d.status <> ''deleted'' ' +
    'ORDER BY d.depth DESC, d.created_at DESC ' +
    'LIMIT :lim');
  try
    // Lesson#2930: explicit DataType for SMALLINT column to dodge param-size gap.
    Qry.ParamByName('threshold').DataType := ftSmallint;
    Qry.ParamByName('threshold').AsSmallInt := DEEP_THREAD_THRESHOLD;
    Qry.ParamByName('lim').AsInteger := RESULT_LIMIT;
    Qry.Open;

    // mxDesignChecker WARN#3: defensive try/except so per-iteration TJSONObject
    // and the parent TJSONArray are freed if any AddPair raises mid-loop.
    Threads := TJSONArray.Create;
    try
      while not Qry.Eof do
      begin
        Item := TJSONObject.Create;
        try
          Item.AddPair('id',         TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
          Item.AddPair('title',      Qry.FieldByName('title').AsString);
          Item.AddPair('depth',      TJSONNumber.Create(Qry.FieldByName('depth').AsInteger));
          Item.AddPair('project',    Qry.FieldByName('project_slug').AsString);
          Item.AddPair('project_id', TJSONNumber.Create(Qry.FieldByName('project_id').AsInteger));
          // mxBugChecker INFO#7: ISO8601 instead of locale-dependent AsString.
          Item.AddPair('created_at',
            FormatDateTime('yyyy-mm-dd"T"hh:nn:ss',
              Qry.FieldByName('created_at').AsDateTime));
          if not Qry.FieldByName('root_parent_doc_id').IsNull then
          begin
            Item.AddPair('root_parent_doc_id',
              TJSONNumber.Create(Qry.FieldByName('root_parent_doc_id').AsInteger));
            Item.AddPair('root_title',    Qry.FieldByName('root_title').AsString);
            Item.AddPair('root_doc_type', Qry.FieldByName('root_doc_type').AsString);
          end
          else
          begin
            Item.AddPair('root_parent_doc_id', TJSONNull.Create);
            Item.AddPair('root_title', TJSONNull.Create);
            Item.AddPair('root_doc_type', TJSONNull.Create);
          end;
          Threads.AddElement(Item);
        except
          Item.Free;
          raise;
        end;
        Qry.Next;
      end;

      Json := TJSONObject.Create;
      try
        Json.AddPair('threshold', TJSONNumber.Create(DEEP_THREAD_THRESHOLD));
        Json.AddPair('threads', Threads);  // ownership transferred to Json
        MxSendJson(C, 200, Json);
      finally
        Json.Free;
      end;
    except
      Threads.Free;  // only reached if pre-Json-AddPair raise (i.e. inner loop)
      raise;
    end;
  finally
    Qry.Free;
  end;
end;

end.
