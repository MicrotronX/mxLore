unit mx.Logic.AdminRecovery;

// Break-glass admin-key recovery. Issues a fresh admin client_key for an
// existing developer when the plaintext key was lost but the key row is still
// active (so the HasNoDevelopers setup-bypass in mx.Admin.Server does NOT fire
// and the operator is locked out of the Admin-UI).
//
// Authorization anchor: host access. The operator already holds the INI DB
// credentials and can reach the database directly, so this crosses no new
// trust boundary -- the same trust level as --encrypt. No AD/SMTP dependency.
//
// I/O is decoupled via an output callback so both frontends can drive it: the
// console exe writes lines to stdout, the VCL GUI (no console) collects the
// lines and shows them in a modal dialog. The unit owns its own short-lived
// TMxConfig + TMxConnectionPool because it runs as a one-shot op before server
// boot -- there is no Boot-managed pool to borrow at that point.

interface

type
  /// <summary>Per-line output sink (stdout for console, dialog buffer for GUI).</summary>
  TMxRecoveryOutput = reference to procedure(const ALine: string);

/// <summary>
///   Core handler for --issue-admin-key, frontend-agnostic.
///   ATarget = ''            -> list developers (no mutation).
///   ATarget = id or name    -> issue an admin key for that developer; the
///                              plaintext is emitted via AOutput exactly once.
///   Returns a process exit code: 0 = ok/listed, 1 = config/DB error,
///   2 = target could not be resolved (not found / ambiguous).
/// </summary>
function MxIssueAdminKey(const AConfigPath, ATarget: string;
  const AOutput: TMxRecoveryOutput): Integer;

/// <summary>
///   Core handler for --break-glass (Spec#19960 Req 7). Rescues a private
///   project through host access only, there is no HTTP path.
///   AAction = 'public'      -> lift the private flag.
///   AAction = 'owner'       -> set ADeveloperId as owner, with read-write.
///   Writes a break_glass row to access_audit. Returns 0 = ok, 1 = config/DB
///   error, 2 = bad arguments or unknown project/developer.
/// </summary>
function MxBreakGlassProject(const AConfigPath, ASlug, AAction: string;
  ADeveloperId: Integer; const AOutput: TMxRecoveryOutput): Integer;

/// <summary>Console convenience wrapper: routes every line to WriteLn (stdout).</summary>
function MxRunIssueAdminKeyCli(const AConfigPath, ATarget: string): Integer;

implementation

uses
  System.SysUtils, System.DateUtils,
  FireDAC.Comp.Client,
  mx.Types, mx.Config, mx.Data.Pool, mx.Crypto, mx.Logic.AccessWrite;

// Recovery keys get the same 180-day default expiry as an admin key created via
// the Admin-UI (mx.Admin.Api.Keys HandleCreateKey M3.3), so a recovery key is
// an ordinary admin key with no special-casing downstream.
const
  ADMIN_KEY_EXPIRY_DAYS = 180;

procedure ListDevelopers(APool: TMxConnectionPool; const AOutput: TMxRecoveryOutput);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Count: Integer;
begin
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT d.id, d.name, d.is_active, ' +
    '  (SELECT COUNT(*) FROM client_keys ck ' +
    '   WHERE ck.developer_id = d.id AND ck.is_active = TRUE ' +
    '     AND ck.permissions = ''admin'' AND ck.revoked_at IS NULL) AS admin_keys ' +
    'FROM developers d ORDER BY d.id');
  try
    Qry.Open;
    Count := 0;
    AOutput('Developers (pass id or name as the argument):');
    AOutput('   ID | active | admin-keys | name');
    AOutput('  ----+--------+------------+------------------------------');
    while not Qry.Eof do
    begin
      Inc(Count);
      AOutput(Format('  %3d | %-6s | %10d | %s',
        [Qry.FieldByName('id').AsInteger,
         BoolToStr(Qry.FieldByName('is_active').AsBoolean, True),
         Qry.FieldByName('admin_keys').AsInteger,
         Qry.FieldByName('name').AsString]));
      Qry.Next;
    end;
    if Count = 0 then
      AOutput('  (none yet -- start the server once: the Admin-UI runs in setup '
        + 'mode while no admin key exists)');
  finally
    Qry.Free;
  end;
  AOutput('');
  AOutput('Usage: --issue-admin-key <developer-id|developer-name>');
