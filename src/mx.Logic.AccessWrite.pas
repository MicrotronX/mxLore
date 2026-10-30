unit mx.Logic.AccessWrite;

// Spec#19960 / Plan#19964 M1 — the ONLY place that writes
// developer_project_access. Every change writes one access_audit row in the
// caller's transaction (sql/054). Grep gate (AC8): INSERT/UPDATE/DELETE on
// developer_project_access must not appear in any other unit.
//
// Callers own the transaction: these routines never Start/Commit/Rollback, so
// the access change and its audit row commit or roll back together.
//
// Actor id 0 = no developer (boot, setup mode, server CLI) -> stored as NULL;
// ASource says which path it was.

interface

uses
  System.SysUtils, mx.Types;

type
  /// A write on a private project by anyone but its owner. The admin router
  /// answers 403 and logs a 'denied' row after the caller's rollback.
  EMxAccessWriteDenied = class(Exception)
  public
    ProjectId: Integer;
    TargetDeveloperId: Integer;
    Source: string;
    constructor Create(AProjectId, ATargetDeveloperId: Integer;
      const ASource: string);
  end;

const
  cAccessSrcDevPage       = 'admin:developer-projects';
  cAccessSrcProjectTeam   = 'admin:project-team';
  cAccessSrcDevDelete     = 'admin:developer-delete';
  cAccessSrcDevMerge      = 'admin:developer-merge';
  cAccessSrcProjectDelete = 'admin:project-delete';
  cAccessSrcProjectMerge  = 'admin:project-merge';
  cAccessSrcCreatorChange = 'admin:creator-change';
  cAccessSrcInitProject   = 'mcp:init-project';
  cAccessSrcImport        = 'import:project-bundle';

/// Sets one developer's level on one project. ALevel '' or 'none' revokes.
/// Returns True when the row changed (no-op = no audit row).
function SetProjectAccess(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ALevel, ASource: string): Boolean;

/// Inserts ALevel only when the developer has no row yet; an existing row is
/// never changed (creator auto-grant, bundle import). True = inserted.
function GrantProjectAccessIfAbsent(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ALevel, ASource: string): Boolean;

/// Makes the developer's rows match AProjectIds/ALevels (same length). Only
/// differing rows are written; rows the actor may not write stay untouched.
procedure ReplaceDeveloperAccess(const ACtx: IMxDbContext;
  AActorId, ADeveloperId: Integer; const AProjectIds: TArray<Integer>;
  const ALevels: TArray<string>; const ASource: string);

procedure RevokeAllForDeveloper(const ACtx: IMxDbContext;
  AActorId, ADeveloperId: Integer; const ASource: string);
procedure RevokeAllForProject(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer; const ASource: string);

/// Copies the source's rows onto the target (higher level wins, same rule as
/// the former SQL: read-write > comment > read), then revokes the source.
procedure MergeDeveloperAccess(const ACtx: IMxDbContext;
  AActorId, ASourceDevId, ATargetDevId: Integer; const ASource: string);
procedure MergeProjectAccess(const ACtx: IMxDbContext;
  AActorId, ASourceProjectId, ATargetProjectId: Integer; const ASource: string);

/// Boot data migration (sql/046 step 2): legacy 'write' -> 'read-write'.
/// Same right under a canonical name, so no audit row (the audit table may not
/// exist yet at that point of the boot). Returns affected rows.
function NormalizeLegacyWriteLevel(const ACtx: IMxDbContext): Integer;

/// True for the levels a row may be written with.
function IsGrantableLevel(const ALevel: string): Boolean;

/// Private-project rule (Plan#19964 M2.7): public = True, private = owner only.
function CanWriteProjectAccess(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer): Boolean;

function IsProjectOwner(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer): Boolean;

/// Owner only (Spec#19960 Req 2); raises EMxAccessWriteDenied otherwise.
/// A project without owner can never become private. True = flag changed.
function SetProjectPrivate(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer; APrivate: Boolean; const ASource: string): Boolean;

/// Appends one row to access_audit, for events other than level changes.
procedure WriteAccessEvent(const ACtx: IMxDbContext;
  AActorId, AProjectId, ATargetDeveloperId: Integer;
  const AAction, ABefore, AAfter, ASource: string);

/// Server CLI only, no HTTP path (Spec#19960 Req 7). Actor is stored as NULL.
procedure BreakGlassMakePublic(const ACtx: IMxDbContext; AProjectId: Integer);
procedure BreakGlassSetOwner(const ACtx: IMxDbContext;
  AProjectId, ADeveloperId: Integer);

