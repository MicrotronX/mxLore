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
**Phased sequential-with-parallel:** Steps are phased to avoid shared-MCP-doc races (Step 3 ↔ Step 4 on WF docs) and to honour data-dependencies (Step 4b needs Step 5's doc_id). Do NOT collapse phases into a single parallel fan-out.

1. **Main (sequential):** Init → Steps 1, 2 (settings + CLAUDE.md/status.md incl. zombie check)
2. **Parallel phase A:** Step 3 (Background Subagent, MCP-only) + Step 4a (Main). Topology only — Step 4a body is the SoT for its internals (unsynced-push + Step-State Delta Check + Snapshot + Finalize).
   - ⚡ Pass `mcp_available` (from Init ping) as a parameter in Step 3 subagent prompt — subagents do not share main-context variables
   - ⚡ Step 3 and Step 4a both touch WF docs in MCP → Step 4a's Step-State Delta Check MUST send `expected_updated_at` on every `mx_update_doc` call + MUST skip WFs whose MCP `data.status != 'active'` (Step 3 may have archived them in this tick). Both safeguards are specified inline in Step 4.
3. **Main (sequential, synchronous MCP call):** Step 5 — `mx_create_doc(session_note)` issued from Main context so the returned doc_id is synchronously available for Step 4b. Body construction (potentially long) MAY be offloaded to a background subagent that RETURNS the body string; Main then issues the `mx_create_doc` itself and captures the doc_id. ⚡ Step 5 MUST NOT run as a background subagent whose return value Main waits for — Claude Code skill runtime has no "await subagent" primitive, so that pattern would degrade to `last_save_session_note_doc_id=null` on every save (regressing Bug#3229 fix).
4. **Main (sequential):** Step 4b — write `last_save_summary` + `last_save_session_note_doc_id` (from Step 5's return) to state.json (single deferred Write applying all 4a+4b mutations).
5. **Parallel phase B (fire-and-forget):** Step 6 Peer Notify (Background Subagent) — no join required, errors logged not aborted.

Reason: Subagents lack write permission for `.claude/` files. Step 4 is split (4a pre-Step5 in-memory mutations, 4b post-Step5 final Write) so that `last_save_session_note_doc_id` reliably uses Step 5's return value. Step 5 runs Main-context-synchronous because skill runtime cannot reliably wait for a background subagent's return. Degraded path (Step 5 MCP call fails at runtime): see Step 4b fallback — `last_save_session_note_doc_id=null`, `last_save_summary` written with local summary only.

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
- ⚡ **Zombie Reference Check:** Extract all `#NNNN` doc IDs from "Next Steps"→`mx_batch_detail(doc_ids=[...])` (max 10 per call; if >10 IDs: iterate — call batch_detail(next 10), process, advance cursor until all IDs consumed)→check status. Archived/superseded→remove from "Next Steps". Output: `Zombie refs removed: #X, #Y (archived)`
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
Read `.claude/orchestrate-state.json`. ⚡ ∅file → skip entire Step 4 (no state to sync). Otherwise execute in TWO phases per Execution Mode; all 4a/4b mutations are buffered in-memory and the state.json Write happens ONCE at the end of 4b.

⚡ **Crash-resilience (atomic-write reality):** Plain `Write` tool against state.json is NOT OS-atomic on Windows — a mid-write crash can truncate the file (loadState then treats it as empty per Init §3, losing `workflow_stack`). For resilience: Write to `.claude/orchestrate-state.json.tmp` first, then `Bash mv` (rename is atomic on most filesystems). If the Write tool cannot do temp-file-plus-rename, the risk is documented and accepted (mxSave at session-end is rarely interrupted).

⚡ **Concurrent state_deltas race (accepted trade-off):** Between the in-memory Snapshot below and the deferred Write at 4b end, an external mxOrchestrate auto-invoke (same session, different tool-call) can increment `state_deltas` on disk. The deferred Write overwrites those concurrent increments with `state_deltas=0` (lost). Accepted because mxSave runs at session-end boundaries where concurrent writes are rare. Stronger mitigation (if needed): Read-Modify-Write pre-Write — re-read state.json immediately before Write, preserve `(on_disk_state_deltas - pre_snapshot_value)` as the new baseline after reset.

#### 4a — Parallel with Step 3 (Main context, in-memory only)

- **WF-guarded sub-checks** (skip BOTH bullets if `workflow_stack` is empty — doc-only sessions have no WFs to sync):
  - **Push unsynced:** WFs with `unsynced=true` → `mx_update_doc` → flip in-memory `unsynced=false`. Events with `synced=false` → append to session note → flip in-memory `synced=true`.
  - **⚡ Step-State Delta Check (Bug#3281):** For each WF in `workflow_stack` where `status='active'` AND `doc_id` is set. ⚡ Runs REGARDLESS of loop idempotency (Bug#3281 scenario produces no MCP activity — local-only step-flips are EXPECTED to coexist with `total_changes==0`):
    - `mx_detail(wf.doc_id, max_content_tokens=0)` — ⚡ **unlimited** (0 = no truncation); full body is needed for rebuild, any truncation causes silent data loss on write-back
    - ⚡ **MCP status guard (Bug#3281 race with Step 3):** if `data.status != 'active'` (Step 3 background may have archived this WF in the same tick) → skip, do NOT revive
    - Count MCP done-steps: iterate step-table rows (authoritative template per mxOrchestrate WF Markdown: `| # | Step | Skill | Status | Result | Timestamp |`). Split each row by `|`, check the **Status column (4th content cell, 1-indexed, trimmed)** equals `done` case-insensitive. Do NOT grep `| done |` globally — the word "done" in Step/Skill/Result cells would false-positive the count.
    - Compare `(local current_step - 1)` vs MCP done-count:
      - `local-1 > MCP done-count` → local ahead, sync needed:
        - Take `data.content` verbatim, rewrite only the Status cells: rows 1..(current_step-1) → `done`, remaining rows keep their existing status (usually `pending`). Preserve all appendices/metadata/headers/non-step-table sections verbatim.
        - `mx_update_doc(doc_id, content=<full rewritten body>, change_reason='mxSave Step4: step-state rewrite sync', expected_updated_at=data.updated_at)` — ⚡ `rewrite` keyword bypasses Bug#3018 50%-length-gate; `expected_updated_at` prevents overwriting a concurrent Step 3 archive
        - On error (optimistic-lock / destructive-write block / FOR-UPDATE contention) → log `WF #<id>: step-sync failed (<error>)`, continue to next WF, do NOT abort the whole Step 4. Counter `K` increments.
      - `local-1 == MCP done-count` → skip (already in sync)
      - `local-1 < MCP done-count` → ⚡ **MCP ahead of local** (local state.json stale, probably from another session/agent): emit warning `Step-sync: WF #<id> MCP ahead (MCP=<a>, local=<b>) — state.json may need reconciliation via mxOrchestrate resume`, do NOT write back. Counter `W` increments.
    - Track in-memory counters for 4b Output aggregation: `N = WFs updated`, `K = failed`, `W = MCP-ahead warnings`.
    - Emit inline summary: `Step-sync: <N> updated, <K> failed, <W> MCP-ahead warnings` (silent if all zeroes).
    - ∅active WFs with doc_id → skip silently
    - ⚡ **Token-budget caveat:** this check writes full WF bodies in MCP (not the state.json file) — budget ~1-2 MCP calls per active WF with doc_id. Typical: 2-5 WFs × 2 calls = 4-10 MCP calls added to Step 4.
    - ⚡ **Intent-not-verified caveat (interaction with Rules §"confirmed-implemented as done"):** This sync marks rows `done` based on the local `current_step` counter as an **intent signal** — it does NOT independently re-verify the step's work was completed. Rationale: mxOrchestrate is the authoritative step-lifecycle owner for INTERACTIVE flows (Spec#1161 MCP-First Step-Update). Bug#3281 shows that subagents with direct state.json Write access can ALSO increment `current_step` WITHOUT going through that contract. mxSave trusts whatever wrote `current_step` (explicit trust in the writer, not in mxOrchestrate per se). A hostile or buggy subagent can cause unwarranted step-flips in MCP via this path — accepted risk at present. The Rules ban on "assumptions" is overridden here by the owning-skill-trust principle — see Rules §Exception.
- **Snapshot (Spec#2152, Clear-Cycle pre-reset, UNCONDITIONAL):** `last_save_deltas = state_deltas` (in-memory) — MUST be set BEFORE reset below. Single Source of Truth for this field. ⚡ Runs even when `workflow_stack` is empty — Final Block consumes this regardless of stack depth.
- **Finalize (UNCONDITIONAL):** `state_deltas` → 0, `last_save` → now, `last_reconciliation` → now (all in-memory). ⚡ Doc-only sessions REQUIRE this — otherwise `state_deltas` accumulates forever and Final Block emits the Active prompt on every subsequent save (regression of Spec#2152).
- ⚡ Do NOT archive workflows in this step. Only sync+reset.

#### 4b — After Step 5 returns (Main context, sequential)

Step 5 runs in Main context synchronously (see Execution Mode Phase 3 + Step 5 header) so its returned doc_id is available here without any subagent-join primitive.

- **⚡ Prune state (token-discipline):** apply state-pruning algorithm. → `references/pruning.md` for full spec (4b.1 two-pass adhoc-tasks, 4b.2 dual-cap events_log 30/50, 4b.3 commit-style schema v2→v3 bump + `last_pruned` stamp). ⚡ **Fail-soft:** missing/unreadable `references/pruning.md` → log + skip pruning, continue 4b. Output suffix: `; pruned <X> adhocs (<Y> migrated), <Z> events trimmed` OR `; pruning skipped: <reason>`.
- **⚡ last_save_summary (Bug#3229 proper fix):** Update the in-memory state object:
  - `state.last_save_summary` = 1-line narrative, **max 200 chars**, describing this save's main artefacts (new/updated specs/plans/ADRs, bug-fixes, commits, WF-step-flips). NO internal reasoning, NO timestamps (those are in `last_save`). Example: `"Spec#3194 v3 + ADR#3264 + Plan#3266 (33 tasks M1-M3); Bug#3229/3230/3239 fixed (commits d327b92+577dff3)"`.
  - `state.last_save_session_note_doc_id` = doc_id returned by Step 5's `mx_create_doc`. Pointer for Resume/cross-session enrichment (Bug#3230 pairing). Always set when Step 5 succeeded.
  - Both fields are **required** (not optional). The statusline hook prefers them over events_log parsing for the `last:` display.
  - If Step 5's `mx_create_doc` failed (mcp_available=false, destructive-write block, network error) → still write `last_save_summary` with the local summary + set `last_save_session_note_doc_id = null` (signals "summary is real, but no MCP-archive link"). The degraded path is honest about the missing link instead of silently omitting the summary.
- **Write state file back** — single deferred Write applying ALL 4a+4b in-memory mutations. This is the ONLY state.json write in Step 4. See crash-resilience note at top of Step 4.
- ⚡ Token discipline: the combined write touches 5-7 fields (`last_save_deltas`, `state_deltas=0`, `last_save`, `last_reconciliation`, `last_save_summary`, `last_save_session_note_doc_id`, plus any flipped WF `unsynced`/event `synced` flags) — use Edit for surgical field updates, Write only for full rewrites. Per global rule "Edit surgical 1-5L, multi-line→Write".
- Output (aggregated): `Orchestrate: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead), deltas reset, summary written[<archive-link-suffix>]`. Suffix rules: append `" (no archive link — Step 5 failed)"` ONLY if `last_save_session_note_doc_id==null` AND `mcp_available==true` at Init (distinguishes degraded from expected-null paths). If K>0: also append at end `⚠ root-cause K step-sync failures before next session`.

### 5) Session Summary as MCP Note (MCP, Main-context synchronous)
⚡ **Main-context synchronous** so the returned doc_id is available for Step 4b without any subagent-join primitive. Body construction (often 2-8k tokens per Archive-Fidelity Rule) MAY be offloaded to a background helper subagent that RETURNS the body string — then Main performs the `mx_create_doc` call itself and captures the doc_id. Do NOT run the MCP call from a background subagent; Main cannot reliably wait for its return.

⚡ **Body-Validation Gate — BEFORE mx_create_doc:**
The subagent-returned body string MAY be empty/truncated/error-prose when the subagent crashes, hits its token cap, or returns a meta-reply instead of the template content. Persisting such a body produces a session_note whose `content=""` — the next session's resume has no archived context. Gate to prevent that:

Validate the body string against ALL THREE criteria:
1. **Length:** `len(body) >= 500` chars.
2. **Structure:** contains at least 3 of the template section headers (`## What was done`, `## Changed files`, `## Commits`, `## Docs created this session`, `## Next step`).
3. **Archive-Fidelity (Bug#3239 hardening):** if the chat history contains structured decision artefacts — markdown tables with ≥5 rows, `## Step N`, `## Substep`, `## Konsens`, `## Brainstorm`, `## Review` headings, or Q/A-resolution blocks — the returned body MUST contain at least one matching `## Appendix:` heading per detected artefact-class. Regex: detect artefacts via `^\|[^\n]+\|$` ×≥5 consecutive lines OR `^## (Step \d+|Substep|Konsens|Brainstorm|Review)` in chat; body must carry `^## Appendix:` followed by the verbatim block. Missing appendix for a detected artefact = fidelity-fail.

If ANY criterion fails: DO NOT pass the subagent body to `mx_create_doc`. Instead, Main builds a fallback body directly in the current context (no subagent) using the same template, reading from chat history / tool-call returns / git state — and MUST include all detected decision artefacts verbatim under `## Appendix:` sections. Then log once:
`WARN: Step 5 body-subagent returned N chars, K sections, M/X fidelity-artefacts preserved (< threshold); fallback to local prose.`
Invariant: the body passed to `mx_create_doc` is NEVER empty AND NEVER shorter than the local fallback AND NEVER drops detected decision artefacts — a degraded fallback beats a silent body-drop or compression-loss.

⚡ **Subagent dispatch hardening (Bug#3239):** when spawning the body-builder subagent, pre-scan the chat history for the artefact classes above and pass an explicit `required_appendices` list in the subagent prompt (e.g. `required_appendices: ["Konsens-Tabelle Step 4", "CC2050 Review Outcome", "Q3 Body-Limits 2000/8000"]`). Raise the token budget hint to 8000 for Brainstorm/Review-heavy sessions (already allowed per Archive-Fidelity Rule). The subagent cannot "forget" appendices under compression pressure when they are enumerated as required parameters.

⚡ **Status must be `active`:** Session-notes are finalised at save-time. Pass `status='active'` explicitly — leaving it at the server's `draft` default breaks resume-enrichment pairing in the next session.
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content, status='active')
```
**Template (all sections required — omit only if truly ∅, do NOT paraphrase absence):**
- `## What was done` — numbered per work stream
- `## Changed files` — git-status / file-touch list verbatim
- `## Commits` — `<hash> — <subject>` + explicit push status (`pushed` / `NOT pushed`)
- `## Docs created this session` — enumerate ALL doc_ids created this session (notes, lessons, references, ADRs, plans, specs, bugreports, feature_requests). Format: `<type>#<id> — <title>`. Source: `mx_create_doc` tool-call returns from THIS session, NOT prose-guessed. Purpose: a fresh `/clear` session reads this block + `mx_detail` each ID to fully reconstruct the work.
- `## Next step` — if the active Plan has pending next-phase tasks (M2/M3/next milestone), enumerate them **verbatim** from the Plan body (copy `- [ ]` lines 1:1, do NOT paraphrase). Pointer-only (`see Plan#NNNN M2`) is insufficient because resume-enrichment may not fetch the Plan body.
- `## Open bugs / TODOs` — inline code-TODOs, pending MCP findings, version-bumps pending, push-pending
- `## User notes` — explicit user corrections, feedback, near-misses
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

**Read `N = state.last_save_deltas` (default 0 per Init §3 loadState contract — applies to all legacy state files pre-Spec#2152).**

Then, based on `N`:

- **`N >= 15`**:
  - **Loop-mode check**: if the skill is running in `--loop` mode, downgrade to the N≥10 tip line below (loop forbids interactive waits — see Loop Mode section `!Prompts, !interactive steps` rule). Do NOT emit the active prompt.
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
3. Compute `N` for the threshold: in `--clear-cycle` mode, `N = state.state_deltas` (default 0 per Init §3 loadState contract — same rule as the Final Block). Current in-flight value, NOT the stale `last_save_deltas`. This override exists because Step 4 — which normally snapshots `state_deltas → last_save_deltas` — is skipped in this mode.
4. Run Final Block threshold logic with `N` (4-stage: ≥15 active prompt / ≥10 tip / ≥1 marketing / ==0 silent)
5. Exit (do NOT touch state_deltas, do NOT update CLAUDE.md or status.md)

## Loop Mode (--loop or /loop context)
- **Idempotency:** check `mx_session_delta(project, session_id=<state.session_id>, limit=1)` → evaluate total_changes. ⚡ If `state.session_id` is null/missing → skip idempotency check, proceed with normal save. ⚡ **Step 4a always runs (NOT 4b):** regardless of total_changes, Step 4a executes in full (WF-guarded sub-checks if stack non-empty, plus unconditional Snapshot + Finalize). Rationale: Step 4a sub-checks detect local-only divergence that by definition produces NO MCP activity (unsynced=true events haven't been flushed; Bug#3281 subagent step-flips bypass MCP entirely). Skipping Step 4a on total_changes==0 would mask exactly the bugs these checks were designed to catch. Step 4b + Step 5 are skipped in the idempotent branch (no session-note needed when no session activity).
- **Honesty-conditional output:** after Step 4a returns its counters, emit:
  - `total_changes==0 AND N==0 AND K==0 AND W==0 AND ∅unsynced-push` → `mxSave: No changes`
  - `total_changes==0 AND any(N,K,W,unsynced)>0` → `mxSave: No session-delta; local-sync: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead)` (never claim "No changes" when mxSave actually rewrote MCP docs)
  - `total_changes>0` → normal save, compact output per below
- Changes present→normal save, but compact output (1 line per step)
- !settings.local.json cleanup in loop (only on manual invocation)
- !Prompts, !interactive steps
- Session note shorter: only changes since last save
- ⚡ Final Block in loop mode: downgrade the N≥15 active prompt to the N≥10 tip line. Loop mode forbids interactive waits (`!Prompts, !interactive steps`), so the active prompt would hang the loop. Tip line is non-interactive and conveys the same urgency.

## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions
  - ⚡ **Exception (Step 4a Step-State Delta Check):** mxSave's Bug#3281 sync propagates `current_step` from state.json to MCP as an **intent signal**, not a re-verified completion claim. Rationale: mxOrchestrate is the authoritative step-lifecycle writer for interactive flows; subagents with direct Write-tool access can also write `current_step` (Bug#3281 path). mxSave trusts the writer. See Step 4a "Intent-not-verified caveat" for the full rationale. Future refactors of Step 4a that add independent step-verification are welcome but not required.
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback
- ⚡ **!Bash for MCP calls.** NEVER execute `claude --print` or `claude -p` in Bash. ALWAYS call MCP tools directly (mx_search, mx_detail, mx_update_doc etc.). Bash only for filesystem operations (cp, mkdir).

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
