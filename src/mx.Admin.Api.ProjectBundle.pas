unit mx.Admin.Api.ProjectBundle;

// FR#3896 — Admin-only REST endpoints for Project Export/Import.
//
// POST /api/export
//   Body (JSON): {project_ids: int[], crypto_mode: 'api_key'|'passphrase',
//                 secret: string, include_revisions, include_env_vars,
//                 include_acl: bool}
//   Response: application/octet-stream — encrypted .mxbundle ZIP
//             Content-Disposition: attachment; filename=mxLore-export-....mxbundle
//
// POST /api/import
//   Body (JSON):
//     Phase A (preview):  {bundle_b64, secret, preview: true}
//       Response: {manifest, conflicts[], developers[], auto_dev_map[]}
//     Phase B (execute):  {bundle_b64, secret, preview: false,
//                          conflict_resolutions: [{source_slug, resolution,
//                              new_slug?}],
//                          dev_mapping: [{source_id, local_id}]}
//       Response: {summary: {...}}
//
// We use Base64-in-JSON instead of multipart/form-data because (a) existing
// admin endpoints use MxParseBody (JSON) and (b) a hand-rolled multipart
// parser would not be binary-safe with Delphi's UTF-8 string helpers.
// Base64 overhead (~33%) is acceptable for admin-only migration bundles.
//
// Admin-gate: caller's developer.role must be 'admin' (hard 403 otherwise).

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool, mx.Admin.Auth;

procedure HandleExport(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);

