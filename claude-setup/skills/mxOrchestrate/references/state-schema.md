# mxOrchestrate State File Schema (v3)

State file: `.claude/orchestrate-state.json`. Owned by mxOrchestrate.

## Single-writer assumption (cross-skill invariant)

state.json is single-writer per /mxSave or /mxOrchestrate invocation. Concurrent writers (e.g. /mxSave running while /mxOrchestrate auto-invoke fires from another tool-call) accept overwrite-loss per Step 4 "concurrent state_deltas race" note in mxSave SKILL.md. Stronger mitigation (file-lock, Read-Modify-Write pre-Write) is documented as a deferred hardening — current sessions trust the rarity of true concurrent writes in interactive flows.

## Schema v3 (additive over v2 — the MCP-first step-update spec + token-efficiency-pass-v1)

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

## Timestamp base ⚡ (every ISO field in this file)

All timestamps are **true UTC** with a `Z` suffix — never local time wearing a `Z`.
Covers `last_save`, `last_reconciliation`, `last_pruned`, `events_log[*].ts`,
`workflow_stack[*].started`, `adhoc_tasks[*].created`, `team_agents[*].spawned`,
`context_cleared_at`, `last_schema_repair`.

Produce it, do not estimate it: `date -u +%Y-%m-%dT%H:%MZ`. The chat-visible clock and
plain `date` are local time; stamping those with a `Z` mislabels them.

**Why this is load-bearing:** the tracker-gap guard passes `last_save` straight into
`mx_session_delta(since=…)`. The server reads the `Z` as UTC and converts into the DB's
local time (`ISO8601ToDate(s, False)`, `mx.Tool.Session.pas`). A local timestamp labelled
`Z` thus lands `UTC_OFFSET` hours in the **future**: the cutoff outruns every real change,
`total_changes` returns `0`, and the guard reports "nothing unsaved" while writes sit in
MCP. Reproduced live at UTC+2 — `since=13:02Z` → server echo `15:02:00` → `total_changes=0`;
the same query at `11:02Z` → echo `13:02:00` → 2 changes.

The SessionStart hook already writes true UTC (`new Date().toISOString()`). A file whose
model-written fields are local is therefore internally inconsistent: two bases, one suffix.

**Legacy `events_log[*].ts`:** entries written before this rule carry local time with a `Z`.
No *correctness* guard reads them; their one consumer is the `<N>h ago` rendering in the
Output-discipline rule (SKILL.md), which for a legacy entry can therefore be off by the UTC
offset. They were deliberately left untouched, because rewriting ~30 lines of a live state
file is real risk against a cosmetic gain. Entries from this rule onward are UTC. Do not
"fix" them in bulk; they age out via pruning.

**Detector:** the hook warns when `last_save` or `last_reconciliation` lies in the future
relative to real UTC. That is exactly the window in which this defect bites the clear-cycle
(a save less than `UTC_OFFSET` hours before the resume). It warns only — it never guesses an
offset and rewrites, because a genuinely skewed clock is indistinguishable from a mislabel.

### v2 → v3 additive fields

| Field | Type | Default | Owner | Notes |
|---|---|---|---|---|
| `schema_version` | int | `3` | mxSave Step 4b.3 | bumped commit-style after 4b.1+4b.2 succeed |
| `last_pruned` | ISO 8601 OR null | `null` | mxSave Step 4b.3 + `orchestrate-reconcile.js` | `null` = never pruned. Stamped whenever the SessionStart hook caps `events_log` (last 30 `synced=true`, all `synced=false` kept) or mxSave Step 4b.3 runs. |
| `adhoc_tasks[*].status` | string OR null | `null` | mxOrchestrate Mode 3 + caller | structured token (prefix ∈ `{fixed,done,archived,later,active,in-progress}` + opt `-<suffix>`); used by mxSave Step 4b.1 for migration triage |
| `context_cleared_at` | ISO 8601 OR absent | absent | SessionStart hook (`orchestrate-reconcile.js`) writes, mxOrchestrate Init deletes | Set when SessionStart fires with `source ∈ {startup, clear, compact}` — the model has no prior conversation. `source=resume` does NOT set it. Init reads it as the PRIMARY staleness signal and deletes it after `mx_session_start`. The `age`-based check is only the fallback for hooks that predate this field. |
| `context_cleared_source` | string OR absent | absent | same as above | The raw `source` value, kept for diagnosis. |
| `last_schema_repair` | ISO 8601 OR absent | absent | SessionStart hook | When the hook last normalized fields. ⚡ Deliberately NOT `last_reconciliation`: JS hooks cannot reach MCP, so they must not stamp a field that asserts an MCP reconciliation happened. |

