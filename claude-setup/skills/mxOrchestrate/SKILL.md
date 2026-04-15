---
name: mxOrchestrate
description: Persistent session orchestrator for mxLore. This skill should be used when the user says "park", "resume", "what's my workflow status", "/mxOrchestrate start/track/park/resume/status/suggest", "start a new feature/bugfix workflow", "track this as ad-hoc", "spawn a team agent", or when a session begins and workflow state must be loaded. Always-on via SessionStart/UserPromptSubmit hooks. Manages workflow stack (LIFO), ad-hoc tasks, team agents, and skill chains.
allowed-tools: Read, Write, Edit, Grep, Glob, Skill, Agent
---

# /mxOrchestrate — Persistent Session Orchestrator (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS run as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Central session manager. Manages workflow stack, ad-hoc tasks, team agents.
Skills **auto-execute fully**. Only ask user for **optional steps**.
**Spec:** #1089 | **Plan:** #1090

## Trigger phrases

This skill fires on:
- `/mxOrchestrate start <type>`, `/mxOrchestrate track <note>`, `/mxOrchestrate park`, `/mxOrchestrate resume [id]`, `/mxOrchestrate status`, `/mxOrchestrate suggest`
- Natural language: "park this", "resume my workflow", "what's my workflow status", "start a new feature/bugfix", "track this as ad-hoc", "spawn a team agent for X"
- Automatic: SessionStart, UserPromptSubmit (every prompt, 3-line context), [DORMANT] PreCompact/PostCompact

## Architecture
```
SessionStart Hook → loads state, informs Claude (no questions!)
UserPromptSubmit Hook → injects 3-line context on every prompt
mxOrchestrate Skill → brain: routing, tracking, control
MCP = Source of Truth | .claude/orchestrate-state.json = Cache
```
Full hook documentation + dormant PreCompact/PostCompact note → `references/hooks.md`.

## Init (Pre-Routing, EVERY call)
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. Load state: `.claude/orchestrate-state.json`→parse. ∅file or corrupt→mode `init`
3. **Ensure session:**
   - **Staleness check (ADR-0016):** compute `age = now() - max(state.last_save, state.last_reconciliation)`. Both fields missing → treat as stale. Threshold: **12h**.
   - state.session_id present AND mode≠`init` AND age < 12h → mx_ping()→OK=MCP-mode | Error=Local
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

⚡ Token discipline — main-context cost per mode:

| Mode | MCP calls | State writes |
|------|-----------|--------------|
| init | 1 mx_session_start, 1 mx_ping (or skip if cached <12h) | 1 Write (full state) |
| start | 1 mx_create_doc | 1 Edit (append WF to stack) |
| track | 1 mx_create_doc | 1 Edit (append to adhoc_tasks) |
| park | 0 | 1 Edit (status flip + reorder) |
| resume | 1 mx_detail, conditional 1 mx_update_doc | 1 Edit (stack reorder + reconcile) |
| status | 2 mx_search (plans/specs + notes) | 0 |
| suggest | 0 | 0 |

**Edit vs Write:** use Edit for 1-5 field changes (surgical). Background subagent Write for full rewrites only. NEVER full-rewrite state.json from main context.

## State File (.claude/orchestrate-state.json)

