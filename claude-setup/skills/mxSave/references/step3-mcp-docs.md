<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
### 3) Update MCP Docs (MCP only)
**Clean orphaned workflows (ADR-0006):**
`mx_search(project, doc_type='workflow_log', query='active')`→collect IDs→`mx_batch_detail(doc_ids=[...])`→check each WF:
- WF title references feature marked done in CLAUDE.md/status.md→archive
- Collect all WFs to archive→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup by mxSave"}, ...]')` — one call instead of N
- ⚡ Only close clearly completed WFs. Doubt→leave open.

**Ad-hoc WF Auto-Cleanup:**
Check WFs whose title starts with "Ad-hoc:":
- WF has only step 1 AND title starts with "Ad-hoc:" AND WF content shows no done steps except step 1
  → Silently archive: `mx_update_doc(doc_id, status='archived', change_reason='auto-cleanup: empty ad-hoc WF')`
  → No output (no noise)
- WF has real work→archive normally like other WFs

**Stale-Suspect Detection (Pre-Save Stale-Plan-Sweep):**
- ⚡ Skip entire block if `!mcp_available`
- ⚡ Skip entire block in `--loop` mode (interactive prompt incompatible; loop-silence preserved)
- Threshold read: `r = mx_get_env(project, key='MXSAVE_STALE_THRESHOLD_DAYS')` → `T = int(r.value) if r.found else 14` (env tool returns `{found, value}` object, no `default=` param)
- `mx_search(project, doc_type='plan,spec', status='active', limit=50)` — `plan,spec` only (FS-anchor doc_type matrix per `~/.claude/skills/_shared/fs-anchor.md`); limit=50 aligns with the implementation plan, task T2.2 (catches deeper backlog)
- For each candidate: `mx_detail(doc_id, max_content_tokens=0)` →
  - **Age filter (post-detail):** use `days_since_content_change` from the detail response — the age of the last real body revision, NOT `days_since_update` (the updated_at staleness defect: `updated_at` is bumped by any touch incl. access_count-on-read, so it falsely rejuvenates stales). `days_since_content_change < T` → skip this candidate (NOT stale yet). Server-side field via `doc_revisions.MAX(changed_at)`; older servers without it → fall back to `days_since_update` + note the weaker signal.
  - Run FS-Anchor algorithm per `~/.claude/skills/_shared/fs-anchor.md`:
    - Extract `- [ ]` lines from `## Tasks` (Plan) or `## Acceptance Criteria` (Spec) as items
    - All items return `divergence` → stale-suspect (code shipped, doc not flipped)
    - Any item `confirmed_pending` → NOT stale (real work outstanding) → skip
    - All items `unverifiable` → skip (cannot determine, no false positive). !per-item output; when N>0 emit one aggregate line: `stale-sweep: N of M candidates unverifiable, skipped`
- Build candidate list: `[{doc_id, title, doc_type, divergence_count, evidence, days_since_update}]`
- ⚡ Subagent/Main split: when Step 3 runs as background subagent (Execution Mode phase A), the subagent performs DETECTION ONLY and returns the candidate list — subagents cannot prompt the user. Main re-checks each candidate against the FS-anchor skip rules (any `confirmed_pending` → reject as false positive) and prompts via AskUserQuestion, bundling up to 4 candidates per call (NOT N sequential prompts). Tag is set ONLY on `skip` to avoid orphan-tag if user aborts mid-prompt:
  - Show: `<type>#<id>: <title>` + `evidence: <path>` + `age: <D>d` + `(y=archive / n=ignore / skip=tag-for-next-session)`
  - `y` → `mx_update_doc(doc_id, status='archived', change_reason='Pre-save stale sweep: code shipped, doc not flipped')`
  - `n` → no-op (ignore for this session; no tag, no archive)
  - `skip` → `mx_add_tags(doc_id, ['stale-suspect'])` (idempotent — re-run silently if already tagged; persists for next-session review)
- Output: `Stale-Sweep: <Y> archived, <I> ignored, <S> tagged-for-review (of <C> candidates)`

