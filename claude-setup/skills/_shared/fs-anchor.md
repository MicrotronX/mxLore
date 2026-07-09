# FS-Anchor — Canonical Algorithm (Shared)

Doc-vs-code reality check. Both **mxOrchestrate Mode 5 (Reconciliation)** and
**mxSave Step 3 (Pre-Save Stale-Plan-Sweep)** call this helper to
verify whether a doc's "pending" / "active" status is contradicted by the real
filesystem.

⚡ This is the **algorithm** only — no I/O dispatch, no MCP calls. Callers pass
in the doc body + the items to check; the helper returns per-item verdicts.

## Inputs

| Param | Type | Notes |
|---|---|---|
| `doc_body` | string | Full markdown body of WF / Plan / Spec |
| `items` | list | Items whose state to verify. Each item: `{label, expected_state}` |

`expected_state` values per caller:
- **mxOrchestrate Mode 5:** `pending` — verify the code does NOT yet implement
  the step.
- **mxSave Step 3:** `pending` (i.e. checkbox `- [ ]` on a Plan task / Spec AC)
  — verify the code does NOT yet implement it.

Both use the same direction: "if code is present but doc says pending → diverged."

## Algorithm

### 1. Extract target files

From `doc_body` collect candidate target paths **only from structured sources**
— never from casual prose mentions:

- backtick-quoted paths in the body (`dir/file.ext`)
- the `## Interfaces / Data` section of a referenced spec (if the WF/Plan body
  links a `Spec#NNNN`)

∅ structured path references → return all items as `unverifiable` (jump to step 4).

### 2. Existence check

Default: `Glob` each extracted path — existence is the cheap, deterministic
signal. Deeper `Grep` content-check ONLY when the item label names a concrete
symbol/function — then Grep that symbol in the target file. Do not Grep
speculatively.

### 3. Per-item verdict

For each item with `expected_state == 'pending'`:

- **target files exist** (and, if a symbol was named, the symbol is present)
  → verdict `divergence: doc says pending, code says implemented`.
- **target files absent** → verdict `confirmed_pending` (no false-positive).

### 4. Unverifiable case

Doc named no structured target paths → verdict `unverifiable` for all items.
Caller MUST surface this honestly (e.g. mark `unverified against code`) — do not
promise GREEN.

## Outputs

Per-item: `{label, verdict, evidence}` where:
- `verdict` ∈ `divergence` | `confirmed_pending` | `unverifiable`
- `evidence` ∈ matched path / symbol location / `"no-structured-targets"`

## Caller responsibilities (not in helper)

- mxOrchestrate Mode 5: `divergence` → STOP + ?user (same halt semantics as the
  doc-vs-doc "Both diverged" branch — never silently overwrite).
- mxSave Step 3: all items `divergence` AND no `confirmed_pending` AND doc
  `days_since_content_change` older than `MXSAVE_STALE_THRESHOLD_DAYS` env
  (default 14) → tag `stale-suspect` + prompt user y/n/skip.
  Use `days_since_content_change`, NOT `updated_at` (`updated_at` is bumped
  by any touch incl. access_count-on-read).

## doc_type applicability

| doc_type | FS-anchor-fähig? | Reason |
|---|---|---|
| `plan` | yes | Task lines `- [ ] <action>` carry implementation targets |
| `spec` | yes | Acceptance Criteria `- [ ] <ac>` + Interfaces/Data section |
| `workflow_log` | yes | Step table with status column |
| `note` | no | No structured impl-target convention |
| `bugreport` | no | Describes failure, not impl-target |
| `feature_request` | no | User-direktive, not impl-target |
| `decision` | no | Records choice, not impl-target |

Callers MUST filter to fähig doc_types before invoking the helper. Excluded
doc_types just keep their MCP status as-is.