end;

function IssueForTarget(APool: TMxConnectionPool; const ATarget: string;
  const AOutput: TMxRecoveryOutput): Integer;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  TargetId, MatchCount, DevId: Integer;
  DevName: string;
  DevActive: Boolean;
  RawKey, KeyHash, KeyName: string;
begin
  Ctx := APool.AcquireContext;

  // Resolve target -> developer. All-digits => id lookup, else exact (case-
  // insensitive) name lookup.
  if TryStrToInt(ATarget, TargetId) then
  begin
    Qry := Ctx.CreateQuery(
      'SELECT id, name, is_active FROM developers WHERE id = :v');
    Qry.ParamByName('v').AsInteger := TargetId;
  end
  else
  begin
    Qry := Ctx.CreateQuery(
      'SELECT id, name, is_active FROM developers WHERE LOWER(name) = LOWER(:v)');
    Qry.ParamByName('v').AsWideString := ATarget;
  end;

  MatchCount := 0;
  DevId := 0;
  DevName := '';
  DevActive := False;
  try
    Qry.Open;
    while not Qry.Eof do
    begin
      Inc(MatchCount);
      DevId := Qry.FieldByName('id').AsInteger;
      DevName := Qry.FieldByName('name').AsString;
      DevActive := Qry.FieldByName('is_active').AsBoolean;
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;

  if MatchCount = 0 then
  begin
    AOutput(Format('issue-admin-key: no developer matches "%s".', [ATarget]));
    AOutput('');
    ListDevelopers(APool, AOutput);
    Exit(2);
  end;
  if MatchCount > 1 then
  begin
    AOutput(Format(
      'issue-admin-key: name "%s" is ambiguous (%d matches) -- pass the numeric id.',
      [ATarget, MatchCount]));
    AOutput('');
    ListDevelopers(APool, AOutput);
    Exit(2);
  end;

  // Generate + persist the admin key. Same format/hashing as every other key
  // (mxk_ + 32 hex, PBKDF2 via MxHashKey, 12-char key_prefix for fast lookup).
  RawKey := 'mxk_' + MxGenerateRandomHex(16);
  KeyHash := MxHashKey(RawKey);
  KeyName := 'cli-recovery-' + FormatDateTime('yyyymmdd-hhnn', Now);

  // Key and audit row in one transaction: no admin key without a trace.
  // Not tied to a project, so project_id = 0.
  Ctx.StartTransaction;
  try
    Qry := Ctx.CreateQuery(
      'INSERT INTO client_keys (developer_id, name, key_hash, key_prefix, ' +
      '  permissions, is_active, created_at, expires_at) ' +
      'VALUES (:d, :n, :h, :p, ''admin'', TRUE, NOW(), :exp)');
    try
      Qry.ParamByName('d').AsInteger := DevId;
      Qry.ParamByName('n').AsWideString := KeyName;
      Qry.ParamByName('h').AsWideString := KeyHash;
      Qry.ParamByName('p').AsWideString := Copy(RawKey, 1, 12);
      Qry.ParamByName('exp').AsDateTime := IncDay(Now, ADMIN_KEY_EXPIRY_DAYS);
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;
    WriteAccessEvent(Ctx, 0, 0, DevId, 'break_glass', '', 'admin-key', 'server-cli');
    Ctx.Commit;
  except
    Ctx.Rollback;
    raise;
  end;

  AOutput('');
  AOutput(Format('New ADMIN key issued for developer #%d (%s):', [DevId, DevName]));
  AOutput('');
  AOutput('    ' + RawKey);
  AOutput('');
  AOutput(Format('Shown ONCE -- store it now. Key name: %s, expires in %d days.',
    [KeyName, ADMIN_KEY_EXPIRY_DAYS]));
  if not DevActive then
    AOutput(Format('WARNING: developer #%d is INACTIVE -- the key will NOT '
      + 'authenticate until the developer is reactivated.', [DevId]));
  Result := 0;
