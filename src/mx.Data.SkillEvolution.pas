unit mx.Data.SkillEvolution;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils, System.Hash,
  Data.DB, FireDAC.Comp.Client,
  mx.Types;

type
  TMxFindingSeverity = (fsInfo, fsWarning, fsError, fsCritical);
  TMxFindingReaction = (frPending, frConfirmed, frDismissed, frFalsePositive);

  TMxSkillFinding = record
    Id: Integer;
    FindingUid: string;
    SkillName: string;
    RuleId: string;
    ProjectId: Integer;
    Severity: TMxFindingSeverity;
    Title: string;
    ContextHash: string;
    FilePath: string;
    LineNumber: Integer;
    Details: string;
    Reaction: TMxFindingReaction;
    ReactedAt: TDateTime;
    CreatedAt: TDateTime;
  end;

  TMxSkillMetrics = record
    SkillName: string;
    RuleId: string;
    ProjectId: Integer;
    TotalFindings: Integer;
    Confirmed: Integer;
    Dismissed: Integer;
    FalsePositives: Integer;
    Pending: Integer;
    Precision: Double;
    FalsePositiveRate: Double;
    ConfirmationRate: Double;
    Ignored: Integer;
    WeightedPrecision: Double;
    WeightedFpRate: Double;
    WeightedConfirmationRate: Double;
  end;

  TMxSkillParam = record
    SkillName: string;
    ProjectId: Integer;
    ParamKey: string;
    ParamValue: string;
    Version: Integer;
    PreviousValue: string;
    ChangeReason: string;
  end;

  TMxSkillEvolutionData = class
  public
    // --- Findings ---
    class function SaveFinding(ACtx: IMxDbContext;
      const AFinding: TMxSkillFinding): Integer; static;
    class function FindByUid(ACtx: IMxDbContext;
      const AUid: string): TMxSkillFinding; static;
    class function UpdateReaction(ACtx: IMxDbContext;
      const AUid: string; AReaction: TMxFindingReaction): Boolean; static;
    class function DismissPendingByProject(ACtx: IMxDbContext;
      AProjectId: Integer;
      AReaction: TMxFindingReaction): Integer; static;
    class function FindingExists(ACtx: IMxDbContext;
      const AUid: string): Boolean; static;

    // --- List Findings ---
    class function ListFindings(ACtx: IMxDbContext;
      AProjectId: Integer; const ASkillName, ARuleId: string;
      AReaction: TMxFindingReaction; AFilterReaction: Boolean;
      ALimit: Integer): TArray<TMxSkillFinding>; static;

    // --- Metrics ---
    class function GetMetrics(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      ASince: TDateTime): TArray<TMxSkillMetrics>; static;
    class function GetMetricsForRule(ACtx: IMxDbContext;
      const ASkillName, ARuleId: string; AProjectId: Integer;
      ASince: TDateTime): TMxSkillMetrics; static;

    // --- Params ---
    class function GetParam(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      const AParamKey: string; const ADefault: string = ''): string; static;
    class function SetParam(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      const AParamKey, AParamValue, AChangeReason: string;
      AMetrics: TJSONObject = nil;
      AExpectedVersion: Integer = 0): Boolean; static;
    class function RollbackParam(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      const AParamKey: string): Boolean; static;
    class function GetAllParams(ACtx: IMxDbContext;
      const ASkillName: string;
      AProjectId: Integer): TArray<TMxSkillParam>; static;

    // --- Helpers ---
    class function SeverityToStr(ASev: TMxFindingSeverity): string; static;
    class function StrToSeverity(const AValue: string): TMxFindingSeverity; static;
    class function ReactionToStr(AReact: TMxFindingReaction): string; static;
    class function StrToReaction(const AValue: string): TMxFindingReaction; static;
    class function GenerateUid(const ASkillName, ARuleId,
      AContextHash: string): string; static;
  end;

implementation

{ --- Helpers --- }

class function TMxSkillEvolutionData.SeverityToStr(
  ASev: TMxFindingSeverity): string;
const
  Names: array[TMxFindingSeverity] of string = (
    'info', 'warning', 'error', 'critical');
begin
  Result := Names[ASev];
end;

class function TMxSkillEvolutionData.StrToSeverity(
  const AValue: string): TMxFindingSeverity;
