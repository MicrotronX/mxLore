---
name: mxSave
description: Use when the user says "save state", "/mxSave", "session end", "before /compact", "wrap up", or otherwise wants to persist the current mx-project state (clean settings, update CLAUDE.md + docs/status.md, create session notes in MCP-DB, sync orchestrate-state deltas, emit clear-cycle tip). Loop-capable. Fires at natural session-end boundaries.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Task
argument-hint: "[optional-notes] [--loop] [--clear-cycle]"
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
1. CLAUDE.md→`**Slug:**`=project slug. ∅slug→?user
2. mx_ping()→check MCP availability. Set `mcp_available = (ping == ok)`. Steps 3, 5, 6 reference this flag for fallback decisions instead of repeating "MCP error→fallback" inline.
3. ⚡ State file safety: If `.claude/orchestrate-state.json` is missing or unparseable, treat as empty state per the mxOrchestrate `loadState()` contract: `state_deltas=0`, `last_save_deltas=0`, `workflow_stack=[]`, `mcp_available` still set from ping result. Warn user inline ("orchestrate-state.json missing/corrupt — proceeding with empty state"). The `--clear-cycle` mode in this case emits nothing (N==0 silent path).

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
- ⚡ **Zombie Reference Check:** Extract all `#NNNN` doc IDs from "Next Steps"→`mx_batch_detail(doc_ids=[...])` (max 10 per call, chunk if >10 IDs)→check status. Archived/superseded→remove from "Next Steps". Output: `Zombie refs removed: #X, #Y (archived)`
- If `!mcp_available` → skip zombie check (log: "Step 2 zombie check skipped — MCP unavailable"). Use the `mcp_available` flag set in Init step 2 — do not re-ping.

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
- Define `ARCHIVE_SWEEP_LIMIT = 20` once at the top of Step 3 (sync this constant if you change the limit anywhere)
- `mx_search(project, doc_type='plan,spec,decision', status='active', limit=ARCHIVE_SWEEP_LIMIT)`→collect IDs→`mx_batch_detail(doc_ids=[...])`→check each doc:
- ⚡ If result count == ARCHIVE_SWEEP_LIMIT → warn: "Archive sweep truncated at <ARCHIVE_SWEEP_LIMIT> — re-run /mxSave or paginate manually if more active items exist." This is an auto-cleanup correctness guard, not a token-savings concern.
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
See `references/lesson-template.json` for the lesson_data field schema.
⚡ **Mandatory:** what_happened+what_was_learned derived from chat context. applies_to_files from changed files. source_session from state.
⚡ **∅info→omit** instead of inventing. Empty arrays allowed, empty strings not.

∅MCP→skip (mcp_available flag from Init)

**Auto-dismiss pending findings:**
Batch-dismiss all pending findings (not reviewed in session context):
`mx_skill_feedback(project=<slug>, reaction='dismissed')` — one call dismisses all pending findings for the project.
- Output: `Findings: batch-dismissed`
- if !mcp_available → skip

### 4) Orchestrate State Sync (HYBRID, Spec#1161)
Read `.claude/orchestrate-state.json`. If present+not empty:

- **Push unsynced:** WFs with `unsynced=true`→`mx_update_doc`→`unsynced=false`. Events with `synced=false`→session note→`synced=true`
- **Snapshot (Spec#2152, Clear-Cycle pre-reset):** `last_save_deltas = state_deltas` — MUST be set BEFORE reset below. Single Source of Truth for this field.
- **⚡ last_save_summary (Bug#3229 proper fix):** After Step 5 creates the session_note, write:
  - `state.last_save_summary` = 1-line narrative, **max 200 chars**, describing this save's main artefacts (new/updated specs/plans/ADRs, bug-fixes, commits, WF-step-flips). NO internal reasoning, NO timestamps (those are in `last_save`). Example: `"Spec#3194 v3 + ADR#3264 + Plan#3266 (33 tasks M1-M3); Bug#3229/3230/3239 fixed (commits d327b92+577dff3)"`.
  - `state.last_save_session_note_doc_id` = doc_id of the session_note created in Step 5. Pointer for Resume/cross-session enrichment (Bug#3230 pairing).
  - Both fields are **required** (not optional). The statusline hook prefers them over events_log parsing for the `last:` display.
  - If Step 5 failed (MCP down, subagent error) → write `last_save_summary` anyway with the local summary + set `last_save_session_note_doc_id = null` (signals "summary is real, but no MCP-archive link").
- **Finalize:** `state_deltas`→0, `last_save`→now, `last_reconciliation`→now
- ⚡ Do NOT archive workflows. Only sync+reset.
- Write state file back
- ⚡ Token discipline: use Edit for surgical field updates (e.g. `last_save_deltas` snapshot+reset + `last_save_summary` + `last_save_session_note_doc_id`), Write for full rewrites only. Per global rule "Edit surgical 1-5L, multi-line→Write".
- ∅file or empty stack→skip
- Output: `Orchestrate: <N> unsynced pushed, deltas reset, summary written`

### 5) Session Summary as MCP Note (MCP)
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content)
```
**Template:** What was done? | Changed files | Next step | Open bugs | User notes
**Numbering:** mx_search(project=<slug>, doc_type='session_note', query='YYYY-MM-DD')→exists→append number
**if !mcp_available →** Fallback local `docs/plans/session-notes-YYYY-MM-DD.md`+warning

⚡ **Archive-Fidelity Rule (Bug#3239):** Session notes must ARCHIVE chat-produced decision artefacts VERBATIM, not compress them.
- Detect structured blocks in chat history: Konsens-Tabellen (markdown tables ≥5 rows with decision content), Step-N-Konsens-Summaries, Brainstorm-Progress outputs, CC2050-Review outcomes, Q/A-resolution blocks.
- Include these blocks 1:1 in session_note.content under `## Appendix: <section-name>` headings.
- The meta-summary (What was done? Next step? etc.) stays at the top; the verbatim blocks follow as appendices.
- Token-budget: session_notes for Brainstorm-heavy or multi-review sessions may grow to ~8000 tokens (default cap 3000 is a suggestion, not a hard limit).
- Rationale: when `/clear` happens, `resume` reads back ONLY the session_note. A compressed summary loses per-step parameters (e.g. "Body-Limits 2000/8000", "Token-Bucket 50/10h") that block subsequent Spec/Plan work. Verbatim archival is cheaper than mid-next-session user-rescue from screen-scrollback.
- When in doubt between brevity and fidelity → choose fidelity.

### 6) Peer Notify (MCP, only if delta > 0)
if !mcp_available → skip entire step.
`mx_session_delta(project, session_id=<state.session_id>, limit=1)`→total_changes==0→skip.
`mx_agent_peers(project)`→∅peers→skip.
1 call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 sentences>","changed_files":<count>,"project":"<slug>"}`
- Error→log, don't abort

## Final Block — Clear-Cycle Recommendation (Spec#2152, /clear mode)

After all 6 steps complete, read `last_save_deltas` from `.claude/orchestrate-state.json` (NOT `state_deltas` — that one has been reset to 0 in Step 4). Step 4 has already snapshotted the pre-reset value into `last_save_deltas`.

(In `--clear-cycle` mode, the calling sequence has already overridden `N` with `state.state_deltas` — see Clear-Cycle Mode section. Final Block is mode-agnostic; it just consumes `N`.)

**⚡ Skip criterion:** Skip the Final Block only if the state file is missing OR the relevant deltas field is unset. Mode-aware: in normal mode the relevant field is `last_save_deltas` (set in Step 4); in `--clear-cycle` mode the relevant field is `state_deltas` (the in-flight counter). A fresh state with `state_deltas > 0` but `last_save_deltas` unset MUST emit the threshold line in `--clear-cycle` mode — do NOT skip. Do NOT skip on empty workflow_stack alone — deltas can be meaningful from doc-only sessions (edits, notes, specs) that never touched a workflow.

**Read `N = state.last_save_deltas` (default 0 if field missing for backwards-compat).**

Then, based on `N`:

- **`N >= 15`**:
  - **Loop-mode check**: if the skill is running in `--loop` mode, downgrade to the N≥10 tip line below (loop forbids interactive waits per L181). Do NOT emit the active prompt.
  - **Normal mode**: emit **Active prompt:**
    ```
    Session is large (<N> deltas persisted). /clear + new session + mx_briefing is now worthwhile.
    Execute? (1=yes /clear / 2=no, keep working)
    ```
    Wait for user. On `1`: print `Next step: press /clear + new session + mx_briefing` and exit. On `2`: print `Continuing — call /mxSave again before the next /compact.` and exit.

- **`N >= 10`** (and `< 15`) → **Info tip** (1 line):
  ```
  Tip: <N> deltas persisted. /clear + new session + mx_briefing is worthwhile when convenient.
  ```

- **`N >= 1`** (and `< 10`) → **Marketing line only** (1 line, honest, no token estimates):
  ```
  Clear-Cycle: <N> deltas persisted. /clear + manual mx_briefing ready.
  ```

- **`N == 0`** → **No output** (no noise for trivial saves).

⚡ **Honesty rule:** No token-multiplier numbers (e.g. "~3k per delta") — that would not be reliable (state_deltas counts DB events, not transcript tokens). Marketing line signals readiness only, not a numerical claim.

⚡ **Why this matters:** PreCompact/PostCompact hooks are **dormant** (Spec#2152, Lesson#2161 — prompt-type hooks blocked upstream in Claude Code). Therefore `/compact` is no longer a clean path: re-briefing cannot be triggered automatically. Active workflow: **`/clear` → start a new session → call `mx_briefing` manually**. This returns a lean, structured state overview; the full detail history stays persistent in the MCP-DB. Hook re-activation if upstream is fixed: see `~/.claude/hooks/dormant-pre-post-compact.md`.

## Clear-Cycle Mode (`--clear-cycle`)

⚡ Manual replacement for the dormant PreCompact/PostCompact hooks (Spec#2152 + Lesson#2161). Skips Steps 1-6 entirely and runs ONLY the Final Block (compact-cycle threshold logic) using the current `state_deltas` value. Use when:
- After a manual /compact, invoke /mxSave --clear-cycle explicitly to emit the threshold line. (Note: PreCompact/PostCompact hooks are dormant per Spec#2152, so there is NO automatic trigger — the user must invoke this.)
- Or when the user types `/mxSave --clear-cycle` to get the threshold-driven prompt without doing a full state save
- Output: same 4-stage Final Block (≥15 active prompt / ≥10 tip / ≥1 marketing / ==0 silent)

⚡ Flag precedence: If both `--loop` and `--clear-cycle` are passed, `--clear-cycle` wins — runs the Sequence below ONCE and exits. The loop body is suppressed because Clear-Cycle is a one-shot threshold-emit.

Sequence:
1. Init (read state file only — no MCP roundtrip; use loadState contract: corrupt/missing → empty state with state_deltas=0)
2. Skip Steps 1-6
3. Compute `N` for the threshold: in `--clear-cycle` mode, `N = state.state_deltas` (default 0 if field missing — handles legacy state files pre-Spec#2152). Mirror the default-0 fallback used by Final Block on line 132. Current in-flight value, NOT the stale `last_save_deltas`. This override exists because Step 4 — which normally snapshots `state_deltas → last_save_deltas` — is skipped in this mode.
4. Run Final Block threshold logic with `N` (4-stage: ≥15 active prompt / ≥10 tip / ≥1 marketing / ==0 silent)
5. Exit (do NOT touch state_deltas, do NOT update CLAUDE.md or status.md)

## Loop Mode (--loop or /loop context)
- **Idempotency:** check `mx_session_delta(project, session_id=<state.session_id>, limit=1)`→total_changes==0→single line `mxSave: No changes` + skip
- Changes present→normal save, but compact output (1 line per step)
- !settings.local.json cleanup in loop (only on manual invocation)
- !Prompts, !interactive steps
- Session note shorter: only changes since last save
- ⚡ Final Block in loop mode: downgrade the N≥15 active prompt to the N≥10 tip line. Loop mode forbids interactive waits (`!Prompts, !interactive steps`), so the active prompt would hang the loop. Tip line is non-interactive and conveys the same urgency.

## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback
- ⚡ **!Bash for MCP calls.** NEVER execute `claude --print` or `claude -p` in Bash. ALWAYS call MCP tools directly (mx_search, mx_detail, mx_update_doc etc.). Bash only for filesystem operations (cp, mkdir).

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
