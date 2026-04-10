unit mx.Data.Invite;

// v2.4.0: Data layer for invite_links table (Spec #1755, Plan #1756 Phase 3.1).
// All state transitions flow through this unit; business rules live in
// mx.Logic.Invite.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client,
  mx.Types;

type
  TMxInviteRecord = record
    Id: Integer;
    Token: string;
    DeveloperId: Integer;
    ClientKeyId: Integer;
    Mode: string;
    ExpiresAt: TDateTime;
    FirstViewedAt: TDateTime;   // 0 if NULL
    RevokedAt: TDateTime;       // 0 if NULL
    RevokedBy: Integer;         // 0 if NULL
    ConsumerIp: string;
    CreatedBy: Integer;
    CreatedAt: TDateTime;
    // v2.4.0 R4 (Security ADR#1767): raw key obfuscated at rest,
    // nulled after Confirm or 1h after First-View.
    RawApiKeyObfuscated: string; // empty if NULL (post-confirm or cleaned)
    ConfirmedAt: TDateTime;      // 0 if NULL
  end;

  TMxInviteData = class
  public
    /// <summary>
    ///   Insert a new invite row with obfuscated raw API key (from
    ///   mxEncryptStaticString). Returns new id or 0 on failure.
    /// </summary>
    class function CreateInvite(ACtx: IMxDbContext;
      const AToken: string; ADeveloperId, AClientKeyId: Integer;
      const AMode: string; AExpiresAt: TDateTime;
      ACreatedBy: Integer; const ARawApiKeyObfuscated: string): Integer; static;

    /// <summary>Lookup by token. Returns False if not found.</summary>
    class function GetByToken(ACtx: IMxDbContext; const AToken: string;
      out ARecord: TMxInviteRecord): Boolean; static;

    /// <summary>Lookup by id. Returns False if not found.</summary>
    class function GetById(ACtx: IMxDbContext; AId: Integer;
      out ARecord: TMxInviteRecord): Boolean; static;

    /// <summary>All invites for a developer, newest first. Optional active-only filter.</summary>
    class function ListByDeveloper(ACtx: IMxDbContext;
      ADeveloperId: Integer; AActiveOnly: Boolean): TArray<TMxInviteRecord>; static;

    /// <summary>
    ///   All invites across the system, newest first. AStatusFilter is
    ///   'active' / 'expired' / 'revoked' / '' (no filter). Hard-capped
    ///   at 500 rows for admin UI pagination.
    /// </summary>
    class function ListAll(ACtx: IMxDbContext;
      const AStatusFilter: string): TArray<TMxInviteRecord>; static;

    /// <summary>
    ///   Sets first_viewed_at + consumer_ip. Returns True only on the first
    ///   call (actual row update); subsequent calls return False because the
    ///   row already has first_viewed_at set. Callers can use this to detect
    ///   "is this a fresh view?" for audit / telemetry.
    /// </summary>
    class function MarkFirstViewed(ACtx: IMxDbContext;
      AId: Integer; const AConsumerIp: string): Boolean; static;

    /// <summary>
    ///   Sets confirmed_at + nulls raw_api_key_obfuscated. Idempotent — only
    ///   updates if not already confirmed. Returns True if the confirm happened
    ///   now, False if it was already confirmed (replay / double-click).
    ///   This is the consumer-initiated lifecycle event per ADR#1767.
    /// </summary>
    class function ConfirmInvite(ACtx: IMxDbContext; AId: Integer): Boolean; static;

    /// <summary>
    ///   Sets revoked_at + revoked_by AND nulls raw_api_key_obfuscated.
    ///   Returns True only if a row was actually revoked now.
    ///   Note: the linked client_keys row is NOT deactivated — invites and
    ///   keys have independent lifecycles (ADR#1767, no key-recycling).
    /// </summary>
    class function Revoke(ACtx: IMxDbContext;
      AId: Integer; ARevokedBy: Integer): Boolean; static;

    /// <summary>
    ///   Cleanup job: nulls raw_api_key_obfuscated on invites that were
    ///   first-viewed more than AMinutesAgo minutes ago without being confirmed.
    ///   Prevents unconfirmed raw keys from lingering. Returns affected rows.
    /// </summary>
    class function NullUnconfirmedRawKeys(ACtx: IMxDbContext;
      AMinutesAgo: Integer): Integer; static;

    /// <summary>Hard-delete a single invite (only if revoked or expired). Returns True if deleted.</summary>
    class function DeleteById(ACtx: IMxDbContext; AId: Integer): Boolean; static;

    /// <summary>Hard-delete ALL revoked+expired invites. Returns affected row count.</summary>
    class function DeleteAllInactive(ACtx: IMxDbContext): Integer; static;

    /// <summary>Delete expired/revoked invites older than ADaysOld days. Returns affected rows.</summary>
    class function DeleteStale(ACtx: IMxDbContext;
      ADaysOld: Integer): Integer; static;
  end;

