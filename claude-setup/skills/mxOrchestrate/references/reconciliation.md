# Mode 5 (Resume) — Reconciliation Deep-Dive

Called from mxOrchestrate Mode 5 when resuming a workflow. Compares local `current_step` vs MCP step count, handles divergence, enforces session-boundary sync.

## Pre-check

⚡ `doc_id` must be a positive integer. If not → remove WF from stack + warn user, skip to next WF.

## Fetch + classify

Call `mx_detail(doc_id)` → parse response:

- **Error / NotFound:** remove WF from local stack + warn user "WF deleted in MCP" → skip.
- **`status='archived'`:** ⚡ before removing, check for unsynced local work. If `wf.unsynced == true` AND `wf.current_step > 0`, the local stack holds steps marked done that were never pushed to MCP before the archive happened. Do NOT silently discard — WARN user: "WF archived in MCP but local has N unsynced steps. Options: (1) resurrect as new WF from the lost work, (2) discard local and accept MCP archive, (3) inspect both." Wait for user choice before removing from stack. If `wf.unsynced == false` OR `wf.current_step == 0`, remove from local stack + warn "WF already archived" → skip.
- **OK:** parse step table → `mcp_step` = count of done steps, `mcp_total` = count of total rows.

## Sanity

If local `current_step > total_steps` → clamp to `total_steps` + warn.

## Compare local vs MCP

Compare local `current_step` vs `mcp_step`:

- **Local > MCP (local is ahead):** push ALL locally-done steps to MCP via
  `mx_update_doc(doc_id, content with Steps=done+Timestamps, change_reason='Reconcile: Steps N-M→done')`
  → update `doc_revision` from response → set `unsynced=false`.
- **MCP > local (MCP is ahead):** update local → `current_step=mcp_step`, `total_steps=mcp_total`,
  `doc_revision` from response, `unsynced=false`.
- **Both diverged** (steps overlap with different results, e.g. team-agent vs local):
  WARN user, show both versions, ask which to keep before pushing.
- **Equal:** no action needed.

## FS-Anchor Post-Check (Bug#6813)

⚡ The doc-vs-doc compare above can yield a **false GREEN**: if the implementation
happened but neither the state file nor the MCP WF-doc was updated (e.g. the work
ran through `superpowers:executing-plans`, not the mxOrchestrate auto-invoke
step-flow), both tracking artefacts are stale *in the same direction* and the
compare looks healthy. This post-check anchors the result against the real
filesystem.

Runs AFTER the 4-way compare, as an **orthogonal override** — not a 5th compare
branch. It can overturn ANY of the four results above.

### 1. Extract target files

From the WF/Plan doc collect candidate target files **only from structured
sources** — never from casual prose mentions:

- backtick-quoted paths in the WF/Plan body (`dir/file.ext`)
- the `## Interfaces / Data` section of a referenced spec (if the WF body links a
  `Spec#NNNN`)

∅ structured path references → skip to step 4 (unverifiable).

### 2. Check existence

Default: `Glob` each extracted path — existence is the cheap, deterministic
signal. Deeper `Grep` content-check ONLY when the pending step text names a
concrete symbol/function — then Grep that symbol in the target file. Do not Grep
speculatively.

### 3. Compare against step status

For each step the compare-above classified as `pending`:

- **target files exist** (and, if a symbol was named, the symbol is present) →
  the code contradicts the doc. Do NOT report GREEN. Report
  `divergence: doc says pending, code says implemented` → **STOP + ?user**
  (same halt semantics as the "Both diverged" branch — never silently overwrite).
- **target files absent** → FS-anchor confirms `pending`; no false-positive.

### 4. Unverifiable case

WF/Plan named no structured target paths → FS-anchor cannot run. Do NOT promise
GREEN; mark the reconciliation result explicitly as `unverified against code` so
the user knows the step status rests on doc-vs-doc alone.

## Finalize

Set `state.last_reconciliation = now()`.
