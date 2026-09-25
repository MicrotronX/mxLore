---
name: mxOrchestrate
description: Persistent session orchestrator for mxLore. This skill should be used when the user says "park", "resume", "continue", "keep going", "where were we", "pick up where we left off" (non-English phrasing with the same meaning maps to these triggers), "what's my workflow status", "/mxOrchestrate start/track/park/resume/status/suggest", "start a new feature/bugfix workflow", "track this as ad-hoc", "spawn a team agent", or when a session begins and workflow state must be loaded. Always-on via SessionStart/UserPromptSubmit hooks. Manages workflow stack (LIFO), ad-hoc tasks, team agents, and skill chains.
user-invocable: true
allowed-tools: Read, Write, Edit, Grep, Glob, Skill
argument-hint: "start <type> | track <note> | park [reason] | resume [id] | status | suggest"
---

# /mxOrchestrate — Persistent Session Orchestrator (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

Central session manager: workflow stack (LIFO), ad-hoc tasks, team agents. Skills **auto-execute fully**; ?user only for **optional steps**. Fires on `/mxOrchestrate <mode>`, natural phrasing ("park this", "resume my workflow", "what's my workflow status", "start a new feature/bugfix", "track this as ad-hoc", "spawn a team agent for X") and hooks (SessionStart, UserPromptSubmit; PreCompact/PostCompact DORMANT → `references/hooks.md`).

## Weight routing ⚡ (decide BEFORE doing anything)
- **MINI = Main-inline, NO spawn:** `start`, `track`, `park`, `resume` **with empty stack**, Auto-Invoke step-updates, Workflow Completion (1-3 MCP calls + 1 state edit). A spawn re-reads SKILL.md + references + full state (~70-142k tokens measured live 2026-07-10/14) for 2-3 calls.
- **HEAVY = subagent** (`model: sonnet`): `init`, `resume` **with non-empty stack** (real reconciliation), `status`, `suggest`. Result max 20 lines.
- ⚡ **Init Pre-Routing always runs in Main, NEVER inside a HEAVY subagent** (subagent dropped the flag-clear and reported success, live 2026-07-14). Main does Init, THEN dispatches enrichment/reconciliation, passing `session_id` + cleared state.
- ⚡ Tokens: mx_create_doc/mx_update_doc body >300 words → assemble in subagent, !echo to parent. mx_detail default 600 tokens.
- ⚡ Tool budget: 0-2 MCP calls per mode, 1 Edit per state write, NEVER full-rewrite state from Main (full rewrite → background subagent).
- ⚡ **Timestamps = true UTC** via `date -u +%Y-%m-%dT%H:%MZ` everywhere (event `ts`, WF content, `last_reconciliation`, `since`) — NEVER the chat clock (local-time-with-Z observed live 2026-07-10). Base → `references/state-schema.md` → Timestamp base.

## Init (Pre-Routing, EVERY call)
0. ⚡ MCP tools deferred? → load per `~/.claude/skills/_shared/mcp-tools-load.md` (tool-missing ≠ server-down; `Local` only after a real ping/session_start error).
1. CLAUDE.md: ∅file OR ∅`**Slug:**` → ?user; else slug = that value.
2. State `.claude/orchestrate-state.json` → parse. ∅/corrupt → mode `init`.
3. **Ensure session** (first match wins; rationale + history → `references/init-session.md`):
   - ⚡ `context_cleared_at` present (hook sets it on startup/clear/compact = context is EMPTY) → `mx_session_start` unconditionally.
   - ⚡ Input has `<command-name>`/`<command-message>` tag OR detection ambiguous → `mx_session_start` (fail-OPEN).
   - ∅session_id OR mode=`init` OR age ≥ 12h (`age = now_utc - max(last_save, last_reconciliation)`, all UTC; both missing = stale; FALLBACK only when `context_cleared_at` absent — it measures state age, never context) → `mx_session_start`.
   - else (hook-triggered, fresh) → `mx_ping()` → OK=MCP | Error=Local.
   - `mx_session_start(project, include_briefing=true, setup_version=<~/.claude/setup-version.json .version, ∅→''>)` → overwrite session_id + response into state, `last_reconciliation ← now_utc`, delete `context_cleared_at` + `context_cleared_source` in the SAME write. Error → Local (`docs/ops/workflow-log.md` + warning).
   - ⚡ **Verify-after-write:** re-read the file, flag must be gone; still present → re-Edit + re-verify. A subagent's "cleared" is NOT proof.
   - ⚡ **Handoff path:** SessionStart printed `Resume handoff loaded` → that text IS the briefing; no skill call just to brief. Flag stays set on purpose until the first real call (`start`/`track`/`park`/explicit `resume`), which clears it here. Explicit user `resume` still runs Mode 5 in full.
   - ⚡ Hooks NEVER stamp `last_reconciliation` (means "reconciled against MCP"; JS hooks cannot reach MCP).