implementation

{ TMxInviteData }

// All SELECTs include the raw_api_key_obfuscated + confirmed_at columns
// added in the v2.4.0 R4 schema migration (ADR#1767).
const
  CInviteSelectCols =
    'SELECT id, token, developer_id, client_key_id, mode, expires_at, ' +
    '  first_viewed_at, revoked_at, revoked_by, consumer_ip, ' +
    '  created_by, created_at, raw_api_key_obfuscated, confirmed_at ';

procedure ReadInviteRow(AQry: TFDQuery; out ARecord: TMxInviteRecord);
begin
  ARecord.Id := AQry.FieldByName('id').AsInteger;
  ARecord.Token := AQry.FieldByName('token').AsString;
  ARecord.DeveloperId := AQry.FieldByName('developer_id').AsInteger;
  ARecord.ClientKeyId := AQry.FieldByName('client_key_id').AsInteger;
  ARecord.Mode := AQry.FieldByName('mode').AsString;
  ARecord.ExpiresAt := AQry.FieldByName('expires_at').AsDateTime;
  if AQry.FieldByName('first_viewed_at').IsNull then
    ARecord.FirstViewedAt := 0
  else
    ARecord.FirstViewedAt := AQry.FieldByName('first_viewed_at').AsDateTime;
  if AQry.FieldByName('revoked_at').IsNull then
    ARecord.RevokedAt := 0
  else
    ARecord.RevokedAt := AQry.FieldByName('revoked_at').AsDateTime;
  if AQry.FieldByName('revoked_by').IsNull then
    ARecord.RevokedBy := 0
  else
    ARecord.RevokedBy := AQry.FieldByName('revoked_by').AsInteger;
  ARecord.ConsumerIp := AQry.FieldByName('consumer_ip').AsString;
  ARecord.CreatedBy := AQry.FieldByName('created_by').AsInteger;
  ARecord.CreatedAt := AQry.FieldByName('created_at').AsDateTime;
  if AQry.FieldByName('raw_api_key_obfuscated').IsNull then
    ARecord.RawApiKeyObfuscated := ''
  else
    ARecord.RawApiKeyObfuscated := AQry.FieldByName('raw_api_key_obfuscated').AsString;
  if AQry.FieldByName('confirmed_at').IsNull then
    ARecord.ConfirmedAt := 0
  else
    ARecord.ConfirmedAt := AQry.FieldByName('confirmed_at').AsDateTime;
end;

class function TMxInviteData.CreateInvite(ACtx: IMxDbContext;
  const AToken: string; ADeveloperId, AClientKeyId: Integer;
  const AMode: string; AExpiresAt: TDateTime;
  ACreatedBy: Integer; const ARawApiKeyObfuscated: string): Integer;
var
  Qry: TFDQuery;