**Archive completed Plans/Specs/Decisions:**
- Define `ARCHIVE_SWEEP_LIMIT = 50` once at the top of Step 3 (sync this constant if you change the limit anywhere). Raised from 20 on 2026-08-28: a live run hit 19 active plan/spec/decision docs, one short of truncation. The truncation warning below does fire at `==`, so this is a threshold correction, not a silent-gap fix — deliberately no pagination.
- `mx_search(project, doc_type='plan,spec,decision', status='active', limit=ARCHIVE_SWEEP_LIMIT)`→collect IDs→`mx_batch_detail(doc_ids=[...])`→check each doc:
- ⚡ If result count == ARCHIVE_SWEEP_LIMIT → warn: "Archive sweep truncated at <ARCHIVE_SWEEP_LIMIT> — re-run /mxSave or paginate manually if more active items exist." This is an auto-cleanup correctness guard, not a token-savings concern.
- **Plan:** All tasks `- [x]` (no `- [ ]`)→archive
- **Spec:** All ACs `- [x]` AND no open questions→archive
- **Decision:** Status `proposed` for >30 days without change→warning (don't auto-archive)
- Collect→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup: all tasks/ACs completed"}, ...]')`
- ⚡ Only for clearly completed docs. Mixed checkboxes→leave open.
- Output: `Archived: <N> Plans, <M> Specs. <K> stale Decisions (warning).`

**FR/BR Closure-Sweep (the FR/BR closure gap, content-reference-driven, Main-context):**
FR/BR are NOT FS-anchor-capable (no checkbox / impl-target — see `~/.claude/skills/_shared/fs-anchor.md` doc_type table), so the plan/spec Stale-Sweep above cannot touch them. Without a closure trigger, fixed FR/BR stay `status=active` forever and re-surface as open backlog (re-investigation token waste). Signal instead: **the session that fixed them already knows the ID** — no svn blame, no code-scan.
- ⚡ Skip entire block if `!mcp_available` OR `--loop` mode (interactive prompt).
- Collect `#IDs` this session explicitly discussed as **fixed / shipped / committed / closed / done** — sources: chat decisions of THIS session + the Step-2 status.md/CLAUDE.md edits (both available before Step 3). Do NOT infer from code; only IDs the session actually named.
- ∅collected IDs → skip silently (do not scan the whole backlog).
- `mx_batch_detail(doc_ids=[...])` (max 10/call, iterate) → keep only `doc_type ∈ {feature_request, bugreport, todo}` AND `status='active'` (already-archived → drop silently, no re-archive).
- Bundle up to 4 per `AskUserQuestion`: `<type>#<id>: <title>` + `evidence: <session-reference>` + options `archive` / `pending-verify` (built, only a test is open) / `keep`. NEVER auto-archive without confirm (an ID named in passing may not be truly closed).
  - `archive` → `mx_update_doc(doc_id, status='archived', change_reason='mxSave FR/BR closure-sweep: fixed/shipped this session')`
  - `pending-verify` → set BOTH marker parts per `~/.claude/skills/_shared/backlog-hygiene.md` (tag + dated line), status stays `active`.
  - `keep` → no-op (keep open this session).
- Output: `FR/BR-Closure: <Y> archived, <P> pending-verify (of <C> session-referenced candidates)`. Silent if ∅candidates.

**Backlog auto-close + stale count (every run, incl. `--loop`, no prompt):**
Read `~/.claude/skills/_shared/backlog-hygiene.md` and run its "Auto-close" block verbatim (this step is its single locus), then its stale count (reuse the auto-close tag search ids; one extra `mx_search` for the active list). Skip if `!mcp_available`. Output lines exactly as defined there, silent if 0.

**Extract lesson candidates (Auto-Learn, AnsatzC-compliant):**
Derive lesson candidates from chat history:
- Types: pitfall, decision_note, integration_fact, rule, solution
- Dedupe: `mx_search(project, doc_type='lesson', query='<title>', limit=3)`→hit→merge, else new
- Gate: confidence >= 0.6→`mx_create_doc(project, doc_type='lesson', ...)`, <0.6→tag `lesson-candidate`
- ∅Lessons→skip. Output: `Lessons: N created, M merged, K candidates`

**Lesson template:** `references/lesson-template.json` (schema + mandatory fields). ∅info→omit, never invent.

∅MCP→skip (mcp_available flag from Init)

**Report unresolved findings (⚡ NEVER batch-dismiss):**
`mx_skill_findings_list(project=<slug>, status='pending', limit=50)` → N = number of findings returned
- N == 0 → silent (the normal case: every finding got its verdict at fix time)
- N >= 1 → `Findings: <N> without verdict — a checker run ended without recording the user's call`
- if !mcp_available → skip

⚡ **Batch-dismiss is FORBIDDEN here.** `pending` is not a backlog to clear; it is the signal that a checker dropped a verdict on the floor. Dismissing it hides the defect and destroys the metric: `confirmed`/`false_positive` never accumulate, `precision` stays `0/0`, and the server renders that as `0.0` — indistinguishable from "always wrong". Fix the checker, not the queue.

⚡ Reaction vocabulary + who may write a verdict: `~/.claude/skills/_shared/skill-verdicts.md` (SSoT). mxSave writes NO verdicts — it only reports the anomaly.
