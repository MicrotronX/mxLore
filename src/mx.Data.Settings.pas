unit mx.Data.Settings;

// v2.4.0: Runtime-editable settings backed by app_settings table.
// Replaces INI for values changeable via Admin-UI.
// Thread-safe via DB transactions; caching handled by mx.Logic.Settings.

interface

uses
  System.SysUtils, System.Classes, System.Variants, System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client,
  mx.Types;

type
  TMxSettingRecord = record
    Key: string;
    Value: string;
    UpdatedAt: TDateTime;
    UpdatedBy: Integer;  // 0 = unknown/seed
  end;

  TMxSettingsData = class
  public
    // Single key read. Returns empty string if key missing.
    class function GetSetting(ACtx: IMxDbContext; const AKey: string): string; static;

    // Single key write. Upserts. UpdatedBy=0 allowed for system writes.
    class function SetSetting(ACtx: IMxDbContext; const AKey, AValue: string;
      AUpdatedBy: Integer): Boolean; static;

    // Full list (used by GET /api/settings). Ordered by key.
    class function GetAllSettings(ACtx: IMxDbContext): TArray<TMxSettingRecord>; static;

    // Atomic batch-update inside a transaction. All-or-nothing.
    // Returns True on success, False on any error (transaction rolled back).
    class function SetMultipleSettings(ACtx: IMxDbContext;
      const AUpdates: TDictionary<string, string>;
      AUpdatedBy: Integer): Boolean; static;
  end;

implementation

{ TMxSettingsData }

class function TMxSettingsData.GetSetting(ACtx: IMxDbContext;
  const AKey: string): string;
var
  Qry: TFDQuery;
begin
  Result := '';
  Qry := ACtx.CreateQuery(
    'SELECT setting_value FROM app_settings WHERE setting_key = :k');
  try
    Qry.ParamByName('k').AsString := AKey;
    Qry.Open;
    if not Qry.IsEmpty then
      Result := Qry.FieldByName('setting_value').AsString;
  finally
    Qry.Free;
  end;
end;

class function TMxSettingsData.SetSetting(ACtx: IMxDbContext;
  const AKey, AValue: string; AUpdatedBy: Integer): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'INSERT INTO app_settings (setting_key, setting_value, updated_by) ' +
    'VALUES (:k, :v, :uid) ' +
    'ON DUPLICATE KEY UPDATE ' +
    '  setting_value = VALUES(setting_value), ' +
    '  updated_by = VALUES(updated_by), ' +
    '  updated_at = CURRENT_TIMESTAMP');
  try
    Qry.ParamByName('k').AsString := AKey;
    Qry.ParamByName('v').AsString := AValue;
    if AUpdatedBy > 0 then
      Qry.ParamByName('uid').AsInteger := AUpdatedBy
    else
    begin
      Qry.ParamByName('uid').DataType := ftInteger;
      Qry.ParamByName('uid').Value := Null;
    end;
    Qry.ExecSQL;
    // ON DUPLICATE KEY UPDATE returns 0 rows_affected when value is unchanged.
    // Any successful ExecSQL (no exception) means the upsert worked.
    Result := True;
  finally
    Qry.Free;
  end;
end;

class function TMxSettingsData.GetAllSettings(ACtx: IMxDbContext): TArray<TMxSettingRecord>;
var
  Qry: TFDQuery;
  List: TList<TMxSettingRecord>;
  Rec: TMxSettingRecord;
begin
  List := TList<TMxSettingRecord>.Create;
  try
    Qry := ACtx.CreateQuery(
      'SELECT setting_key, setting_value, updated_at, ' +
      '  COALESCE(updated_by, 0) AS updated_by ' +
      'FROM app_settings ORDER BY setting_key');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Rec.Key := Qry.FieldByName('setting_key').AsString;
        Rec.Value := Qry.FieldByName('setting_value').AsString;
        Rec.UpdatedAt := Qry.FieldByName('updated_at').AsDateTime;
        Rec.UpdatedBy := Qry.FieldByName('updated_by').AsInteger;
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

class function TMxSettingsData.SetMultipleSettings(ACtx: IMxDbContext;
  const AUpdates: TDictionary<string, string>; AUpdatedBy: Integer): Boolean;
var
  Pair: TPair<string, string>;
  Qry: TFDQuery;
begin
  Result := False;
  if (AUpdates = nil) or (AUpdates.Count = 0) then
    Exit(True);  // Nothing to do = success

  // Use transaction for atomic batch
  ACtx.StartTransaction;
  try
    Qry := ACtx.CreateQuery(
      'INSERT INTO app_settings (setting_key, setting_value, updated_by) ' +
      'VALUES (:k, :v, :uid) ' +
      'ON DUPLICATE KEY UPDATE ' +
      '  setting_value = VALUES(setting_value), ' +
      '  updated_by = VALUES(updated_by), ' +
      '  updated_at = CURRENT_TIMESTAMP');
    try
      for Pair in AUpdates do
      begin
        Qry.ParamByName('k').AsString := Pair.Key;
        Qry.ParamByName('v').AsString := Pair.Value;
        if AUpdatedBy > 0 then
          Qry.ParamByName('uid').AsInteger := AUpdatedBy
        else
          Qry.ParamByName('uid').Clear;
        Qry.ExecSQL;
      end;
    finally
      Qry.Free;
    end;
    ACtx.Commit;
    Result := True;
  except
    on E: Exception do
    begin
      try ACtx.Rollback; except end;
      if Assigned(ACtx.Logger) then
        ACtx.Logger.Log(mlError,
          'SetMultipleSettings transaction rolled back: ' + E.Message);
      Result := False;
    end;
  end;
end;

end.