3a. Agent messages arrive via mxMCPProxy session-inbox (proxy >= 1.0.9); nothing to arm.
4. Auto-Detect Project Setup (checks CLAUDE.md presence, MCP project registration, local migration candidates): 0 extra MCP calls (session_start response + ≤2 Globs); only suggests, never executes → `references/auto-detect.md`.
5. → Mode routing.

## Modes
| Argument | Mode |
|----------|------|
| `init` | 1: Force `mx_session_start` (ignore cached id), load workflows into `workflow_stack`, reset `events_log` |
| `start <type>` (`new-feature`, `bugfix`, `decision`, `<custom>`) | 2: Start workflow (push) |
| `track <note>` | 3: Log ad-hoc task |
| `park [reason]` | 4: Park active WF |
| `resume [id]` / `--resume` | 5: Resume WF (pop / ID select) |
| `status` | 6: Full overview |
| `suggest` | 7: Suggest next step |

State schema v2, stack rules, internal ops → `references/state-schema.md`. `state_deltas`, `last_save_deltas`, `subagent_ran_since_save` are reset/snapshotted ONLY by mxSave (single-writer rule, SSoT). This skill only increments `state_deltas` (step-done) and NEVER writes `last_save_deltas` or clears `subagent_ran_since_save`.

## Model Tiering ⚡ (Cost Discipline)
Main on premium (Fable/Opus) → every spawn sets `model` to the cheapest sufficient tier: `haiku` = mechanical (state rewrites, copy/sync, log tails, body assembly, simple greps) | `sonnet` = **DEFAULT** (HEAVY modes, MCP CRUD, checkers standard scope, Explore, standard impl) | inherit = architecture/security/cross-cutting/ambiguous, needs 1-line justification in the spawn. Main already sonnet/haiku → omit `model`. Routing/escalation/interpretation stays in Main; diverged state or code-vs-doc conflict → STOP + ?user regardless of model.
⚡ **Loop rule:** >5 same-shaped MCP calls (`mx_ai_batch_log`, `mx_add_tags`, `mx_skill_feedback` rounds, tag sweeps, findings triage, AI-batch) NEVER in Main — ONE sonnet/haiku subagent with the full item list, Main gets ≤20-line tally. Full text + measurements → `references/model-tiering.md`.

## Mode 2: Start
1. Template: `docs/workflows.md` (project, priority) → `~/.claude/skills/mxOrchestrate/workflows.md`. ∅ → ?user → ad-hoc.
2. ID `WF-YYYY-MM-DD-NNN`. 3. `mx_create_doc(project, doc_type='workflow_log', title='WF-...: <Title>', content)`.
4. Push onto stack ([0]=active, previous [0] → parked). ⚡ **Canonical keys:** `id`, `name`, `doc_id`, `doc_revision`, `status`, `current_step`, `total_steps`, `started`, `unsynced` — **NOT `wf_id`/`title`** (hook drops WFs missing `id`).
5. Save state + event `start`. 6. Output `Workflow "<Name>" started (WF-xxx, doc_id=<id>). Stack: <N> WFs.` 7. Auto-invoke step 1.

```markdown
**Template:** <name> | **Started:** YYYY-MM-DD HH:MM | **Status:** active

| # | Step | Skill | Status | Result | Timestamp |
|---|------|-------|--------|--------|-----------|
| 1 | <Description> | <Skill> | pending | | |
```

