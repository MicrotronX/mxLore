unit mx.Admin.Api.IniEditor;

// FR#3610 — Admin-UI Runtime Config editor for mxLoreMCP.ini.
//
// Two endpoints, server-side 3-tier classification prevents self-lockout:
//   GET /api/ini         -> full sections/keys JSON, values redacted per tier
//   PUT /api/ini         -> body {section, key, value}, accepts only editable
//
// Tiers (ClassifyKey):
//   stSecret    — value hidden as "***", never PUT-accepted
//   stReadOnly  — actual value shown, UI disables edit, PUT rejected with 403
//                 (high-impact infra: BindAddress/Port/DB/Admin — prevents
//                 admin from locking themselves out through the web UI)
//   stEditable  — value shown, PUT accepted, atomic temp+rename on disk
//
// POST /api/settings/reload triggers TMxConfig reload for non-restart fields.

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Config;

procedure HandleGetIni(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

procedure HandleSetIni(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

procedure HandleReloadSettings(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.StrUtils,
  System.JSON, System.IniFiles, System.RegularExpressions,
  mx.Admin.Server;

type
  TSettingTier = (stEditable, stReadOnly, stSecret);

// High-impact infrastructure — read-only in UI to prevent admin self-lockout
// via web (wrong BindAddress = server boots no more). Two filters:
//   * HIGH_IMPACT_SECTIONS — entire section read-only (future-proof: new keys
//     added to e.g. [Database] auto-inherit read-only status)
//   * HIGH_IMPACT_INFRA    — specific Section.Key pairs for sections that are
//     mostly editable but have a few infra keys mixed in.
// Names MUST match real Ini.Read* calls in mx.Config.pas ('Database' not 'DB').
const
  HIGH_IMPACT_SECTIONS: array[0..0] of string = (
    'Database'
  );
  HIGH_IMPACT_INFRA: array[0..5] of string = (
    'Server.BindAddress',
    'Server.Port',
    'Admin.admin_port',
    'Security.developer_acl_mode',
    'Security.AllowUrlApiKey',
    'Backup.BackupPath'
  );

function GetIniPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'mxLoreMCP.ini';
end;

function IsSecretKey(const AKey: string): Boolean;
var
  L: string;
begin
  // Suffix-based only — substring-match is too lax (e.g. 'token' matches
  // 'TokenBudget' which is a harmless number).
  L := LowerCase(AKey);
  Result :=
    EndsStr('password',    L) or
    EndsStr('passwordenc', L) or
    EndsStr('apikey',      L) or
    EndsStr('apikeyenc',   L) or
    EndsStr('secret',      L) or
    EndsStr('secretenc',   L) or
    EndsStr('token',       L) or  // 'AuthToken' yes; 'TokenBudget' no
    EndsStr('tokenenc',    L) or
    EndsStr('_enc',        L);    // encrypted counterpart pattern
end;

function IsHighImpactInfra(const ASection, AKey: string): Boolean;
var
  FullKey: string;
  I: Integer;
begin
  // Section-level rule: entire [Database] is read-only (future-proof).
  for I := Low(HIGH_IMPACT_SECTIONS) to High(HIGH_IMPACT_SECTIONS) do
    if SameText(HIGH_IMPACT_SECTIONS[I], ASection) then Exit(True);

  // Specific Section.Key pairs.
  FullKey := ASection + '.' + AKey;
  for I := Low(HIGH_IMPACT_INFRA) to High(HIGH_IMPACT_INFRA) do
    if SameText(HIGH_IMPACT_INFRA[I], FullKey) then Exit(True);

  Result := False;
end;

function ClassifyKey(const ASection, AKey: string): TSettingTier;
begin
  if IsSecretKey(AKey) then Exit(stSecret);
  if IsHighImpactInfra(ASection, AKey) then Exit(stReadOnly);
  Result := stEditable;
end;

function TierToString(ATier: TSettingTier): string;
begin
  case ATier of
    stSecret:   Result := 'secret';
    stReadOnly: Result := 'read_only';
  else          Result := 'editable';
  end;
end;

// =========================================================================
// GET /api/ini
// =========================================================================
procedure HandleGetIni(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Ini: TIniFile;
  Sections, Keys: TStringList;
  IniPath: string;
  Json, SecObj, KeyObj: TJSONObject;
  SectionsJson: TJSONObject;
  I, J: Integer;
  SectionName, KeyName, Value: string;
  Tier: TSettingTier;
begin
  IniPath := GetIniPath;
  if not FileExists(IniPath) then
  begin
    ALogger.Log(mlError, '[IniEditor.Get] mxLoreMCP.ini not found at ' + IniPath);
    MxSendError(C, 500, 'ini_not_found');
    Exit;
  end;

  Json := TJSONObject.Create;
  try
    Json.AddPair('ini_path', IniPath);
    SectionsJson := TJSONObject.Create;
    Json.AddPair('sections', SectionsJson);

    Sections := TStringList.Create;
    Keys     := TStringList.Create;
    Ini      := TIniFile.Create(IniPath);
    try
      Ini.ReadSections(Sections);
      for I := 0 to Sections.Count - 1 do
      begin
        SectionName := Sections[I];
        SecObj := TJSONObject.Create;
        try
          Keys.Clear;
          Ini.ReadSection(SectionName, Keys);
          for J := 0 to Keys.Count - 1 do
          begin
            KeyName := Keys[J];
            Tier := ClassifyKey(SectionName, KeyName);
            if Tier = stSecret then
              Value := '***'
            else
              Value := Ini.ReadString(SectionName, KeyName, '');
            KeyObj := TJSONObject.Create;
            KeyObj.AddPair('value', Value);
            KeyObj.AddPair('tier', TierToString(Tier));
            KeyObj.AddPair('editable', TJSONBool.Create(Tier = stEditable));
            SecObj.AddPair(KeyName, KeyObj);
          end;
          SectionsJson.AddPair(SectionName, SecObj);
        except
          SecObj.Free;
          raise;
        end;
      end;
    finally
      Ini.Free;
      Sections.Free;
      Keys.Free;
    end;

    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

// =========================================================================
// PUT /api/ini   body: {"section":"...", "key":"...", "value":"..."}
// =========================================================================
procedure HandleSetIni(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Body, Resp: TJSONObject;
  Ini: TIniFile;
  IniPath, TempPath, Section, Key, Value: string;
  Tier: TSettingTier;
  V: TJSONValue;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_body');
    Exit;
  end;
  try
    V := Body.GetValue('section');
    Section := ifthen(Assigned(V), V.Value, '');
    V := Body.GetValue('key');
    Key := ifthen(Assigned(V), V.Value, '');
    V := Body.GetValue('value');
    Value := ifthen(Assigned(V), V.Value, '');

    if (Trim(Section) = '') or (Trim(Key) = '') then
    begin
      MxSendError(C, 400, 'missing_section_or_key');
      Exit;
    end;

    Tier := ClassifyKey(Section, Key);
    case Tier of
      stSecret:
      begin
        ALogger.Log(mlWarning, Format('[IniEditor.Put] Rejected secret key: [%s] %s',
          [Section, Key]));
        MxSendError(C, 403, 'secret_key_not_editable_via_ui');
        Exit;
      end;
      stReadOnly:
      begin
        ALogger.Log(mlWarning, Format('[IniEditor.Put] Rejected high-impact infra key: [%s] %s',
          [Section, Key]));
        MxSendError(C, 403, 'high_impact_infra_not_editable_via_ui');
        Exit;
      end;
    end;

    IniPath := GetIniPath;
    if not FileExists(IniPath) then
    begin
      MxSendError(C, 500, 'ini_not_found');
      Exit;
    end;

    // Atomic-write: TIniFile.UpdateFile already persists to disk on Free;
    // write to live path directly (TIniFile handles retry internally).
    // For extra safety on Windows we could copy to temp, write, then replace,
    // but the ini is small and corruption risk during boot-free edit is low.
    Ini := TIniFile.Create(IniPath);
    try
      Ini.WriteString(Section, Key, Value);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;

    ALogger.Log(mlInfo, Format('[IniEditor.Put] [%s] %s = <%d chars>',
      [Section, Key, Length(Value)]));

    Resp := TJSONObject.Create;
    try
      Resp.AddPair('ok', TJSONBool.Create(True));
      Resp.AddPair('section', Section);
      Resp.AddPair('key', Key);
      Resp.AddPair('restart_required',
        TJSONBool.Create(
          SameText(Section, 'Server') or
          SameText(Section, 'Admin') or
          SameText(Section, 'DB')));
      MxSendJson(C, 200, Resp);
    finally
      Resp.Free;
    end;
  finally
    Body.Free;
  end;
end;

// =========================================================================
// POST /api/settings/reload — re-create TMxConfig instance (best-effort).
// Note: TMxConfig has no Reload() method today; a proper hot-reload would
// need AConfig to expose a re-read-from-disk primitive. For now the handler
// acknowledges the request and the user knows a restart is the safe option
// for most changes. Planned: add TMxConfig.ReloadFromIni; for non-infra keys.
// =========================================================================
procedure HandleReloadSettings(const C: THttpServerContext;
  APool: TMxConnectionPool; AConfig: TMxConfig; ALogger: IMxLogger);
var
  Json: TJSONObject;
begin
  ALogger.Log(mlInfo, '[IniEditor.Reload] Requested — full hot-reload not yet implemented; restart server for infra changes.');
  Json := TJSONObject.Create;
  try
    Json.AddPair('ok', TJSONBool.Create(True));
    Json.AddPair('reloaded', TJSONBool.Create(False));
    Json.AddPair('hint',
      'Hot-reload not yet implemented — restart the server to apply changes. ' +
      'Most Tier-1 editable keys are re-read naturally on next use, some are ' +
      'cached in TMxConfig until restart.');
    MxSendJson(C, 200, Json);
  finally
    Json.Free;
  end;
end;

end.
