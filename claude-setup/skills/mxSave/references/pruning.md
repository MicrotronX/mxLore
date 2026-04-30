# mxSave Step 4b — State Pruning Algorithm

> Lazy-loaded by mxSave Step 4b only. Goal: keep `.claude/orchestrate-state.json` lean across long sessions.
> Schema bump: v2 → v3 (additive: `last_pruned`, `schema_version=3`).
> ⚡ Fail-soft: if mxSave cannot read this reference (missing/corrupt/permission) → log+skip Step 4b pruning silently, continue with `last_save_summary` write and Step 4b Write.

## Pre-conditions

- Step 4a in-memory finalize completed (`state_deltas=0`, `last_save=now`).
- ⚡ **Step 4a "Push unsynced" MUST have run before 4b.** Step 4a flushes `synced=false` events to the active session_note via `mx_update_doc append_content` and flips `synced=true` in memory. By the time 4b.2 runs, the events_log SHOULD contain only `synced=true` events plus any newly-emitted-this-session `synced=false`. If 4a was skipped or failed, 4b.2 will see a backlog (handled per its escalation rule below — never silently dropped).
- Single-writer assumption: state.json is owned exclusively by the current /mxSave invocation. Concurrent writers (mxOrchestrate auto-invoke from another tool-call) accept overwrite-loss per existing 4a "concurrent state_deltas race" note.

## 4b.1 — adhoc_tasks two-pass pruning

### Pass 1 — migrate to MCP, persist `mcp_note_id` BEFORE drop

For each `t` in `state.adhoc_tasks` where `t.mcp_note_id == null` AND `should_migrate(t)`:

```
should_migrate(t) =
  (t.status startswith "fixed-" OR "done-" OR "archived-")
  OR (now() - t.created > 14 days AND t.status startswith "later-")
```

Migration mapping:
- `fixed-` / `done-` / `archived-` → `doc_type='lesson'` if `applies_to` fields are derivable, else `doc_type='bugreport'`. `status='archived'`.
- `later-` older than 14 days → `doc_type='feature_request'`. `status='active'`.

Migration call (⚡ content parameter REQUIRED):

```
new_id = mx_create_doc(
  project=<slug>,
  doc_type=<target>,
  title=t.note[:80],          # server clamp ClampTitle=255
  content=<full t.note body>, # MUST be non-empty (server-side empty-body-guard rejects '')
  status='archived' or 'active'
)
```

⚡ **Empty-body-guard interaction:** server rejects empty `content` for high-signal doc_types (lesson, bugreport, feature_request). The note body MUST be non-empty. Verify via response `content_length > 0`.

⚡ **Long-body workaround:** if `len(body) > 5500 chars`, use the Subagent body-builder pattern (assemble body in subagent, return string, Main does the mx_create_doc) to avoid harness XML-truncation.

After successful migration:

```
Edit state.adhoc_tasks entry: t.mcp_note_id = new_id   # PERSISTED to disk BEFORE drop
```

The Edit (one operation per migrated entry, or single batch Edit at end of Pass 1) MUST land on disk before Pass 2 runs.

⚡ **Crash-safety:** if /mxSave dies between Pass 1 and Pass 2, `mcp_note_id` is durable; the next /mxSave catches the entry in Pass 2 (already-migrated, just drop) — no duplicate migration.

### Pass 2 — drop migrated entries

```
for each t in state.adhoc_tasks where t.mcp_note_id != null:
  state.adhoc_tasks.remove(t)
```

Idempotent: re-running Pass 2 on a freshly-pruned state is a no-op (all migrated entries already removed).

### Status field schema (structured token, not free text)

- `prefix` ∈ `{fixed, done, archived, later, active, in-progress}`
- optional `-<descriptor>` suffix (e.g. `fixed-2026-04-30`, `later-cleanup`)
- prefix-match operates on the `status` field (`t.status`), NOT on the `t.note` body
- Non-conforming entries are kept (NOT migrated) — defensive default

## 4b.2 — events_log dual-cap pruning

Two caps, never silently drop `synced=false`:

```
synced_true  = events_log filtered synced=true,  sorted by ts ascending
synced_false = events_log filtered synced=false, preserve original order

if len(synced_true) > 30:
  drop oldest FIFO until 30 remain

if len(synced_false) > 0 AND len(synced_false) < 50:
  log INFO in /mxSave Output: "MCP-backlog: N unsynced events — Step 4a push did not flush; events retained for next /mxSave attempt"

if len(synced_false) >= 50:
  log WARNING in /mxSave Output: "MCP-backlog approaching limit (50+ unsynced events) — investigate Step 4a failure or MCP outage"
  do NOT silently drop synced=false (data preservation)

state.events_log = synced_true_kept ++ synced_false
```

Rationale: `synced=true` events are mirrored in MCP session_notes — local copy is redundant, FIFO drop safe. `synced=false` events are LOCAL-ONLY (not yet pushed) — dropping them = data loss; they get retried by the next 4a push.

⚡ **Recovery path for stale backlog:** if `synced=false` events accumulate across many /mxSave runs (e.g. age > 7 days, 4a chronically failing), file a `feature_request` titled `synced=false Backlog Recovery` to bundle the backlog into a single MCP doc (e.g. `doc_type='backlog-recovery'`) then flip the local copies to `synced=true`. Out of scope for this pruning algorithm — pruning never drops, only retains.

## 4b.3 — schema bump + `last_pruned` stamp (commit-style FINAL Edit)

Run ONLY after 4b.1 (Pass 1+2) AND 4b.2 both completed without exception.

```
state.last_pruned = now() ISO8601
if state.schema_version == 2 OR state.schema_version is missing:
  state.schema_version = 3
```

On any 4b.1 or 4b.2 exception:
- log error
- skip 4b.3 (`schema_version` stays 2, `last_pruned` not set)
- /mxSave Output reports partial-state ("Pruning incomplete: <error>")

## Migration v2 → v3 (additive, atomic)

Pure additive. All v2 fields untouched. Two new fields:

| Field | Type | Default | Owner | Read by |
|---|---|---|---|---|
| `schema_version` | int | 3 | mxSave Step 4b | all skills (route-by-version) |
| `last_pruned` | ISO 8601 string OR null | null | mxSave Step 4b | mxSave (idempotency hint), mxOrchestrate hook (optional overdue-prune detection) |

No backup file. No migration marker. Forward-compatible: skills running on v2-aware-only code ignore the new fields. Single Edit-tool call when applied — no FS-crash-atomicity claim beyond Edit-tool semantics.

## Net token impact

Per /mxSave invocation:
- adhoc_tasks pruned: typically 5-20 entries × ~150 chars each → state.json shrinks by 1-3 KB
- events_log pruned: typically 30-100 events × ~300 chars each → state.json shrinks by 10-30 KB
- This file's load cost: ~1500 tokens, ONLY on /mxSave invocations (rare vs every-prompt CLAUDE.md)

Net positive for any session with ≥5 adhoc_tasks or ≥30 events_log entries. Smaller state.json = cheaper Read in subsequent /mxOrchestrate / /mxSave / Edit operations.

## Output line addition (Step 4b)

Append to existing `Orchestrate:` Output line: `; pruned <X> adhocs (migrated <Y> to MCP), <Z> events trimmed`. If pruning was skipped (fail-soft path): `; pruning skipped: <reason>`.
