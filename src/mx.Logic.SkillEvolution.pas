unit mx.Logic.SkillEvolution;

interface

uses
  System.SysUtils, System.JSON, System.DateUtils, System.Math, System.StrUtils,
  mx.Types, mx.Errors, mx.Data.SkillEvolution;

type
  TMxSkillEvolutionManager = class
  private
    FPool: TObject;  // TMxConnectionPool — forward-avoids circular ref
    FLogger: IMxLogger;
    function AcquireContext: IMxDbContext;
    function GetMinFindings(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer): Integer;
    function GetThreshold(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      const AParamKey: string; ADefault: Double): Double;
  public
    constructor Create(APool: TObject; ALogger: IMxLogger);

    // --- Finding Lifecycle ---
    function RecordFinding(const ASkillName, ARuleId: string;
      AProjectId: Integer; ASeverity: TMxFindingSeverity;
      const ATitle: string; const ADetails: string = '';
      const AFilePath: string = ''; ALineNumber: Integer = 0;
      const AContextHash: string = ''): string;

    function SubmitFeedback(const AFindingUid: string;
      AReaction: TMxFindingReaction): Boolean;

    // --- Metrics ---
    function GetSkillMetrics(const ASkillName: string;
      AProjectId: Integer;
      ADaysSince: Integer = 90): TArray<TMxSkillMetrics>;

    function GetRuleMetrics(const ASkillName, ARuleId: string;
      AProjectId: Integer;
      ADaysSince: Integer = 90): TMxSkillMetrics;

    function MetricsToJSON(const AMetrics: TArray<TMxSkillMetrics>): TJSONObject;

    // --- Params ---
    function GetParam(const ASkillName: string; AProjectId: Integer;
      const AParamKey: string; const ADefault: string = ''): string;

    function SetParam(const ASkillName: string; AProjectId: Integer;
      const AParamKey, AParamValue, AReason: string): Boolean;

    function RollbackParam(const ASkillName: string; AProjectId: Integer;
      const AParamKey: string): Boolean;

    // --- Auto-Tuning ---
    function CalculateTuningProposal(const ASkillName: string;
      AProjectId: Integer): TJSONObject; overload;
    function CalculateTuningProposal(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer): TJSONObject; overload;
    function ApplyTuning(const ASkillName: string;
      AProjectId: Integer; AAutoApply: Boolean): TJSONObject; overload;
    function ApplyTuning(ACtx: IMxDbContext; const ASkillName: string;
      AProjectId: Integer; AAutoApply: Boolean): TJSONObject; overload;
    function ApplyDirectAction(ACtx: IMxDbContext;
      const ASkillName: string; AProjectId: Integer;
      const ARuleName, AAction: string): TJSONObject;
  end;

implementation

uses
  mx.Data.Pool;

constructor TMxSkillEvolutionManager.Create(APool: TObject;
  ALogger: IMxLogger);
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
end;

function TMxSkillEvolutionManager.AcquireContext: IMxDbContext;
begin
  Result := TMxConnectionPool(FPool).AcquireContext;
end;

function TMxSkillEvolutionManager.GetMinFindings(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer): Integer;
var
  S: string;
begin
  S := TMxSkillEvolutionData.GetParam(ACtx, ASkillName, AProjectId,
    'min_findings_for_tuning', '20');
  Result := StrToIntDef(S, 20);
end;

function TMxSkillEvolutionManager.GetThreshold(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  const AParamKey: string; ADefault: Double): Double;
var
  S: string;
  FS: TFormatSettings;
begin
  S := TMxSkillEvolutionData.GetParam(ACtx, ASkillName, AProjectId,
    AParamKey, '');
  if S = '' then
    Result := ADefault
  else
  begin
    FS := TFormatSettings.Create;
    FS.DecimalSeparator := '.';
    Result := StrToFloatDef(S, ADefault, FS);
  end;
end;

{ --- Finding Lifecycle --- }

function TMxSkillEvolutionManager.RecordFinding(
  const ASkillName, ARuleId: string; AProjectId: Integer;
  ASeverity: TMxFindingSeverity; const ATitle, ADetails, AFilePath: string;
  ALineNumber: Integer; const AContextHash: string): string;
var
  Ctx: IMxDbContext;
  Finding: TMxSkillFinding;
  Uid: string;
