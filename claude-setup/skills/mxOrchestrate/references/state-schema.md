# mxOrchestrate State File Schema (v3)

State file: `.claude/orchestrate-state.json`. Owned by mxOrchestrate.

## Single-writer assumption (cross-skill invariant)

state.json is single-writer per /mxSave or /mxOrchestrate invocation. Concurrent writers (e.g. /mxSave running while /mxOrchestrate auto-invoke fires from another tool-call) accept overwrite-loss per Step 4 "concurrent state_deltas race" note in mxSave SKILL.md. Stronger mitigation (file-lock, Read-Modify-Write pre-Write) is documented as a deferred hardening — current sessions trust the rarity of true concurrent writes in interactive flows.

## Schema v3 (additive over v2 — Spec#1161 + token-efficiency-pass-v1)

```json
{
  "schema_version": 3,
  "session_id": "<int|null>",
  "workflow_stack": [{"id","name","doc_id","doc_revision","status","current_step","total_steps","started","unsynced"}],
  "adhoc_tasks": [{"note","created","origin_workflow","mcp_note_id","status"}],
  "team_agents": [{"id","task","origin_workflow","spawned","status","workflow_id"}],
  "state_deltas": "<int>",
  "last_save_deltas": "<int>",
  "last_save": "<ISO|null>",
  "last_pruned": "<ISO|null>",
  "last_reconciliation": "<ISO|null>",
  "events_log": [{"ts","type","wf","detail","synced"}]
}
```

### v2 → v3 additive fields

| Field | Type | Default | Owner | Notes |
|---|---|---|---|---|
| `schema_version` | int | `3` | mxSave Step 4b.3 | bumped commit-style after 4b.1+4b.2 succeed |
| `last_pruned` | ISO 8601 OR null | `null` | mxSave Step 4b.3 | `null` = never pruned (legacy v2 file) |
| `adhoc_tasks[*].status` | string OR null | `null` | mxOrchestrate Mode 3 + caller | structured token (prefix ∈ `{fixed,done,archived,later,active,in-progress}` + opt `-<suffix>`); used by mxSave Step 4b.1 for migration triage |

### Migration

Skills running with v2-aware-only code IGNORE the new fields. mxSave Step 4b.3 silently bumps `schema_version` and stamps `last_pruned` on the next /mxSave after upgrade. No backup file. No migration marker.

## Field `last_save_deltas` (Compact-Cycle, Spec#2152)

- Pre-reset snapshot of the `state_deltas` value captured directly before the reset in mxSave Step 4
- Default `0` if the field is missing (legacy state files are backward-compatible)
- **Single Source of Truth:** only mxSave Step 4 writes this field
- Consumers: mxSave Final Block (multi-stage threshold logic), PostCompact hook (re-brief last-save line). **Note (Bug#2989 Finding 3, corrected):** mxOrchestrate Mode 5/6/Auto-Invoke output emits a deltas-band line based on the LIVE counter `state_deltas` (deltas since last save reset), NOT on the pre-reset snapshot `last_save_deltas`. `last_save_deltas` is informational-only outside mxSave; mxOrchestrate never writes either field per Spec#2152 SSoT.

## Stack rules

- `workflow_stack[0]` = active workflow
- park = move active WF to index 1+, new one at [0]
- resume = bring WF to [0] (LIFO or by ID)
- ⚡ Max 5 stack entries. >3 parked → warning "N parked WFs — recommend completing?"
- `state_deltas++`: on every step-done, ad-hoc, park, resume, start
- `events_log`: log every event immediately `{ts, type, wf, detail}`
- ⚡ **`events_log[*].detail` content rule (Bug#2989 Findings 2+5):** detail MUST be a FACTUAL fragment that survives cross-session re-read without propagating hallucinations.
  - **Forbidden in `detail`:** relative temporal natural language — `gestern`, `heute`, `vorhin`, `yesterday`, `today`, `earlier`, `just now`, `soon`, `recently`. Any subagent reading the state file on the next call will echo the adverb as if it were ground truth (live-reproduced in mxTicketSystem Session #255, doc#2989).
  - **Allowed in `detail`:** doc_ids (e.g. `doc#2988`), WF-IDs (e.g. `WF-2026-04-15-007`), step summaries (e.g. `Step 2 → done, 8 AC + 4 OQ`), ISO-8601 timestamps when a past time must be referenced (e.g. `completed at 2026-04-15T17:24:38`).
  - **Recommended template:** `<action>: <what> (doc#<id>, WF=<wf-id>, <count>=<N>)`. Examples: `step_done: spec created (doc#2988, WF=WF-2026-04-15-007, AC=8)`, `start: new-feature FR#2800 (template=new-feature, doc#2987)`.
  - **Reader protocol:** any downstream skill reading `events_log[*].detail` MUST treat the field as audit-log only — recompute temporal relations from `events_log[*].ts` (which is ISO-8601 and trustworthy), never parse adverbs out of `detail`.

## State operations (internal)

- `loadState()`: Read + parse file. Corrupt/missing → return empty state + warning.
- `saveState(state)`: JSON.stringify → write file.
- `addEvent(type, wf, detail)`: Push event to `events_log` + `state_deltas++`.