### Migration

Skills running with v2-aware-only code IGNORE the new fields. mxSave Step 4b.3 silently bumps `schema_version` and stamps `last_pruned` on the next /mxSave after upgrade. No backup file. No migration marker.

## Field `last_save_deltas` (Compact-Cycle, the single-writer rule)

- Pre-reset snapshot of the `state_deltas` value captured directly before the reset in mxSave Step 4
- Default `0` if the field is missing (legacy state files are backward-compatible)
- **Single Source of Truth:** only mxSave Step 4 writes this field
- Consumers: mxSave Final Block (multi-stage threshold logic), PostCompact hook (re-brief last-save line). **Note (corrected):** mxOrchestrate Mode 5/6/Auto-Invoke output emits a deltas-band line based on the LIVE counter `state_deltas` (deltas since last save reset), NOT on the pre-reset snapshot `last_save_deltas`. `last_save_deltas` is informational-only outside mxSave; mxOrchestrate never writes either field per the single-writer rule (SSoT).

## Stack rules

- `workflow_stack[0]` = active workflow
- park = move active WF to index 1+, new one at [0]
- resume = bring WF to [0] (LIFO or by ID)
- ⚡ Max 5 stack entries. >3 parked → warning "N parked WFs — recommend completing?"
- `state_deltas++`: on every step-done, ad-hoc, park, resume, start
- `events_log`: log every event immediately `{ts, type, wf, detail}`
- ⚡ **`events_log[*].detail` content rule:** detail MUST be a FACTUAL fragment that survives cross-session re-read without propagating hallucinations.
  - **Forbidden in `detail`:** relative temporal natural language — `gestern`, `heute`, `vorhin`, `yesterday`, `today`, `earlier`, `just now`, `soon`, `recently`. Any subagent reading the state file on the next call will echo the adverb as if it were ground truth (live-reproduced in a sibling project).
  - **Allowed in `detail`:** doc_ids (e.g. `doc#12`), WF-IDs (e.g. `WF-2026-04-15-007`), step summaries (e.g. `Step 2 → done, 8 AC + 4 OQ`), ISO-8601 timestamps when a past time must be referenced (e.g. `completed at 2026-04-15T17:24:38`).
  - **Recommended template:** `<action>: <what> (doc#<id>, WF=<wf-id>, <count>=<N>)`. Examples: `step_done: spec created (doc#12, WF=WF-2026-04-15-007, AC=8)`, `start: new-feature FR#12 (template=new-feature, doc#13)`.
  - **Reader protocol:** any downstream skill reading `events_log[*].detail` MUST treat the field as audit-log only — recompute temporal relations from `events_log[*].ts` (ISO-8601 UTC per the Timestamp base rule above), never parse adverbs out of `detail`.

## State operations (internal)

- `loadState()`: Read + parse file. Corrupt/missing → return empty state + warning.
- `saveState(state)`: JSON.stringify → write file.
- `addEvent(type, wf, detail)`: Push event to `events_log` + `state_deltas++`. `ts` = `date -u +%Y-%m-%dT%H:%MZ` (Timestamp base rule).