begin
  if SameText(AValue, 'warning') then Result := fsWarning
  else if SameText(AValue, 'error') then Result := fsError
  else if SameText(AValue, 'critical') then Result := fsCritical
  else Result := fsInfo;
end;

class function TMxSkillEvolutionData.ReactionToStr(
  AReact: TMxFindingReaction): string;
const
  Names: array[TMxFindingReaction] of string = (
    'pending', 'confirmed', 'dismissed', 'false_positive');
begin
  Result := Names[AReact];
end;

class function TMxSkillEvolutionData.StrToReaction(
  const AValue: string): TMxFindingReaction;
begin
  if SameText(AValue, 'confirmed') then Result := frConfirmed
  else if SameText(AValue, 'dismissed') then Result := frDismissed
  else if SameText(AValue, 'false_positive') then Result := frFalsePositive
  else Result := frPending;
end;

class function TMxSkillEvolutionData.GenerateUid(
  const ASkillName, ARuleId, AContextHash: string): string;
begin
  if AContextHash <> '' then
    Result := ASkillName + ':' + ARuleId + ':' + AContextHash
  else
    Result := ASkillName + ':' + ARuleId + ':' +
      THashMD5.GetHashString(ASkillName + ARuleId +
        FormatDateTime('yyyymmddhhnnsszzz', Now));
end;

{ --- Findings --- }

class function TMxSkillEvolutionData.SaveFinding(ACtx: IMxDbContext;
  const AFinding: TMxSkillFinding): Integer;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'INSERT INTO skill_findings ' +
    '(finding_uid, skill_name, rule_id, project_id, severity, ' +
    ' title, context_hash, file_path, line_number, details) ' +
    'VALUES (:uid, :skill, :rule, :proj, :sev, ' +
    ' :title, :ctx_hash, :fpath, :lnum, :details)');
  try
    Qry.ParamByName('uid').AsString := AFinding.FindingUid;
    Qry.ParamByName('skill').AsString := AFinding.SkillName;
    Qry.ParamByName('rule').AsString := AFinding.RuleId;
    Qry.ParamByName('proj').AsInteger := AFinding.ProjectId;
    Qry.ParamByName('sev').AsString := SeverityToStr(AFinding.Severity);
    Qry.ParamByName('title').AsString := AFinding.Title;
    if AFinding.ContextHash <> '' then
      Qry.ParamByName('ctx_hash').AsString := AFinding.ContextHash
    else begin
      Qry.ParamByName('ctx_hash').DataType := ftString;
      Qry.ParamByName('ctx_hash').Clear;
    end;
    if AFinding.FilePath <> '' then
      Qry.ParamByName('fpath').AsString := AFinding.FilePath
    else begin
      Qry.ParamByName('fpath').DataType := ftString;
      Qry.ParamByName('fpath').Clear;
    end;
    if AFinding.LineNumber > 0 then
      Qry.ParamByName('lnum').AsInteger := AFinding.LineNumber
    else begin
      Qry.ParamByName('lnum').DataType := ftInteger;
      Qry.ParamByName('lnum').Clear;
    end;
    if AFinding.Details <> '' then
      Qry.ParamByName('details').AsString := AFinding.Details
    else begin
      Qry.ParamByName('details').DataType := ftString;
      Qry.ParamByName('details').Clear;
    end;
    Qry.ExecSQL;
  finally
    Qry.Free;
  end;
  // Match existing codebase pattern for LAST_INSERT_ID
  Qry := ACtx.CreateQuery('SELECT LAST_INSERT_ID() AS id');
  try
    Qry.Open;
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.FindByUid(ACtx: IMxDbContext;
  const AUid: string): TMxSkillFinding;
var
  Qry: TFDQuery;