begin
  Uid := TMxSkillEvolutionData.GenerateUid(ASkillName, ARuleId, AContextHash);
  Ctx := AcquireContext;

  // Dedup: if finding with same UID exists, return existing
  if TMxSkillEvolutionData.FindingExists(Ctx, Uid) then
  begin
    FLogger.Log(mlDebug, 'Skill finding already exists: ' + Uid);
    Exit(Uid);
  end;

  Finding := Default(TMxSkillFinding);
  Finding.FindingUid := Uid;
  Finding.SkillName := ASkillName;
  Finding.RuleId := ARuleId;
  Finding.ProjectId := AProjectId;
  Finding.Severity := ASeverity;
  Finding.Title := ATitle;
  Finding.Details := ADetails;
  Finding.FilePath := AFilePath;
  Finding.LineNumber := ALineNumber;
  Finding.ContextHash := AContextHash;

  TMxSkillEvolutionData.SaveFinding(Ctx, Finding);
  FLogger.Log(mlInfo, 'Skill finding recorded: ' + Uid);
  Result := Uid;
end;

function TMxSkillEvolutionManager.SubmitFeedback(
  const AFindingUid: string; AReaction: TMxFindingReaction): Boolean;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.UpdateReaction(Ctx, AFindingUid, AReaction);
  if Result then
    FLogger.Log(mlInfo, Format('Feedback recorded: %s -> %s',
      [AFindingUid, TMxSkillEvolutionData.ReactionToStr(AReaction)]))
  else
    FLogger.Log(mlWarning, 'Finding not found for feedback: ' + AFindingUid);
end;

{ --- Metrics --- }

function TMxSkillEvolutionManager.GetSkillMetrics(
  const ASkillName: string; AProjectId: Integer;
  ADaysSince: Integer): TArray<TMxSkillMetrics>;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.GetMetrics(Ctx, ASkillName, AProjectId,
    IncDay(Now, -ADaysSince));
end;

function TMxSkillEvolutionManager.GetRuleMetrics(
  const ASkillName, ARuleId: string; AProjectId: Integer;
  ADaysSince: Integer): TMxSkillMetrics;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.GetMetricsForRule(Ctx,
    ASkillName, ARuleId, AProjectId, IncDay(Now, -ADaysSince));
end;

function TMxSkillEvolutionManager.MetricsToJSON(
  const AMetrics: TArray<TMxSkillMetrics>): TJSONObject;
var
  Arr: TJSONArray;
  I: Integer;
  M: TMxSkillMetrics;
  Obj: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    Result.AddPair('rules', Arr); // Arr now owned by Result
    for I := 0 to High(AMetrics) do
    begin
      M := AMetrics[I];
      Obj := TJSONObject.Create;
      Obj.AddPair('rule_id', M.RuleId);
      Obj.AddPair('total', TJSONNumber.Create(M.TotalFindings));
      Obj.AddPair('confirmed', TJSONNumber.Create(M.Confirmed));
      Obj.AddPair('dismissed', TJSONNumber.Create(M.Dismissed));
      Obj.AddPair('false_positives', TJSONNumber.Create(M.FalsePositives));
      Obj.AddPair('pending', TJSONNumber.Create(M.Pending));
      Obj.AddPair('ignored', TJSONNumber.Create(M.Ignored));
      Obj.AddPair('precision', TJSONNumber.Create(RoundTo(M.Precision, -3)));
      Obj.AddPair('fp_rate', TJSONNumber.Create(RoundTo(M.FalsePositiveRate, -3)));
      Obj.AddPair('confirmation_rate', TJSONNumber.Create(RoundTo(M.ConfirmationRate, -3)));
      Obj.AddPair('weighted_precision', TJSONNumber.Create(RoundTo(M.WeightedPrecision, -3)));
      Obj.AddPair('weighted_fp_rate', TJSONNumber.Create(RoundTo(M.WeightedFpRate, -3)));
      Obj.AddPair('weighted_confirmation_rate', TJSONNumber.Create(RoundTo(M.WeightedConfirmationRate, -3)));
      Arr.AddElement(Obj);
    end;
    Result.AddPair('count', TJSONNumber.Create(Length(AMetrics)));
  except
    Result.Free;
    raise;
  end;
end;

{ --- Params --- }

function TMxSkillEvolutionManager.GetParam(const ASkillName: string;
  AProjectId: Integer; const AParamKey, ADefault: string): string;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.GetParam(Ctx, ASkillName, AProjectId,
    AParamKey, ADefault);
end;

