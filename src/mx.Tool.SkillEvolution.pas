unit mx.Tool.SkillEvolution;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  mx.Types, mx.Errors, mx.Logic.AccessControl, mx.Data.Pool,
  mx.Data.SkillEvolution, mx.Logic.SkillEvolution;

function HandleSkillManage(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillRecordFinding(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillFeedback(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillMetrics(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillFindingsList(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillTune(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillRollback(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
function HandleSkillDelete(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;

implementation

// ---------------------------------------------------------------------------
// Helper: Resolve project slug to ID
// ---------------------------------------------------------------------------
function ResolveProjectId(AContext: IMxDbContext;
  const ASlug: string): Integer;
var
  Qry: TFDQuery;
begin
  Qry := AContext.CreateQuery(
    'SELECT id FROM projects WHERE slug = :slug AND deleted_at IS NULL');
  try
    Qry.ParamByName('slug').AsString := ASlug;
    Qry.Open;
    if Qry.IsEmpty then
      raise EMxError.Create('NOT_FOUND', 'Project not found: ' + ASlug);
    Result := Qry.FieldByName('id').AsInteger;
  finally
    Qry.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_manage — Unified routing (B6.4, replaces 3 separate tools)
// ---------------------------------------------------------------------------
function HandleSkillManage(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  Action: string;
begin
  Action := AParams.GetValue<string>('action', '');
  if Action = 'record_finding' then
    Result := HandleSkillRecordFinding(AParams, AContext)
  else if Action = 'tune' then
    Result := HandleSkillTune(AParams, AContext)
  else if Action = 'rollback' then
    Result := HandleSkillRollback(AParams, AContext)
  else if Action = 'delete_skill' then
    Result := HandleSkillDelete(AParams, AContext)
  else
    raise EMxError.Create('INVALID_PARAM',
      'action must be one of: record_finding, tune, rollback, delete_skill');
end;

// ---------------------------------------------------------------------------
// mx_skill_record_finding — Persist a skill finding to the DB
// ---------------------------------------------------------------------------
function HandleSkillRecordFinding(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName, RuleId, ProjectSlug, SevStr, Title, Details,
    FilePath, CtxHash: string;
  ProjectId, LineNum: Integer;
  Finding: TMxSkillFinding;
  Uid: string;
  Data: TJSONObject;
begin
  SkillName := AParams.GetValue<string>('skill', '');
  RuleId := AParams.GetValue<string>('rule_id', '');
  ProjectSlug := AParams.GetValue<string>('project', '');
  SevStr := AParams.GetValue<string>('severity', 'info');
  Title := AParams.GetValue<string>('title', '');
  Details := AParams.GetValue<string>('details', '');
  FilePath := AParams.GetValue<string>('file_path', '');
  LineNum := AParams.GetValue<Integer>('line_number', 0);
  CtxHash := AParams.GetValue<string>('context_hash', '');

  if SkillName = '' then
    raise EMxError.Create('INVALID_PARAM', 'skill is required');
  if RuleId = '' then
    raise EMxError.Create('INVALID_PARAM', 'rule_id is required');
  if ProjectSlug = '' then
    raise EMxError.Create('INVALID_PARAM', 'project is required');
  if Title = '' then
    raise EMxError.Create('INVALID_PARAM', 'title is required');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  if not AContext.AccessControl.CheckProject(ProjectId, alReadWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadWrite);

  Uid := TMxSkillEvolutionData.GenerateUid(SkillName, RuleId, CtxHash);

  // Dedup: return existing UID if already recorded
  if TMxSkillEvolutionData.FindingExists(AContext, Uid) then
  begin
    Data := TJSONObject.Create;
    try
      Data.AddPair('finding_uid', Uid);
      Data.AddPair('status', 'duplicate');
      Data.AddPair('message', 'Finding already recorded');
      Result := MxSuccessResponse(Data, 0);
    except
      Data.Free;
      raise;
    end;
    Exit;
  end;

  Finding := Default(TMxSkillFinding);
  Finding.FindingUid := Uid;
  Finding.SkillName := SkillName;
  Finding.RuleId := RuleId;
  Finding.ProjectId := ProjectId;
  Finding.Severity := TMxSkillEvolutionData.StrToSeverity(SevStr);
  Finding.Title := Title;
  Finding.Details := Details;
  Finding.FilePath := FilePath;
  Finding.LineNumber := LineNum;
  Finding.ContextHash := CtxHash;

  TMxSkillEvolutionData.SaveFinding(AContext, Finding);

  Data := TJSONObject.Create;
  try
    Data.AddPair('finding_uid', Uid);
    Data.AddPair('status', 'created');
    Data.AddPair('message', 'Finding recorded');
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_feedback — Submit user reaction to a finding
// ---------------------------------------------------------------------------
function HandleSkillFeedback(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  FindingUid, ReactionStr, ProjectSlug: string;
  Reaction: TMxFindingReaction;
  Finding: TMxSkillFinding;
  ProjectId, Affected: Integer;
  Data: TJSONObject;
begin
  FindingUid := AParams.GetValue<string>('finding_uid', '');
  ReactionStr := AParams.GetValue<string>('reaction', '');
  ProjectSlug := AParams.GetValue<string>('project', '');

  if ReactionStr = '' then
    raise EMxError.Create('INVALID_PARAM', 'reaction is required');

  Reaction := TMxSkillEvolutionData.StrToReaction(ReactionStr);
  if (Reaction = frPending) and not SameText(ReactionStr, 'pending') then
    raise EMxError.Create('INVALID_PARAM',
      'Invalid reaction. Use: confirmed, dismissed, false_positive');

  // Batch mode: project provided, no finding_uid -> dismiss all pending
  if (FindingUid = '') and (ProjectSlug <> '') then
  begin
    ProjectId := ResolveProjectId(AContext, ProjectSlug);
    if not AContext.AccessControl.CheckProject(ProjectId, alReadWrite) then
      raise EMxAccessDenied.Create(ProjectSlug, alReadWrite);

    Affected := TMxSkillEvolutionData.DismissPendingByProject(
      AContext, ProjectId, Reaction);

    Data := TJSONObject.Create;
    try
      Data.AddPair('project', ProjectSlug);
      Data.AddPair('reaction', TMxSkillEvolutionData.ReactionToStr(Reaction));
      Data.AddPair('affected', TJSONNumber.Create(Affected));
      Data.AddPair('message', Format('Batch: %d pending findings updated', [Affected]));
      Result := MxSuccessResponse(Data, 0);
    except
      Data.Free;
      raise;
    end;
    Exit;
  end;

  // Single mode: finding_uid required
  if FindingUid = '' then
    raise EMxError.Create('INVALID_PARAM',
      'finding_uid is required (or provide project for batch mode)');

  // ACL: Load finding to get project, then check access
  Finding := TMxSkillEvolutionData.FindByUid(AContext, FindingUid);
  if Finding.Id = 0 then
    raise EMxError.Create('NOT_FOUND', 'Finding not found: ' + FindingUid);
  if not AContext.AccessControl.CheckProject(Finding.ProjectId, alReadWrite) then
    raise EMxAccessDenied.Create(FindingUid, alReadWrite);

  TMxSkillEvolutionData.UpdateReaction(AContext, FindingUid, Reaction);

  Data := TJSONObject.Create;
  try
    Data.AddPair('finding_uid', FindingUid);
    Data.AddPair('reaction', TMxSkillEvolutionData.ReactionToStr(Reaction));
    Data.AddPair('message', 'Feedback recorded');
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_metrics — Get metrics for a skill/project
// ---------------------------------------------------------------------------
function HandleSkillMetrics(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName, ProjectSlug, RuleId: string;
  ProjectId, DaysSince: Integer;
  Since: TDateTime;
  Metrics: TArray<TMxSkillMetrics>;
  Data, RuleObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  M: TMxSkillMetrics;
begin
  SkillName := AParams.GetValue<string>('skill', '');
  ProjectSlug := AParams.GetValue<string>('project', '');
  RuleId := AParams.GetValue<string>('rule_id', '');
  DaysSince := AParams.GetValue<Integer>('days', 90);

  if SkillName = '' then
    raise EMxError.Create('INVALID_PARAM', 'skill is required');
  if ProjectSlug = '' then
    raise EMxError.Create('INVALID_PARAM', 'project is required');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

  Since := IncDay(Now, -DaysSince);
  Metrics := TMxSkillEvolutionData.GetMetrics(AContext, SkillName,
    ProjectId, Since);

  Data := TJSONObject.Create;
  try
    Data.AddPair('skill', SkillName);
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('days', TJSONNumber.Create(DaysSince));

    Arr := TJSONArray.Create;
    for I := 0 to High(Metrics) do
    begin
      M := Metrics[I];
      // Filter by rule_id if specified
      if (RuleId <> '') and not SameText(M.RuleId, RuleId) then
        Continue;

      RuleObj := TJSONObject.Create;
      RuleObj.AddPair('rule_id', M.RuleId);
      RuleObj.AddPair('total', TJSONNumber.Create(M.TotalFindings));
      RuleObj.AddPair('confirmed', TJSONNumber.Create(M.Confirmed));
      RuleObj.AddPair('dismissed', TJSONNumber.Create(M.Dismissed));
      RuleObj.AddPair('false_positives', TJSONNumber.Create(M.FalsePositives));
      RuleObj.AddPair('pending', TJSONNumber.Create(M.Pending));
      RuleObj.AddPair('ignored', TJSONNumber.Create(M.Ignored));
      RuleObj.AddPair('precision', TJSONNumber.Create(Round(M.Precision * 1000) / 1000));
      RuleObj.AddPair('fp_rate', TJSONNumber.Create(Round(M.FalsePositiveRate * 1000) / 1000));
      RuleObj.AddPair('confirmation_rate', TJSONNumber.Create(Round(M.ConfirmationRate * 1000) / 1000));
      RuleObj.AddPair('weighted_precision', TJSONNumber.Create(Round(M.WeightedPrecision * 1000) / 1000));
      RuleObj.AddPair('weighted_fp_rate', TJSONNumber.Create(Round(M.WeightedFpRate * 1000) / 1000));
      RuleObj.AddPair('weighted_confirmation_rate', TJSONNumber.Create(Round(M.WeightedConfirmationRate * 1000) / 1000));
      Arr.AddElement(RuleObj);
    end;

    Data.AddPair('rules', Arr);
    Data.AddPair('rule_count', TJSONNumber.Create(Arr.Count));
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_findings_list — List individual findings with details
// ---------------------------------------------------------------------------
function HandleSkillFindingsList(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName, ProjectSlug, RuleId, StatusStr: string;
  ProjectId, Limit: Integer;
  FilterReaction: Boolean;
  Reaction: TMxFindingReaction;
  Findings: TArray<TMxSkillFinding>;
  Data, FindObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  F: TMxSkillFinding;
begin
  ProjectSlug := AParams.GetValue<string>('project', '');
  SkillName := AParams.GetValue<string>('skill', '');
  RuleId := AParams.GetValue<string>('rule_id', '');
  StatusStr := AParams.GetValue<string>('status', '');
  Limit := AParams.GetValue<Integer>('limit', 50);

  if ProjectSlug = '' then
    raise EMxError.Create('INVALID_PARAM', 'project is required');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  if not AContext.AccessControl.CheckProject(ProjectId, alReadOnly) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadOnly);

  FilterReaction := StatusStr <> '';
  if FilterReaction then
    Reaction := TMxSkillEvolutionData.StrToReaction(StatusStr)
  else
    Reaction := frPending; // unused when FilterReaction=False

  Findings := TMxSkillEvolutionData.ListFindings(AContext, ProjectId,
    SkillName, RuleId, Reaction, FilterReaction, Limit);

  Data := TJSONObject.Create;
  try
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('count', TJSONNumber.Create(Length(Findings)));

    Arr := TJSONArray.Create;
    for I := 0 to High(Findings) do
    begin
      F := Findings[I];
      FindObj := TJSONObject.Create;
      FindObj.AddPair('finding_uid', F.FindingUid);
      FindObj.AddPair('skill', F.SkillName);
      FindObj.AddPair('rule_id', F.RuleId);
      FindObj.AddPair('severity', TMxSkillEvolutionData.SeverityToStr(F.Severity));
      FindObj.AddPair('title', F.Title);
      if F.FilePath <> '' then
        FindObj.AddPair('file_path', F.FilePath);
      if F.LineNumber > 0 then
        FindObj.AddPair('line_number', TJSONNumber.Create(F.LineNumber));
      if F.Details <> '' then
        FindObj.AddPair('details', F.Details);
      FindObj.AddPair('status', TMxSkillEvolutionData.ReactionToStr(F.Reaction));
      FindObj.AddPair('created_at', FormatDateTime('yyyy-mm-dd hh:nn:ss', F.CreatedAt));
      Arr.AddElement(FindObj);
    end;

    Data.AddPair('findings', Arr);
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_tune — Calculate and optionally apply tuning proposals
// ---------------------------------------------------------------------------
function HandleSkillTune(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName, ProjectSlug, RuleName, RuleAction: string;
  ProjectId: Integer;
  AutoApply: Boolean;
  Manager: TMxSkillEvolutionManager;
begin
  SkillName := AParams.GetValue<string>('skill', '');
  ProjectSlug := AParams.GetValue<string>('project', '');
  AutoApply := AParams.GetValue<Boolean>('auto_apply', False);
  RuleName := AParams.GetValue<string>('rule_name', '');
  RuleAction := AParams.GetValue<string>('tune_action', '');

  if SkillName = '' then
    raise EMxError.Create('INVALID_PARAM', 'skill is required');
  if ProjectSlug = '' then
    raise EMxError.Create('INVALID_PARAM', 'project is required');

  // Validate action if provided
  if (RuleAction <> '') and (RuleName = '') then
    raise EMxError.Create('INVALID_PARAM', 'rule_name is required when action is specified');
  if (RuleAction <> '') and
     (RuleAction <> 'disable') and (RuleAction <> 'enable') and
     (RuleAction <> 'downgrade') and (RuleAction <> 'promote') then
    raise EMxError.Create('INVALID_PARAM',
      'action must be one of: disable, enable, downgrade, promote');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  if not AContext.AccessControl.CheckProject(ProjectId, alReadWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadWrite);

  Manager := TMxSkillEvolutionManager.Create(nil, AContext.Logger);
  try
    if (RuleName <> '') and (RuleAction <> '') then
      Result := Manager.ApplyDirectAction(AContext, SkillName, ProjectId,
        RuleName, RuleAction)
    else
      Result := Manager.ApplyTuning(AContext, SkillName, ProjectId, AutoApply);
  finally
    Manager.Free;
  end;
end;

// ---------------------------------------------------------------------------
// mx_skill_rollback — Rollback last parameter change
// ---------------------------------------------------------------------------
function HandleSkillRollback(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName, ProjectSlug, ParamKey: string;
  ProjectId: Integer;
  Data: TJSONObject;
begin
  SkillName := AParams.GetValue<string>('skill', '');
  ProjectSlug := AParams.GetValue<string>('project', '');
  ParamKey := AParams.GetValue<string>('param_key', '');

  if SkillName = '' then
    raise EMxError.Create('INVALID_PARAM', 'skill is required');
  if ProjectSlug = '' then
    raise EMxError.Create('INVALID_PARAM', 'project is required');
  if ParamKey = '' then
    raise EMxError.Create('INVALID_PARAM', 'param_key is required');

  ProjectId := ResolveProjectId(AContext, ProjectSlug);

  if not AContext.AccessControl.CheckProject(ProjectId, alReadWrite) then
    raise EMxAccessDenied.Create(ProjectSlug, alReadWrite);

  if not TMxSkillEvolutionData.RollbackParam(AContext, SkillName,
    ProjectId, ParamKey) then
    raise EMxError.Create('ROLLBACK_FAILED',
      'No previous value to rollback for: ' + ParamKey);

  Data := TJSONObject.Create;
  try
    Data.AddPair('skill', SkillName);
    Data.AddPair('project', ProjectSlug);
    Data.AddPair('param_key', ParamKey);
    Data.AddPair('message', 'Parameter rolled back to previous value');
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

// ---------------------------------------------------------------------------
// delete_skill — Remove all skill data (findings, rules, params)
// ---------------------------------------------------------------------------
function HandleSkillDelete(const AParams: TJSONObject;
  AContext: IMxDbContext): TJSONObject;
var
  SkillName: string;
  Qry: TFDQuery;
  DelFindings, DelParams: Integer;
  Data: TJSONObject;
begin
  SkillName := LowerCase(Trim(AParams.GetValue<string>('skill', '')));
  if SkillName = '' then
    raise EMxError.Create('INVALID_PARAM', 'skill is required');

  if not AContext.AccessControl.IsAdmin then
    raise EMxAccessDenied.Create('_global', alReadWrite);

  // Delete findings
  Qry := AContext.CreateQuery(
    'DELETE FROM skill_findings WHERE skill_name = :skill');
  try
    Qry.ParamByName('skill').AsString := SkillName;
    Qry.ExecSQL;
    DelFindings := Qry.RowsAffected;
  finally
    Qry.Free;
  end;

  // Delete params
  Qry := AContext.CreateQuery(
    'DELETE FROM skill_params WHERE skill_name = :skill');
  try
    Qry.ParamByName('skill').AsString := SkillName;
    Qry.ExecSQL;
    DelParams := Qry.RowsAffected;
  finally
    Qry.Free;
  end;

  Data := TJSONObject.Create;
  try
    Data.AddPair('skill', SkillName);
    Data.AddPair('deleted_findings', TJSONNumber.Create(DelFindings));
    Data.AddPair('deleted_params', TJSONNumber.Create(DelParams));
    if (DelFindings = 0) and (DelParams = 0) then
      Data.AddPair('message', 'No data found for skill')
    else
      Data.AddPair('message', 'Skill completely removed');
    Result := MxSuccessResponse(Data, 0);
  except
    Data.Free;
    raise;
  end;
end;

end.
