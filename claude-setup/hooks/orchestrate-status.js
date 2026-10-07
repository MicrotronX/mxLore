#!/usr/bin/env node
// mxOrchestrate SessionStart + UserPromptSubmit Hook — reads local state.
// Active workflow → 3-line context. Empty stack → NO_WORKFLOW / JUST_COMPLETED hint
// (full text once per session). Resume/continue wording in the prompt → RESUME intent line.
// Performance target: <50ms. Silent fail on any error.

const fs = require('fs');
const path = require('path');

const STATE_FILE = path.join(process.cwd(), '.claude', 'orchestrate-state.json');

// Hook payload (stdin JSON): prompt + session_id. Empty/invalid → {}.
function readPayload() {
  try { return JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch (e) { return {}; }
}

// Resume/continue intent in DE/EN. Explicit words only — avoids firing on "weiter unten".
const RESUME_RE = /^\s*(weiter|continue|fortsetzen|weitermachen)\s*[.!]?\s*$|\b(resume|pick up where|where were we|wo waren wir|mach(en)? (wir )?weiter|keep going)\b/i;

try {
  const payload = readPayload();
  const prompt = String(payload.prompt || '');
  // Harness-injected prompts (task notifications, agent hand-backs) are not user intent.
  const injected = /<task-notification>|\[SYSTEM NOTIFICATION|<agent-message|<command-name>/i.test(prompt);
  if (!injected && RESUME_RE.test(prompt) && !/^\s*\/mxOrchestrate/i.test(prompt)) {
    console.log('[mxOrchestrate] ⚡ RESUME intent — invoke the mxOrchestrate SKILL (args "resume") FIRST, before any other tool; answer the rest of the prompt afterwards.');
  }
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
    // Fix: events_log may be reverse-chrono (newest at [0]) or chrono (newest at end).
    // Sort defensively by ts desc so we always get the truly most-recent event.
    const sortedDesc = events.map((e, i) => ({ e, i }))
      .sort((a, b) => (new Date(b.e.ts || 0) - new Date(a.e.ts || 0)) || (b.i - a.i))
      .map(x => x.e);
    const last = sortedDesc.length > 0 ? sortedDesc[0] : null;
    if (last && last.type === 'completed') {
      const completedMs = new Date(last.ts).getTime();
      const nowMs = Date.now();
      if (nowMs - completedMs < 5 * 60 * 1000) {
        console.log('[mxOrchestrate] \u26a1 JUST_COMPLETED \u2014 If this prompt is substantive work (code/fix/feature/refactor), you MUST run: /mxOrchestrate start ad-hoc "<summary>". For questions/chat/save: ignore.');
        process.exit(0);
      }
    }
    // Full directive once per Claude session (sidecar file, never the state file \u2014
    // mxOrchestrate/mxSave own that). Later prompts get a 1-line reminder.
    const seenFile = path.join(process.cwd(), '.claude', 'orchestrate-hook-seen.json');
    let seen = {};
    try { seen = JSON.parse(fs.readFileSync(seenFile, 'utf8')); } catch (e) { /* first run */ }
    const sid = payload.session_id || '';
    if (sid && seen.no_workflow_session === sid) {
      console.log('[mxOrchestrate] NO_WORKFLOW (substantive work \u2192 /mxOrchestrate start ad-hoc first)');
    } else {
      console.log('[mxOrchestrate] \u26a1 NO_WORKFLOW \u2014 If this prompt is substantive work (code/fix/feature/refactor), you MUST run: /mxOrchestrate start ad-hoc "<summary>". For questions/chat/save: ignore.');
      try { fs.writeFileSync(seenFile, JSON.stringify({ no_workflow_session: sid }) + '\n', 'utf8'); } catch (e) { /* ignore */ }
    }
    process.exit(0);
  }

  const active = stack[0];
  if (!active) process.exit(0);
  const parkedCount = stack.length - 1;
  const adhocCount = (state.adhoc_tasks || []).length;
  const deltas = state.state_deltas || 0;
  // Proper fix: prefer explicit last_save_summary field (written by mxSave Step 4,
  // max 200 chars, narrative pointer). Fallback to events_log ts-desc sort for backward-compat
  // with pre-fix state files.
  const events = state.events_log || [];
  const sortedEvents = events.map((e, i) => ({ e, i }))
    .sort((a, b) => (new Date(b.e.ts || 0) - new Date(a.e.ts || 0)) || (b.i - a.i))
    .map(x => x.e);
  const lastEvent = sortedEvents.length > 0 ? sortedEvents[0] : null;
  const lastAction = state.last_save_summary
    ? `mxsave: ${state.last_save_summary}`
    : (lastEvent ? `${lastEvent.type}: ${lastEvent.detail || lastEvent.wf}` : '–');

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
  // SubagentStop-hook flag: a subagent ran since the last save. Boolean, not a
  // count — surfaced so a deltas=0 line cannot read as "nothing unsaved".
  const subagentFlag = state.subagent_ran_since_save === true ? ' +subagent' : '';
  console.log(`  adhoc: ${adhocCount} | deltas since save: ${deltas}${subagentFlag} | team: ${teamStr}`);
  console.log(`  last: "${lastAction}"`);

  // Save warning, same bands as the skill's save-signal line (10 tip, 15 compact)
  if (deltas >= 15) {
    console.log(`  ⚡ ${deltas} deltas since save - /mxSave + /compact cycle recommended`);
  } else if (deltas >= 10) {
    console.log(`  ⚡ ${deltas} deltas since save - consider /mxSave soon`);
  }

  // Stack depth warning at > 3 parked
  if (parkedCount > 3) {
    console.log(`  ⚡ ${parkedCount} parked workflows — completion recommended`);
  }
} catch (e) {
  // Silent fail: corrupt JSON, missing file, any error → no output
  process.exit(0);
}