begin
  Result := Default(TMxSkillFinding);
  Qry := ACtx.CreateQuery(
    'SELECT id, finding_uid, skill_name, rule_id, project_id, severity, ' +
    'title, context_hash, file_path, line_number, details, ' +
    'user_reaction, reacted_at, created_at ' +
    'FROM skill_findings WHERE finding_uid = :uid');
  try
    Qry.ParamByName('uid').AsString := AUid;
    Qry.Open;
    if not Qry.Eof then
    begin
      Result.Id := Qry.FieldByName('id').AsInteger;
      Result.FindingUid := Qry.FieldByName('finding_uid').AsString;
      Result.SkillName := Qry.FieldByName('skill_name').AsString;
      Result.RuleId := Qry.FieldByName('rule_id').AsString;
      Result.ProjectId := Qry.FieldByName('project_id').AsInteger;
      Result.Severity := StrToSeverity(Qry.FieldByName('severity').AsString);
      Result.Title := Qry.FieldByName('title').AsString;
      Result.ContextHash := Qry.FieldByName('context_hash').AsString;
      Result.FilePath := Qry.FieldByName('file_path').AsString;
      Result.LineNumber := Qry.FieldByName('line_number').AsInteger;
      Result.Details := Qry.FieldByName('details').AsString;
      Result.Reaction := StrToReaction(Qry.FieldByName('user_reaction').AsString);
      if not Qry.FieldByName('reacted_at').IsNull then
        Result.ReactedAt := Qry.FieldByName('reacted_at').AsDateTime;
      Result.CreatedAt := Qry.FieldByName('created_at').AsDateTime;
    end;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.UpdateReaction(ACtx: IMxDbContext;
  const AUid: string; AReaction: TMxFindingReaction): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'UPDATE skill_findings SET user_reaction = :react, reacted_at = NOW() ' +
    'WHERE finding_uid = :uid');
  try
    Qry.ParamByName('react').AsString := ReactionToStr(AReaction);
    Qry.ParamByName('uid').AsString := AUid;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.DismissPendingByProject(
  ACtx: IMxDbContext; AProjectId: Integer;
  AReaction: TMxFindingReaction): Integer;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'UPDATE skill_findings SET user_reaction = :react, reacted_at = NOW() ' +
    'WHERE project_id = :proj AND user_reaction = ''pending''');
  try
    Qry.ParamByName('react').AsString := ReactionToStr(AReaction);
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ExecSQL;
    Result := Qry.RowsAffected;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.FindingExists(ACtx: IMxDbContext;
  const AUid: string): Boolean;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'SELECT 1 FROM skill_findings WHERE finding_uid = :uid LIMIT 1');
  try
    Qry.ParamByName('uid').AsString := AUid;
    Qry.Open;
    Result := not Qry.Eof;
  finally
    Qry.Free;
  end;
end;

{ --- List Findings --- }

class function TMxSkillEvolutionData.ListFindings(ACtx: IMxDbContext;
  AProjectId: Integer; const ASkillName, ARuleId: string;
  AReaction: TMxFindingReaction; AFilterReaction: Boolean;
  ALimit: Integer): TArray<TMxSkillFinding>;
var
  Qry: TFDQuery;
  SQL: string;
  List: TArray<TMxSkillFinding>;
  Count: Integer;
  F: TMxSkillFinding;
begin
  Count := 0;
  if ALimit <= 0 then ALimit := 50;
  if ALimit > 200 then ALimit := 200;
  SetLength(List, ALimit);

  SQL := 'SELECT id, finding_uid, skill_name, rule_id, project_id, severity, ' +
    'title, context_hash, file_path, line_number, details, ' +
    'user_reaction, reacted_at, created_at ' +
    'FROM skill_findings WHERE project_id = :proj';

  if ASkillName <> '' then
    SQL := SQL + ' AND skill_name = :skill';
  if ARuleId <> '' then
    SQL := SQL + ' AND rule_id = :rule';
  if AFilterReaction then
    SQL := SQL + ' AND user_reaction = :react';

  SQL := SQL + ' ORDER BY created_at DESC LIMIT :lim';

  Qry := ACtx.CreateQuery(SQL);
  try
    Qry.ParamByName('proj').AsInteger := AProjectId;
    if ASkillName <> '' then
      Qry.ParamByName('skill').AsString := ASkillName;
    if ARuleId <> '' then
      Qry.ParamByName('rule').AsString := ARuleId;
    if AFilterReaction then
      Qry.ParamByName('react').AsString := ReactionToStr(AReaction);
    Qry.ParamByName('lim').AsInteger := ALimit;
    Qry.Open;
    while not Qry.Eof do
    begin
      F := Default(TMxSkillFinding);
      F.Id := Qry.FieldByName('id').AsInteger;
      F.FindingUid := Qry.FieldByName('finding_uid').AsString;
      F.SkillName := Qry.FieldByName('skill_name').AsString;
      F.RuleId := Qry.FieldByName('rule_id').AsString;
      F.ProjectId := Qry.FieldByName('project_id').AsInteger;
      F.Severity := StrToSeverity(Qry.FieldByName('severity').AsString);
      F.Title := Qry.FieldByName('title').AsString;
      F.ContextHash := Qry.FieldByName('context_hash').AsString;
      F.FilePath := Qry.FieldByName('file_path').AsString;
      F.LineNumber := Qry.FieldByName('line_number').AsInteger;
      F.Details := Qry.FieldByName('details').AsString;
      F.Reaction := StrToReaction(Qry.FieldByName('user_reaction').AsString);
      if not Qry.FieldByName('reacted_at').IsNull then
        F.ReactedAt := Qry.FieldByName('reacted_at').AsDateTime;
      F.CreatedAt := Qry.FieldByName('created_at').AsDateTime;
      if Count >= Length(List) then
        SetLength(List, Length(List) * 2);
      List[Count] := F;
      Inc(Count);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  SetLength(List, Count);
  Result := List;