end;

function MxIssueAdminKey(const AConfigPath, ATarget: string;
  const AOutput: TMxRecoveryOutput): Integer;
var
  Config: TMxConfig;
  Pool: TMxConnectionPool;
begin
  Result := 1;
  Config := nil;
  Pool := nil;
  try
    try
      Config := TMxConfig.Create(AConfigPath);
      Pool := TMxConnectionPool.Create(Config);
    except
      on E: Exception do
      begin
        AOutput('issue-admin-key: cannot open database: ' + E.Message);
        Exit(1);
      end;
    end;

    try
      if Trim(ATarget) = '' then
      begin
        ListDevelopers(Pool, AOutput);
        Result := 0;
      end
      else
        Result := IssueForTarget(Pool, Trim(ATarget), AOutput);
    except
      on E: Exception do
      begin
        AOutput('issue-admin-key: failed: ' + E.Message);
        Result := 1;
      end;
    end;
  finally
    Pool.Free;
    Config.Free;
  end;
end;

function MxBreakGlassProject(const AConfigPath, ASlug, AAction: string;
  ADeveloperId: Integer; const AOutput: TMxRecoveryOutput): Integer;
var
  Config: TMxConfig;
  Pool: TMxConnectionPool;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ProjectId: Integer;
  ToOwner: Boolean;
begin
  ToOwner := SameText(AAction, 'owner');
  if (ASlug = '') or not (ToOwner or SameText(AAction, 'public')) or
     (ToOwner and (ADeveloperId <= 0)) then
  begin
    AOutput('usage: --break-glass <project-slug> public');
    AOutput('       --break-glass <project-slug> owner <developer-id>');
    Exit(2);
  end;

  Config := nil;
  Pool := nil;
  try
    try
      Config := TMxConfig.Create(AConfigPath);
      Pool := TMxConnectionPool.Create(Config);
      Ctx := Pool.AcquireContext;

      Qry := Ctx.CreateQuery('SELECT id FROM projects WHERE slug = :slug');
      try
        Qry.ParamByName('slug').AsWideString := ASlug;
        Qry.Open;
        if Qry.IsEmpty then
        begin
          AOutput('break-glass: unknown project: ' + ASlug);
          Exit(2);
        end;
        ProjectId := Qry.FieldByName('id').AsInteger;
      finally
        Qry.Free;
      end;

      if ToOwner then
      begin
        Qry := Ctx.CreateQuery('SELECT 1 FROM developers WHERE id = :id');
        try
          Qry.ParamByName('id').AsInteger := ADeveloperId;
          Qry.Open;
          if Qry.IsEmpty then
          begin
            AOutput('break-glass: unknown developer: ' + IntToStr(ADeveloperId));
            Exit(2);
          end;
        finally
          Qry.Free;
        end;
      end;

      Ctx.StartTransaction;
      try
        if ToOwner then
          BreakGlassSetOwner(Ctx, ProjectId, ADeveloperId)
        else
          BreakGlassMakePublic(Ctx, ProjectId);
        Ctx.Commit;
      except
        Ctx.Rollback;
        raise;
      end;
      AOutput('break-glass: done for ' + ASlug + ', recorded in access_audit.');
      Result := 0;
    except
      on E: Exception do
      begin
        AOutput('break-glass: failed: ' + E.Message);
        Result := 1;
      end;
    end;
  finally
    Ctx := nil;
    Pool.Free;
    Config.Free;
  end;
end;

function MxRunIssueAdminKeyCli(const AConfigPath, ATarget: string): Integer;
begin
  Result := MxIssueAdminKey(AConfigPath, ATarget,
    procedure(const ALine: string)
    begin
      WriteLn(ALine);
    end);
end;

end.
