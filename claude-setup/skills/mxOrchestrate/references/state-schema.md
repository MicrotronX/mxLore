# mxOrchestrate State File Schema (v2)

State file: `.claude/orchestrate-state.json`. Owned by mxOrchestrate.

## Schema v2 (Spec#1161)

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

## Field `last_save_deltas` (Compact-Cycle, Spec#2152)

- Pre-reset snapshot of the `state_deltas` value captured directly before the reset in mxSave Step 4
- Default `0` if the field is missing (legacy state files are backward-compatible)
- **Single Source of Truth:** only mxSave Step 4 writes this field
- Consumers: mxSave Final Block (multi-stage threshold logic), PostCompact hook (re-brief last-save line)

## Stack rules

- `workflow_stack[0]` = active workflow
- park = move active WF to index 1+, new one at [0]
- resume = bring WF to [0] (LIFO or by ID)
- ⚡ Max 5 stack entries. >3 parked → warning "N parked WFs — recommend completing?"
- `state_deltas++`: on every step-done, ad-hoc, park, resume, start
- `events_log`: log every event immediately `{ts, type, wf, detail}`

## State operations (internal)

- `loadState()`: Read + parse file. Corrupt/missing → return empty state + warning.
- `saveState(state)`: JSON.stringify → write file.
- `addEvent(type, wf, detail)`: Push event to `events_log` + `state_deltas++`.