/// Writes one 'denied' row. Call outside the rolled-back transaction.
procedure WriteAccessDenied(const ACtx: IMxDbContext;
  AActorId, AProjectId, ATargetDeveloperId: Integer; const ASource: string);

/// A key for a developer with access to a private project lets its issuer act
/// as that developer (Spec#19960 section 11). True = refused, 'denied' written.
/// Developers may always manage their own keys.
function KeyIssueDenied(const ACtx: IMxDbContext;
  AActorId, ATargetDeveloperId: Integer; const ASource: string): Boolean;

implementation

uses
  System.Generics.Collections, Data.DB, FireDAC.Comp.Client;

constructor EMxAccessWriteDenied.Create(AProjectId, ATargetDeveloperId: Integer;
  const ASource: string);
begin
  inherited Create('access_write_denied');
  ProjectId := AProjectId;
  TargetDeveloperId := ATargetDeveloperId;
  Source := ASource;
end;

function NormLevel(const ALevel: string): string;
begin
  Result := LowerCase(Trim(ALevel));
  if Result = 'none' then
    Result := ''
  else if Result = 'write' then
    Result := 'read-write';
end;

// Level of an EXISTING row. A stored ''/'none' row stays 'none' so it is not
// mistaken for "no row" ('') and can still be revoked or kept by a grant.
function NormStored(const ALevel: string): string;
begin
  Result := NormLevel(ALevel);
  if Result = '' then
    Result := 'none';
end;

// Unknown non-empty levels rank as 'read', as in the former merge SQL.
function MergeRank(const ALevel: string): Integer;
begin
  if ALevel = 'read-write' then Result := 3
  else if ALevel = 'comment' then Result := 2
  else if (ALevel = '') or (ALevel = 'none') then Result := 0
  else Result := 1;
end;

function IsGrantableLevel(const ALevel: string): Boolean;
var
  Level: string;
begin
  Level := NormLevel(ALevel);
  Result := (Level = 'read') or (Level = 'comment') or (Level = 'read-write');
end;

function CanWriteProjectAccess(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'SELECT created_by_developer_id FROM projects ' +
    'WHERE id = :id AND is_private = 1');
  try
    Qry.ParamByName('id').AsInteger := AProjectId;
    Qry.Open;
    Result := Qry.IsEmpty or
      ((AActorId > 0) and
       (not Qry.FieldByName('created_by_developer_id').IsNull) and
       (Qry.FieldByName('created_by_developer_id').AsInteger = AActorId));
  finally
    Qry.Free;
  end;
end;

procedure RequireWrite(const ACtx: IMxDbContext;
  AActorId, AProjectId, ATargetDeveloperId: Integer; const ASource: string);
begin
  if not CanWriteProjectAccess(ACtx, AActorId, AProjectId) then
    raise EMxAccessWriteDenied.Create(AProjectId, ATargetDeveloperId, ASource);
end;

function ReadLevel(const ACtx: IMxDbContext;
  AProjectId, ADeveloperId: Integer): string;
var
  Qry: TFDQuery;
begin
  Result := '';
  Qry := ACtx.CreateQuery(
    'SELECT access_level FROM developer_project_access ' +
    'WHERE developer_id = :dev AND project_id = :proj FOR UPDATE');
  try
    Qry.ParamByName('dev').AsInteger := ADeveloperId;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.Open;
    if not Qry.IsEmpty then
      Result := NormStored(Qry.FieldByName('access_level').AsString);
  finally
    Qry.Free;
  end;
end;

procedure WriteAudit(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ABefore, AAfter, ASource: string);
var
  Qry: TFDQuery;
  Action: string;
begin
  if ABefore = '' then
    Action := 'grant'
  else if AAfter = '' then
    Action := 'revoke'
  else
    Action := 'change';
  Qry := ACtx.CreateQuery(
    'INSERT INTO access_audit (created_at_utc, actor_developer_id, ' +
    '  project_id, target_developer_id, action, level_before, level_after, source) ' +
    'VALUES (UTC_TIMESTAMP(3), :actor, :proj, :dev, :action, :before, :after, :src)');
  try
    if AActorId > 0 then
      Qry.ParamByName('actor').AsInteger := AActorId
    else
    begin
      Qry.ParamByName('actor').DataType := ftInteger;
      Qry.ParamByName('actor').Clear;
    end;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ParamByName('dev').AsInteger := ADeveloperId;
    Qry.ParamByName('action').AsWideString := Action;
    Qry.ParamByName('before').AsWideString := ABefore;
    Qry.ParamByName('after').AsWideString := AAfter;
    Qry.ParamByName('src').AsWideString := ASource;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

