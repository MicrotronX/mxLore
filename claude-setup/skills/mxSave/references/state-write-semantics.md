# Step 4 — state.json Write Semantics

Reference offloaded from SKILL.md (Step 4 atomic-write + concurrent-race notes).

## Atomic-write reality (Windows)

Plain `Write` tool against `.claude/orchestrate-state.json` is NOT OS-atomic on Windows — a mid-write crash can truncate the file. `loadState` then treats it as empty per Init §3, losing `workflow_stack`.

**For resilience:** Write to `.claude/orchestrate-state.json.tmp` first, then `Bash mv` (rename is atomic on most filesystems). If the Write tool cannot do temp-file-plus-rename, the risk is documented and accepted (mxSave at session-end is rarely interrupted).

## Concurrent state_deltas race (accepted trade-off)

Between the in-memory Snapshot in Step 4a and the deferred Write at end of Step 4b, an external mxOrchestrate auto-invoke (same session, different tool-call) can increment `state_deltas` on disk. The deferred Write overwrites those concurrent increments with `state_deltas=0` (lost).

Accepted because mxSave runs at session-end boundaries where concurrent writes are rare.

**Stronger mitigation (if needed):** Read-Modify-Write pre-Write — re-read state.json immediately before Write, preserve `(on_disk_state_deltas - pre_snapshot_value)` as the new baseline after reset.

## Single deferred Write principle (Bug#3229 fix mechanism)

All 4a + 4b mutations are buffered in-memory. The state.json Write happens ONCE at the end of 4b. This is the Bug#3229 fix mechanism — Step 4a stages mutations, Step 5 returns its doc_id synchronously, Step 4b adds `last_save_summary` + `last_save_session_note_doc_id`, then a single Write applies everything. Do NOT split into multiple Writes.