function TMxSkillEvolutionManager.SetParam(const ASkillName: string;
  AProjectId: Integer; const AParamKey, AParamValue, AReason: string): Boolean;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.SetParam(Ctx, ASkillName, AProjectId,
    AParamKey, AParamValue, AReason);
  if Result then
    FLogger.Log(mlInfo, Format('Skill param updated: %s/%d/%s = %s (%s)',
      [ASkillName, AProjectId, AParamKey, AParamValue, AReason]));
end;

function TMxSkillEvolutionManager.RollbackParam(const ASkillName: string;
  AProjectId: Integer; const AParamKey: string): Boolean;
var
  Ctx: IMxDbContext;
begin
  Ctx := AcquireContext;
  Result := TMxSkillEvolutionData.RollbackParam(Ctx, ASkillName, AProjectId,
    AParamKey);
  if Result then
    FLogger.Log(mlInfo, Format('Skill param rolled back: %s/%d/%s',
      [ASkillName, AProjectId, AParamKey]))
  else
    FLogger.Log(mlWarning, Format('Rollback failed (no previous value): %s/%d/%s',
      [ASkillName, AProjectId, AParamKey]));
end;

{ --- Auto-Tuning --- }

function TMxSkillEvolutionManager.CalculateTuningProposal(
  const ASkillName: string; AProjectId: Integer): TJSONObject;
begin
  Result := CalculateTuningProposal(AcquireContext, ASkillName, AProjectId);
end;

function TMxSkillEvolutionManager.CalculateTuningProposal(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer): TJSONObject;
var
  Metrics: TArray<TMxSkillMetrics>;
  MinFindings: Integer;
  FpThreshold, PrecisionThreshold, ConfirmThreshold: Double;
  Proposals: TJSONArray;
  I, TotalReacted: Integer;
  M: TMxSkillMetrics;
  Prop: TJSONObject;
begin
  MinFindings := GetMinFindings(ACtx, ASkillName, AProjectId);
  // Configurable thresholds via skill_params (per-skill override)
  FpThreshold := GetThreshold(ACtx, ASkillName, AProjectId,
    'fp_rate_threshold_downgrade', 0.50);
  PrecisionThreshold := GetThreshold(ACtx, ASkillName, AProjectId,
    'precision_threshold_promote', 0.90);
  ConfirmThreshold := GetThreshold(ACtx, ASkillName, AProjectId,
    'confirm_rate_threshold_disable', 0.10);

  Metrics := TMxSkillEvolutionData.GetMetrics(ACtx, ASkillName, AProjectId,
    IncDay(Now, -90));

  Result := TJSONObject.Create;
  try
    Result.AddPair('skill', ASkillName);
    Result.AddPair('project_id', TJSONNumber.Create(AProjectId));
    Result.AddPair('min_findings', TJSONNumber.Create(MinFindings));
    Result.AddPair('thresholds', TJSONObject.Create
      .AddPair('fp_rate_downgrade', TJSONNumber.Create(FpThreshold))
      .AddPair('precision_promote', TJSONNumber.Create(PrecisionThreshold))
      .AddPair('confirm_rate_disable', TJSONNumber.Create(ConfirmThreshold)));
    Proposals := TJSONArray.Create;
    Result.AddPair('proposals', Proposals);

    for I := 0 to High(Metrics) do
    begin
      M := Metrics[I];
      // Reacted = total - pending - ignored
      TotalReacted := M.TotalFindings - M.Pending - M.Ignored;
      if TotalReacted < MinFindings then
        Continue;

      Prop := TJSONObject.Create;
      Prop.AddPair('rule_id', M.RuleId);
      Prop.AddPair('total_reacted', TJSONNumber.Create(TotalReacted));
      Prop.AddPair('ignored', TJSONNumber.Create(M.Ignored));
      Prop.AddPair('precision', TJSONNumber.Create(RoundTo(M.Precision, -3)));
      Prop.AddPair('fp_rate', TJSONNumber.Create(RoundTo(M.FalsePositiveRate, -3)));
      Prop.AddPair('weighted_precision', TJSONNumber.Create(RoundTo(M.WeightedPrecision, -3)));
      Prop.AddPair('weighted_fp_rate', TJSONNumber.Create(RoundTo(M.WeightedFpRate, -3)));
      Prop.AddPair('confirmation_rate', TJSONNumber.Create(RoundTo(M.ConfirmationRate, -3)));

      // Use weighted metrics for tuning decisions (recent findings count more)
      if M.WeightedFpRate > FpThreshold then
        Prop.AddPair('proposal', 'downgrade_severity')
      else if M.WeightedPrecision > PrecisionThreshold then
        Prop.AddPair('proposal', 'promote_priority')
      else if M.WeightedConfirmationRate < ConfirmThreshold then
        Prop.AddPair('proposal', 'disable_rule')
      else
        Prop.AddPair('proposal', 'no_change');

      Proposals.AddElement(Prop);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ --- Apply Tuning with Regression Gate --- }

