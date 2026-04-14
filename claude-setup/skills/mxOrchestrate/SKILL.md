---
name: mxOrchestrate
description: "Persistent Session Orchestrator. Always-on via Hooks. Manages workflows (stack), ad-hoc tasks, team agents, and skill chains. Central coordinator for all session activities via MCP."
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Skill, Agent
argument-hint: "init | start <type> | track <note> | park [reason] | resume [id] | status | suggest | --resume"
---

# /mxOrchestrate — Persistent Session Orchestrator (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS run as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Central session manager. Manages workflow stack, ad-hoc tasks, team agents.
Skills **auto-execute fully**. Only ask user for **optional steps**.
**Spec:** #1089 | **Plan:** #1090

## Architecture
```
SessionStart Hook → loads state, informs Claude (no questions!)
UserPromptSubmit Hook → injects 3-line context on every prompt
mxOrchestrate Skill → brain: routing, tracking, control
MCP = Source of Truth | .claude/orchestrate-state.json = Cache
```

## Init (Pre-Routing, EVERY call)
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. Load state: `.claude/orchestrate-state.json`→parse. ∅file or corrupt→mode `init`
3. **Ensure session:**
   - state.session_id present AND mode≠`init` → mx_ping()→OK=MCP-mode | Error=Local
   - ∅session_id OR mode=`init` → **Setup version:** `~/.claude/setup-version.json`→parse→`version`. ∅file→`''`
     → `mx_session_start(project, include_briefing=true, setup_version=<version>)`→session_id+Response into state
     → Error=Local(`docs/ops/workflow-log.md`+warning)
4. **Auto-Detect: Project Setup** (see below)
5. → Mode routing by argument

## Auto-Detect: Project Setup
Runs in pre-routing after session setup. ⚡ 0 extra MCP calls — uses mx_session_start response + max 2x Glob.

1. **CLAUDE.md check** (always, 1x Glob):
   - Glob: `CLAUDE.md` in project root → ∅match = setup missing
   - → User: "Project has no AI config. Run `/mxInitProject`? (1=yes/2=no)"
   - ⚡ Only suggest, never auto-execute
2. **MCP project check** (MCP-mode only, only if mx_session_start ran):
   - mx_session_start response contains "project not found" → project not registered
   - If CLAUDE.md present: → User: "Project not in MCP. `/mxInitProject` registers it. (1=yes/2=no)"
   - If CLAUDE.md missing: integrate into suggestion from step 1
3. **Local migration candidates** (MCP-mode only + project exists, 1x Glob):
   - Glob: `docs/*.md` (NOT recursive)
   - Allow-list: `status.md`, `workflows.md`
   - Matches outside allow-list → User: "N local docs found (list). Run `/mxMigrateToDb`? (1=yes/2=no)"
   - ⚡ Only suggest, never auto-execute
4. **All checks OK → no message** (no noise for correctly configured projects)

## Modes
| Argument | Mode |
|----------|------|
| `init` | 1: Initialize state from MCP |
| `start <type>` (`new-feature`, `bugfix`, `decision`, `<custom>`) | 2: Start workflow (stack push) |
| `track <note>` | 3: Log ad-hoc task |
| `park [reason]` | 4: Park active WF (stack push-down) |
| `resume [id]` | 5: Resume WF (stack pop / ID select) |
| `--resume` | 5: Alias for resume (backward-compatible) |
| `status` | 6: Full overview |
| `suggest` | 7: Suggest next step |

## State File (.claude/orchestrate-state.json)

**Schema v2 (Spec#1161):**
```json
{
  "schema_version": 2,
  "session_id": "<int|null>",
  "workflow_stack": [{"id","name","doc_id","doc_revision","status","current_step","total_steps","started","unsynced"}],
  "adhoc_tasks": [{"note","created","origin_workflow","mcp_note_id"}],
  "team_agents": [{"id","task","origin_workflow","spawned","status","workflow_id"}],
  "state_deltas": "<int>",
  "last_save_deltas": "<int>",
  "last_save": "<ISO|null>",
  "last_reconciliation": "<ISO|null>",
  "events_log": [{"ts","type","wf","detail","synced"}]
}
```

**Field `last_save_deltas` (Compact-Cycle, Spec#2152):**
- Pre-reset Snapshot des `state_deltas`-Werts direkt vor dem Reset in mxSave Step 4
- Default `0` wenn Feld fehlt (alte State-Files sind abwaertskompatibel)
- **Single Source of Truth:** Nur mxSave Step 4 schreibt dieses Feld
- Konsumenten: mxSave Final-Block (2-Stufen-Threshold-Logik), PostCompact-Hook (Re-Brief-Last-Save-Zeile)

**Stack rules:**
- workflow_stack[0] = active workflow
- park = move active WF to index 1+, new one at [0]
- resume = bring WF to [0] (LIFO or by ID)
- ⚡ Max 5 stack entries. >3 parked→warning "N parked WFs — recommend completing?"
- state_deltas++: on every step-done, ad-hoc, park, resume, start
- events_log: log every event immediately {ts, type, wf, detail}

**State operations (internal):**
- `loadState()`: Read+parse file. Corrupt/missing→return empty state+warning
- `saveState(state)`: JSON.stringify→write file
- `addEvent(type, wf, detail)`: Push event to events_log + state_deltas++

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
4. **Escalation check** (Claude decides based on context):
   - **note** (default): Only noted. Workflow continues.
   - **park+start**: Park current WF→Mode 4(park) + Mode 2(start)
   - **spawn**: Start team agent→Mode spawn (see Team Agents)
5. Output: `Ad-hoc tracked: "<note>" (origin: <WF-ID>). Escalation: <note|park|spawn>.`

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
5. **⚡ Reconciliation (Session-Boundary Sync):**
   - ⚡ Pre-check: `doc_id` must be positive integer. If not→remove WF from stack + warn user, skip to next WF
   - `mx_detail(doc_id)`→parse response:
     - **Error/NotFound:** remove WF from local stack + warn user "WF deleted in MCP"→skip
     - **status='archived':** remove WF from local stack + warn user "WF already archived"→skip
     - **OK:** parse step table→count done steps = `mcp_step`, count total rows = `mcp_total`
   - Sanity: if local `current_step` > `total_steps`→clamp to `total_steps` + warn
   - Compare: local `current_step` vs `mcp_step`
   - If local > MCP (local is ahead): push ALL locally-done steps to MCP via `mx_update_doc(doc_id, content with Steps=done+Timestamps, change_reason='Reconcile: Steps N-M→done')` → update `doc_revision` from response → set `unsynced=false`
   - If MCP > local (MCP is ahead): update local→`current_step=mcp_step`, `total_steps=mcp_total`, `doc_revision` from response, `unsynced=false`
   - If both diverged (steps overlap with different results, e.g. team-agent vs local): WARN user, show both versions, ask which to keep before pushing
   - If equal: no action needed
   - Set `state.last_reconciliation = now()`
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