procedure HandleImport(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils,
  System.NetEncoding, System.Generics.Collections, System.StrUtils,
  Data.DB, FireDAC.Comp.Client,
  mx.Admin.Server,
  mx.Logic.ProjectExport, mx.Logic.ProjectImport,
  mx.Crypto.Bundle;

// ---------------------------------------------------------------------------
// Admin gate
// ---------------------------------------------------------------------------

function IsAdminDeveloper(APool: TMxConnectionPool; ADevId: Integer): Boolean;
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
begin
  // Admin-UI login path (mx.Admin.Auth.Login) gates on
  // client_keys.permissions='admin'. Mirror that check here so Export/Import
  // uses the SAME definition of "admin" as the rest of the admin API.
  Result := False;
  if ADevId <= 0 then Exit;
  Ctx := APool.AcquireContext;
  Qry := Ctx.CreateQuery(
    'SELECT 1 FROM client_keys ' +
    'WHERE developer_id = :id AND is_active = 1 AND permissions = ''admin'' ' +
    'LIMIT 1');
  try
    Qry.ParamByName('id').AsInteger := ADevId;
    Qry.Open;
    Result := not Qry.IsEmpty;
  finally
    Qry.Free;
  end;
end;

function ExtractJsonArrayInt(AArr: TJSONArray): TArray<Integer>;
var
  I: Integer;
  V: TJSONValue;
  List: TList<Integer>;
begin
  List := TList<Integer>.Create;
  try
    if AArr = nil then Exit(nil);
    for I := 0 to AArr.Count - 1 do
    begin
      V := AArr.Items[I];
      if V is TJSONNumber then
        List.Add((V as TJSONNumber).AsInt);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function JsonStrValue(O: TJSONObject; const Key: string;
  const ADefault: string = ''): string;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if O = nil then Exit;
  V := O.GetValue(Key);
  if (V = nil) or (V is TJSONNull) then Exit;
  Result := V.Value;
end;

function JsonBoolValue(O: TJSONObject; const Key: string;
  ADefault: Boolean = False): Boolean;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if O = nil then Exit;
  V := O.GetValue(Key);
  if V is TJSONBool then Exit((V as TJSONBool).AsBoolean);
  if (V <> nil) and (not (V is TJSONNull)) then
    Result := SameText(V.Value, 'true');
end;

function SlugifyFilenameDate: string;
begin
  Result := FormatDateTime('yyyy-mm-dd-hhnn', Now);
end;

// ---------------------------------------------------------------------------
// Export handler
// ---------------------------------------------------------------------------

procedure HandleExport(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Body: TJSONObject;
  Exporter: TMxProjectExporter;
  Opts: TMxExportOptions;
  Res: TMxExportResult;
  FileName: string;
  ProjectIds: TArray<Integer>;
  ModeStr: string;
  IdsArr: TJSONArray;
  Qry: TFDQuery;
  Ctx: IMxDbContext;
begin
  if not IsAdminDeveloper(APool, ASession.DeveloperId) then
  begin
    MxSendError(C, 403, 'admin_required');
    Exit;
  end;

  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_json');
    Exit;
  end;

  try try
    IdsArr := Body.GetValue('project_ids') as TJSONArray;
    ProjectIds := ExtractJsonArrayInt(IdsArr);
    if Length(ProjectIds) = 0 then
    begin
      MxSendError(C, 400, 'no_project_ids');
      Exit;
    end;

    Opts := Default(TMxExportOptions);
    Opts.ProjectIds := ProjectIds;

    ModeStr := JsonStrValue(Body, 'crypto_mode', '');
    if SameText(ModeStr, 'api_key') then
      Opts.CryptoMode := bcmApiKey
    else if SameText(ModeStr, 'passphrase') then
      Opts.CryptoMode := bcmPassphrase
    else
    begin
      MxSendError(C, 400, 'invalid_crypto_mode');
      Exit;
    end;

    Opts.Secret := JsonStrValue(Body, 'secret', '');
    if Opts.Secret = '' then
    begin
      MxSendError(C, 400, 'missing_secret');
      Exit;
    end;

    Opts.IncludeRevisions := JsonBoolValue(Body, 'include_revisions', True);
    Opts.IncludeEnvVars   := JsonBoolValue(Body, 'include_env_vars', True);
    Opts.IncludeAcl       := JsonBoolValue(Body, 'include_acl', True);
    Opts.DeveloperName    := ASession.DeveloperName;

    if Opts.CryptoMode = bcmApiKey then
    begin
      Ctx := APool.AcquireContext;
      Qry := Ctx.CreateQuery(
        'SELECT id, key_prefix FROM client_keys WHERE developer_id = :d ' +
        'AND is_active = 1 ORDER BY id DESC LIMIT 1');
      try
        Qry.ParamByName('d').AsInteger := ASession.DeveloperId;
        Qry.Open;
        if not Qry.IsEmpty then
        begin
          Opts.KeyId     := Qry.FieldByName('id').AsInteger;
          Opts.KeyPrefix := Qry.FieldByName('key_prefix').AsString;
        end;
      finally
        Qry.Free;
      end;
    end;

    Opts.OriginServer := 'mxLore@' + string(GetEnvironmentVariable('COMPUTERNAME'));
    Opts.MxLoreBuild  := MXAI_BUILD;

    Exporter := TMxProjectExporter.Create(APool, ALogger);
    try
      Res := Exporter.BuildBundle(Opts);
    finally
      Exporter.Free;
    end;

    FileName := Format('mxLore-export-%s-%dprojects.mxbundle',
      [SlugifyFilenameDate, Res.ProjectCount]);

    C.Response.StatusCode := 200;
    C.Response.ContentType := 'application/octet-stream';
    C.Response.Headers.SetValue('Content-Disposition',
      'attachment; filename="' + FileName + '"');
    C.Response.Headers.SetValue('X-MxLore-Bundle-Project-Count',
      IntToStr(Res.ProjectCount));
    C.Response.Headers.SetValue('X-MxLore-Bundle-Doc-Count',
      IntToStr(Res.DocCount));
    C.Response.Headers.SetValue('X-MxLore-Bundle-Dropped-Relations',
      IntToStr(Length(Res.DroppedRelations)));
    C.Response.Close(Res.Bundle);

  except
    on E: Exception do
    begin
      if Assigned(ALogger) then
        ALogger.Log(mlError,
          '[Admin.ProjectBundle.Export] ' + E.ClassName + ': ' + E.Message);
      // Generic error to client — full detail in server log only.
      MxSendError(C, 500, 'export_failed');
    end;
  end;
  finally
    Body.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Import handler — single endpoint, `preview` flag toggles Phase A vs Phase B.
// ---------------------------------------------------------------------------

procedure HandleImport(const C: THttpServerContext;
  APool: TMxConnectionPool; const ASession: TMxAdminSession;
  ALogger: IMxLogger);
var
  Body: TJSONObject;
  Importer: TMxProjectImporter;
  BundleB64, Secret: string;
  BundleBytes, Ciphertext: TBytes;
  ManifestInfo: TMxManifestInfo;
  ManifestJson, Payload, Resp, ConfObj, DevObj, PairObj,
    SummaryObj, CRObj, DevMapObj: TJSONObject;
  IsPreview: Boolean;
  Ctx: IMxDbContext;
  AutoMap, DevMapIn: TDictionary<Integer, Integer>;
  Conflicts: TArray<TMxProjectConflict>;
  Devs: TArray<TMxDeveloperInfo>;
  Session: TMxImportSession;
  Summary: TMxImportSummary;
  I, J, SrcId, TargetId: Integer;
  ConflictsArr, DevsArr, AutoMapArr, ResolveArr,
    DevMapArr, WarnArr: TJSONArray;
  Pair: TPair<Integer, Integer>;
  V: TJSONValue;
  ResStr, SrcSlug, NewSlug: string;
  Res: TMxConflictResolution;
begin
  if not IsAdminDeveloper(APool, ASession.DeveloperId) then
  begin
    MxSendError(C, 403, 'admin_required');
    Exit;
  end;

  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_json');
    Exit;
  end;

  try
    BundleB64 := JsonStrValue(Body, 'bundle_b64', '');
    Secret    := JsonStrValue(Body, 'secret', '');
    IsPreview := JsonBoolValue(Body, 'preview', True);
    if BundleB64 = '' then
    begin
      MxSendError(C, 400, 'missing_bundle_b64');
      Exit;
    end;
    if Secret = '' then
    begin
      MxSendError(C, 400, 'missing_secret');
      Exit;
    end;

    BundleBytes := TNetEncoding.Base64.DecodeStringToBytes(BundleB64);

    ManifestJson := nil;
    Payload := nil;
    Importer := TMxProjectImporter.Create(APool, ALogger);
    try
      try
        Importer.ReadManifest(BundleBytes, ManifestInfo, ManifestJson,
          Ciphertext);
        Payload := Importer.Decrypt(Ciphertext, ManifestInfo.Aad,
          ManifestInfo, Secret);

        try
          Ctx := APool.AcquireContext;

          if IsPreview then
          begin
            // Phase A: preview only
            Conflicts := Importer.ResolveConflicts(Ctx, Payload);
            Importer.ResolveDevMapping(Ctx, Payload, Devs, AutoMap);
            try
              Resp := TJSONObject.Create;
              try
                Resp.AddPair('manifest', ManifestJson.Clone as TJSONObject);

                ConflictsArr := TJSONArray.Create;
                for I := 0 to High(Conflicts) do
                begin
                  ConfObj := TJSONObject.Create;
                  ConfObj.AddPair('source_slug',        Conflicts[I].SourceSlug);
                  ConfObj.AddPair('source_name',        Conflicts[I].SourceName);
                  ConfObj.AddPair('source_id',          TJSONNumber.Create(Conflicts[I].SourceId));
                  ConfObj.AddPair('local_id',           TJSONNumber.Create(Conflicts[I].LocalId));
                  ConfObj.AddPair('local_name',         Conflicts[I].LocalName);
                  ConfObj.AddPair('suggested_new_slug', Conflicts[I].NewSlug);
                  ConflictsArr.AddElement(ConfObj);
                end;
                Resp.AddPair('conflicts', ConflictsArr);

                DevsArr := TJSONArray.Create;
                for I := 0 to High(Devs) do
                begin
                  DevObj := TJSONObject.Create;
                  DevObj.AddPair('source_id', TJSONNumber.Create(Devs[I].SourceId));
                  DevObj.AddPair('name',      Devs[I].Name);
                  DevObj.AddPair('email',     Devs[I].Email);
                  DevsArr.AddElement(DevObj);
                end;
                Resp.AddPair('developers', DevsArr);

                AutoMapArr := TJSONArray.Create;
                for Pair in AutoMap do
                begin
                  PairObj := TJSONObject.Create;
                  PairObj.AddPair('source_id', TJSONNumber.Create(Pair.Key));
                  PairObj.AddPair('local_id',  TJSONNumber.Create(Pair.Value));
                  AutoMapArr.AddElement(PairObj);
                end;
                Resp.AddPair('auto_dev_map', AutoMapArr);

                MxSendJson(C, 200, Resp);
              finally
                Resp.Free;
              end;
            finally
              AutoMap.Free;
            end;
          end
          else
          begin
            // Phase B: execute with user decisions
            Conflicts := Importer.ResolveConflicts(Ctx, Payload);

            ResolveArr := nil;
            V := Body.GetValue('conflict_resolutions');
            if V is TJSONArray then ResolveArr := V as TJSONArray;

            if ResolveArr <> nil then
              for I := 0 to ResolveArr.Count - 1 do
              begin
                if not (ResolveArr.Items[I] is TJSONObject) then Continue;
                CRObj   := ResolveArr.Items[I] as TJSONObject;
                SrcSlug := JsonStrValue(CRObj, 'source_slug', '');
                ResStr  := JsonStrValue(CRObj, 'resolution', '');
                NewSlug := JsonStrValue(CRObj, 'new_slug', '');

                if SameText(ResStr, 'skip') then Res := crSkip
                else if SameText(ResStr, 'overwrite') then Res := crOverwrite
                else Res := crRenameNewSlug;

                for J := 0 to High(Conflicts) do
                  if SameText(Conflicts[J].SourceSlug, SrcSlug) then
                  begin
                    Conflicts[J].Resolution := Res;
                    if NewSlug <> '' then
                      Conflicts[J].NewSlug := NewSlug;
                    Break;
                  end;
              end;

            DevMapIn := TDictionary<Integer, Integer>.Create;
            try
              DevMapArr := nil;
              V := Body.GetValue('dev_mapping');
              if V is TJSONArray then DevMapArr := V as TJSONArray;
              if DevMapArr <> nil then
                for I := 0 to DevMapArr.Count - 1 do
                begin
                  if not (DevMapArr.Items[I] is TJSONObject) then Continue;
                  DevMapObj := DevMapArr.Items[I] as TJSONObject;
                  SrcId := 0;
                  TargetId := -1;
                  if DevMapObj.GetValue('source_id') is TJSONNumber then
                    SrcId := (DevMapObj.GetValue('source_id') as TJSONNumber).AsInt;
                  if DevMapObj.GetValue('local_id') is TJSONNumber then
                    TargetId := (DevMapObj.GetValue('local_id') as TJSONNumber).AsInt;
                  if SrcId > 0 then
                    DevMapIn.AddOrSetValue(SrcId, TargetId);
                end;

              Session := Default(TMxImportSession);
              Session.ManifestJson     := ManifestJson;
              Session.DecryptedPayload := Payload;
              Session.Manifest         := ManifestInfo;
              Session.Conflicts        := Conflicts;
              Session.DevMap           := DevMapIn;

              Summary := Importer.Execute(Session, ASession.DeveloperId);

              Resp := TJSONObject.Create;
              try
                SummaryObj := TJSONObject.Create;
                SummaryObj.AddPair('projects_created',   TJSONNumber.Create(Summary.ProjectsCreated));
                SummaryObj.AddPair('projects_updated',   TJSONNumber.Create(Summary.ProjectsUpdated));
                SummaryObj.AddPair('projects_skipped',   TJSONNumber.Create(Summary.ProjectsSkipped));
                SummaryObj.AddPair('projects_renamed',   TJSONNumber.Create(Summary.ProjectsRenamed));
                SummaryObj.AddPair('docs_inserted',      TJSONNumber.Create(Summary.DocsInserted));
                SummaryObj.AddPair('docs_updated',       TJSONNumber.Create(Summary.DocsUpdated));
                SummaryObj.AddPair('revisions_inserted', TJSONNumber.Create(Summary.RevisionsInserted));
                SummaryObj.AddPair('tags_inserted',      TJSONNumber.Create(Summary.TagsInserted));
                SummaryObj.AddPair('relations_inserted', TJSONNumber.Create(Summary.RelationsInserted));
                SummaryObj.AddPair('acl_inserted',       TJSONNumber.Create(Summary.AclInserted));
                SummaryObj.AddPair('acl_skipped',        TJSONNumber.Create(Summary.AclSkipped));
                SummaryObj.AddPair('env_vars_inserted',  TJSONNumber.Create(Summary.EnvVarsInserted));

                WarnArr := TJSONArray.Create;
                for I := 0 to High(Summary.Warnings) do
                  WarnArr.AddElement(TJSONString.Create(Summary.Warnings[I]));
                SummaryObj.AddPair('warnings', WarnArr);

                Resp.AddPair('summary', SummaryObj);
                MxSendJson(C, 200, Resp);
              finally
                Resp.Free;
              end;
            finally
              DevMapIn.Free;
            end;
          end;
        finally
          // Payload freed in outer finally now
        end;
      except
        on E: EMxCryptoAuthFail do
        begin
          if Assigned(ALogger) then
            ALogger.Log(mlWarning, '[Admin.ProjectBundle.Import] auth fail: ' + E.Message);
          MxSendError(C, 401, 'decrypt_failed');
        end;
        on E: Exception do
        begin
          if Assigned(ALogger) then
            ALogger.Log(mlError,
              '[Admin.ProjectBundle.Import] ' + E.ClassName + ': ' + E.Message);
          // Generic error to client — full detail in server log only.
          MxSendError(C, 500, 'import_failed');
        end;
      end;
    finally
      if Payload <> nil then Payload.Free;
      if ManifestJson <> nil then ManifestJson.Free;
      Importer.Free;
    end;
  finally
    Body.Free;
  end;
end;

end.
