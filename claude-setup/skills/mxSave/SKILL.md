---
name: mxSave
description: Use when the user says "save state", "/mxSave", "session end", "before /compact", "wrap up", or otherwise wants to persist the current mx-project state (clean settings, update CLAUDE.md + docs/status.md, create session notes in MCP-DB, sync orchestrate-state deltas, emit clear-cycle tip). Loop-capable. Fires at natural session-end boundaries.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Task
argument-hint: "[optional-notes] [--loop] [--clear-cycle]"
---

# /mxSave — Persist Project State (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** Hybrid — MCP work→background subagent, `.claude/` files→Main (subagents lack write perm). Long bodies (>300 words) via background subagent; mx_detail default 600 tokens.

Save agent. Persists project state for seamless session continuation.
**Hybrid:** CLAUDE.md+status.md=local. Session notes=MCP-DB.

## Execution Mode ⚡
**Phased sequential-with-parallel** (do NOT collapse into a single fan-out; race + data-dependency hazards):

1. **Main:** Init → Steps 1, 2 (settings + CLAUDE.md/status.md + zombie check).
2. **Parallel phase A:** Step 3 (background subagent, MCP-only) + Step 4a (Main, in-memory mutations). Pass `mcp_available` to Step 3 explicitly; Step 4a sends `expected_updated_at` and skips WFs already archived by Step 3.
3. **Main (synchronous):** Step 5 — `mx_create_doc(session_note)` issued from Main; subagent may build the body string but Main issues the call and captures the doc_id (skill runtime has no await-subagent primitive — running Step 5 in background would regress Bug#3229).
4. **Main:** Step 4b — single deferred Write applying ALL 4a + 4b mutations (incl. `last_save_summary` + `last_save_session_note_doc_id` from Step 5's return).
5. **Parallel phase B (fire-and-forget):** Step 6 Peer Notify — no join, errors logged not aborted.

Degraded path: Step 5 MCP call fails → Step 4b writes `last_save_summary` (local) + `last_save_session_note_doc_id=null`.

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

**Lesson template:** `references/lesson-template.json` (schema + mandatory fields). ∅info→omit, never invent.

∅MCP→skip (mcp_available flag from Init)

**Auto-dismiss pending findings:**
Batch-dismiss all pending findings (not reviewed in session context):
`mx_skill_feedback(project=<slug>, reaction='dismissed')` — one call dismisses all pending findings for the project.
- Output: `Findings: batch-dismissed`
- if !mcp_available → skip

### 4) Orchestrate State Sync (HYBRID, Spec#1161)
Read `.claude/orchestrate-state.json`. ⚡ ∅file → skip entire Step 4 (no state to sync). Otherwise execute in TWO phases per Execution Mode; all 4a/4b mutations are buffered in-memory and the state.json Write happens ONCE at the end of 4b.

⚡ **Atomic-write + concurrent-race semantics:** see `references/state-write-semantics.md` (Windows non-atomic Write, accepted state_deltas race, optional temp+rename mitigation).

#### 4a — Parallel with Step 3 (Main context, in-memory only)

- **WF-guarded sub-checks** (skip BOTH bullets if `workflow_stack` is empty — doc-only sessions have no WFs to sync):
  - **Push unsynced:** WFs with `unsynced=true` → `mx_update_doc` → flip in-memory `unsynced=false`. Events with `synced=false` → append to session note → flip in-memory `synced=true`.
  - **⚡ Step-State Delta Check (Bug#3281)** — 4-bullet contract; full algorithm + intent-not-verified rationale in `references/step-state-sync.md`:
    - **When:** each WF in `workflow_stack` with `status='active'` AND `doc_id` set; runs regardless of loop idempotency.
    - **What:** if `(local current_step - 1) > MCP done-count`, rewrite WF body's Status cells with `expected_updated_at` + `change_reason='mxSave Step4: step-state rewrite sync'`. MCP-status guard skips WFs Step 3 archived. `local-1 < MCP-count` emits warning, no write-back.
    - **On-error:** optimistic-lock / destructive-write block / FOR-UPDATE contention → log per WF, increment `K`, continue (do NOT abort Step 4).
    - **Counters (for 4b output):** `N = WFs updated`, `K = failed`, `W = MCP-ahead warnings`. Inline summary silent if all zero.
- **Snapshot (Spec#2152, Clear-Cycle pre-reset, UNCONDITIONAL):** `last_save_deltas = state_deltas` (in-memory) — MUST be set BEFORE reset below. Single Source of Truth for this field. ⚡ Runs even when `workflow_stack` is empty — Final Block consumes this regardless of stack depth.
- **Finalize (UNCONDITIONAL):** `state_deltas` → 0, `last_save` → now, `last_reconciliation` → now (all in-memory). ⚡ Doc-only sessions REQUIRE this — otherwise `state_deltas` accumulates forever and Final Block emits the Active prompt on every subsequent save (regression of Spec#2152).
- ⚡ Do NOT archive workflows in this step. Only sync+reset.

#### 4b — After Step 5 returns (Main context, sequential)

Step 5 runs in Main; subagent may build body but Main issues `mx_create_doc` → doc_id available here without subagent-join.

- **⚡ Prune state:** see `references/pruning.md` (fail-soft: missing/unreadable → log + skip, continue 4b).
- **⚡ last_save_summary (Bug#3229 proper fix):** Update the in-memory state object:
  - `state.last_save_summary` = 1-line narrative, **max 200 chars**, describing this save's main artefacts (new/updated specs/plans/ADRs, bug-fixes, commits, WF-step-flips). NO internal reasoning, NO timestamps (those are in `last_save`). Example: `"Spec#3194 v3 + ADR#3264 + Plan#3266 (33 tasks M1-M3); Bug#3229/3230/3239 fixed (commits d327b92+577dff3)"`.
  - `state.last_save_session_note_doc_id` = doc_id returned by Step 5's `mx_create_doc`. Pointer for Resume/cross-session enrichment (Bug#3230 pairing). Always set when Step 5 succeeded.
  - Both fields are **required** (not optional). The statusline hook prefers them over events_log parsing for the `last:` display.
  - If Step 5's `mx_create_doc` failed (mcp_available=false, destructive-write block, network error) → still write `last_save_summary` with the local summary + set `last_save_session_note_doc_id = null` (signals "summary is real, but no MCP-archive link"). The degraded path is honest about the missing link instead of silently omitting the summary.
- **Write state file back** — single deferred Write applying ALL 4a+4b in-memory mutations. This is the ONLY state.json write in Step 4. See crash-resilience note at top of Step 4.
- ⚡ Token discipline: the combined write touches 5-7 fields (`last_save_deltas`, `state_deltas=0`, `last_save`, `last_reconciliation`, `last_save_summary`, `last_save_session_note_doc_id`, plus any flipped WF `unsynced`/event `synced` flags) — use Edit for surgical field updates, Write only for full rewrites. Per global rule "Edit surgical 1-5L, multi-line→Write".
- Output (aggregated): `Orchestrate: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead), deltas reset, summary written[<archive-link-suffix>]`. Suffix rules: append `" (no archive link — Step 5 failed)"` ONLY if `last_save_session_note_doc_id==null` AND `mcp_available==true` at Init (distinguishes degraded from expected-null paths). If K>0: also append at end `⚠ root-cause K step-sync failures before next session`.

### 5) Session Summary as MCP Note (MCP, Main-context synchronous)
Step 5 runs in Main; subagent may build body but Main issues `mx_create_doc` (skill runtime cannot await a background subagent — running Step 5 in background regresses Bug#3229).

⚡ **Body-Validation Gate + Subagent dispatch hardening + Archive-Fidelity Rule (Bug#3239):** see `references/body-validation.md`.
Enforce in Step 5 BEFORE `mx_create_doc`: validate length≥500 / ≥3 template sections / required-appendices preserved → fail any → Main builds local fallback (verbatim appendices). Body passed to `mx_create_doc` is NEVER empty, NEVER shorter than fallback, NEVER drops detected decision artefacts.

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

### 6) Peer Notify (MCP, only if delta > 0)
if !mcp_available → skip entire step.
`mx_session_delta(project, session_id=<state.session_id>, limit=1)`→total_changes==0→skip.
`mx_agent_peers(project)`→∅peers→skip.
1 call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 sentences>","changed_files":<count>,"project":"<slug>"}`
- Error→log, don't abort

## Final Block — Clear-Cycle Recommendation (Spec#2152)

Mode-agnostic threshold emit consuming `N` (normal: `last_save_deltas` set by Step 4; `--clear-cycle`: `state_deltas` in-flight, see Clear-Cycle section).

**Skip:** state file missing OR mode-relevant deltas field unset. Do NOT skip on empty workflow_stack — doc-only sessions can have meaningful deltas.

| N | Output | Notes |
|---|---|---|
| `>=15` | Active prompt: `Session is large (<N> deltas persisted). /clear + new session + mx_briefing is now worthwhile. Execute? (1=yes /clear / 2=no, keep working)` then wait | `--loop` downgrades to `>=10` tip (no interactive waits) |
| `>=10` | Tip line: `Tip: <N> deltas persisted. /clear + new session + mx_briefing is worthwhile when convenient.` | |
| `>=1` | Marketing: `Clear-Cycle: <N> deltas persisted. /clear + manual mx_briefing ready.` | No token-multiplier numbers (state_deltas counts DB events not transcript tokens) |
| `==0` | silent | |

⚡ PreCompact/PostCompact hooks dormant (Spec#2152, Lesson#2161 — prompt-type hooks blocked upstream); `/clear` + manual `mx_briefing` is the active path. Re-activation: `~/.claude/hooks/dormant-pre-post-compact.md`.

## Clear-Cycle Mode (`--clear-cycle`)

⚡ Manual replacement for dormant PreCompact/PostCompact hooks (Spec#2152 + Lesson#2161). Skips Steps 1-6 and runs ONLY the Final Block, using **`N = state.state_deltas`** (in-flight, NOT the stale `last_save_deltas` — Step 4 snapshot is skipped in this mode). Flag precedence: `--clear-cycle` wins over `--loop`.

Sequence:
1. Init (read state file only — no MCP roundtrip; loadState contract: corrupt/missing → empty state).
2. Skip Steps 1-6.
3. Final Block with `N = state.state_deltas`.
4. Exit (do NOT touch state_deltas, CLAUDE.md, status.md).

## Loop Mode (--loop or /loop context)

**Idempotency:** `mx_session_delta(project, session_id=<state.session_id>, limit=1)` → `total_changes`. Null session_id → skip check, normal save. **Step 4a always runs** (detects local-only divergence that produces no MCP activity); Step 4b + Step 5 skipped on idempotent branch.

**Output decision (after Step 4a counters):**

| Condition | Output |
|---|---|
| `total_changes==0` AND `N==K==W==0` AND ∅unsynced-push | `mxSave: No changes` |
| `total_changes==0` AND `any(N,K,W,unsynced)>0` | `mxSave: No session-delta; local-sync: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead)` |
| `total_changes>0` | normal save, compact 1-line-per-step output |

Constraints: !settings.local.json cleanup (manual only), !Prompts, !interactive steps, shorter session note (changes since last save). Final Block downgrades N>=15 active prompt to >=10 tip line (no interactive waits).

## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions. **Exception:** Step 4a Step-State Delta Check (intent signal — see `references/step-state-sync.md`).
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