procedure WriteRow(const ACtx: IMxDbContext;
  AProjectId, ADeveloperId: Integer; const ALevel: string);
var
  Qry: TFDQuery;
begin
  if ALevel = '' then
  begin
    Qry := ACtx.CreateQuery(
      'DELETE FROM developer_project_access ' +
      'WHERE developer_id = :dev AND project_id = :proj');
    try
      Qry.ParamByName('dev').AsInteger := ADeveloperId;
      Qry.ParamByName('proj').AsInteger := AProjectId;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  end
  else
  begin
    Qry := ACtx.CreateQuery(
      'INSERT INTO developer_project_access (developer_id, project_id, access_level) ' +
      'VALUES (:dev, :proj, :level) ' +
      'ON DUPLICATE KEY UPDATE access_level = VALUES(access_level)');
    try
      Qry.ParamByName('dev').AsInteger := ADeveloperId;
      Qry.ParamByName('proj').AsInteger := AProjectId;
      Qry.ParamByName('level').AsWideString := ALevel;
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
  end;
end;

procedure WriteAccessDenied(const ACtx: IMxDbContext;
  AActorId, AProjectId, ATargetDeveloperId: Integer; const ASource: string);
begin
  WriteAccessEvent(ACtx, AActorId, AProjectId, ATargetDeveloperId,
    'denied', '', '', ASource);
end;

function IsProjectOwner(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Result := False;
  if AActorId <= 0 then Exit;
  Qry := ACtx.CreateQuery(
    'SELECT 1 FROM projects WHERE id = :id AND created_by_developer_id = :dev');
  try
    Qry.ParamByName('id').AsInteger := AProjectId;
    Qry.ParamByName('dev').AsInteger := AActorId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function ApplyLevel(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ABefore, AAfter, ASource: string): Boolean; forward;

procedure WritePrivateFlag(const ACtx: IMxDbContext; AProjectId: Integer;
  APrivate: Boolean);
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery('UPDATE projects SET is_private = :v WHERE id = :id');
  try
    Qry.ParamByName('v').AsInteger := Ord(APrivate);
    Qry.ParamByName('id').AsInteger := AProjectId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

function ReadPrivateFlag(const ACtx: IMxDbContext; AProjectId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery('SELECT is_private FROM projects WHERE id = :id FOR UPDATE');
  try
    Qry.ParamByName('id').AsInteger := AProjectId;
    Qry.Open;
    Result := (not Qry.IsEmpty) and Qry.FieldByName('is_private').AsBoolean;
  finally
    Qry.Free;
  end;
end;

function SetProjectPrivate(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer; APrivate: Boolean; const ASource: string): Boolean;
const
  ACTIONS: array[Boolean] of string = ('private_off', 'private_on');
begin
  if not IsProjectOwner(ACtx, AActorId, AProjectId) then
    raise EMxAccessWriteDenied.Create(AProjectId, 0, ASource);
  Result := ReadPrivateFlag(ACtx, AProjectId) <> APrivate;
  if not Result then Exit;
  WritePrivateFlag(ACtx, AProjectId, APrivate);
  WriteAccessEvent(ACtx, AActorId, AProjectId, 0, ACTIONS[APrivate], '', '', ASource);
end;

procedure BreakGlassMakePublic(const ACtx: IMxDbContext; AProjectId: Integer);
begin
  WritePrivateFlag(ACtx, AProjectId, False);
  WriteAccessEvent(ACtx, 0, AProjectId, 0, 'break_glass', 'private', 'public', 'server-cli');
end;

procedure BreakGlassSetOwner(const ACtx: IMxDbContext;
  AProjectId, ADeveloperId: Integer);
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'UPDATE projects SET created_by_developer_id = :dev WHERE id = :id');
  try
    Qry.ParamByName('dev').AsInteger := ADeveloperId;
    Qry.ParamByName('id').AsInteger := AProjectId;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
  // New owner now passes RequireWrite; the row itself is audited as a grant.
  ApplyLevel(ACtx, 0, AProjectId, ADeveloperId,
    ReadLevel(ACtx, AProjectId, ADeveloperId), 'read-write', 'server-cli');
  WriteAccessEvent(ACtx, 0, AProjectId, ADeveloperId, 'break_glass', '', 'owner', 'server-cli');
end;

procedure WriteAccessEvent(const ACtx: IMxDbContext;
  AActorId, AProjectId, ATargetDeveloperId: Integer;
  const AAction, ABefore, AAfter, ASource: string);
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'INSERT INTO access_audit (created_at_utc, actor_developer_id, ' +
    '  project_id, target_developer_id, action, level_before, level_after, source) ' +
    'VALUES (UTC_TIMESTAMP(3), :actor, :proj, :dev, :action, :before, :after, :src)');
  try
    Qry.ParamByName('action').AsWideString := AAction;
    Qry.ParamByName('before').AsWideString := ABefore;
    Qry.ParamByName('after').AsWideString := AAfter;
    if AActorId > 0 then
      Qry.ParamByName('actor').AsInteger := AActorId
    else
    begin
      Qry.ParamByName('actor').DataType := ftInteger;
      Qry.ParamByName('actor').Clear;
    end;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    if ATargetDeveloperId > 0 then
      Qry.ParamByName('dev').AsInteger := ATargetDeveloperId
    else
    begin
      Qry.ParamByName('dev').DataType := ftInteger;
      Qry.ParamByName('dev').Clear;
    end;
    Qry.ParamByName('src').AsWideString := ASource;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