end;

{ --- Metrics --- }

class function TMxSkillEvolutionData.GetMetrics(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  ASince: TDateTime): TArray<TMxSkillMetrics>;
var
  Qry: TFDQuery;
  List: TArray<TMxSkillMetrics>;
  Count: Integer;
  M: TMxSkillMetrics;
begin
  Count := 0;
  SetLength(List, 64);
  Qry := ACtx.CreateQuery(
    'SELECT rule_id, ' +
    '  COUNT(*) AS total, ' +
    '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN 1 ELSE 0 END) AS confirmed, ' +
    '  SUM(CASE WHEN user_reaction = ''dismissed'' THEN 1 ELSE 0 END) AS dismissed, ' +
    '  SUM(CASE WHEN user_reaction = ''false_positive'' THEN 1 ELSE 0 END) AS false_pos, ' +
    '  SUM(CASE WHEN user_reaction = ''pending'' AND created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY) THEN 1 ELSE 0 END) AS pending, ' +
    '  SUM(CASE WHEN user_reaction = ''pending'' AND created_at < DATE_SUB(NOW(), INTERVAL 7 DAY) THEN 1 ELSE 0 END) AS ignored, ' +
    // Age-weighted columns: <30d=1.0, 30-60d=0.7, >60d=0.3
    '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN ' +
    '    CASE WHEN created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN 1.0 ' +
    '         WHEN created_at >= DATE_SUB(NOW(), INTERVAL 60 DAY) THEN 0.7 ELSE 0.3 END ' +
    '    ELSE 0 END) AS w_confirmed, ' +
    '  SUM(CASE WHEN user_reaction = ''false_positive'' THEN ' +
    '    CASE WHEN created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN 1.0 ' +
    '         WHEN created_at >= DATE_SUB(NOW(), INTERVAL 60 DAY) THEN 0.7 ELSE 0.3 END ' +
    '    ELSE 0 END) AS w_false_pos, ' +
    '  SUM(CASE WHEN user_reaction IN (''confirmed'', ''dismissed'', ''false_positive'') THEN ' +
    '    CASE WHEN created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN 1.0 ' +
    '         WHEN created_at >= DATE_SUB(NOW(), INTERVAL 60 DAY) THEN 0.7 ELSE 0.3 END ' +
    '    ELSE 0 END) AS w_reacted ' +
    'FROM skill_findings ' +
    'WHERE skill_name = :skill AND project_id = :proj AND created_at >= :since ' +
    'GROUP BY rule_id ' +
    'ORDER BY total DESC');
  try
    Qry.ParamByName('skill').AsString := ASkillName;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ParamByName('since').AsDateTime := ASince;
    Qry.Open;
    while not Qry.Eof do
    begin
      M := Default(TMxSkillMetrics);
      M.SkillName := ASkillName;
      M.ProjectId := AProjectId;
      M.RuleId := Qry.FieldByName('rule_id').AsString;
      M.TotalFindings := Qry.FieldByName('total').AsInteger;
      M.Confirmed := Qry.FieldByName('confirmed').AsInteger;
      M.Dismissed := Qry.FieldByName('dismissed').AsInteger;
      M.FalsePositives := Qry.FieldByName('false_pos').AsInteger;
      M.Pending := Qry.FieldByName('pending').AsInteger;
      M.Ignored := Qry.FieldByName('ignored').AsInteger;

      // Precision: confirmed / (confirmed + false_positive)
      if (M.Confirmed + M.FalsePositives) > 0 then
        M.Precision := M.Confirmed / (M.Confirmed + M.FalsePositives)
      else
        M.Precision := 0;

      // FP rate: false_positive / total_reacted
      if (M.TotalFindings - M.Pending - M.Ignored) > 0 then
        M.FalsePositiveRate := M.FalsePositives / (M.TotalFindings - M.Pending - M.Ignored)
      else
        M.FalsePositiveRate := 0;

      // Confirmation rate: confirmed / total_reacted
      if (M.TotalFindings - M.Pending - M.Ignored) > 0 then
        M.ConfirmationRate := M.Confirmed / (M.TotalFindings - M.Pending - M.Ignored)
      else
        M.ConfirmationRate := 0;

      // Age-weighted precision and FP rate
      var WConf := Qry.FieldByName('w_confirmed').AsFloat;
      var WFP := Qry.FieldByName('w_false_pos').AsFloat;
      var WReacted := Qry.FieldByName('w_reacted').AsFloat;
      if (WConf + WFP) > 0 then
        M.WeightedPrecision := WConf / (WConf + WFP)
      else
        M.WeightedPrecision := 0;
      if WReacted > 0 then
        M.WeightedFpRate := WFP / WReacted
      else
        M.WeightedFpRate := 0;
      if WReacted > 0 then
        M.WeightedConfirmationRate := WConf / WReacted
      else
        M.WeightedConfirmationRate := 0;

      if Count >= Length(List) then
        SetLength(List, Length(List) * 2);
      List[Count] := M;
      Inc(Count);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  SetLength(List, Count);
  Result := List;
