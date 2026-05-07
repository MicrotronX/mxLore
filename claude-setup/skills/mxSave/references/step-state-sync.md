# Step 4a — Step-State Delta Check (Bug#3281)

Reference offloaded from SKILL.md. The 4-bullet contract in SKILL.md remains the authoritative summary; this file holds the full algorithm and rationale.

## Scope

For each WF in `workflow_stack` where `status='active'` AND `doc_id` is set. Runs REGARDLESS of loop idempotency (Bug#3281 scenario produces no MCP activity — local-only step-flips are EXPECTED to coexist with `total_changes==0`).

## Algorithm

1. `mx_detail(wf.doc_id, max_content_tokens=0)` — **unlimited** (0 = no truncation); full body is needed for rebuild, any truncation causes silent data loss on write-back.
2. **MCP status guard (Bug#3281 race with Step 3):** if `data.status != 'active'` (Step 3 background may have archived this WF in the same tick) → skip, do NOT revive.
3. Count MCP done-steps: iterate step-table rows (authoritative template per mxOrchestrate WF Markdown: `| # | Step | Skill | Status | Result | Timestamp |`). Split each row by `|`, check the **Status column (4th content cell, 1-indexed, trimmed)** equals `done` case-insensitive. Do NOT grep `| done |` globally — the word "done" in Step/Skill/Result cells would false-positive the count.
4. Compare `(local current_step - 1)` vs MCP done-count:
   - `local-1 > MCP done-count` → local ahead, sync needed:
     - Take `data.content` verbatim, rewrite only the Status cells: rows 1..(current_step-1) → `done`, remaining rows keep their existing status (usually `pending`). Preserve all appendices/metadata/headers/non-step-table sections verbatim.
     - `mx_update_doc(doc_id, content=<full rewritten body>, change_reason='mxSave Step4: step-state rewrite sync', expected_updated_at=data.updated_at)` — `rewrite` keyword bypasses Bug#3018 50%-length-gate; `expected_updated_at` prevents overwriting a concurrent Step 3 archive.
     - On error (optimistic-lock / destructive-write block / FOR-UPDATE contention) → log `WF #<id>: step-sync failed (<error>)`, continue to next WF, do NOT abort the whole Step 4. Counter `K` increments.
   - `local-1 == MCP done-count` → skip (already in sync).
   - `local-1 < MCP done-count` → **MCP ahead of local** (local state.json stale, probably from another session/agent): emit warning `Step-sync: WF #<id> MCP ahead (MCP=<a>, local=<b>) — state.json may need reconciliation via mxOrchestrate resume`, do NOT write back. Counter `W` increments.

## Counters

Track in-memory for 4b Output aggregation: `N = WFs updated`, `K = failed`, `W = MCP-ahead warnings`.

Emit inline summary: `Step-sync: <N> updated, <K> failed, <W> MCP-ahead warnings` (silent if all zeroes). ∅active WFs with doc_id → skip silently.

## Token-budget caveat

This check writes full WF bodies in MCP (not the state.json file) — budget ~1-2 MCP calls per active WF with doc_id. Typical: 2-5 WFs × 2 calls = 4-10 MCP calls added to Step 4.

## Intent-not-verified caveat (CANONICAL — interaction with Rules §"confirmed-implemented as done")

This sync marks rows `done` based on the local `current_step` counter as an **intent signal** — it does NOT independently re-verify the step's work was completed.

Rationale: mxOrchestrate is the authoritative step-lifecycle owner for INTERACTIVE flows (Spec#1161 MCP-First Step-Update). Bug#3281 shows that subagents with direct state.json Write access can ALSO increment `current_step` WITHOUT going through that contract. mxSave trusts whatever wrote `current_step` (explicit trust in the writer, not in mxOrchestrate per se).

A hostile or buggy subagent can cause unwarranted step-flips in MCP via this path — accepted risk at present. The Rules ban on "assumptions" is overridden here by the owning-skill-trust principle.

Future refactors of Step 4a that add independent step-verification are welcome but not required.