function TMxSkillEvolutionManager.ApplyTuning(const ASkillName: string;
  AProjectId: Integer; AAutoApply: Boolean): TJSONObject;
begin
  Result := ApplyTuning(AcquireContext, ASkillName, AProjectId, AAutoApply);
end;

function TMxSkillEvolutionManager.ApplyTuning(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  AAutoApply: Boolean): TJSONObject;
var
  Proposal: TJSONObject;
  Proposals, Applied, Rejected: TJSONArray;
  I: Integer;
  Prop, Entry: TJSONObject;
  RuleId, Action, ParamKey, ParamValue, Reason: string;
  MetricsSnap: TJSONObject;
  FpRate, Precision, ConfirmRate: Double;
  TotalReacted: Integer;
begin
  // Step 1: Calculate proposals
  Proposal := CalculateTuningProposal(ACtx, ASkillName, AProjectId);
  try
    Proposals := Proposal.GetValue<TJSONArray>('proposals');
  except
    Proposal.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  try
    Result.AddPair('skill', ASkillName);
    Result.AddPair('project_id', TJSONNumber.Create(AProjectId));
    Result.AddPair('auto_apply', TJSONBool.Create(AAutoApply));
    Applied := TJSONArray.Create;
    Result.AddPair('applied', Applied);
    Rejected := TJSONArray.Create;
    Result.AddPair('rejected', Rejected);

    for I := 0 to Proposals.Count - 1 do
    begin
      Prop := Proposals.Items[I] as TJSONObject;
      RuleId := Prop.GetValue<string>('rule_id', '');
      Action := Prop.GetValue<string>('proposal', 'no_change');
      FpRate := Prop.GetValue<Double>('fp_rate', 0);
      Precision := Prop.GetValue<Double>('precision', 0);
      ConfirmRate := Prop.GetValue<Double>('confirmation_rate', 0);
      TotalReacted := Prop.GetValue<Integer>('total_reacted', 0);

      if Action = 'no_change' then
        Continue;

      // --- Regression Gate ---
      // Rule 1: Never disable a rule with >30% confirmation rate
      if (Action = 'disable_rule') and (ConfirmRate > 0.3) then
      begin
        Entry := TJSONObject.Create;
        Entry.AddPair('rule_id', RuleId);
        Entry.AddPair('action', Action);
        Entry.AddPair('reason', 'Regression gate: confirmation rate > 30%');
        Rejected.AddElement(Entry);
        Continue;
      end;

      // Rule 2: Never promote with < 10 reacted findings (extra caution)
      if (Action = 'promote_priority') and (TotalReacted < 10) then
      begin
        Entry := TJSONObject.Create;
        Entry.AddPair('rule_id', RuleId);
        Entry.AddPair('action', Action);
        Entry.AddPair('reason', 'Regression gate: insufficient data for promotion');
        Rejected.AddElement(Entry);
        Continue;
      end;

      // Rule 3: Downgrade only if FP rate consistently high (>50%)
      if (Action = 'downgrade_severity') and (FpRate <= 0.5) then
      begin
        Entry := TJSONObject.Create;
        Entry.AddPair('rule_id', RuleId);
        Entry.AddPair('action', Action);
        Entry.AddPair('reason', 'Regression gate: FP rate not high enough');
        Rejected.AddElement(Entry);
        Continue;
      end;

      // --- Passed regression gate ---
      // Map action to param
      ParamKey := 'rule_' + RuleId;
      case IndexStr(Action, ['downgrade_severity', 'promote_priority',
        'disable_rule']) of
        0: begin // downgrade_severity
             ParamKey := ParamKey + '_severity';
             ParamValue := 'downgraded';
             Reason := Format('FP rate %.0f%% > 50%% (%d findings)',
               [FpRate * 100, TotalReacted]);
           end;
        1: begin // promote_priority
             ParamKey := ParamKey + '_priority';
             ParamValue := 'high';
             Reason := Format('Precision %.0f%% > 90%% (%d findings)',
               [Precision * 100, TotalReacted]);
           end;
        2: begin // disable_rule
             ParamKey := ParamKey + '_enabled';
             ParamValue := 'false';
             Reason := Format('Confirmation rate < 10%% (%d findings)',
               [TotalReacted]);
           end;
      else
        Continue;
      end;

      Entry := TJSONObject.Create;
      Entry.AddPair('rule_id', RuleId);
      Entry.AddPair('action', Action);
      Entry.AddPair('param_key', ParamKey);
      Entry.AddPair('param_value', ParamValue);
      Entry.AddPair('reason', Reason);

      if AAutoApply then
      begin
        // Build metrics snapshot for audit trail
        MetricsSnap := TJSONObject.Create;
        try
          MetricsSnap.AddPair('fp_rate', TJSONNumber.Create(FpRate));
          MetricsSnap.AddPair('precision', TJSONNumber.Create(Precision));
          MetricsSnap.AddPair('total_reacted', TJSONNumber.Create(TotalReacted));

          TMxSkillEvolutionData.SetParam(ACtx, ASkillName, AProjectId,
            ParamKey, ParamValue, Reason, MetricsSnap);
        finally
          MetricsSnap.Free;
        end;
        Entry.AddPair('status', 'applied');
        FLogger.Log(mlInfo, Format('Auto-tune applied: %s/%s = %s (%s)',
          [ASkillName, ParamKey, ParamValue, Reason]));
      end
      else
        Entry.AddPair('status', 'proposed');

      Applied.AddElement(Entry);
    end;

    Result.AddPair('applied_count', TJSONNumber.Create(Applied.Count));
    Result.AddPair('rejected_count', TJSONNumber.Create(Rejected.Count));
  except
    Result.Free;
    Proposal.Free;
    raise;
  end;

  Proposal.Free;