end;

function KeyIssueDenied(const ACtx: IMxDbContext;
  AActorId, ATargetDeveloperId: Integer; const ASource: string): Boolean;
var
  Qry: TFDQuery;
  ProjectId: Integer;
begin
  Result := False;
  if AActorId = ATargetDeveloperId then Exit;
  Qry := ACtx.CreateQuery(
    'SELECT p.id FROM projects p ' +
    'WHERE p.is_private = 1 AND (p.created_by_developer_id = :dev OR p.id IN ' +
    '  (SELECT a.project_id FROM developer_project_access a ' +
    '   WHERE a.developer_id = :dev2 AND a.access_level <> ''none'')) ' +
    'LIMIT 1');
  try
    Qry.ParamByName('dev').AsInteger := ATargetDeveloperId;
    Qry.ParamByName('dev2').AsInteger := ATargetDeveloperId;
    Qry.Open;
    if Qry.IsEmpty then Exit;
    ProjectId := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
  WriteAccessDenied(ACtx, AActorId, ProjectId, ATargetDeveloperId, ASource);
  Result := True;
end;

function ApplyLevel(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ABefore, AAfter, ASource: string): Boolean;
begin
  Result := ABefore <> AAfter;
  if not Result then Exit;
  WriteRow(ACtx, AProjectId, ADeveloperId, AAfter);
  WriteAudit(ACtx, AActorId, AProjectId, ADeveloperId, ABefore, AAfter, ASource);
end;

function SetProjectAccess(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ALevel, ASource: string): Boolean;
begin
  RequireWrite(ACtx, AActorId, AProjectId, ADeveloperId, ASource);
  Result := ApplyLevel(ACtx, AActorId, AProjectId, ADeveloperId,
    ReadLevel(ACtx, AProjectId, ADeveloperId), NormLevel(ALevel), ASource);
end;

function GrantProjectAccessIfAbsent(const ACtx: IMxDbContext;
  AActorId, AProjectId, ADeveloperId: Integer;
  const ALevel, ASource: string): Boolean;
begin
  RequireWrite(ACtx, AActorId, AProjectId, ADeveloperId, ASource);
  Result := (ReadLevel(ACtx, AProjectId, ADeveloperId) = '') and
    ApplyLevel(ACtx, AActorId, AProjectId, ADeveloperId, '',
      NormLevel(ALevel), ASource);
end;

type
  TAccessRow = record
    Key: Integer;
    Level: string;
  end;

// AByDeveloper=True: rows of developer AId, Key = project_id.
// AByDeveloper=False: rows of project AId, Key = developer_id.
function LoadRows(const ACtx: IMxDbContext; AByDeveloper: Boolean;
  AId: Integer): TArray<TAccessRow>;
var
  Qry: TFDQuery;
  List: TList<TAccessRow>;
  Row: TAccessRow;
