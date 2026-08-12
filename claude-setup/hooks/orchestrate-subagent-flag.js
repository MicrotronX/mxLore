#!/usr/bin/env node
// mxOrchestrate SubagentStop Hook — tracker-gap bridge
// Sets a single boolean `subagent_ran_since_save: true` in orchestrate-state.json.
// Why a boolean, not a counter: this hook cannot know whether the subagent
// actually wrote to MCP (an Explore agent reads only), so counting would lie.
// The flag only widens the tracker-gap net: mxSave Step 4 and the mxOrchestrate
// tracker-gap guard treat it like state_deltas >= 1 and verify the real delta
// via mx_session_delta. mxSave clears the flag on its counter reset.
// Performance target: <100ms. Silent fail on any error. Write only on change.

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
    // Corrupt JSON — never write over it; the reconcile hook already warns.
    process.exit(0);
  }

  if (state.subagent_ran_since_save === true) process.exit(0); // idempotent, no write

  state.subagent_ran_since_save = true;
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n', 'utf8');
} catch (e) {
  // Silent fail
  process.exit(0);
}
