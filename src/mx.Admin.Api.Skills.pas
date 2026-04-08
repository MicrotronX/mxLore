unit mx.Admin.Api.Skills;

interface

uses
  Sparkle.HttpServer.Context,
  mx.Types, mx.Data.Pool;

procedure HandleGetSkillsDashboard(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

procedure HandlePostSkillFeedback(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);

implementation

uses
  System.SysUtils, System.JSON, System.DateUtils, System.IOUtils,
  System.Classes, System.Types,
  FireDAC.Comp.Client,
  mx.Admin.Server, mx.Data.SkillEvolution;

// ---------------------------------------------------------------------------
// GET /skills/dashboard — Complete Skills Dashboard Data
// ---------------------------------------------------------------------------
procedure HandleGetSkillsDashboard(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  Json, Obj, Summary: TJSONObject;
  SkillsArr, FindingsArr, ParamsArr, RulesArr: TJSONArray;
  TotalFindings, TotalPending, TotalConfirmed, TotalDismissed, TotalFP: Integer;
begin
  Ctx := APool.AcquireContext;
  Json := TJSONObject.Create;
  try
    TotalFindings := 0;
    TotalPending := 0;
    TotalConfirmed := 0;
    TotalDismissed := 0;
    TotalFP := 0;

    // 1. Per-skill aggregation
    SkillsArr := TJSONArray.Create;
    Json.AddPair('skills', SkillsArr);
    Qry := Ctx.CreateQuery(
      'SELECT skill_name, ' +
      '  COUNT(*) AS total, ' +
      '  SUM(CASE WHEN user_reaction = ''pending'' THEN 1 ELSE 0 END) AS pending, ' +
      '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN 1 ELSE 0 END) AS confirmed, ' +
      '  SUM(CASE WHEN user_reaction = ''dismissed'' THEN 1 ELSE 0 END) AS dismissed, ' +
      '  SUM(CASE WHEN user_reaction = ''false_positive'' THEN 1 ELSE 0 END) AS false_pos, ' +
      '  MIN(created_at) AS first_finding, ' +
      '  MAX(created_at) AS last_finding, ' +
      '  COUNT(DISTINCT rule_id) AS rule_count, ' +
      '  COUNT(DISTINCT project_id) AS project_count ' +
      'FROM skill_findings ' +
      'GROUP BY skill_name ORDER BY total DESC');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Obj := TJSONObject.Create;
        Obj.AddPair('name', Qry.FieldByName('skill_name').AsString);
        Obj.AddPair('total', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
        Obj.AddPair('pending', TJSONNumber.Create(Qry.FieldByName('pending').AsInteger));
        Obj.AddPair('confirmed', TJSONNumber.Create(Qry.FieldByName('confirmed').AsInteger));
        Obj.AddPair('dismissed', TJSONNumber.Create(Qry.FieldByName('dismissed').AsInteger));
        Obj.AddPair('false_positives', TJSONNumber.Create(Qry.FieldByName('false_pos').AsInteger));
        Obj.AddPair('rules', TJSONNumber.Create(Qry.FieldByName('rule_count').AsInteger));
        Obj.AddPair('projects', TJSONNumber.Create(Qry.FieldByName('project_count').AsInteger));
        if not Qry.FieldByName('last_finding').IsNull then
          Obj.AddPair('last_finding', FormatDateTime('yyyy-mm-dd hh:nn',
            Qry.FieldByName('last_finding').AsDateTime));
        // FP rate calculation
        var Reacted := Qry.FieldByName('total').AsInteger - Qry.FieldByName('pending').AsInteger;
        if Reacted > 0 then
          Obj.AddPair('fp_rate', TJSONNumber.Create(
            Round(Qry.FieldByName('false_pos').AsInteger / Reacted * 100)))
        else
          Obj.AddPair('fp_rate', TJSONNumber.Create(0));
        // Confirmation rate: confirmed / all reacted (confirmed + dismissed + FP)
        var Conf := Qry.FieldByName('confirmed').AsInteger;
        if Reacted > 0 then
          Obj.AddPair('precision', TJSONNumber.Create(Round(Conf / Reacted * 100)))
        else
          Obj.AddPair('precision', TJSONNumber.Create(0));

        SkillsArr.AddElement(Obj);

        TotalFindings := TotalFindings + Qry.FieldByName('total').AsInteger;
        TotalPending := TotalPending + Qry.FieldByName('pending').AsInteger;
        TotalConfirmed := TotalConfirmed + Qry.FieldByName('confirmed').AsInteger;
        TotalDismissed := TotalDismissed + Qry.FieldByName('dismissed').AsInteger;
        TotalFP := TotalFP + Qry.FieldByName('false_pos').AsInteger;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // Summary
    Summary := TJSONObject.Create;
    Json.AddPair('summary', Summary);
    Summary.AddPair('total_findings', TJSONNumber.Create(TotalFindings));
    Summary.AddPair('pending', TJSONNumber.Create(TotalPending));
    Summary.AddPair('confirmed', TJSONNumber.Create(TotalConfirmed));
    Summary.AddPair('dismissed', TJSONNumber.Create(TotalDismissed));
    Summary.AddPair('false_positives', TJSONNumber.Create(TotalFP));
    Summary.AddPair('skills_tracked', TJSONNumber.Create(SkillsArr.Count));
    var TotalReacted := TotalFindings - TotalPending;
    if TotalReacted > 0 then
    begin
      Summary.AddPair('overall_fp_rate', TJSONNumber.Create(Round(TotalFP / TotalReacted * 100)));
      Summary.AddPair('overall_conf_rate', TJSONNumber.Create(Round(TotalConfirmed / TotalReacted * 100)));
    end
    else
    begin
      Summary.AddPair('overall_fp_rate', TJSONNumber.Create(0));
      Summary.AddPair('overall_conf_rate', TJSONNumber.Create(0));
    end;

    // 2. Per-rule breakdown (top rules by finding count)
    RulesArr := TJSONArray.Create;
    Json.AddPair('rules', RulesArr);
    Qry := Ctx.CreateQuery(
      'SELECT skill_name, rule_id, ' +
      '  COUNT(*) AS total, ' +
      '  SUM(CASE WHEN user_reaction = ''confirmed'' THEN 1 ELSE 0 END) AS confirmed, ' +
      '  SUM(CASE WHEN user_reaction = ''dismissed'' THEN 1 ELSE 0 END) AS dismissed, ' +
      '  SUM(CASE WHEN user_reaction = ''false_positive'' THEN 1 ELSE 0 END) AS false_pos, ' +
      '  SUM(CASE WHEN user_reaction = ''pending'' THEN 1 ELSE 0 END) AS pending ' +
      'FROM skill_findings ' +
      'GROUP BY skill_name, rule_id ' +
      'ORDER BY total DESC LIMIT 20');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Obj := TJSONObject.Create;
        Obj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        Obj.AddPair('rule', Qry.FieldByName('rule_id').AsString);
        Obj.AddPair('total', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
        Obj.AddPair('confirmed', TJSONNumber.Create(Qry.FieldByName('confirmed').AsInteger));
        Obj.AddPair('dismissed', TJSONNumber.Create(Qry.FieldByName('dismissed').AsInteger));
        Obj.AddPair('false_positives', TJSONNumber.Create(Qry.FieldByName('false_pos').AsInteger));
        Obj.AddPair('pending', TJSONNumber.Create(Qry.FieldByName('pending').AsInteger));
        RulesArr.AddElement(Obj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // 3. Recent findings (all, limited to 50)
    FindingsArr := TJSONArray.Create;
    Json.AddPair('findings', FindingsArr);
    Qry := Ctx.CreateQuery(
      'SELECT f.id, f.finding_uid, f.skill_name, f.rule_id, f.severity, ' +
      '  f.title, f.file_path, f.line_number, f.user_reaction, ' +
      '  f.created_at, f.reacted_at, p.slug AS project ' +
      'FROM skill_findings f ' +
      'JOIN projects p ON p.id = f.project_id ' +
      'ORDER BY f.created_at DESC LIMIT 50');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Obj := TJSONObject.Create;
        Obj.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Obj.AddPair('uid', Qry.FieldByName('finding_uid').AsString);
        Obj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        Obj.AddPair('rule', Qry.FieldByName('rule_id').AsString);
        Obj.AddPair('severity', Qry.FieldByName('severity').AsString);
        Obj.AddPair('title', Qry.FieldByName('title').AsString);
        if not Qry.FieldByName('file_path').IsNull then
          Obj.AddPair('file', Qry.FieldByName('file_path').AsString);
        if Qry.FieldByName('line_number').AsInteger > 0 then
          Obj.AddPair('line', TJSONNumber.Create(Qry.FieldByName('line_number').AsInteger));
        Obj.AddPair('reaction', Qry.FieldByName('user_reaction').AsString);
        Obj.AddPair('project', Qry.FieldByName('project').AsString);
        Obj.AddPair('created', FormatDateTime('yyyy-mm-dd hh:nn',
          Qry.FieldByName('created_at').AsDateTime));
        if not Qry.FieldByName('reacted_at').IsNull then
          Obj.AddPair('reacted', FormatDateTime('yyyy-mm-dd hh:nn',
            Qry.FieldByName('reacted_at').AsDateTime));
        FindingsArr.AddElement(Obj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // 4. Active tuning params
    ParamsArr := TJSONArray.Create;
    Json.AddPair('params', ParamsArr);
    Qry := Ctx.CreateQuery(
      'SELECT sp.skill_name, sp.param_key, sp.param_value, sp.version, ' +
      '  sp.previous_value, sp.change_reason, sp.updated_at, p.slug AS project ' +
      'FROM skill_params sp ' +
      'JOIN projects p ON p.id = sp.project_id ' +
      'ORDER BY sp.updated_at DESC LIMIT 30');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        Obj := TJSONObject.Create;
        Obj.AddPair('skill', Qry.FieldByName('skill_name').AsString);
        Obj.AddPair('key', Qry.FieldByName('param_key').AsString);
        Obj.AddPair('value', Qry.FieldByName('param_value').AsString);
        Obj.AddPair('version', TJSONNumber.Create(Qry.FieldByName('version').AsInteger));
        if not Qry.FieldByName('previous_value').IsNull then
          Obj.AddPair('previous', Qry.FieldByName('previous_value').AsString);
        Obj.AddPair('reason', Qry.FieldByName('change_reason').AsString);
        Obj.AddPair('project', Qry.FieldByName('project').AsString);
        Obj.AddPair('updated', FormatDateTime('yyyy-mm-dd hh:nn',
          Qry.FieldByName('updated_at').AsDateTime));
        ParamsArr.AddElement(Obj);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // 5. MCP tools count (36 tools as of Build 66)
    Json.AddPair('mcp_tools_count', TJSONNumber.Create(36));

    // 6. Installed skills (scan claude-setup/skills/)
    var InstalledArr := TJSONArray.Create;
    Json.AddPair('installed_skills', InstalledArr);
    var SkillsDir := TPath.Combine(ExtractFilePath(ParamStr(0)), 'claude-setup\skills');
    if TDirectory.Exists(SkillsDir) then
    begin
      var Dirs := TDirectory.GetDirectories(SkillsDir);
      for var D in Dirs do
      begin
        var SkillFile := '';
        if TFile.Exists(TPath.Combine(D, 'SKILL.md')) then
          SkillFile := TPath.Combine(D, 'SKILL.md')
        else if TFile.Exists(TPath.Combine(D, 'skill.md')) then
          SkillFile := TPath.Combine(D, 'skill.md');
        if SkillFile = '' then Continue;

        var SkillObj := TJSONObject.Create;
        SkillObj.AddPair('name', TPath.GetFileName(D));

        // Parse YAML frontmatter for description and user-invocable
        var Lines := TFile.ReadAllLines(SkillFile, TEncoding.UTF8);
        var InFrontmatter := False;
        var Desc := '';
        var Invocable := False;
        for var L in Lines do
        begin
          var Trimmed := Trim(L);
          if Trimmed = '---' then
          begin
            if InFrontmatter then Break; // end of frontmatter
            InFrontmatter := True;
            Continue;
          end;
          if not InFrontmatter then Continue;
          if Trimmed.StartsWith('description:') then
            Desc := Trim(Copy(Trimmed, 13, MaxInt)).TrimLeft(['"']).TrimRight(['"'])
          else if Trimmed.StartsWith('user-invocable:') then
            Invocable := Trim(Copy(Trimmed, 16, MaxInt)) = 'true';
        end;

        if Desc.Length > 120 then
          Desc := Copy(Desc, 1, 120) + '...';
        SkillObj.AddPair('description', Desc);
        SkillObj.AddPair('user_invocable', TJSONBool.Create(Invocable));
        InstalledArr.AddElement(SkillObj);
      end;
    end;

    // 7. AI-Batch Status
    var BatchArr := TJSONArray.Create;
    var BatchObj := TJSONObject.Create;
    Json.AddPair('ai_batch', BatchObj);
    BatchObj.AddPair('jobs', BatchArr);
    var BatchTotalCalls := 0;
    var BatchTotalTokens: Int64 := 0;
    Qry := Ctx.CreateQuery(
      'SELECT job_type, ' +
      '  COUNT(*) AS total, ' +
      '  SUM(CASE WHEN status = ''success'' THEN 1 ELSE 0 END) AS success_count, ' +
      '  SUM(CASE WHEN status = ''error'' THEN 1 ELSE 0 END) AS error_count, ' +
      '  SUM(tokens_input) AS total_tokens_in, ' +
      '  SUM(tokens_output) AS total_tokens_out, ' +
      '  MAX(created_at) AS last_run ' +
      'FROM ai_batch_log ' +
      'GROUP BY job_type ' +
      'ORDER BY job_type');
    try
      Qry.Open;
      while not Qry.Eof do
      begin
        var JobObj := TJSONObject.Create;
        JobObj.AddPair('type', Qry.FieldByName('job_type').AsString);
        JobObj.AddPair('total', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
        JobObj.AddPair('success', TJSONNumber.Create(Qry.FieldByName('success_count').AsInteger));
        JobObj.AddPair('errors', TJSONNumber.Create(Qry.FieldByName('error_count').AsInteger));
        var TokIn := Qry.FieldByName('total_tokens_in').AsLargeInt;
        var TokOut := Qry.FieldByName('total_tokens_out').AsLargeInt;
        JobObj.AddPair('tokens_in', TJSONNumber.Create(TokIn));
        JobObj.AddPair('tokens_out', TJSONNumber.Create(TokOut));
        if not Qry.FieldByName('last_run').IsNull then
          JobObj.AddPair('last_run', FormatDateTime('yyyy-mm-dd hh:nn',
            Qry.FieldByName('last_run').AsDateTime));
        BatchArr.AddElement(JobObj);
        BatchTotalCalls := BatchTotalCalls + Qry.FieldByName('total').AsInteger;
        BatchTotalTokens := BatchTotalTokens + TokIn + TokOut;
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;
    BatchObj.AddPair('total_calls', TJSONNumber.Create(BatchTotalCalls));
    BatchObj.AddPair('total_tokens', TJSONNumber.Create(BatchTotalTokens));

    // 8. Feature Tracking (non-finding metrics)
    var FeatArr := TJSONArray.Create;
    Json.AddPair('features', FeatArr);

    // Auto-ADR: count decisions
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total, MAX(created_at) AS last_created ' +
      'FROM documents WHERE doc_type = ''decision'' AND status <> ''deleted''');
    try
      Qry.Open;
      var FAdr := TJSONObject.Create;
      FAdr.AddPair('name', 'Auto-ADR');
      FAdr.AddPair('icon', 'file-check');
      FAdr.AddPair('accent', '#7c3aed');
      FAdr.AddPair('metric', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
      FAdr.AddPair('metric_label', 'Decisions');
      if not Qry.FieldByName('last_created').IsNull then
        FAdr.AddPair('last_activity', FormatDateTime('yyyy-mm-dd hh:nn',
          Qry.FieldByName('last_created').AsDateTime));
      FeatArr.AddElement(FAdr);
    finally
      Qry.Free;
    end;

    // Institutional Memory: recall stats
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS total, ' +
      '  SUM(CASE WHEN outcome IN (''applied'',''candidate_success'',''edited_after_recall'') THEN 1 ELSE 0 END) AS positive, ' +
      '  ROUND(AVG(latency_ms)) AS avg_latency, ' +
      '  SUM(CASE WHEN gate_level = ''BLOCK'' THEN 1 ELSE 0 END) AS blocks, ' +
      '  MAX(created_at) AS last_recall ' +
      'FROM recall_log');
    try
      Qry.Open;
      var FRecall := TJSONObject.Create;
      FRecall.AddPair('name', 'Institutional Memory');
      FRecall.AddPair('icon', 'library');
      FRecall.AddPair('accent', '#0891b2');
      FRecall.AddPair('metric', TJSONNumber.Create(Qry.FieldByName('total').AsInteger));
      FRecall.AddPair('metric_label', 'Recalls');
      FRecall.AddPair('positive', TJSONNumber.Create(Qry.FieldByName('positive').AsInteger));
      FRecall.AddPair('avg_latency_ms', TJSONNumber.Create(Qry.FieldByName('avg_latency').AsInteger));
      FRecall.AddPair('blocks', TJSONNumber.Create(Qry.FieldByName('blocks').AsInteger));
      if not Qry.FieldByName('last_recall').IsNull then
        FRecall.AddPair('last_activity', FormatDateTime('yyyy-mm-dd hh:nn',
          Qry.FieldByName('last_recall').AsDateTime));
      FeatArr.AddElement(FRecall);
    finally
      Qry.Free;
    end;

    // Conflict Detection: sessions with files_touched
    Qry := Ctx.CreateQuery(
      'SELECT COUNT(*) AS tracked, ' +
      '  SUM(CASE WHEN JSON_LENGTH(files_touched) > 0 THEN 1 ELSE 0 END) AS with_files ' +
      'FROM sessions WHERE files_touched IS NOT NULL');
    try
      Qry.Open;
      var FConflict := TJSONObject.Create;
      FConflict.AddPair('name', 'Conflict Detection');
      FConflict.AddPair('icon', 'shield-alert');
      FConflict.AddPair('accent', '#d97706');
      FConflict.AddPair('metric', TJSONNumber.Create(Qry.FieldByName('with_files').AsInteger));
      FConflict.AddPair('metric_label', 'Sessions tracked');
      FeatArr.AddElement(FConflict);
    finally
      Qry.Free;
    end;

    MxSendJson(C, 200, Json);
    Json.Free;
  except
    on E: Exception do
    begin
      Json.Free;
      ALogger.Log(mlError, 'Skills dashboard error: ' + E.Message);
      MxSendError(C, 500, 'internal_error');
    end;
  end;
end;

// ---------------------------------------------------------------------------
// POST /skills/feedback — Submit finding feedback from Admin-UI
// ---------------------------------------------------------------------------
procedure HandlePostSkillFeedback(const C: THttpServerContext;
  APool: TMxConnectionPool; ALogger: IMxLogger);
var
  Ctx: IMxDbContext;
  Body, Data: TJSONObject;
  FindingUid, ReactionStr: string;
  Reaction: TMxFindingReaction;
begin
  Body := MxParseBody(C);
  if Body = nil then
  begin
    MxSendError(C, 400, 'invalid_json');
    Exit;
  end;

  try
    FindingUid := Body.GetValue<string>('finding_uid', '');
    ReactionStr := Body.GetValue<string>('reaction', '');

    if (FindingUid = '') or (ReactionStr = '') then
    begin
      MxSendError(C, 400, 'finding_uid and reaction required');
      Exit;
    end;

    if not SameText(ReactionStr, 'confirmed') and
       not SameText(ReactionStr, 'dismissed') and
       not SameText(ReactionStr, 'false_positive') then
    begin
      MxSendError(C, 400, 'Invalid reaction. Use: confirmed, dismissed, false_positive');
      Exit;
    end;

    Reaction := TMxSkillEvolutionData.StrToReaction(ReactionStr);

    Ctx := APool.AcquireContext;
    if not TMxSkillEvolutionData.UpdateReaction(Ctx, FindingUid, Reaction) then
    begin
      MxSendError(C, 404, 'finding_not_found');
      Exit;
    end;

    Data := TJSONObject.Create;
    try
      Data.AddPair('finding_uid', FindingUid);
      Data.AddPair('reaction', TMxSkillEvolutionData.ReactionToStr(Reaction));
      Data.AddPair('message', 'Feedback recorded');
      MxSendJson(C, 200, Data);
    finally
      Data.Free;
    end;
  finally
    Body.Free;
  end;
end;

end.
