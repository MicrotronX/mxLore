#!/usr/bin/env node
// mxOrchestrate Stop-Hook — JS Gate for step-completion check
// Reads local state; if active workflow exists AND step progressed, outputs prompt.
// Tracks last-seen step in temp file to avoid redundant output.
// If no active WF or no step progress → silent exit (0 tokens consumed).
// Performance target: <50ms. Silent fail on any error.

const fs = require('fs');
const path = require('path');
const os = require('os');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');
const LAST_STEP_FILE = path.join(os.tmpdir(), 'mxOrchestrate-last-step.json');

try {
  if (!fs.existsSync(STATE_FILE)) process.exit(0);

  const raw = fs.readFileSync(STATE_FILE, 'utf8');
  if (!raw || !raw.trim()) process.exit(0);
  const state = JSON.parse(raw);

  const stack = Array.isArray(state.workflow_stack) ? state.workflow_stack : [];
  if (stack.length === 0) process.exit(0);

  const active = stack[0];
  if (!active || active.status !== 'active') process.exit(0);

  const currentStep = active.current_step || 0;
  const wfId = active.id || '';

  // Step-progress gate: compare with last-seen step
  let lastSeen = { wfId: '', step: -1 };
  try {
    if (fs.existsSync(LAST_STEP_FILE)) {
      lastSeen = JSON.parse(fs.readFileSync(LAST_STEP_FILE, 'utf8'));
    }
  } catch (_) { /* corrupt temp file → treat as no history */ }

  // Same workflow, same step → no progress → silent exit
  if (lastSeen.wfId === wfId && lastSeen.step === currentStep) {
    process.exit(0);
  }

  // Update last-seen step (fire-and-forget, non-blocking)
  try {
    fs.writeFileSync(LAST_STEP_FILE, JSON.stringify({ wfId, step: currentStep }));
  } catch (_) { /* temp write fail is non-critical */ }

  // Find next pending step info from MCP doc (we only have local metadata)
  const stepNum = currentStep + 1;
  const totalSteps = active.total_steps || '?';
  const wfName = active.name || active.id;
  const docId = active.doc_id;

  // Output prompt for Claude to evaluate step completion
  console.log(`[Orchestrate Step-Check] Active workflow: "${wfName}" (${active.id}), Step ${stepNum}/${totalSteps}, doc_id=${docId}.`);
  console.log(`Did you complete a step of this workflow in your last response?`);
  console.log(`- If YES: mx_update_doc(doc_id=${docId}) with Step=${stepNum} as done + timestamp + one-line result. Then update orchestrate-state.json: current_step=${stepNum}, event in events_log, state_deltas++.`);
  console.log(`- If NO: No action needed.`);
  console.log(`- On MCP error: write orchestrate-state.json with unsynced=true.`);
} catch (e) {
  // Silent fail
  process.exit(0);
}
