#!/usr/bin/env node
// mxOrchestrate UserPromptSubmit Hook — reads local state, outputs 3-line context
// JS-Gate: only output when workflow_stack is non-empty AND has active WF.
// Performance target: <50ms. Silent fail on any error.

const fs = require('fs');
const path = require('path');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');

try {
  if (!fs.existsSync(STATE_FILE)) process.exit(0);

  const raw = fs.readFileSync(STATE_FILE, 'utf8');
  if (!raw || !raw.trim()) process.exit(0);
  const state = JSON.parse(raw);

  // workflow_stack
  const stack = Array.isArray(state.workflow_stack) ? state.workflow_stack
    : Array.isArray(state.active_workflows) ? state.active_workflows
    : [];

  // Auto-Track: NO_WORKFLOW or JUST_COMPLETED signal when stack is empty
  if (stack.length === 0) {
    const events = state.events_log || [];
    const last = events.length > 0 ? events[events.length - 1] : null;
    if (last && last.type === 'completed') {
      const completedMs = new Date(last.ts).getTime();
      const nowMs = Date.now();
      if (nowMs - completedMs < 5 * 60 * 1000) {
        console.log('[mxOrchestrate] \u26a0 JUST_COMPLETED \u2014 Auto-Track aktiv');
        process.exit(0);
      }
    }
    console.log('[mxOrchestrate] \u26a0 NO_WORKFLOW \u2014 Auto-Track aktiv');
    process.exit(0);
  }

  const active = stack[0];
  if (!active) process.exit(0);
  const parkedCount = stack.length - 1;
  const adhocCount = (state.adhoc_tasks || []).length;
  const deltas = state.state_deltas || 0;
  // Derive last action from events_log (last entry) or fallback
  const events = state.events_log || [];
  const lastEvent = events.length > 0 ? events[events.length - 1] : null;
  const lastAction = lastEvent ? `${lastEvent.type}: ${lastEvent.detail || lastEvent.wf}` : '–';

  // Team agents status
  const agents = state.team_agents || [];
  const running = agents.filter(a => a.status === 'running').length;
  const done = agents.filter(a => a.status === 'done').length;
  let teamStr = 'idle';
  if (running > 0 || done > 0) {
    const parts = [];
    if (running > 0) parts.push(`${running} running`);
    if (done > 0) parts.push(`${done} done`);
    teamStr = parts.join(', ');
  }

  // 3-line context output
  const wfName = active.name || active.id || '?';
  const step = active.current_step || 0;
  const total = active.total_steps || '?';
  const wfStatus = active.status || '?';
  console.log(`[mxOrchestrate] ${active.id} ${wfName} (${step}/${total} ${wfStatus}) | parked: ${parkedCount}`);
  console.log(`  adhoc: ${adhocCount} | deltas since save: ${deltas} | team: ${teamStr}`);
  console.log(`  last: "${lastAction}"`);

  // Save warning at >= 8 deltas
  if (deltas >= 8) {
    console.log(`  ⚡ ${deltas} state deltas since last save — intermediate /mxSave recommended`);
  }

  // Stack depth warning at > 3 parked
  if (parkedCount > 3) {
    console.log(`  ⚡ ${parkedCount} parked workflows — completion recommended`);
  }
} catch (e) {
  // Silent fail: corrupt JSON, missing file, any error → no output
  process.exit(0);
}
