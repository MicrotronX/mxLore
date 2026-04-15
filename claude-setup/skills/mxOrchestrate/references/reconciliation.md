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

## Finalize

Set `state.last_reconciliation = now()`.