end;

class function TMxSkillEvolutionData.GetMetricsForRule(ACtx: IMxDbContext;
  const ASkillName, ARuleId: string; AProjectId: Integer;
  ASince: TDateTime): TMxSkillMetrics;
var
  All: TArray<TMxSkillMetrics>;
  I: Integer;
begin
  Result := Default(TMxSkillMetrics);
  Result.SkillName := ASkillName;
  Result.RuleId := ARuleId;
  Result.ProjectId := AProjectId;
  // Reuse GetMetrics and filter — small result set per skill
  All := GetMetrics(ACtx, ASkillName, AProjectId, ASince);
  for I := 0 to High(All) do
    if SameText(All[I].RuleId, ARuleId) then
      Exit(All[I]);
end;

{ --- Params --- }

class function TMxSkillEvolutionData.GetParam(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  const AParamKey: string; const ADefault: string): string;
var
  Qry: TFDQuery;
begin
  Qry := ACtx.CreateQuery(
    'SELECT param_value FROM skill_params ' +
    'WHERE skill_name = :skill AND project_id = :proj AND param_key = :key');
  try
    Qry.ParamByName('skill').AsString := ASkillName;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ParamByName('key').AsString := AParamKey;
    Qry.Open;
    if not Qry.Eof then
      Result := Qry.FieldByName('param_value').AsString
    else
      Result := ADefault;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.SetParam(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  const AParamKey, AParamValue, AChangeReason: string;
  AMetrics: TJSONObject; AExpectedVersion: Integer): Boolean;
var
  Qry: TFDQuery;
  MetricsStr: string;