## Mode 3: Track
Push `{note, created, origin_workflow: stack[0].id, mcp_note_id}` to `adhoc_tasks[]` + `mx_create_doc(doc_type='todo', title=note, content='Origin: <WF-ID>')` + event `track_adhoc`. Escalation (Claude decides): **note** (default) | **park+start** | **spawn** (`references/team-agents.md`). Steps → `references/adhoc.md`.

## Mode 4: Park
stack[0].status='parked' + `parked_reason`; ⚡ >3 parked → warning + suggest completing oldest; event `park`; save; output `WF "<Name>" parked. Reason: <reason>. Stack: <N> WFs.`; ∅new WF started → Mode 7.

## Mode 5: Resume
Empty stack → MINI (steps 5 = no-op); stack-pop / ID → HEAVY subagent. Init already ran in Main.
1. ∅ID → stack[1] to [0] (LIFO); ID → move that WF to [0]. 2. status='active'. 3. Event `resume`.
4. ⚡ **Reconciliation** (stack only): `mx_detail` vs local, push/pull whichever is ahead, handle archived; **diverged → STOP + ?user, NEVER silently overwrite**; clamp; **FS-Anchor post-check** on every `pending` step (structured paths → Glob; Grep only on a named symbol); code contradicts doc → STOP + ?user; ∅paths → `unverified against code`. `last_reconciliation ← now_utc`. → `references/reconciliation.md`.
5. ⚡ **Context-Note Enrichment — MANDATORY, NEVER SKIP, BOTH PATHS** (calls parallel in one message):
   - stack: `mx_search(project, doc_type='session_note', query='<WF-ID> OR <primary_artifact_IDs> OR <outcome-keywords>', limit=4)` always; hit → `mx_detail(id, max_content_tokens=1500)`; 0 hits valid.
   - empty stack: `mx_detail(state.last_save_session_note_doc_id)` if set + `mx_search(doc_type='session_note', limit=4)` fallback.
   - Resume event `detail` MUST contain `context-note=<id>` or `context-note=none`; `wf=<WF-ID>` or `wf=null`.
   - primary_artifact tagged `unbacked-decision` → scan body with `~/.claude/skills/_shared/decision-marker.md`, keep `{tag_present, marker_count, spec_id}`. Render rules + keyword/limit rationale → `references/resume-enrichment.md`.
6. Next pending step from reconciled state.
7. Output: `WF "<Name>" resumed. Progress: <X>/<Y>. Next step: <Description>.` → unbacked-decision warning (if `tag_present AND marker_count > 0`) → 2-3 enrichment bullets → save-signal line (Rules). 8. Auto-invoke next step.

