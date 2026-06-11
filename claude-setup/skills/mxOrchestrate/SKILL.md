---
name: mxOrchestrate
description: Persistent session orchestrator for mxLore. This skill should be used when the user says "park", "resume", "continue", "keep going", "where were we", "pick up where we left off" (non-English phrasing with the same meaning maps to these triggers), "what's my workflow status", "/mxOrchestrate start/track/park/resume/status/suggest", "start a new feature/bugfix workflow", "track this as ad-hoc", "spawn a team agent", or when a session begins and workflow state must be loaded. Always-on via SessionStart/UserPromptSubmit hooks. Manages workflow stack (LIFO), ad-hoc tasks, team agents, and skill chains.
user-invocable: true
allowed-tools: Read, Write, Edit, Grep, Glob, Skill
argument-hint: "start <type> | track <note> | park [reason] | resume [id] | status | suggest"
---

# /mxOrchestrate — Persistent Session Orchestrator (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS run as subagent(Agent-Tool, `model` per Model Tiering ⚡) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Central session manager. Manages workflow stack, ad-hoc tasks, team agents.
Skills **auto-execute fully**. Only ask user for **optional steps**.
**Spec:** #1089 | **Plan:** #1090

## Trigger phrases

This skill fires on:
- `/mxOrchestrate start <type>`, `/mxOrchestrate track <note>`, `/mxOrchestrate park`, `/mxOrchestrate resume [id]`, `/mxOrchestrate status`, `/mxOrchestrate suggest`
- Natural language: "park this", "resume my workflow", "what's my workflow status", "start a new feature/bugfix", "track this as ad-hoc", "spawn a team agent for X"
- Automatic: SessionStart, UserPromptSubmit (every prompt, 3-line context), [DORMANT] PreCompact/PostCompact (see `references/hooks.md` for reactivation path)

## Init (Pre-Routing, EVERY call)
1. CLAUDE.md parse: if file missing OR no `**Slug:**` line is present → ?user. If `**Slug:**` line is present → use that value as project slug.
2. Load state: `.claude/orchestrate-state.json`→parse. ∅file or corrupt→mode `init`
3. **Ensure session:**
   - **Staleness check (ADR-0016):** compute `age = now() - max(state.last_save, state.last_reconciliation)`. Both fields missing → treat as stale. Threshold: **12h**.
   - ⚡ **Explicit-trigger fail-OPEN:** input contains `<command-name>` OR `<command-message>` tag OR detection ambiguous → `mx_session_start` regardless of age (slash invocations need fresh briefing in fresh Claude process; live-confirmed tag injection at prompt position 0). Fresh briefing > stale ping.
   - hook-triggered (no command-tag) AND state.session_id present AND mode≠`init` AND age < 12h → mx_ping()→OK=MCP-mode | Error=Local
   - ∅session_id OR mode=`init` OR age ≥ 12h (STALE) → **Setup version:** `~/.claude/setup-version.json`→parse→`version`. ∅file→`''`
     → `mx_session_start(project, include_briefing=true, setup_version=<version>)`→session_id (overwrite cached)+Response into state, `state.last_reconciliation ← now()`
     → Error=Local(`docs/ops/workflow-log.md`+warning)
4. **Auto-Detect: Project Setup** (see below)
5. → Mode routing by argument

## Auto-Detect: Project Setup

Runs in pre-routing after session setup. 0 extra MCP calls — uses `mx_session_start` response + up to 2 Globs. Checks CLAUDE.md presence, MCP project registration, local migration candidates. Full decision tree → `references/auto-detect.md`. ⚡ Only suggests, never auto-executes.

## Modes
| Argument | Mode |
|----------|------|
| `init` | 1: Initialize state from MCP |
| `start <type>` (`new-feature`, `bugfix`, `decision`, `<custom>`) | 2: Start workflow (stack push) |
| `track <note>` | 3: Log ad-hoc task |
| `park [reason]` | 4: Park active WF (stack push-down) |
| `resume [id]` / `--resume` | 5: Resume WF (stack pop / ID select) |
| `status` | 6: Full overview |
| `suggest` | 7: Suggest next step |

## Tool Budget per Mode

⚡ Stay surgical: 0-2 MCP calls per mode, 1 Edit per state write, NEVER full-rewrite state from main ctx.

## Model Tiering ⚡ (Cost Discipline)

Main loop on premium model (Fable/Opus) → every subagent spawn (Agent-Tool, team agents, checker runs) sets the `model` param to the cheapest tier that satisfies the task. Match model to task floor, !ceiling:

