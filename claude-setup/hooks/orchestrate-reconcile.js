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

  // --- events_log deterministic cap ---
  // Guarantees state.json stays lean regardless of whether mxSave Step 4b ran.
  // The Step 4b prune is a lazy-loaded, silently-skippable instruction; this hook
  // is code and runs on every SessionStart, so the cap can never be skipped.
  // synced=true events are mirrored in MCP session_notes -> local copy redundant,
  // FIFO-drop by ts is safe. synced=false events are LOCAL-ONLY (not yet pushed)
  // -> never drop; they retry on the next mxSave Step 4a push.
  const EVENTS_CAP = 30;
  const evs = state.events_log;
  const syncedTrue = evs.filter(ev => ev.synced === true);
  if (syncedTrue.length > EVENTS_CAP) {
    // Sort by parsed epoch, not raw string: ts precision varies across writers
    // (minute `...:mmZ` vs seconds `...:ss.sssZ`), and 'Z'(0x5A) > ':'(0x3A) makes
    // a naive string sort misorder same-minute mixed-precision events at the cutoff.
    const tsMs = ev => { const t = Date.parse(ev.ts); return Number.isNaN(t) ? 0 : t; };
    const keep = new Set(
      syncedTrue.slice()
        .sort((a, b) => tsMs(a) - tsMs(b))
        .slice(-EVENTS_CAP)
    );
    const before = evs.length;
    state.events_log = evs.filter(ev => ev.synced !== true || keep.has(ev));
    state.last_pruned = new Date().toISOString();
    changed = true;
    console.log(`[Orchestrate] events_log capped ${before} -> ${state.events_log.length} (kept last ${EVENTS_CAP} synced + all unsynced)`);
  }

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

  // --- Timestamp-base guard (state-schema.md → Timestamp base) ---
  // Model-written fields must be TRUE UTC. Local time carrying a `Z` lands in the
  // future; mx_session_delta(since=…) then converts it past every real change and
  // answers total_changes=0, so the tracker-gap guard reports "nothing unsaved".
  // Warn only — a genuinely skewed clock is indistinguishable from a mislabel, and
  // guessing an offset here would corrupt the field this guard exists to protect.
  // Two distinct defect shapes, two distinct checks:
  //   (a) local time WITH a `Z`  -> parses as UTC, lands in the future. Only detectable
  //       on fields whose value must be in the past. Scoped to the two guard-feeding
  //       fields; `started`/`created` feed no guard, so a future value there is noise.
  //   (b) NO `Z` at all          -> parses as local per ECMA-262, so it never looks like
  //       the future. Undetectable by (a); caught by format, on every ISO field.
  const skewCutoff = Date.now() + 120000; // tolerate clock jitter; a TZ error is >= 1h
  const futureFields = ['last_save', 'last_reconciliation'].filter(f => {
    const t = Date.parse(state[f]);
    return Number.isFinite(t) && t > skewCutoff;
  });
  if (futureFields.length > 0) {
    const verb = futureFields.length === 1 ? 'lies' : 'lie';
    console.log(
      `[Orchestrate] WARNING: ${futureFields.join(', ')} ${verb} in the future — not true UTC. ` +
      `The tracker-gap guard will report a false "nothing unsaved". ` +
      `Stamp with \`date -u +%Y-%m-%dT%H:%MZ\`; the next /mxSave rewrites the field(s).`
    );
  }

  const unlabelled = [];
  const checkIso = (val, label) => {
    if (typeof val === 'string' && val && !val.endsWith('Z')) unlabelled.push(label);
  };
  for (const f of ['last_save', 'last_reconciliation', 'last_pruned', 'context_cleared_at', 'last_schema_repair']) {
    checkIso(state[f], f);
  }
  (state.workflow_stack || []).forEach((wf, i) => checkIso(wf.started, `workflow_stack[${i}].started`));
  (state.adhoc_tasks || []).forEach((t, i) => checkIso(t.created, `adhoc_tasks[${i}].created`));
  (state.team_agents || []).forEach((a, i) => checkIso(a.spawned, `team_agents[${i}].spawned`));
  (state.events_log || []).forEach((ev, i) => checkIso(ev.ts, `events_log[${i}].ts`));
  if (unlabelled.length > 0) {
    const shown = unlabelled.slice(0, 5).join(', ');
    const more = unlabelled.length > 5 ? ` (+${unlabelled.length - 5} more)` : '';
    console.log(
      `[Orchestrate] WARNING: ${unlabelled.length} timestamp(s) without a \`Z\` suffix: ${shown}${more}. ` +
      `Unlabelled ISO strings parse as LOCAL time, so the future-check above cannot see them. ` +
      `Stamp with \`date -u +%Y-%m-%dT%H:%MZ\`.`
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
