---
name: mxSave
description: Use when the user says "save state", "/mxSave", "session end", "before /compact", "wrap up", or otherwise wants to persist the current mx-project state (clean settings, update CLAUDE.md + docs/status.md, create session notes in MCP-DB, sync orchestrate-state deltas, emit clear-cycle tip). Loop-capable. Fires at natural session-end boundaries.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Task, AskUserQuestion, Monitor, TaskStop
argument-hint: "[optional-notes] [--loop] [--delta-check]"
---

# /mxSave — Persist Project State (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** Hybrid — MCP work→background subagent, `.claude/` files→Main (subagents lack write perm). Long bodies (>300 words) via background subagent; mx_detail default 600 tokens.

Save agent. Persists project state for seamless session continuation.
**Hybrid:** CLAUDE.md+status.md=local. Session notes=MCP-DB.

## Execution Mode ⚡
**Phased sequential-with-parallel** (do NOT collapse into a single fan-out; race + data-dependency hazards):

1. **Main:** Init → Steps 1, 1b, 2 (settings + artifact sweep + CLAUDE.md/status.md + zombie check).
2. **Parallel phase A:** Step 3 (background subagent, `model=sonnet` per mxOrchestrate Model Tiering — MCP CRUD needs no premium; MCP-only) + Step 4a (Main, in-memory mutations). Pass `mcp_available` to Step 3 explicitly; Step 4a sends `expected_updated_at` and skips WFs already archived by Step 3. Stale-sweep: subagent returns candidates ONLY — prompts happen in Main after phase A (see Step 3). ⚡ The **FR/BR Closure-Sweep** (Step 3) runs in **Main**, not the subagent — its candidate source is this session's chat context, which the MCP-only subagent lacks.
3. **Main (synchronous):** Step 5 — `mx_create_doc(session_note)` issued from Main; subagent may build the body string but Main issues the call and captures the doc_id (skill runtime has no await-subagent primitive — running Step 5 in background would regress the deferred-write fix).
4. **Main:** Step 4b — single deferred Write applying ALL 4a + 4b mutations (incl. `last_save_summary` + `last_save_session_note_doc_id` from Step 5's return).
5. **Parallel phase B (fire-and-forget):** Step 6 Peer Notify — no join, errors logged not aborted.
6. **Main (terminal):** re-arm the agent-inbox watcher (see Terminal section) — always last, after Step 6, so the watcher stays down for the whole save.

Degraded path: Step 5 MCP call fails → Step 4b writes `last_save_summary` (local) + `last_save_session_note_doc_id=null`.

## Init
1. CLAUDE.md→`**Slug:**`=project slug. ∅slug→?user
2. mx_ping()→check MCP availability. Set `mcp_available = (ping == ok)`. Steps 3, 5, 6 reference this flag for fallback decisions instead of repeating "MCP error→fallback" inline.
3. ⚡ State file safety: If `.claude/orchestrate-state.json` is missing or unparseable, treat as empty state per the mxOrchestrate `loadState()` contract: `state_deltas=0`, `last_save_deltas=0`, `workflow_stack=[]`, `mcp_available` still set from ping result. Warn user inline ("orchestrate-state.json missing/corrupt — proceeding with empty state"). The `--delta-check` mode in this case emits nothing (N==0 silent path).
4. ⚡ **Init-Q — Quiesce the agent-inbox watcher (skip in `--delta-check`).** (Referred to as **Init-Q** everywhere else: Init numbers its own steps 1-4 and the sequential Steps do the same, so a bare "step 4" would be ambiguous next to Step 4a/4b.) The `Monitor` armed by mxOrchestrate Init 3a keeps firing during a save and pushes peer notifications into the middle of the step sequence — in a message-heavy session that interrupts repeatedly, and a late peer message can overtake the session note being written. Read `agent_watch_task_id` → `TaskStop(id)`, ignore failure (already dead is fine) → clear **both** `agent_watch_task_id` and `agent_watch_session_id`. Procedure + rationale: `~/.claude/skills/_shared/agent-watch.md` (**Stop** section).
   - ⚡ **No mode detection. Do not try to tell a pre-`/clear` save from an intermediate one** — it is neither knowable nor needed. Not knowable: the `/clear` decision is made by the Final Block at the END of the save and `no, keep working` is a valid answer, and no flag carries session-end semantics (see Delta-Check Mode: the difference between save modes is cleanup DEPTH, never session end). Not needed: the watcher is a wakeup, not a transport — stopping it loses nothing and re-arming it risks nothing (`_shared/agent-watch.md`, "What this watcher is"). Guessing "pre-`/clear`" on a session that continues would kill peer delivery for the rest of it, silently — the exact failure this step exists to avoid.
   - Clearing the fields is not cosmetic: if the save aborts before the terminal re-arm, the cleared `agent_watch_session_id` makes the next mxOrchestrate call arm a fresh watcher instead of trusting a dead task id.


## Steps (sequential)

### 1) Clean settings.local.json (LOCAL)
Read+clean `.claude/settings.local.json`:
- Remove duplicates (e.g. `python:*`+`python3:*`→keep one)
- Remove stale/one-time Bash permissions
- Bash(grep/find/ls/dir:*)→remove (Glob/Grep/Read exist)
- Keep useful entries (WebSearch, WebFetch domains, python)
- Sort logically: WebSearch→WebFetch→Bash
- ⚡ Fail-soft: auto-mode permission classifier may DENY settings.local.json edits (even pure removals get classified as self-modification) → skip + report `Step 1 skipped — settings edit denied by classifier`, do NOT retry or escalate (observed live 2026-06-10)

### 1b) Local Artifact Sweep (LOCAL, report-only)
Scan workspace for stale local artifacts — REPORT only; any delete/refresh strictly confirm-gated (AskUserQuestion). Generic patterns only (project-specific paths belong in project docs, not here):
- Superseded build/release artifacts: keep the newest ZIP + extracted-dir pair, list older ones (count+size)
- `logs/` entries older than 14d (aggregate count+size only, no per-file listing)
- `*.new` / `*.old-*` / `*.bak` leftovers from install/update scripts (repo root + bin dirs)
- Mirrored-file timestamp drift: files maintained as copies in 2+ repo locations where the designated SOURCE is older than its mirror → report (downgrade risk on next copy)
- Output: `Artifacts: <N> stale candidates (report-only)` — silent if 0. Missing dirs → skip silently. `--loop` mode: skip entire step.

### 2) Update CLAUDE.md + status.md (HYBRID — local + MCP for zombie check)
**CLAUDE.md:**
- **Weight ⚡ (BYTES, not lines):** check `wc -c CLAUDE.md` AND the longest line (`LC_ALL=C awk '{print length}' CLAUDE.md | sort -rn | head -1`). Targets: **max 40 KB total** AND **no single line above 4 KB**. Report both numbers, not just a verdict.
- ⚡ **`LC_ALL=C` is not decoration — without it the two numbers are in different units.** GNU awk counts CHARACTERS in a UTF-8 locale and BYTES in the C locale, while `wc -c` always counts bytes. Measured 2026-08-28 on one line holding two umlauts, an eszett and an arrow: `wc -c` = 19, `LC_ALL=C awk` = 19, UTF-8-locale awk = **14** — 26 % low. A German CLAUDE.md full of umlauts, `→` and `⚡` therefore passes a line gate on macOS/Linux that it fails on a C-locale machine, and the gate reports "healthy" while the file is oversized. Same failure class this whole byte rule was written to kill: a limit in the wrong unit is worse than no limit.
- ⚡ `wc -l` is NOT a weight metric and must not be used as one: a chronicle that grows in line LENGTH passes a line-count gate forever. Measured live 2026-08-28 in two projects — one at 212 lines but 163 KB / ~41k tokens (largest single entry 12.5 KB in ONE line), another at 53 lines but 32 KB with 80 % of the file inside line 11. Both read as "well under 200 lines". CLAUDE.md is loaded into every session AND every subagent fork, so bytes are the cost, and one long line costs exactly as much as the same bytes spread over 300 lines.
- Exceeded→offload domain details to `docs/reference/`, keep only reference in CLAUDE.md.
- AI-Start-Here links current. Arch changes high-level (1-3 lines/feature). !long backlogs→DB(/mxPlan). Compact: links+rules+architecture.

**⚡ Resume-pointer discipline (REPLACE, never prepend):** the single "AI-Start-Here" line in CLAUDE.md and the current-status line in status.md each point at the NEWEST session note — overwrite the existing pointer in place, do NOT prepend a new line and leave the stale one. Pointers accumulating into a changelog is a defect: one current pointer, always. ⚡ **Verify after write (local-stale guard):** grep each file for the pointer marker — it MUST appear exactly ONCE. `>1` → an older pointer survived the replace; remove all but the newest. `0` → the pointer was never written (silent Edit/Write drop, or the marker line was renamed); write it explicitly, then re-grep. Still `0` → the LOCAL fast-resume pointer is missing. Scope the claim precisely: the SAVE stays resume-capable (Step 5's MCP note is the surviving path); only the local shortcut degrades. Emit `⚠ local resume-pointer missing in <file> — local fast-resume degraded, MCP note (Step 5) still carries the session` and continue. ⚡ Fail LOUD on `0`: a missing pointer is invisible until the next session resumes into nothing. The MCP note is gated (Step 5); the local pointer must be equally stale-proof, or resume reads the wrong note.

**⚡ Status-entry discipline (REPLACE, never accumulate) — the same rule as the resume pointer, applied to the `**Status:**` chronicle:** CLAUDE.md carries the CURRENT state as **exactly ONE entry**, written in full. The entry it replaces is **REMOVED, not condensed** — it is already a duplicate: every chronicle entry carries its own `note#`, and the MCP session note is the SSoT. After replacing, ensure the section ends with a single pointer line `History → mx_search(project=<slug>, doc_type='session_note')`; write it once, never a second copy.
- ⚡ Do NOT build a "keep the last N entries, condense the rest into one-liners" rule. Three reasons, each sufficient: N condensed one-liners are themselves duplicated content that says nothing without opening the note anyway; the condensing step is per-save LLM judgement, i.e. drift surface in a loop that runs every save; and the file grows straight back after every cleanup because the rule licenses growth. One entry plus one pointer needs no mechanism and cannot drift.
- ⚡ This is what the byte gate above is FOR. A gate without this rule only reports the symptom later and louder; this rule without the gate is unenforced. Ship both or neither.
- **Where the entry lives:** the `- **Status:**` bullet inside the `## Project` section of the project CLAUDE.md (the same bullet list that carries `**Slug:**`, `**Goal:**`, `**Stack:**`). Locate it with `grep -n '^- \*\*Status:\*\*' CLAUDE.md` — that bullet, in full, IS the entry; everything the previous save appended to it goes.
- **First run on an accumulated file (migration, run once):** the bullet already holds N chronicle entries chained by `Davor:` / prose. Keep ONLY the newest entry — the one this save is about to write — and delete the rest outright. Do NOT try to salvage the older ones: each already names its `note#`, so the content survives in MCP, and salvaging is exactly the condensing step ruled out above. State the drop in the save output (`CLAUDE.md status chronicle: N entries dropped, <X> KB → <Y> KB, history in MCP`) so the deletion is visible, never silent.
- ⚡ **Verify after write (same guard as the resume pointer):** `grep -c '^- \*\*Status:\*\*' CLAUDE.md` MUST be exactly `1`, and `grep -cE '^[-*>[:space:]]*History.*mx_search' CLAUDE.md` MUST be exactly `1`. ⚡ **Anchor the pointer pattern at line start, like its neighbour.** An unanchored `History.*mx_search` also matches the STATUS ENTRY whenever that entry happens to discuss the pointer rule — measured live 2026-08-28, where a save that had just written a correct single pointer got `2` and was told to delete a correct line. The character class covers `- `, `> ` and bare-word pointer lines (projects differ), while excluding any line that starts with the `- **Status:**` bullet. `>1` → an older entry or a duplicated pointer survived; remove all but the newest. `0` on the pointer → write it explicitly, then re-grep. Then re-run the byte gate above and report the new numbers — an unverified replace is how the chronicle grew back the last time.
- ⚡ **Verify patterns are ASCII-only — always.** The pattern travels through the tool channel and the console codepage; the file being checked does not. A transcoding layer that rewrites `→` into `->` (reproduced 2026-08-28: identical pattern returns `1` through a clean channel and `0` through a transliterating one) makes grep search for something the file never contained — `0` hits on a perfectly correct file, which this step then reports fail-loud and Step 4b burns into `last_save_summary`. Write the arrow in the FILE, never in the PATTERN; bridge it with `.*`. ⚡ Do NOT "simplify" this to a bare word: `grep -c 'History'` returns `2` on any CLAUDE.md that also carries a `Build history →` line, which turns the false alarm into an instruction to delete a correct line.

**status.md:**
- **Weight ⚡ (BYTES, same unit and same `LC_ALL=C` rule as CLAUDE.md above):** `wc -c docs/status.md` AND `LC_ALL=C awk '{print length}' docs/status.md | sort -rn | head -1`. Targets: **max 4 KB total** AND **no line above 1 KB**. Report both numbers. Measured 2026-08-28 across two projects when this gate was written: 5.2 KB / longest line 364, and 18.2 KB — both over, i.e. the gate is expected to fire on first contact rather than sit silent. status.md is the LOCAL resume entry point; when it drifts, resume reads duplicated detail instead of pointers.
- ⚡ **Never delete a block that has no surviving copy.** The CLAUDE.md chronicle rule above may delete outright because every entry names its own `note#` and the MCP note IS the SSoT. status.md carries no such guarantee — backlog blocks are frequently local-only. **Mechanical test, never judgement:** a block may be removed only if `grep -oE '#[0-9]{3,}\b' <block>` finds a reference. No hit → either leave it standing, or write it to MCP FIRST (`mx_create_doc(doc_type='note')`) and put the returned `#NNNN` in its place. ⚡ The `\b` is load-bearing: without it the pattern also matches the leading digits of a CSS hex colour that happens to start with three digits, handing out a deletion permit for a block that carries no reference at all (the same false positive `check-public.sh` already guards against with the same `\b`). Never decide by reading whether content "looks recoverable" — that is per-save LLM judgement, the exact drift surface the Top-N rule was rejected for.
- ⚡ **No file backup before shortening.** The `#NNNN` test above IS the deletion proof: a block is only removed once its MCP copy is named, so there is nothing a `status.md.bak` could rescue that MCP does not already hold. A `cp -n … .bak` rule shipped in 1.2.32-1.2.34 and was removed in 1.2.35: it had no first-run marker, so EVERY save re-created the file, Step 1b then reported it as an artifact it may not delete, and the user deleted it by hand before the next save re-created it — a loop the skill built itself. Do not reintroduce a backup step; if the deletion proof is felt to be insufficient, tighten the proof, never add a second net.
- **First run on an accumulated file (migration, run once):** same shape as the CLAUDE.md chronicle migration above — remove only blocks that passed the `#NNNN` test, and state the result in the save output (`status.md: N blocks removed, <X> KB → <Y> KB, M blocks kept (no MCP reference)`) so both the deletion AND the retention are visible, never silent.
- ⚡ **Verify after write:** re-run the byte gate above and report the new numbers. An unverified shortening is how the file grew back the last time.
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
- `mx_batch_detail(doc_ids=[...])` (max 10/call, iterate) → keep only `doc_type ∈ {feature_request, bugreport}` AND `status='active'` (already-archived → drop silently, no re-archive).
- Bundle up to 4 per `AskUserQuestion`: `<type>#<id>: <title>` + `evidence: <session-reference>` + `(y=archive / n=keep-open)`. NEVER auto-archive without confirm (an ID named in passing may not be truly closed).
  - `y` → `mx_update_doc(doc_id, status='archived', change_reason='mxSave FR/BR closure-sweep: fixed/shipped this session')`
  - `n` → no-op (keep open this session).
- Output: `FR/BR-Closure: <Y> archived (of <C> session-referenced candidates)`. Silent if ∅candidates.

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

### 4) Orchestrate State Sync (HYBRID)
Read `.claude/orchestrate-state.json`. ⚡ ∅file → skip entire Step 4 (no state to sync). Otherwise execute in TWO phases per Execution Mode; all 4a/4b mutations are buffered in-memory and the state.json Write happens ONCE at the end of 4b.

⚡ **Atomic-write + concurrent-race semantics:** see `references/state-write-semantics.md` (Windows non-atomic Write, accepted state_deltas race, optional temp+rename mitigation).

#### 4a — Parallel with Step 3 (Main context, in-memory only)

- **WF-guarded sub-checks** (skip BOTH bullets if `workflow_stack` is empty — doc-only sessions have no WFs to sync):
  - **Push unsynced:** WFs with `unsynced=true` → `mx_update_doc` → flip in-memory `unsynced=false`. Events with `synced=false` → append to session note → flip in-memory `synced=true`.
  - **⚡ Step-State Delta Check** — 4-bullet contract; full algorithm + intent-not-verified rationale in `references/step-state-sync.md`:
    - **When:** each WF in `workflow_stack` with `status='active'` AND `doc_id` set; runs regardless of loop idempotency.
    - **What:** if `(local current_step - 1) > MCP done-count`, rewrite WF body's Status cells with `expected_updated_at` + `change_reason='mxSave Step4: step-state rewrite sync'`. MCP-status guard skips WFs Step 3 archived. `local-1 < MCP-count` emits warning, no write-back.
    - **On-error:** optimistic-lock / destructive-write block / FOR-UPDATE contention → log per WF, increment `K`, continue (do NOT abort Step 4).
    - **Counters (for 4b output):** `N = WFs updated`, `K = failed`, `W = MCP-ahead warnings`. Inline summary silent if all zero.
- **Snapshot (Clear-Cycle pre-reset, UNCONDITIONAL):** `last_save_deltas = state_deltas` (in-memory) — MUST be set BEFORE reset below. Single Source of Truth for this field. ⚡ Runs even when `workflow_stack` is empty — Final Block consumes this regardless of stack depth.
- **Finalize (UNCONDITIONAL):** `state_deltas` → 0, `subagent_ran_since_save` → delete the field if present (the SubagentStop hook re-sets it on the next subagent run; leaving it `true` past a save would re-trigger the tracker-gap band forever), `last_save` → now_utc, `last_reconciliation` → now_utc (all in-memory). ⚡ **now_utc = `date -u +%Y-%m-%dT%H:%MZ`, never the chat clock** — `last_save` is fed straight into `mx_session_delta(since=…)` by mxOrchestrate's tracker-gap guard, which reads the `Z` as UTC. Local time carrying a `Z` moves the cutoff into the future and the guard silently reports "nothing unsaved". Canonical rule: `mxOrchestrate/references/state-schema.md` → Timestamp base. ⚡ Doc-only sessions REQUIRE this — otherwise `state_deltas` accumulates forever and Final Block emits the Active prompt on every subsequent save (regression of the single-writer rule).
- **⚡ Auto-memory stale-WF guard (read-only, Main-only, UNCONDITIONAL):** If the session-loaded auto-memory index (`MEMORY.md`) is in context, cross-check it against `workflow_stack`: any entry marked ACTIVE / in-progress / DEFERRED for a workflow that is NOT present in the active stack (i.e. completed or archived) → flag inline: `Auto-memory still lists <WF-ID> as ACTIVE but it is not in the active stack — correct the memory entry.` Flag ONLY, NEVER auto-edit (free-text index, correction is a judgement call). Runs even when `workflow_stack` is empty — an empty stack + an ACTIVE auto-memory entry is exactly the stale-resume trap this guards. ∅auto-memory in context OR no match → silent.
- ⚡ Do NOT archive workflows in this step. Only sync+reset.

#### 4b — After Step 5 returns (Main context, sequential)

Step 5 runs in Main; subagent may build body but Main issues `mx_create_doc` → doc_id available here without subagent-join.

- **⚡ Prune state:** see `references/pruning.md` (fail-soft: missing/unreadable → log + skip, continue 4b).
- **⚡ last_save_summary (deferred-write fix):** Update the in-memory state object:
  - `state.last_save_summary` = 1-line narrative, **max 200 chars**, describing this save's main artefacts (new/updated specs/plans/ADRs, bug-fixes, commits, WF-step-flips). NO internal reasoning, NO timestamps (those are in `last_save`). Example (pattern, illustrative numbers): `"Spec#12 v3 + ADR-0003 + Plan#13 (33 tasks M1-M3); Bug#14/15/16 fixed (commits abc1234+def5678)"`.
  - `state.last_save_session_note_doc_id` = doc_id returned by Step 5's `mx_create_doc`. Pointer for Resume/cross-session enrichment (pairing). Always set when Step 5 succeeded.
  - Both fields are **required** (not optional). The statusline hook prefers them over events_log parsing for the `last:` display.
  - ⚡ **Step-2 degradation carry-over:** if Step 2 reported a missing local resume-pointer (still `0` after the explicit re-write), prefix `last_save_summary` with `[local-pointer missing] `. The terminal warning dies with the scrollback; the state file is what the next session actually reads — an invisible degradation is the defect this guard exists to prevent.
  - If Step 5's `mx_create_doc` failed (mcp_available=false, destructive-write block, network error) → still write `last_save_summary` with the local summary + set `last_save_session_note_doc_id = null` (signals "summary is real, but no MCP-archive link"). The degraded path is honest about the missing link instead of silently omitting the summary.
- **Write state file back** — single deferred Write applying ALL 4a+4b in-memory mutations. This is the ONLY state.json write in Step 4. See crash-resilience note at top of Step 4.
- ⚡ Token discipline: the combined write touches 5-7 fields (`last_save_deltas`, `state_deltas=0`, `last_save`, `last_reconciliation`, `last_save_summary`, `last_save_session_note_doc_id`, plus any flipped WF `unsynced`/event `synced` flags) — use Edit for surgical field updates, Write only for full rewrites. Per global rule "Edit surgical 1-5L, multi-line→Write".
- Output (aggregated): `Orchestrate: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead), deltas reset, summary written[<archive-link-suffix>]`. Suffix rules: append `" (no archive link — Step 5 failed)"` ONLY if `last_save_session_note_doc_id==null` AND `mcp_available==true` at Init (distinguishes degraded from expected-null paths). If K>0: also append at end `⚠ root-cause K step-sync failures before next session`.

### 5) Session Summary as MCP Note (MCP, Main-context synchronous)
Step 5 runs in Main; subagent may build body but Main issues `mx_create_doc` (skill runtime cannot await a background subagent — running Step 5 in background regresses the deferred-write fix).

⚡ **Body-Validation Gate + Subagent dispatch hardening + Archive-Fidelity Rule:** see `references/body-validation.md`.
Enforce in Step 5 BEFORE `mx_create_doc`: validate length≥500 / ≥3 template sections / required-appendices preserved → fail any → Main builds local fallback (verbatim appendices). Body passed to `mx_create_doc` is NEVER empty, NEVER shorter than fallback, NEVER drops detected decision artefacts.

⚡ **Status must be `active`:** Session-notes are finalised at save-time. Pass `status='active'` explicitly — leaving it at the server's `draft` default breaks resume-enrichment pairing in the next session.
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content, status='active')
```
**Template (all sections required — omit only if truly ∅, do NOT paraphrase absence). ⚡ Resume-Quality is the DEFAULT, not a mode: EVERY save (incl. `--loop`, incl. doc-only sessions) MUST produce a note from which a fresh `/clear` context is fully reconstructable in ONE read. The two ⚡ALWAYS sections below are never omitted — empty → literal `keine`, never dropped:**
- `## Quickstart after /clear` — ⚡ALWAYS (∅→`keine`, never omit). FIRST section. 1-sentence situation ("where we are") + `mx_briefing(project=<slug>)` hint + the single most-actionable NEXT action (file/function/task). A save you cannot resume from in one read is worthless.
- `## What was done` — numbered per work stream
- `## Changed files` — git-status / file-touch list verbatim
- `## Commits` — `<hash> — <subject>` + explicit push status (`pushed` / `NOT pushed`)
- `## Docs created this session` — enumerate ALL doc_ids created this session (notes, lessons, references, ADRs, plans, specs, bugreports, feature_requests). Format: `<type>#<id> — <title>`. Source: `mx_create_doc` tool-call returns from THIS session, NOT prose-guessed. Purpose: a fresh `/clear` session reads this block + `mx_detail` each ID to fully reconstruct the work.
- `## Next step` — if the active Plan has pending next-phase tasks (M2/M3/next milestone), enumerate them **verbatim** from the Plan body (copy `- [ ]` lines 1:1, do NOT paraphrase). Pointer-only (`see Plan#NNNN M2`) is insufficient because resume-enrichment may not fetch the Plan body.
- `## Tooling gotchas + verify` — ⚡ALWAYS (∅→`keine`, never omit). Verify commands to re-confirm state after resume (build/test/run one-liners) + non-obvious pitfalls this session hit (local-binary-vs-npx, build prerequisites, encoding traps, env quirks). Purpose: the next session re-verifies instead of re-discovering.
- `## Open bugs / TODOs` — inline code-TODOs, pending MCP findings, version-bumps pending, push-pending
- `## User notes` — explicit user corrections, feedback, near-misses
**Numbering:** mx_search(project=<slug>, doc_type='session_note', query='YYYY-MM-DD')→exists→append number
**if !mcp_available →** Fallback local `docs/plans/session-notes-YYYY-MM-DD.md`+warning

### 6) Peer Notify (MCP, only if delta > 0)
if !mcp_available → skip entire step.
`mx_session_delta(project, session_id=<state.session_id>, limit=50)`→total_changes==0→skip. ⚡ `session_id`, NOT `since`: the server derives the cutoff from `started_at`, so this call carries no client timestamp and cannot inherit a wrong timestamp base. Do not "harmonize" it to `since` — mxOrchestrate needs `since=last_save` only because at resume time the session has just begun.
⚡ `limit=50`, NOT `1`: the Final Block reuses this call's `total_changes` as a MAGNITUDE, not a boolean. Servers before the `COUNT(*)` fix return `RecordCount` of the LIMITed query, so `limit=1` pins `total_changes` to 1 and silently kills the tracker-gap guard. 50 clears every band threshold (max 15), so the band stays correct against old and new servers alike.
`mx_agent_peers(project)`→∅peers→skip.
1 call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 sentences>","changed_files":<count>,"project":"<slug>"}`
- Error→log, don't abort

## Final Block — Clear-Cycle Recommendation

Mode-agnostic threshold emit consuming `N` (normal: `last_save_deltas` set by Step 4; `--delta-check`: `state_deltas` in-flight, see Delta-Check section).

**Skip:** state file missing OR mode-relevant deltas field unset. Do NOT skip on empty workflow_stack — doc-only sessions can have meaningful deltas.

⚡ **Tracker-gap guard:** `N_eff = max(N, total_changes, F)` where `total_changes` comes from the `mx_session_delta` call Step 6 already made (reuse, do not re-query; `!mcp_available` OR `--delta-check` (Step 6 skipped, no delta data) → `N_eff = max(N, F)`), and `F = 1` if the state file had `subagent_ran_since_save == true` at Step 4 read-time, else `0` (SubagentStop-hook flag: a subagent ran since the last save; it is a boolean, not a count — the hook cannot know whether the subagent wrote to MCP, so it only prevents a false silent band; the real magnitude still comes from `total_changes`). Subagent MCP-writes bypass the `state_deltas` counter — the band must not fall back to silent when real writes happened.

| N | Output | Notes |
|---|---|---|
| `>=15` | Active prompt via AskUserQuestion tool: question=`Session is large (<N> deltas persisted). /clear + new session + mx_briefing is now worthwhile. Execute?` options: `yes, run /mxSave + suggest /clear` / `no, keep working` | `--loop` downgrades to `>=10` tip (no interactive waits) |
| `>=10` | Tip line: `Tip: <N> deltas persisted. /clear + new session + mx_briefing is worthwhile when convenient.` | |
| `>=1` | Marketing: `Clear-Cycle: <N> deltas persisted. /clear + manual mx_briefing ready.` | No token-multiplier numbers (state_deltas counts DB events not transcript tokens) |
| `==0` | silent | |

⚡ PreCompact/PostCompact hooks dormant (prompt-type hooks blocked upstream); `/clear` + manual `mx_briefing` is the active path. Re-activation: `~/.claude/hooks/dormant-pre-post-compact.md`.

## Terminal — Re-arm the agent-inbox watcher

⚡ **Runs last, always, in every mode that ran **Init-Q** (i.e. every mode except `--delta-check`) — including the degraded `!mcp_available` path and including a save that ended in errors. Re-arm per `~/.claude/skills/_shared/agent-watch.md` (**Arm** section), then write the new `agent_watch_task_id` + the current `agent_watch_session_id` into the state as a single 2-field `Edit`.

- ⚡ **Not folded into Step 4b.** Step 4b lands before Steps 5 and 6, so re-arming there would put the watcher back on the air during the session-note write — the interruption this whole change exists to prevent. The extra 2-field write is explicitly sanctioned by the state-write discipline (Edit for 1-5 fields).
- ⚡ **Unconditional re-arm, no mode branch.** A watcher armed just before a `/clear` costs nothing: the next context's mxOrchestrate Init 3a tears it down by `agent_watch_task_id` before arming its own. Skipping the re-arm to "save" that is a silent zero-benefit trade against a real risk (a session that continues loses peer delivery).
- Anything that landed in the buffer while the watcher was down is surfaced by the arm-time present-file report in the shared poll-loop contract. Nothing is lost by the quiet window — only delayed.
- Output: one line, `Agent-inbox watcher re-armed (<task-id>)`. Failure to re-arm → `⚠ agent-inbox watcher NOT re-armed — peer messages will not wake this session; run /mxOrchestrate to restore`. ⚡ Fail LOUD: a missing watcher is invisible until a peer message goes unanswered.

## Delta-Check Mode (`--delta-check`)

⚡ **Not a save:** `--delta-check` runs ONLY the Final Block (the "/clear worthwhile?" deltas recommendation). It writes no session note, no CLAUDE.md/status.md pointer, and no state. The full resume-capable save is the DEFAULT `/mxSave` (Steps 1-6, incl. the ⚡ALWAYS Quickstart + Tooling-gotchas sections in Step 5). Difference between save modes is Cleanup-DEPTH (loop = light, full = pre-clear), never "resume-capable or not" — every real save is resume-capable.

⚡ **Legacy flag:** `--clear-cycle` was the former name. It falsely implied the flag performed the Clear-Cycle *save*; it never did. Accept `--clear-cycle` as a deprecated alias for `--delta-check` and warn once (`--clear-cycle is deprecated, use --delta-check`). Do NOT silently ignore it — a dropped flag looks like a completed check.

⚡ Touches the agent-inbox watcher not at all — neither **Init-Q** (stop) nor the Terminal re-arm run in this mode. It writes nothing and finishes in seconds, so there is no step sequence to protect.

⚡ Manual replacement for dormant PreCompact/PostCompact hooks. Skips Steps 1-6 and runs ONLY the Final Block, using **`N = state.state_deltas`** (in-flight, NOT the stale `last_save_deltas` — Step 4 snapshot is skipped in this mode). Flag precedence: `--delta-check` — and its deprecated `--clear-cycle` alias, which resolves to `--delta-check` BEFORE precedence is evaluated — wins over `--loop`.

Sequence:
1. Init (read state file only — no MCP roundtrip; loadState contract: corrupt/missing → empty state).
2. Skip Steps 1-6.
3. Final Block with `N = state.state_deltas`.
4. Exit (do NOT touch state_deltas, CLAUDE.md, status.md).

## Loop Mode (--loop or /loop context)

**Idempotency:** `mx_session_delta(project, session_id=<state.session_id>, limit=1)` → `total_changes`. ⚡ `limit=1` is CORRECT here: this is a boolean `==0` test, and `total_changes==0` iff zero rows match on every server build. Contrast Step 6, whose `total_changes` the Final Block reads as a MAGNITUDE and which therefore needs `limit=50`. Null session_id → skip check, normal save. **Step 4a always runs** (detects local-only divergence that produces no MCP activity); Step 4b + Step 5 skipped on idempotent branch.

**Output decision (after Step 4a counters):**

| Condition | Output |
|---|---|
| `total_changes==0` AND `N==K==W==0` AND ∅unsynced-push | `mxSave: No changes` |
| `total_changes==0` AND `any(N,K,W,unsynced)>0` | `mxSave: No session-delta; local-sync: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead)` |
| `total_changes>0` | normal save, compact 1-line-per-step output |

Constraints: !settings.local.json cleanup (manual only), !Prompts, !interactive steps, shorter session note (changes since last save). ⚡ Whenever a loop note IS written (the `total_changes>0` branch — the idempotent `total_changes==0` branch writes no note and this does not apply), that shorter note STILL carries the two ⚡ALWAYS Step-5 sections (`## Quickstart after /clear` ≥1 line + `## Tooling gotchas + verify`) — loop is the light CLEANUP stage, not a resume-less save. Final Block downgrades N>=15 active prompt to >=10 tip line (no interactive waits).

## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions. **Exception:** Step 4a Step-State Delta Check (intent signal — see `references/step-state-sync.md`).
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback
- ⚡ events_log append (Step 4a/4b): skip the append if identical to the current LAST entry (same type+wf+detail) — consecutive-duplicate guard (duplicate step_done observed 2026-06-10; mirrors the mxOrchestrate dedupe-guard rule — keep in sync)
- ⚡ Interactive questions (all `?user` prompts incl. stale-sweep y/n/skip)→AskUserQuestion tool. !freetext-numbered-prompts

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
