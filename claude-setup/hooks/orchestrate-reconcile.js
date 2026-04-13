#!/usr/bin/env node
// mxOrchestrate SessionStart Reconciliation Hook
// Validates orchestrate-state.json against expected schema.
// Fixes field names (v1→v2 migration), removes stale entries.
// NOTE: Cannot call MCP from JS — full MCP reconciliation happens in mxSave.
// This hook handles: schema migration, field fixes, basic sanity checks.
// Performance target: <100ms. Silent fail on any error.

const fs = require('fs');
const path = require('path');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');

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
  const validStack = state.workflow_stack.filter(wf => wf.id && wf.doc_id);
  if (validStack.length !== state.workflow_stack.length) {
    state.workflow_stack = validStack;
    changed = true;
  }

  // --- Write back if changed ---
  if (changed) {
    state.last_reconciliation = new Date().toISOString();
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n', 'utf8');
    console.log('[Orchestrate] State file migrated/repaired to schema v2.');
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
