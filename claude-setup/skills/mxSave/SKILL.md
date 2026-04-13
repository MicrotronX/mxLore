---
name: mxSave
description: Use when the user says "save state", "/mxSave", or wants to persist the current project state for seamless continuation in a new session. Cleans settings, updates CLAUDE.md, docs/status.md (local), and creates session notes in DB. Loop-capable.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
argument-hint: "[optional-notes] [--loop]"
---

# /mxSave — Persist Project State (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** Hybrid mode. MCP work→Subagent(Background). `.claude/` files→Main context (Subagents lack write permission for `.claude/`). Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → background subagent (already enforced in Steps 3+5+6). mx_detail server default = 600 tokens.

Save agent. Persists project state for seamless session continuation.
**Hybrid:** CLAUDE.md+status.md=local. Session notes=MCP-DB.

## Execution Mode ⚡
**Start in parallel:**
- **Agent(Background):** Steps 3, 5, 6 (pure MCP calls)
- **Main context:** Steps 1, 2, 4 (read+write local files, sync `.claude/` files. Step 2 zombie check uses MCP→on MCP error skip)
Reason: Subagents lack write permission for `.claude/` files.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→check MCP availability

## 6 Steps (sequential)

### 1) Clean settings.local.json (LOCAL)
Read+clean `.claude/settings.local.json`:
- Remove duplicates (e.g. `python:*`+`python3:*`→keep one)
- Remove stale/one-time Bash permissions
- Bash(grep/find/ls/dir:*)→remove (Glob/Grep/Read exist)
- Keep useful entries (WebSearch, WebFetch domains, python)
- Sort logically: WebSearch→WebFetch→Bash

### 2) Update CLAUDE.md + status.md (HYBRID — local + MCP for zombie check)
**CLAUDE.md:**
- **Weight:** check `wc -l`. Target: max 200 lines.
- Exceeded→offload domain details to `docs/reference/`, keep only reference in CLAUDE.md.
- AI-Start-Here links current. Arch changes high-level (1-3 lines/feature). !long backlogs→DB(/mxPlan). Compact: links+rules+architecture.

**status.md:**
- Add new features (+date). Update open items.
- Active workflows: use active_workflows from mx_session_start(include_briefing=true), ∅separate mx_search needed
- Use references to docs instead of copying content
- ⚡ **Zombie Reference Check:** Extract all `#NNNN` doc IDs from "Next Steps"→`mx_batch_detail(doc_ids=[...])` (max 10 per call, chunk if >10 IDs)→check status. Archived/superseded→remove from "Next Steps". MCP error→skip zombie check+warning. Output: `Zombie refs removed: #X, #Y (archived)`

### 3) Update MCP Docs (MCP only)
**Clean orphaned workflows (ADR-0006):**
`mx_search(project, doc_type='workflow_log', query='active')`→collect IDs→`mx_batch_detail(doc_ids=[...])`→check each WF:
- WF title references feature marked done in CLAUDE.md/status.md→archive
- Collect all WFs to archive→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup by mxSave"}, ...]')` — one call instead of N
- ⚡ Only close clearly completed WFs. Doubt→leave open.