begin
  Result := 0;
  Qry := ACtx.CreateQuery(
    'INSERT INTO invite_links ' +
    '(token, developer_id, client_key_id, mode, expires_at, created_by, raw_api_key_obfuscated) ' +
    'VALUES (:t, :d, :k, :m, :e, :c, :r)');
  try
    Qry.ParamByName('t').AsString := AToken;
    Qry.ParamByName('d').AsInteger := ADeveloperId;
    Qry.ParamByName('k').AsInteger := AClientKeyId;
    Qry.ParamByName('m').AsString := AMode;
    Qry.ParamByName('e').AsDateTime := AExpiresAt;
    Qry.ParamByName('c').AsInteger := ACreatedBy;
    Qry.ParamByName('r').AsString := ARawApiKeyObfuscated;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;

  // Retrieve last insert id via separate query (keeps this unit driver-agnostic)
  Qry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
  try
    Qry.Open;
    if not Qry.IsEmpty then
      Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.GetByToken(ACtx: IMxDbContext;
  const AToken: string; out ARecord: TMxInviteRecord): Boolean;
var
  Qry: TFDQuery;
begin
  Result := False;
  Qry := ACtx.CreateQuery(CInviteSelectCols +
    'FROM invite_links WHERE token = :t');
  try
    Qry.ParamByName('t').AsString := AToken;
    Qry.Open;
    if not Qry.IsEmpty then
    begin
      ReadInviteRow(Qry, ARecord);
      Result := True;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.GetById(ACtx: IMxDbContext; AId: Integer;
  out ARecord: TMxInviteRecord): Boolean;
var
  Qry: TFDQuery;
begin
  Result := False;
  Qry := ACtx.CreateQuery(CInviteSelectCols +
    'FROM invite_links WHERE id = :i');
  try
    Qry.ParamByName('i').AsInteger := AId;
    Qry.Open;
    if not Qry.IsEmpty then
    begin
      ReadInviteRow(Qry, ARecord);
      Result := True;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.ListByDeveloper(ACtx: IMxDbContext;
  ADeveloperId: Integer; AActiveOnly: Boolean): TArray<TMxInviteRecord>;
var
  Qry: TFDQuery;
  List: TList<TMxInviteRecord>;
  Rec: TMxInviteRecord;
  Sql: string;
begin
  Sql := CInviteSelectCols +
    'FROM invite_links WHERE developer_id = :d';
  if AActiveOnly then
    Sql := Sql + ' AND revoked_at IS NULL AND expires_at > NOW()';
  Sql := Sql + ' ORDER BY created_at DESC';

  List := TList<TMxInviteRecord>.Create;
  try
    Qry := ACtx.CreateQuery(Sql);
    try
      Qry.ParamByName('d').AsInteger := ADeveloperId;
      Qry.Open;
      while not Qry.Eof do
      begin
        ReadInviteRow(Qry, Rec);
        List.Add(Rec);
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

class function TMxInviteData.ListAll(ACtx: IMxDbContext;
  const AStatusFilter: string): TArray<TMxInviteRecord>;
var
  Qry: TFDQuery;
  List: TList<TMxInviteRecord>;
  Rec: TMxInviteRecord;
  Sql: string;
begin
  Sql := CInviteSelectCols + 'FROM invite_links';
  if SameText(AStatusFilter, 'active') then
    Sql := Sql + ' WHERE revoked_at IS NULL AND confirmed_at IS NULL AND expires_at > NOW()'
  else if SameText(AStatusFilter, 'expired') then
    Sql := Sql + ' WHERE revoked_at IS NULL AND expires_at <= NOW()'
  else if SameText(AStatusFilter, 'revoked') then
    Sql := Sql + ' WHERE revoked_at IS NOT NULL'
  else if SameText(AStatusFilter, 'confirmed') then
    Sql := Sql + ' WHERE confirmed_at IS NOT NULL AND revoked_at IS NULL';
  Sql := Sql + ' ORDER BY created_at DESC LIMIT 500';

  List := TList<TMxInviteRecord>.Create;
  try
    Qry := ACtx.CreateQuery(Sql);
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        ReadInviteRow(Qry, Rec);
        // Defense-in-depth: scrub the obfuscated key from admin-facing list
        // results so it cannot leak through future JSON serializers.
        Rec.RawApiKeyObfuscated := '';
        List.Add(Rec);
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

class function TMxInviteData.MarkFirstViewed(ACtx: IMxDbContext;
  AId: Integer; const AConsumerIp: string): Boolean;
