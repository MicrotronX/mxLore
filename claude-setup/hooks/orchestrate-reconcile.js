#!/usr/bin/env node
// mxOrchestrate SessionStart Reconciliation Hook
// Validates orchestrate-state.json against expected schema.
// Fixes field names (v1→v2 migration), removes stale entries.
// Records the SessionStart `source`, which is the only reliable signal that the
// model's context is gone. State age answers "is my state old"; it can never
// answer "is my context empty" — a save one minute before /clear leaves a fresh
// state and an empty context. mxOrchestrate Init reads context_cleared_at.
// NOTE: Cannot call MCP from JS — full MCP reconciliation happens in mxSave.
// This hook therefore must NOT stamp last_reconciliation: that field means
// "reconciled against MCP", and claiming it here suppressed the very briefing
// the staleness check exists to trigger.
// Performance target: <100ms. Silent fail on any error.

const fs = require('fs');
const path = require('path');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');

// Hook payload arrives as JSON on stdin. Never block: a missing or unreadable
// payload degrades to "no source", which falls back to the age heuristic.
function readHookPayload() {
  try {
    if (process.stdin.isTTY) return {};
    const raw = fs.readFileSync(0, 'utf8');
    return raw ? JSON.parse(raw) : {};
  } catch (e) {
    return {};
  }
}

try {
  if (!fs.existsSync(STATE_FILE)) process.exit(0);

  const raw = fs.readFileSync(STATE_FILE, 'utf8');
  let state;
  try {
    state = JSON.parse(raw);
  } catch (e) {
    // Corrupt JSON — warn and exit (mxSave will regenerate from MCP)
    console.log('[Orchestrate] WARNING: orchestrate-state.json is corrupt. Run /mxSave for reconciliation from MCP.');
    process.exit(0);
  }

  let changed = false;

  // --- Schema v1 → v2 migration ---
  if (!state.schema_version || state.schema_version < 2) {
    state.schema_version = 2;
    state.last_reconciliation = null;
    changed = true;

    // Fix legacy field name: active_workflows → workflow_stack
    if (state.active_workflows && !state.workflow_stack) {
      state.workflow_stack = state.active_workflows;
      delete state.active_workflows;
    }
  }

  // --- Always run field sanity checks (catches v1 migration AND manual edits) ---
  const stack = state.workflow_stack || [];
  for (const wf of stack) {
    if (wf.doc_revision === undefined) { wf.doc_revision = null; changed = true; }
    if (wf.unsynced === undefined) { wf.unsynced = false; changed = true; }
    if (wf.title && !wf.name) { wf.name = wf.title; delete wf.title; changed = true; }
    // Canonical key is `id` (state-schema.md). Writers have historically emitted
    // `wf_id`; normalize instead of letting the sanity filter below delete the
    // workflow for a key-name mismatch.
    if (wf.wf_id && !wf.id) { wf.id = wf.wf_id; delete wf.wf_id; changed = true; }
  }
  const events = state.events_log || [];
  for (const ev of events) {
    if (ev.synced === undefined) { ev.synced = false; changed = true; }
  }

  // --- Ensure required fields exist ---
  if (!state.workflow_stack) { state.workflow_stack = []; changed = true; }
  if (!state.adhoc_tasks) { state.adhoc_tasks = []; changed = true; }
  if (!state.team_agents) { state.team_agents = []; changed = true; }
  if (state.state_deltas === undefined) { state.state_deltas = 0; changed = true; }
  if (state.last_save_deltas === undefined) { state.last_save_deltas = 0; changed = true; }
  if (!state.events_log) { state.events_log = []; changed = true; }
  if (state.last_reconciliation === undefined) { state.last_reconciliation = null; changed = true; }

  // --- Sanity: remove workflows with missing required fields ---
  // ⚡ Dropping a workflow is data loss. Say so — a stack that silently empties
  // itself looks identical to "no work in progress" on the next resume.
  const validStack = state.workflow_stack.filter(wf => wf.id && wf.doc_id);
  if (validStack.length !== state.workflow_stack.length) {
    const dropped = state.workflow_stack
      .filter(wf => !(wf.id && wf.doc_id))
      .map(wf => wf.id || wf.wf_id || JSON.stringify(wf).slice(0, 60));
    console.log(`[Orchestrate] WARNING: dropped ${dropped.length} malformed workflow(s) from the stack: ${dropped.join(', ')}. They are still in MCP — run /mxOrchestrate resume <id> to restore.`);
    state.workflow_stack = validStack;
    changed = true;
  }

  // --- Context-reset fact (SessionStart source) ---
  // startup | clear | compact all leave the model without the prior conversation.
  // resume restores it, so it must NOT set the flag. mxOrchestrate Init clears
  // the field once it has actually run mx_session_start.
  const source = readHookPayload().source || '';
  const contextGone = source === 'startup' || source === 'clear' || source === 'compact';
  if (contextGone) {
    state.context_cleared_at = new Date().toISOString();
    state.context_cleared_source = source;
  }

  // --- Write back if anything changed ---
  if (changed) state.last_schema_repair = new Date().toISOString();
  if (changed || contextGone) {
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n', 'utf8');
  }
  if (changed) {
    console.log('[Orchestrate] State file migrated/repaired to schema v2.');
  }
  if (contextGone) {
    const note = state.last_save_session_note_doc_id;
    console.log(
      `[mxOrchestrate] ⚡ Context reset (source=${source}) — briefing REQUIRED before any work. ` +
      `Run /mxOrchestrate resume (or mx_session_start with include_briefing=true)` +
      (note ? `; last session note: #${note}` : '') + '.'
    );
  }

  // --- Check for unsynced entries and warn ---
  const unsyncedWFs = (state.workflow_stack || []).filter(wf => wf.unsynced);
  const unsyncedEvents = (state.events_log || []).filter(ev => !ev.synced);
  if (unsyncedWFs.length > 0 || unsyncedEvents.length > 0) {
    console.log(`[Orchestrate] WARNING: ${unsyncedWFs.length} unsynced WFs, ${unsyncedEvents.length} unsynced events. /mxSave recommended for MCP sync.`);
  }

} catch (e) {
  // Silent fail
  process.exit(0);
}
