#!/usr/bin/env node
// mxOrchestrate PreCompact Hook (type: command — the decision reads the state file).
// One job: a manual /compact with unsaved work is blocked once with "run /mxSave first".
// Auto-compact is never blocked (context is full). Nothing is injected: PreCompact output
// cannot reach the model or the summary — SessionStart (source=compact) re-briefs instead.
// No state file / clean state → silent pass. Silent fail on any error.

const fs = require('fs');
const path = require('path');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');
const MARK_FILE = path.join(process.cwd(), '.claude', 'orchestrate-precompact-block.json');
const RETRY_WINDOW_MS = 2 * 60 * 1000;

function readPayload() {
  try { return JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch (e) { return {}; }
}

try {
  // settings.json registers matcher "manual" with --manual; payload.trigger (documented) covers a registration without the flag.
  const manual = process.argv.includes('--manual') || readPayload().trigger === 'manual';
  if (!manual || !fs.existsSync(STATE_FILE)) process.exit(0);
  const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));

  const deltas = Number(state.state_deltas) || 0;
  const subagent = state.subagent_ran_since_save === true;
  if (deltas === 0 && !subagent) process.exit(0);

  // Retry escape hatch: a second manual /compact inside the window passes (user insists).
  let lastBlock = 0;
  try { lastBlock = JSON.parse(fs.readFileSync(MARK_FILE, 'utf8')).ts || 0; } catch (e) { /* none */ }
  if (Date.now() - lastBlock <= RETRY_WINDOW_MS) process.exit(0);

  try { fs.writeFileSync(MARK_FILE, JSON.stringify({ ts: Date.now() }) + '\n', 'utf8'); } catch (e) { /* ignore */ }
  const why = `${deltas} deltas since save` + (subagent ? ', subagent ran since save' : '');
  console.log(JSON.stringify({
    decision: 'block',
    reason: `[mxOrchestrate] Unsaved work (${why}). Run /mxSave first, then /compact. ` +
      `Run /compact again within 2 min to compact anyway.`
  }));
} catch (e) {
  process.exit(0);
}