**Open items (resume without stack):**
1. `mx_search(project, doc_type='bugreport,feature_request,todo', status='active', include_content=false, limit=30)` ∥ `mx_search(project, doc_type='note', tag='todo', status='active', include_content=false, limit=10)`. ⚡ NO `note` in the first call (machine notes stay active forever, filled 19/30 rows live 2026-09-17). ⚡ NO `_global`. ⚡ `status='active'` only.
2. `mx_search(project, doc_type='plan,spec', status='active', limit=10)` → title+doc_id only.
3. status.md "Known open items" all bullets + "Next steps" only `- [ ]`; ⚡ drop items already archived in MCP.
4. List: dedup, Bug→TODO→Feature→Opt→Other, max 30. Items tagged `fixed-pending-verify` (1 extra `mx_search(tag=…)` in step 1's parallel batch) → own section `verify/close` ABOVE the list (auto-close rules: `~/.claude/skills/_shared/backlog-hygiene.md`). ⚡ Aging marker BEFORE truncation: `days_since_content_change` > 7 → suffix `(>7d — re-audit claims before build)` (NOT `updated_at`; field missing → no marker).

## Mode 6: Status
Workflow stack (ID|Name|Step|Status), ad-hoc tasks (Note|Origin|Created), team agents (Task|Status|Origin), last 10 events, active MCP docs `mx_search(project, doc_type='workflow_log,plan,spec', status='active')`, recently archived (same, `status='archived', limit=5`), open items (MCP active notes + status.md, dedup), save-signal line.

## Mode 7: Suggest
Active WF → next step; parked → oldest; ad-hoc by Bug→TODO→Feature→Next/Later; ∅stack → open items + heuristic ADR→/mxPlan | Plan→impl | Code→/mxDesignChecker | long session→/mxSave.

## Team Agents
`TeamCreate` deferred (`ToolSearch select:TeamCreate`). ⚡ MCP-only access, NEVER `orchestrate-state.json`. → `references/team-agents.md`.

## Auto-Invoke
- Non-optional → auto-execute, step `done` + state + event. Optional → ?user (`skip` → `skipped`). Conditional → no match → `skipped`.
- mxDesignChecker/mxBugChecker → Agent-Tool (tiered). Other mx*/superpowers:*/frontend-design → Skill-Tool. Independent steps → parallel.
- ⚡ **Spawn result-returning agents WITHOUT `name`** — a named agent's answer never arrives as the result (only `idle_notification`, looks like a pass). Lost answer → grep its transcript, do NOT re-run. → `references/agent-spawn.md`.
- ⚡ **MCP-First Step-Update:** 1. `mx_update_doc(doc_id, content with Step=done+Timestamp+Result, change_reason='Step N→done')` FIRST. 2. derive state from response: `current_step++`, event (synced=true). 3. `state_deltas++`. 4. MCP error → write state + `unsynced=true` on WF + event (synced=false). ⚡ NEVER mark done locally without MCP update or unsynced flag.

## Workflow Completion (MINI)
All steps done/skipped: 1. content `**Status:** completed` + `**Completed:** YYYY-MM-DD HH:MM` (UTC). 2. ⚡ `mx_update_doc(doc_id, content, status='archived', change_reason='Workflow completed')` — content AND status in ONE call. 3. Remove from stack + event. 4. Back-link: `N ad-hoc tasks created during <WF-ID>: [list]. Start new workflow?` (origin_workflow==WF-ID). 5. Event `completed`. 6. Activate next stack WF. 7. Output artifacts + back-link + recommend `/mxSave`.

## Auto-Tracking
1. NO_WORKFLOW + substantive work → auto ad-hoc WF (template `ad-hoc`, title `Ad-hoc: <50char>`); ignore questions/smalltalk/mxSave/mxOrchestrate. 2. WF active + small deviation → `track`; >1 step → suggest `park`. 3. JUST_COMPLETED + continued work <5min → new ad-hoc WF. ⚡ Rule 3 beats Rule 1; Rule 2 only when a WF is active.

## Rules
- Auto-invoke via Skill/Agent-Tool, !manually by user. Optional → ?user, non-optional → no confirmation.
- ⚡ Max 5 stack entries. UTF-8 without BOM. Prefer MCP, local = fallback.
- ⚡ **Output discipline:** timestamps `YYYY-MM-DD HH:MM` or `<N>h ago` (UTC; pre-UTC-rule events are local-with-Z → print raw `ts` when age matters); `events_log[*].detail` = factual fragment **max ~50 words** (narrative → session note); !relative words (gestern/heute/vorhin/yesterday/today/earlier/just now); numeric claims only from structured tool data, else prefix `estimated, unverified`. → `references/output-discipline-findings.md`.
- ⚡ **events_log dedupe-guard:** identical (type+wf+detail) to the LAST entry → skip append.
- ⚡ **Save-signal line** (Mode 5, Mode 6, every Auto-Invoke step-done) from `state.state_deltas` (NOT `last_save_deltas`): `0` silent | `1-9` `mxLore knows - /mxSave keeps context alive across /compact + /clear` | `10-14` `<N> deltas since save - consider /mxSave soon` | `>=15` `<N> deltas since save - /mxSave + /compact cycle recommended`.
- ⚡ **Tracker-gap guard** (never a false "all saved"): `subagent_ran_since_save == true` counts as deltas >= 1 (Mode 5 + 6; mention `subagent ran since save`). Mode 5 with deltas 0 + MCP → `mx_session_delta(project, since=state.last_save, limit=50)` (limit 50, NOT 1 — N is a magnitude); `total_changes > 0` → `<N> MCP writes since last save (tracker gap - subagent writes bypass the counter) - /mxSave recommended`. `since` must be true UTC; `last_save` in the future OR non-empty `warnings` → `last_save is not UTC (state file corrupt) - tracker-gap guard cannot verify; /mxSave recommended`. Prefer `server_now_utc` as now. Full text → `references/save-signal.md`.