| Tier | `model` | Task profile |
|------|---------|--------------|
| haiku | `haiku` | mechanical: state-file rewrites, file copy/sync, log tails, doc-body assembly from given content, simple greps |
| sonnet | `sonnet` | **DEFAULT** for subagents: mxOrchestrate runs, MCP CRUD flows, mxBugChecker/mxDesignChecker standard scope, Explore/codebase-search, standard implementation steps |
| inherit | omit param | top-tier reasoning genuinely required: architecture decisions, security-critical analysis, cross-cutting refactors, ambiguous specs |

- ⚡ Orchestration *intelligence* (skill routing, escalation judgment, interpreting results) lives in the MAIN loop (premium model) — the /mxOrchestrate subagent executes a fully specified procedure (state CRUD, fixed decision trees), so `sonnet` suffices. Ambiguity safety net: diverged state / code-vs-doc conflict → STOP + ?user regardless of model.
- Main model ∈ {fable, opus*} → subagent default = `sonnet`. Omitting `model` (inherit=premium) requires 1-line justification in the spawn rationale (written into the Agent-tool prompt or the caller's status text).
- Main model already sonnet/haiku → omit `model` (inherit, no tiering gain).
- !premium subagents for mechanical work — token+cost efficiency over convenience.

## State File (.claude/orchestrate-state.json)

Schema v2, stack rules, and internal operations → `references/state-schema.md`. Key invariant: `last_save_deltas` is owned by mxSave Step 4 (SSoT, Spec#2152). All state writes follow Edit-vs-Write discipline (see Tool Budget table above + Rules section).

## Mode 1: Init
Forces `mx_session_start` ignoring cached `session_id` (see Init pre-routing step 3); loads workflows from the response into `workflow_stack`; resets `events_log`. Multi-Agent Auto-Listener: response contains `active_peers` -> `/mxAgentListen` background agent.

## Mode 2: Start (Create workflow)
1. Search workflow template: `docs/workflows.md`(project) then `~/.claude/skills/mxOrchestrate/workflows.md`(global). ∅template→?user→ad-hoc
2. ID: `WF-YYYY-MM-DD-NNN`
3. `mx_create_doc(project, doc_type='workflow_log', title='WF-...: <Title>', content)`
4. Push WF object onto stack (becomes [0] = active). Previous [0]→parked (if present)
5. Save state + log event (type='start')
6. Output: `Workflow "<Name>" started (WF-xxx, doc_id=<id>). Stack: <N> WFs.`
7. Auto-invoke first step

**WF Markdown (MCP):**
```markdown
**Template:** <name> | **Started:** YYYY-MM-DD HH:MM | **Status:** active

| # | Step | Skill | Status | Result | Timestamp |
|---|------|-------|--------|--------|-----------|
| 1 | <Description> | <Skill> | pending | | |
```

## Mode 3: Track (Ad-hoc Task)
1. Push `{note, created, origin_workflow: stack[0].id, mcp_note_id}` to `adhoc_tasks[]` + `mx_create_doc(doc_type='todo', title=note, content='Origin: <WF-ID>')`. Log event (`type='track_adhoc'`).
2. Escalation (Claude decides): **note** (default) | **park+start** (Mode 4 + Mode 2) | **spawn** (see `references/team-agents.md`).
3. Full step list -> `references/adhoc.md`.

## Mode 4: Park
1. Stack[0].status = 'parked', Stack[0].parked_reason = reason
2. ⚡ Check stack depth: >3 parked→warning + suggest completing oldest
3. Log event (type='park')
4. Save state
5. Output: `WF "<Name>" parked. Reason: <reason>. Stack: <N> WFs.`
6. ∅new WF started→invoke suggest mode

## Mode 5: Resume
1. **Without ID:** Stack LIFO — bring top parked WF (stack[1]) to [0]
2. **With ID:** Find WF by ID in stack→move to [0], shift rest down
3. WF.status = 'active'
4. Log event (type='resume')
5. **⚡ Reconciliation (Session-Boundary Sync):** `mx_detail` + compare local vs MCP, push/pull whichever is ahead, handle archived; **diverged → STOP + ask user which version to keep (NEVER silently overwrite)**; clamp; then the **⚡ FS-Anchor Post-Check (Bug#6813)** — verify any `pending` step against the real filesystem (structured target paths → Glob, Grep only on a named symbol); code contradicts doc → STOP + ?user; ∅ structured paths → mark result `unverified against code`. Set `state.last_reconciliation = now()`. Full decision tree + FS-anchor algorithm → `references/reconciliation.md`.
6. **⚡ Context-Note Enrichment (Bug#3230 + FR#3566) — MANDATORY, NEVER SKIP, BOTH PATHS:**
   - Stack-pop path (stack >= 1): `mx_search(project, doc_type='session_note', query='<WF-ID> OR <primary_artifact_IDs> OR <outcome-keywords>', limit=4)` — ALWAYS runs, recency-ordered (`updated_at DESC`). Hit -> `mx_detail(note_id, max_content_tokens=1500)`. 0-hit is valid, NOT a reason to skip. Outcome-keywords + limit rationale (Bug#6813) → `references/resume-enrichment.md`.
   - Empty-stack path (stack = []): unconditional `mx_detail(state.last_save_session_note_doc_id)` if set + `mx_search(doc_type='session_note', limit=4)` fallback. Both paths run Step 6.
   - ⚡ independent enrichment calls (mx_search + mx_detail on last_save_session_note_doc_id / primary_artifact) → parallel in one message !sequential
   - **Event-log marker (mandatory both paths):** resume event MUST include `context-note=<note_id>` or `context-note=none` in `detail`. Missing = rule violation. `wf=null` for empty-stack path, `wf=<WF-ID>` for stack-pop.
   - **unbacked-decision tag detect:** after primary_artifact `mx_detail`, inspect tags for `unbacked-decision`; if present, regex-scan body via shared regex (Read `~/.claude/skills/_shared/decision-marker.md`). Store `{tag_present, marker_count, spec_id}` for Step 8 rendering.
   - Full prose / rationale / unbacked-decision render-rules -> `references/resume-enrichment.md`.
7. Identify next pending step from reconciled state
8. Output assembly:
   - Line 1: `WF "<Name>" resumed. Progress: <X>/<Y>. Next step: <Description>.`
   - unbacked-decision warning (rendered between Line 1 and bullet-summary when `tag_present AND marker_count > 0`; full render-rules incl. stale-tag guard -> `references/resume-enrichment.md`).
   - 2-3 bullet summary of any session-note enrichment from step 6.
   - see Rules: state_deltas band
9. Auto-invoke next step

**Empty-Stack Resume invariant (Bug#3230 + FR#3566):** `--resume` without active stack still loads the open-items list, AND Step 6 + `events_log` resume-event are STACK-INDEPENDENT and STILL RUN (unconditional `mx_detail` on `last_save_session_note_doc_id` + `mx_search` fallback + `wf=null` resume-event with `context-note=<id|none>`). Full detail -> `references/resume-enrichment.md`.

### Load context (on --resume without stack)
**MCP:** (Session+Briefing already available from pre-routing)
1. Open items: `mx_search(project, doc_type='note,bugreport,feature_request', status='active')`
   - Filter: Tags `todo,bug,feature-request,optimization,next,later` or without session_note/e2e/test
   - ⚡ NO _global search (_global only for env variables, not for open items)
   - ⚡ `status='active'` — DO NOT show archived/completed docs
3. Open plans/specs: `mx_search(project, doc_type='plan,spec', status='active', limit=10)`
   - Show only title+doc_id, not full content
4. status.md: "Known open items"→all bullets. "Next steps"→only `- [ ]`
   - ⚡ Deduplicate against MCP: item in status.md already archived in MCP→remove from display
5. Result: **Open-items list** (deduplicated, Bug→TODO→Feature→Opt→Other, max 30)
6. ⚡ FR-aging marker: items older 7d (per `updated_at`) get suffix `(>7d — re-audit claims before build)` — stale FRs frequently describe already-shipped work

## Mode 6: Status
Full overview:
- **Workflow Stack:** ID|Name|Step|Status for each entry
- **Ad-hoc Tasks:** Note|Origin|Created
- **Team Agents:** Task|Status|Origin
- **Events (last 10):** Timestamp|Type|Detail
- **Active MCP Docs:** `mx_search(project, doc_type='workflow_log,plan,spec', status='active')`→show only open
- **Recently archived:** `mx_search(project, doc_type='workflow_log,plan,spec', status='archived', limit=5)`→last 5 completed
- **Open items:** MCP-Notes(status='active') + status.md (deduplicated against MCP)
- **Save signal:** see Rules: state_deltas band

## Mode 7: Suggest
1. Active WF→next step
2. Parked WFs→suggest oldest
3. Ad-hoc tasks→prioritized: Bug→TODO→Feature→Next/Later
4. ∅stack→open-items list + chat heuristic: ADR→/mxPlan | Plan→Impl | Code→/mxDesignChecker | long session→/mxSave

## Team Agents (Ad-hoc Escalation: spawn)

`TeamCreate` is deferred (load via `ToolSearch select:TeamCreate` before first spawn). Isolation: team agents have MCP-only access, never `orchestrate-state.json`. Full spawn flow + return-flow -> `references/team-agents.md`.

## Auto-Invoke (all workflow modes)
- Non-optional auto-execute -> step `done` + state update + log event. Optional -> ?user (`skip` -> `skipped`). Conditional -> check, no match -> `skipped`.
- Analysis skills (mxDesignChecker, mxBugChecker) -> Agent-Tool (`model` per Model Tiering ⚡). Other mx*/superpowers:*/frontend-design -> Skill-Tool. Independent steps -> parallel via Agent-Tool.
- ⚡ **MCP-First Step-Update (Spec#1161):**
  1. `mx_update_doc(doc_id, content with Step=done+Timestamp+Result, change_reason='Step N→done')` → MCP first
  2. Derive state file from MCP response: current_step++, push event to events_log (synced=true)
  3. state_deltas++
  4. **MCP error→** Write state file directly + set `unsynced=true` on WF + event (synced=false)
  5. ⚡ **NEVER** mark state file as done without MCP update or unsynced flag

## Workflow Completion
All steps done/skipped:
1. Update content: `**Status:** completed` + `**Completed:** YYYY-MM-DD HH:MM`
2. ⚡ `mx_update_doc(doc_id, content, status='archived', change_reason='Workflow completed')` — content AND status synchronously in ONE call
3. Remove WF from stack + log event (synced=true)
4. **Ad-hoc back-link:** Show all adhoc_tasks with origin_workflow==WF-ID:
   `N ad-hoc tasks created during <WF-ID>: [list]. Start new workflow?`
5. Log event (type='completed')
6. Activate next stack WF if present
7. Output: Artifacts list + ad-hoc back-link + recommend `/mxSave`

## Auto-Tracking (Spec#1615)
- **Rule 1 (NO_WORKFLOW + substantive work):** auto-create ad-hoc WF (template `ad-hoc`, title `Ad-hoc: <50char>`). Ignore for questions/smalltalk/mxSave/mxOrchestrate.
- **Rule 2 (WF active + topic deviation):** small deviation -> auto `track` as ad-hoc task; large deviation (>1 step) -> suggest `park`.
- **Rule 3 (JUST_COMPLETED + continued work, <5min):** create new ad-hoc WF.
- ⚡ **Precedence:** Rule 3 wins over Rule 1 (continuation under new ad-hoc WF, not double-tracked). Rule 2 is mutually exclusive with Rules 1+3 (only fires when a WF is already active).

## Rules
- Auto-invoke skills via Skill/Agent-Tool. !manually by user
- Optional→?user. Non-optional→without confirmation
- ⚡ Max 5 stack entries. State-deltas>=8→recommend save
- ⚡ Team agents: MCP access only, never local state file
- UTF-8 without BOM. Prefer MCP, local=fallback
- Workflow templates: `docs/workflows.md`(project, priority) then `~/.claude/skills/mxOrchestrate/workflows.md`(global)
- ⚡ **Token Discipline (state-file):** orchestrate-state.json writes: Edit for incremental changes (1-5 fields), background subagent for full rewrites — keep token cost low in main context
- ⚡ **Output discipline (Bug#2989):** structured timestamps only (`YYYY-MM-DD HH:MM` or `<N>h ago` from `now() - event.ts`); `events_log[*].detail` = factual fragment (doc_ids/WF-IDs/short summaries), no relative natural language (`gestern`/`heute`/`vorhin`/`yesterday`/`today`/`earlier`/`just now`); numeric claims (`N open`, `X/Y done`) MUST come from a structured tool call (`mx_detail` / `mx_search` data array length), never prose-snippet inference — prefix `estimated, unverified` if budget forbids verification. Per-finding rationale -> `references/bug2989-findings.md`.
- ⚡ **events_log dedupe-guard:** before appending an event, compare with the current LAST entry — identical (type+wf+detail) → skip the append (consecutive-duplicate guard)
- ⚡ **Decision-Marker shared regex:** Read `~/.claude/skills/_shared/decision-marker.md` for the canonical regex + fence-exclusion algorithm.
- ⚡ **`state_deltas` band (canonical, Bug#2989 Finding 3 + Spec#2152 SSoT):** every Mode 5 (Resume), Mode 6 (Status), and Auto-Invoke step-done output MUST emit a deltas-band line based on `state.state_deltas` (live counter since the last `/mxSave` reset — NOT `state.last_save_deltas`, which is a pre-reset snapshot owned by mxSave Step 4 per Spec#2152 and MUST NOT be written from here). Bands: `== 0` silent; `>= 1 AND < 10` marketing `mxLore knows - /mxSave keeps context alive across /compact + /clear`; `>= 10 AND < 15` tip `<N> deltas since save - consider /mxSave soon`; `>= 15` compact-question `<N> deltas since save - /mxSave + /compact cycle recommended`. mxOrchestrate reads `state_deltas` + `last_save_deltas` (informational); NEVER writes either — mxSave is the sole writer per Spec#2152.