Schema v2, stack rules, and internal operations → `references/state-schema.md`. Key invariant: `last_save_deltas` is owned by mxSave Step 4 (SSoT, Spec#2152). All state writes follow Edit-vs-Write discipline (see Tool Budget table above + Rules section).

## Mode 1: Init
1. ⚡ **Forces mx_session_start** in pre-routing (step 3, ignores cached session_id)
2. Load active workflows from mx_session_start response into workflow_stack
3. Write state file (session_id + workflows + events_log reset)
4. **Multi-Agent Auto-Listener:** If response contains `active_peers`→`/mxAgentListen` background agent
5. Output: `Orchestrator initialized. Session #<id>. <N> active workflows.`

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
1. Create ad-hoc object: `{note, created: now(), origin_workflow: stack[0].id, mcp_note_id: null}`
2. Push to adhoc_tasks[]
3. Persist to MCP: `mx_create_doc(project, doc_type='todo', title=note, content='Origin: <WF-ID>')`→set mcp_note_id. Error→null (local only)
4. Log event (type='track_adhoc')
5. **Escalation check** (Claude decides based on context):
   - **note** (default): Only noted. Workflow continues.
   - **park+start**: Park current WF→Mode 4(park) + Mode 2(start)
   - **spawn**: Start team agent→Mode spawn (see Team Agents)
6. Output: `Ad-hoc tracked: "<note>" (origin: <WF-ID>). Escalation: <note|park|spawn>.`

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
5. **⚡ Reconciliation (Session-Boundary Sync):** `mx_detail` + compare local vs MCP, push/pull whichever is ahead, handle archived/diverged, clamp, set `state.last_reconciliation = now()`. Full decision tree → `references/reconciliation.md`.
6. Identify next pending step from reconciled state
7. Output: `WF "<Name>" resumed. Progress: <X>/<Y>. Next step: <Description>.`
8. Auto-invoke next step

**Backward-compatible:** `--resume` without active stack→open-items list as before (Phase 1 context load)

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

## Mode 6: Status
Full overview:
- **Workflow Stack:** ID|Name|Step|Status for each entry
- **Ad-hoc Tasks:** Note|Origin|Created
- **Team Agents:** Task|Status|Origin
- **Events (last 10):** Timestamp|Type|Detail
- **Active MCP Docs:** `mx_search(project, doc_type='workflow_log,plan,spec', status='active')`→show only open
- **Recently archived:** `mx_search(project, doc_type='workflow_log,plan,spec', status='archived', limit=5)`→last 5 completed
- **Open items:** MCP-Notes(status='active') + status.md (deduplicated against MCP)

## Mode 7: Suggest
1. Active WF→next step
2. Parked WFs→suggest oldest
3. Ad-hoc tasks→prioritized: Bug→TODO→Feature→Next/Later
4. ∅stack→open-items list + chat heuristic: ADR→/mxPlan | Plan→Impl | Code→/mxDesignChecker | long session→/mxSave

## Team Agents (Ad-hoc Escalation: spawn)
1. Claude recognizes: ad-hoc task is independent + parallelizable
2. **TeamCreate** call with context:
   - Project slug + MCP access
   - Task description
   - Instruction: persist result as MCP note (tag: team-result)
3. Update team_agents[]: {id, task, origin_workflow, spawned, status:'running'}
4. Log event (type='spawn')
5. ⚡ **Isolation:** Team agent has NO access to orchestrate-state.json. MCP only.
6. **Return flow:** Team agent done→MCP note with tag 'team-result'→Proactive Notification
7. Hook shows team status in line 2

## Auto-Invoke (all workflow modes)
- Non-optional→auto-execute→step `done` + state update + log event
- Optional→?user, "skip"→`skipped`
- Conditional→check condition, ∅met→`skipped`
- Analysis skills→Agent-Tool: /mxDesignChecker, /mxBugChecker
- Independent steps→parallel via Agent-Tool
- **Skill mapping:** mx*/superpowers:*→**Skill-Tool** | mxDesignChecker/mxBugChecker→**Agent-Tool** | frontend-design→**Skill-Tool**(if installed, otherwise skip)
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
Hook injects signal on every prompt. Claude reacts based on context.

**Rule 1 — NO_WORKFLOW + substantive work:**
Hook reports `NO_WORKFLOW` + user prompt describes implementation/fix/feature/refactoring
→ Auto-create: ad-hoc WF (template `ad-hoc`, title `Ad-hoc: <50char summary>`)
→ No confirmation. For questions/smalltalk/inquiries/mxSave/mxOrchestrate: ignore

**Rule 2 — WF active + topic deviation:**
Hook shows active WF name + user prompt concerns different topic (semantic comparison)
→ Small deviation (1 response): automatically `track` as ad-hoc task
→ Large deviation (>1 step): suggest `park`

**Rule 3 — JUST_COMPLETED + continued work:**
Hook reports `JUST_COMPLETED` (WF completed <5min ago) + substantive prompt
→ Create new ad-hoc WF (like rule 1)

## Rules
- Auto-invoke skills via Skill/Agent-Tool. !manually by user
- Optional→?user. Non-optional→without confirmation
- ⚡ Max 5 stack entries. State-deltas>=8→recommend save
- ⚡ Team agents: MCP access only, never local state file
- UTF-8 without BOM. Prefer MCP, local=fallback
- Workflow templates: `docs/workflows.md`(project, priority) then `~/.claude/skills/mxOrchestrate/workflows.md`(global)
- ⚡ **Token Discipline (state-file):** orchestrate-state.json writes: Edit for incremental changes (1-5 fields), background subagent for full rewrites — keep token cost low in main context