begin
  List := TList<TAccessRow>.Create;
  try
    if AByDeveloper then
      Qry := ACtx.CreateQuery(
        'SELECT project_id AS k, access_level FROM developer_project_access ' +
        'WHERE developer_id = :id FOR UPDATE')
    else
      Qry := ACtx.CreateQuery(
        'SELECT developer_id AS k, access_level FROM developer_project_access ' +
        'WHERE project_id = :id FOR UPDATE');
    try
      Qry.ParamByName('id').AsInteger := AId;
      Qry.Open;
      while not Qry.Eof do
      begin
        Row.Key := Qry.FieldByName('k').AsInteger;
        Row.Level := NormStored(Qry.FieldByName('access_level').AsString);
        List.Add(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

procedure ReplaceDeveloperAccess(const ACtx: IMxDbContext;
  AActorId, ADeveloperId: Integer; const AProjectIds: TArray<Integer>;
  const ALevels: TArray<string>; const ASource: string);
var
  Current: TArray<TAccessRow>;
  Wanted: TDictionary<Integer, string>;
  Row: TAccessRow;
  I: Integer;
  Before: string;
begin
  if Length(AProjectIds) <> Length(ALevels) then
    raise Exception.Create('ReplaceDeveloperAccess: ids/levels length mismatch');
  Current := LoadRows(ACtx, True, ADeveloperId);
  Wanted := TDictionary<Integer, string>.Create;
  try
    for I := 0 to High(AProjectIds) do
      Wanted.AddOrSetValue(AProjectIds[I], NormLevel(ALevels[I]));

    // A row missing from the body is only revoked if the actor may write it:
    // a save never drops a foreign private row (AC3).
    for Row in Current do
      if (not Wanted.ContainsKey(Row.Key)) and
         CanWriteProjectAccess(ACtx, AActorId, Row.Key) then
        Wanted.Add(Row.Key, '');

    for I in Wanted.Keys do
    begin
      Before := '';
      for Row in Current do
        if Row.Key = I then
        begin
          Before := Row.Level;
          Break;
        end;
      // Unchanged private rows pass; a real change is refused (AC2).
      if Before <> Wanted[I] then
        RequireWrite(ACtx, AActorId, I, ADeveloperId, ASource);
      ApplyLevel(ACtx, AActorId, I, ADeveloperId, Before, Wanted[I], ASource);
    end;
  finally
    Wanted.Free;
  end;
end;

procedure RevokeAllForDeveloper(const ACtx: IMxDbContext;
  AActorId, ADeveloperId: Integer; const ASource: string);
var
  Row: TAccessRow;
begin
  for Row in LoadRows(ACtx, True, ADeveloperId) do
    ApplyLevel(ACtx, AActorId, Row.Key, ADeveloperId, Row.Level, '', ASource);
end;

procedure RevokeAllForProject(const ACtx: IMxDbContext;
  AActorId, AProjectId: Integer; const ASource: string);
var
  Row: TAccessRow;
begin
  for Row in LoadRows(ACtx, False, AProjectId) do
    ApplyLevel(ACtx, AActorId, AProjectId, Row.Key, Row.Level, '', ASource);
end;

procedure MergeDeveloperAccess(const ACtx: IMxDbContext;
  AActorId, ASourceDevId, ATargetDevId: Integer; const ASource: string);
var
  Row: TAccessRow;
  Before: string;
begin
  // Merging would hand the source's private rows to the target.
  for Row in LoadRows(ACtx, True, ASourceDevId) do
    RequireWrite(ACtx, AActorId, Row.Key, ATargetDevId, ASource);
  for Row in LoadRows(ACtx, True, ASourceDevId) do
  begin
    Before := ReadLevel(ACtx, Row.Key, ATargetDevId);
    if MergeRank(Row.Level) > MergeRank(Before) then
      ApplyLevel(ACtx, AActorId, Row.Key, ATargetDevId, Before, Row.Level, ASource);
  end;
  RevokeAllForDeveloper(ACtx, AActorId, ASourceDevId, ASource);
end;

procedure MergeProjectAccess(const ACtx: IMxDbContext;
  AActorId, ASourceProjectId, ATargetProjectId: Integer; const ASource: string);
var
  Row: TAccessRow;
  Before: string;
begin
  RequireWrite(ACtx, AActorId, ASourceProjectId, 0, ASource);
  RequireWrite(ACtx, AActorId, ATargetProjectId, 0, ASource);
  for Row in LoadRows(ACtx, False, ASourceProjectId) do
  begin
    Before := ReadLevel(ACtx, ATargetProjectId, Row.Key);
    if MergeRank(Row.Level) > MergeRank(Before) then
      ApplyLevel(ACtx, AActorId, ATargetProjectId, Row.Key, Before, Row.Level, ASource);
  end;
  RevokeAllForProject(ACtx, AActorId, ASourceProjectId, ASource);
end;

function NormalizeLegacyWriteLevel(const ACtx: IMxDbContext): Integer;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'UPDATE developer_project_access SET access_level = ''read-write'' ' +
    'WHERE access_level = ''write''');
  try
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

end.