end;

// ---------------------------------------------------------------------------
// ApplyDirectAction — Targeted rule action (bypasses Regression Gate)
// Actions: disable, enable, downgrade, promote
// ---------------------------------------------------------------------------
function TMxSkillEvolutionManager.ApplyDirectAction(ACtx: IMxDbContext;
  const ASkillName: string; AProjectId: Integer;
  const ARuleName, AAction: string): TJSONObject;
var
  ParamKey, ParamValue, Reason: string;
  MetricsSnap: TJSONObject;
begin
  // Map action to param_key + value
  if AAction = 'disable' then
  begin
    ParamKey := 'rule_' + ARuleName + '_enabled';
    ParamValue := 'false';
    Reason := 'Manually disabled via mx_skill_tune';
  end
  else if AAction = 'enable' then
  begin
    ParamKey := 'rule_' + ARuleName + '_enabled';
    ParamValue := 'true';
    Reason := 'Manually enabled via mx_skill_tune';
  end
  else if AAction = 'downgrade' then
  begin
    ParamKey := 'rule_' + ARuleName + '_severity';
    ParamValue := 'downgraded';
    Reason := 'Manually downgraded via mx_skill_tune';
  end
  else if AAction = 'promote' then
  begin
    ParamKey := 'rule_' + ARuleName + '_priority';
    ParamValue := 'high';
    Reason := 'Manually promoted via mx_skill_tune';
  end
  else
    raise EMxError.Create('INVALID_PARAM', 'Unknown action: ' + AAction);

  MetricsSnap := TJSONObject.Create;
  try
    MetricsSnap.AddPair('manual_action', AAction);
    MetricsSnap.AddPair('rule_name', ARuleName);

    TMxSkillEvolutionData.SetParam(ACtx, ASkillName, AProjectId,
      ParamKey, ParamValue, Reason, MetricsSnap);
  finally
    MetricsSnap.Free;
  end;

  Result := TJSONObject.Create;
  try
    Result.AddPair('skill', ASkillName);
    Result.AddPair('project_id', TJSONNumber.Create(AProjectId));
    Result.AddPair('rule_name', ARuleName);
    Result.AddPair('action', AAction);
    Result.AddPair('param_key', ParamKey);
    Result.AddPair('param_value', ParamValue);
    Result.AddPair('reason', Reason);
    Result.AddPair('status', 'applied');
  except
    Result.Free;
    raise;
  end;

  FLogger.Log(mlInfo, Format('Direct tune: %s/%s → %s (%s)',
    [ASkillName, ParamKey, ParamValue, Reason]));
end;

end.