var
  Qry: TFDQuery;
begin
  // Only updates if not already viewed (first click wins).
  // RowsAffected = 1 → fresh view; 0 → already viewed.
  Qry := ACtx.CreateQuery(
    'UPDATE invite_links SET ' +
    '  first_viewed_at = CURRENT_TIMESTAMP, ' +
    '  consumer_ip = :ip ' +
    'WHERE id = :i AND first_viewed_at IS NULL');
  try
    Qry.ParamByName('ip').AsString := AConsumerIp;
    Qry.ParamByName('i').AsInteger := AId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.ConfirmInvite(ACtx: IMxDbContext;
  AId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  // Idempotent: only fires on first confirm. Nulls raw_api_key_obfuscated
  // because the consumer no longer needs it (they have stored the key in
  // their client). This is the "post-confirm delete" from ADR#1767.
  Qry := ACtx.CreateQuery(
    'UPDATE invite_links SET ' +
    '  confirmed_at = CURRENT_TIMESTAMP, ' +
    '  raw_api_key_obfuscated = NULL ' +
    'WHERE id = :i AND confirmed_at IS NULL');
  try
    Qry.ParamByName('i').AsInteger := AId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.Revoke(ACtx: IMxDbContext;
  AId: Integer; ARevokedBy: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  // Admin-initiated revoke — also nulls the raw key (if still present).
  // The underlying client_keys row is NOT deactivated (ADR#1767 decision:
  // invites and keys have independent lifecycles).
  Qry := ACtx.CreateQuery(
    'UPDATE invite_links SET ' +
    '  revoked_at = CURRENT_TIMESTAMP, ' +
    '  revoked_by = :rb, ' +
    '  raw_api_key_obfuscated = NULL ' +
    'WHERE id = :i AND revoked_at IS NULL');
  try
    Qry.ParamByName('rb').AsInteger := ARevokedBy;
    Qry.ParamByName('i').AsInteger := AId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.NullUnconfirmedRawKeys(ACtx: IMxDbContext;
  AMinutesAgo: Integer): Integer;
var
  Qry: TFDQuery;
begin
  Result := 0;
  if AMinutesAgo <= 0 then Exit;
  // Defense-in-depth: if the consumer opened the link but never clicked
  // "Confirm", null the raw key after the grace period. Prevents unconfirmed
  // raw keys from lingering in the DB until expires_at (which may be days).
  Qry := ACtx.CreateQuery(
    'UPDATE invite_links SET raw_api_key_obfuscated = NULL ' +
    'WHERE raw_api_key_obfuscated IS NOT NULL ' +
    '  AND first_viewed_at IS NOT NULL ' +
    '  AND confirmed_at IS NULL ' +
    '  AND first_viewed_at < DATE_SUB(NOW(), INTERVAL :m MINUTE)');
  try
    Qry.ParamByName('m').AsInteger := AMinutesAgo;
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.DeleteById(ACtx: IMxDbContext; AId: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'DELETE FROM invite_links WHERE id = :id ' +
    'AND (revoked_at IS NOT NULL OR expires_at < NOW() OR confirmed_at IS NOT NULL)');
  try
    Qry.ParamByName('id').AsInteger := AId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.DeleteAllInactive(ACtx: IMxDbContext): Integer;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'DELETE FROM invite_links WHERE revoked_at IS NOT NULL OR expires_at < NOW() OR confirmed_at IS NOT NULL');
  try
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

class function TMxInviteData.DeleteStale(ACtx: IMxDbContext;
  ADaysOld: Integer): Integer;
var
  Qry: TFDQuery;
begin
  Result := 0;
  if ADaysOld <= 0 then Exit;
  Qry := ACtx.CreateQuery(
    'DELETE FROM invite_links ' +
    'WHERE (expires_at < NOW() OR revoked_at IS NOT NULL) ' +
    '  AND created_at < DATE_SUB(NOW(), INTERVAL :d DAY)');
  try
    Qry.ParamByName('d').AsInteger := ADaysOld;
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

end.