**Ad-hoc WF Auto-Cleanup (Spec#1615):**
Check WFs whose title starts with "Ad-hoc:":
- WF has only step 1 AND title starts with "Ad-hoc:" AND WF content shows no done steps except step 1
  → Silently archive: `mx_update_doc(doc_id, status='archived', change_reason='auto-cleanup: empty ad-hoc WF')`
  → No output (no noise)
- WF has real work→archive normally like other WFs

**Archive completed Plans/Specs/Decisions:**
`mx_search(project, doc_type='plan,spec,decision', status='active', limit=20)`→collect IDs→`mx_batch_detail(doc_ids=[...])`→check each doc:
- **Plan:** All tasks `- [x]` (no `- [ ]`)→archive
- **Spec:** All ACs `- [x]` AND no open questions→archive
- **Decision:** Status `proposed` for >30 days without change→warning (don't auto-archive)
- Collect→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup: all tasks/ACs completed"}, ...]')`
- ⚡ Only for clearly completed docs. Mixed checkboxes→leave open.
- Output: `Archived: <N> Plans, <M> Specs. <K> stale Decisions (warning).`

**Extract lesson candidates (Spec#1198, Auto-Learn, AnsatzC-compliant):**
Derive lesson candidates from chat history:
- Types: pitfall, decision_note, integration_fact, rule, solution
- Dedupe: `mx_search(project, doc_type='lesson', query='<title>', limit=3)`→hit→merge, else new
- Gate: confidence >= 0.6→`mx_create_doc(project, doc_type='lesson', ...)`, <0.6→tag `lesson-candidate`
- ∅Lessons→skip. Output: `Lessons: N created, M merged, K candidates`

**Lesson template (lesson_data JSON, AnsatzC mandatory fields):**
```json
{
  "type": "<rule|pitfall|solution|decision_note|integration_fact>",
  "scope": "<project|shared-domain|global>",
  "severity": "<low|medium|high|critical>",
  "what_happened": "<What happened? 1-2 sentences>",
  "what_was_learned": "<What was learned? 1-2 sentences>",
  "recommended_action": "<Recommended action>",
  "avoid_action": "<What to avoid>",
  "applies_to": "<Comma-separated patterns>",
  "applies_to_files": ["<affected file paths>"],
  "applies_to_functions": ["<affected functions/methods>"],
  "applies_to_patterns": ["<affected code patterns>"],
  "source_session": "<current session_id from orchestrate state>",
  "source_docs": [<doc_ids of referenced Specs/Plans/ADRs>],
  "last_confirmed_at": "<ISO date of creation>"
}
```
⚡ **Mandatory:** what_happened+what_was_learned derived from chat context. applies_to_files from changed files. source_session from state.
⚡ **∅info→omit** instead of inventing. Empty arrays allowed, empty strings not.

∅MCP→skip

**Auto-dismiss pending findings:**
Batch-dismiss all pending findings (not reviewed in session context):
`mx_skill_feedback(project=<slug>, reaction='dismissed')` — one call dismisses all pending findings for the project.
- Output: `Findings: batch-dismissed`
- MCP error→skip

### 4) Orchestrate State Sync (HYBRID, Spec#1161)
Read `.claude/orchestrate-state.json`. If present+not empty:

- **Push unsynced:** WFs with `unsynced=true`→`mx_update_doc`→`unsynced=false`. Events with `synced=false`→session note→`synced=true`
- **Snapshot (Compact-Cycle):** `last_save_deltas = state_deltas` — MUST be set BEFORE reset below. Single Source of Truth for this field.
- **Finalize:** `state_deltas`→0, `last_save`→now, `last_reconciliation`→now
- ⚡ Do NOT archive workflows. Only sync+reset.
- Write state file back
- ∅file or empty stack→skip
- Output: `Orchestrate: <N> unsynced pushed, deltas reset`

### 5) Session Summary as MCP Note (MCP)
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content)
```
**Template:** What was done? | Changed files | Next step | Open bugs | User notes
**Numbering:** mx_search(project=<slug>, doc_type='session_note', query='YYYY-MM-DD')→exists→append number
**MCP error→** Fallback local `docs/plans/session-notes-YYYY-MM-DD.md`+warning

### 6) Peer Notify (MCP, only if delta > 0)
`mx_session_delta(project, session_id=<state.session_id>, limit=1)`→total_changes==0→skip.
`mx_agent_peers(project)`→∅peers→skip.
1 call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 sentences>","changed_files":<count>,"project":"<slug>"}`
- Error→log, don't abort

## Final Block — Compact-Cycle Recommendation

After all 6 steps complete, read `last_save_deltas` from `.claude/orchestrate-state.json` (NOT `state_deltas` — that one has been reset to 0 in Step 4). Step 4 has already snapshotted the pre-reset value into `last_save_deltas`.

**⚡ Fallback:** If `.claude/orchestrate-state.json` does not exist OR workflow_stack is empty → **skip Final-Block completely** (no output, no tip, no marketing line). Analog zum ∅file-Skip in Step 4.

**Read `N = state.last_save_deltas` (default 0 if field missing for backwards-compat).**

Then, based on `N`:

- **`N >= 15`** → **Active Question:**
  ```
  Session umfangreich (<N> deltas persistiert). /compact + Re-Brief jetzt sinnvoll.
  Ausfuehren? (1=ja /compact / 2=nein, weiterarbeiten)
  ```
  Wait for user. On `1`: print `Naechster Schritt: druecke /compact — PostCompact-Hook laedt mx_briefing automatisch.` On `2`: continue silently.

- **`N >= 10`** (and `< 15`) → **Info-Tipp** (1 line):
  ```
  Tipp: <N> deltas persistiert. /compact + Re-Brief sinnvoll, sobald passend.
  ```

- **`N >= 1`** (and `< 10`) → **Marketing-Zeile only** (1 line, honest, no token estimates):
  ```
  Compact-Cycle: <N> deltas persistiert. /compact + PostCompact-Hook bereit.
  ```

- **`N == 0`** → **No output** (no noise for trivial saves).

⚡ **Honesty-Regel:** Keine Token-Multiplikator-Zahlen — `state_deltas` zaehlt DB-Events, nicht Transcript-Tokens. Marketing-Zeile signalisiert nur Bereitschaft.

⚡ **Why this matters:** `/compact` selbst ist nicht programmatisch triggerbar — User muss druecken oder Auto-Compaction uebernimmt. Der `PostCompact`-Hook in `~/.claude/settings.json` ruft danach automatisch `mx_briefing` auf und stellt einen schlanken, strukturierten State-Overview wieder her. So bleibt der Main-Context schlank ohne dass Details verloren gehen — die volle Detail-Historie liegt persistent in der MCP-DB.

## Loop Mode (--loop or /loop context)
- **Idempotency:** check `mx_session_delta(project, session_id=<state.session_id>, limit=1)`→total_changes==0→single line `mxSave: No changes` + skip
- Changes present→normal save, but compact output (1 line per step)
- !settings.local.json cleanup in loop (only on manual invocation)
- !Prompts, !interactive steps
- Session note shorter: only changes since last save

## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback
- ⚡ **!Bash for MCP calls.** NEVER execute `claude --print` or `claude -p` in Bash. ALWAYS call MCP tools directly (mx_search, mx_detail, mx_update_doc etc.). Bash only for filesystem operations (cp, mkdir).

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