begin
  if Assigned(AMetrics) then
    MetricsStr := AMetrics.ToJSON
  else
    MetricsStr := '';

  if AExpectedVersion > 0 then
  begin
    // Optimistic locking: only update if version matches
    Qry := ACtx.CreateQuery(
      'UPDATE skill_params SET ' +
      '  previous_value = param_value, ' +
      '  param_value = :val, ' +
      '  version = version + 1, ' +
      '  change_reason = :reason, ' +
      '  change_metrics = :metrics ' +
      'WHERE skill_name = :skill AND project_id = :proj ' +
      '  AND param_key = :key AND version = :expected_ver');
    try
      Qry.ParamByName('val').AsString := AParamValue;
      Qry.ParamByName('reason').AsString := AChangeReason;
      if MetricsStr <> '' then
        Qry.ParamByName('metrics').AsString := MetricsStr
      else begin
        Qry.ParamByName('metrics').DataType := ftString;
        Qry.ParamByName('metrics').Clear;
      end;
      Qry.ParamByName('skill').AsString := ASkillName;
      Qry.ParamByName('proj').AsInteger := AProjectId;
      Qry.ParamByName('key').AsString := AParamKey;
      Qry.ParamByName('expected_ver').AsInteger := AExpectedVersion;
      Qry.ExecSQL;
      Result := Qry.RowsAffected > 0;
    finally
      Qry.Free;
    end;
  end
  else
  begin
    // INSERT ... ON DUPLICATE KEY UPDATE with version increment and rollback storage
    Qry := ACtx.CreateQuery(
      'INSERT INTO skill_params ' +
      '(skill_name, project_id, param_key, param_value, version, ' +
      ' change_reason, change_metrics) ' +
      'VALUES (:skill, :proj, :key, :val, 1, :reason, :metrics) ' +
      'ON DUPLICATE KEY UPDATE ' +
      '  previous_value = param_value, ' +
      '  param_value = VALUES(param_value), ' +
      '  version = version + 1, ' +
      '  change_reason = VALUES(change_reason), ' +
      '  change_metrics = VALUES(change_metrics)');
    try
      Qry.ParamByName('skill').AsString := ASkillName;
      Qry.ParamByName('proj').AsInteger := AProjectId;
      Qry.ParamByName('key').AsString := AParamKey;
      Qry.ParamByName('val').AsString := AParamValue;
      Qry.ParamByName('reason').AsString := AChangeReason;
      if MetricsStr <> '' then
        Qry.ParamByName('metrics').AsString := MetricsStr
      else begin
        Qry.ParamByName('metrics').DataType := ftString;
        Qry.ParamByName('metrics').Clear;
      end;
      Qry.ExecSQL;
      Result := Qry.RowsAffected > 0;
    finally
      Qry.Free;
    end;
  end;
end;

class function TMxSkillEvolutionData.RollbackParam(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  const AParamKey: string): Boolean;
var
  Qry: TFDQuery;
begin
  // Swap param_value with previous_value, decrement version
  Qry := ACtx.CreateQuery(
    'UPDATE skill_params SET ' +
    '  param_value = previous_value, ' +
    '  previous_value = param_value, ' +
    '  version = GREATEST(version - 1, 1), ' +
    '  change_reason = ''Rollback'', ' +
    '  change_metrics = NULL ' +
    'WHERE skill_name = :skill AND project_id = :proj ' +
    '  AND param_key = :key AND previous_value IS NOT NULL');
  try
    Qry.ParamByName('skill').AsString := ASkillName;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.ParamByName('key').AsString := AParamKey;
    Qry.ExecSQL;
    Result := Qry.RowsAffected > 0;
  finally
    Qry.Free;
  end;
end;

class function TMxSkillEvolutionData.GetAllParams(ACtx: IMxDbContext;
  const ASkillName: string;
  AProjectId: Integer): TArray<TMxSkillParam>;
var
  Qry: TFDQuery;
  List: TArray<TMxSkillParam>;
  Count: Integer;
  P: TMxSkillParam;
begin
  Count := 0;
  SetLength(List, 16);
  Qry := ACtx.CreateQuery(
    'SELECT skill_name, project_id, param_key, param_value, version, ' +
    '  previous_value, change_reason ' +
    'FROM skill_params ' +
    'WHERE skill_name = :skill AND project_id = :proj ' +
    'ORDER BY param_key');
  try
    Qry.ParamByName('skill').AsString := ASkillName;
    Qry.ParamByName('proj').AsInteger := AProjectId;
    Qry.Open;
    while not Qry.Eof do
    begin
      P := Default(TMxSkillParam);
      P.SkillName := Qry.FieldByName('skill_name').AsString;
      P.ProjectId := Qry.FieldByName('project_id').AsInteger;
      P.ParamKey := Qry.FieldByName('param_key').AsString;
      P.ParamValue := Qry.FieldByName('param_value').AsString;
      P.Version := Qry.FieldByName('version').AsInteger;
      P.PreviousValue := Qry.FieldByName('previous_value').AsString;
      P.ChangeReason := Qry.FieldByName('change_reason').AsString;
      if Count >= Length(List) then
        SetLength(List, Length(List) * 2);
      List[Count] := P;
      Inc(Count);
      Qry.Next;
    end;
  finally
    Qry.Free;
  end;
  SetLength(List, Count);
  Result := List;
end;

end.
