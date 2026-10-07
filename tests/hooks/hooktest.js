// Fixture tests for the mxOrchestrate hooks. Each case runs in its own temp cwd.
// Usage: node tests/hooks/hooktest.js [hooksDir]   (default: ~/.claude/hooks)
// Not shipped: build-release.sh copies claude-setup/hooks only.
const { spawnSync } = require('child_process');
const fs = require('fs'), path = require('path'), os = require('os');
const H = path.resolve(process.argv[2] || path.join(os.homedir(), '.claude', 'hooks'));
const CANONICAL = H === path.join(os.homedir(), '.claude', 'hooks');
let pass = 0, fail = 0;

function mkcwd(state, extra = {}, prefix = 'hk-') {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  fs.mkdirSync(path.join(d, '.claude'));
  if (state !== undefined) fs.writeFileSync(path.join(d, '.claude', 'orchestrate-state.json'), typeof state === 'string' ? state : JSON.stringify(state));
  for (const [k, v] of Object.entries(extra)) fs.writeFileSync(path.join(d, '.claude', k), v);
  return d;
}
// TEMP/TMP point into the fixture so the Stop hook's last-step file never touches the real one.
function run(hook, cwd, payload, args = []) {
  const input = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const env = { ...process.env, TEMP: cwd, TMP: cwd, TMPDIR: cwd };
  const r = spawnSync('node', [path.join(H, hook), ...args], { cwd, input, encoding: 'utf8', timeout: 5000, env });
  return { out: r.stdout || '', code: r.status, err: r.stderr || '' };
}
const stateOf = d => JSON.parse(fs.readFileSync(path.join(d, '.claude', 'orchestrate-state.json'), 'utf8'));
const rawOf = d => fs.readFileSync(path.join(d, '.claude', 'orchestrate-state.json'), 'utf8');
const has = (d, f) => fs.existsSync(path.join(d, '.claude', f));
function t(name, cond, info) { if (cond) pass++; else { fail++; console.log('FAIL', name, '\n   ', JSON.stringify(info === undefined ? null : info).slice(0, 400)); } }

const WF = { id: 'WF-X', name: 'X', doc_id: 1, status: 'active', current_step: 1, total_steps: 2 };
const clean = { workflow_stack: [], state_deltas: 0, events_log: [] };
const dirty = { workflow_stack: [WF], state_deltas: 5, events_log: [], last_save_session_note_doc_id: 99 };
const full = { schema_version: 2, workflow_stack: [], adhoc_tasks: [], team_agents: [], state_deltas: 0, last_save_deltas: 0, events_log: [], last_reconciliation: null };
let d, r, a, b, c;

// ---------- static: every hook parses ----------
for (const f of fs.readdirSync(H).filter(f => f.endsWith('.js'))) {
  r = spawnSync('node', ['--check', path.join(H, f)], { encoding: 'utf8' });
  t('syntax ' + f, r.status === 0, r.stderr);
  t('no raw BOM bytes in ' + f, !fs.readFileSync(path.join(H, f), 'utf8').includes(String.fromCharCode(0xFEFF)), 0);
}

// ---------- precompact ----------
const PC = 'orchestrate-precompact.js', MARK = 'orchestrate-precompact-block.json';
d = mkcwd(dirty); r = run(PC, d, {}, ['--manual']);
t('pc manual dirty blocks', r.code === 0 && JSON.parse(r.out).decision === 'block' && /\/mxSave/.test(JSON.parse(r.out).reason), r);
t('pc block writes marker', has(d, MARK), 0);
r = run(PC, d, {}, ['--manual']);
t('pc manual retry passes silently', r.out === '' && r.code === 0, r);
d = mkcwd(dirty, { [MARK]: JSON.stringify({ ts: Date.now() - 3 * 60 * 1000 }) });
t('pc stale marker (>2min) blocks again', run(PC, d, {}, ['--manual']).out.includes('"block"'), 0);
d = mkcwd(dirty, { [MARK]: '{corrupt' });
t('pc corrupt marker blocks', run(PC, d, {}, ['--manual']).out.includes('"block"'), 0);
d = mkcwd(dirty); r = run(PC, d, { trigger: 'auto' });
t('pc auto never blocks, silent, no marker', r.out === '' && r.code === 0 && !has(d, MARK), r);
r = run(PC, mkcwd(dirty), {});
t('pc no flag + no trigger silent', r.out === '' && r.code === 0, r);
t('pc trigger=manual without flag blocks', run(PC, mkcwd(dirty), { trigger: 'manual' }).out.includes('"block"'), 0);
t('pc subagent flag alone blocks', run(PC, mkcwd({ ...clean, subagent_ran_since_save: true }), {}, ['--manual']).out.includes('subagent ran since save'), 0);
t('pc deltas as string blocks', run(PC, mkcwd({ ...clean, state_deltas: '3' }), {}, ['--manual']).out.includes('"block"'), 0);
r = run(PC, mkcwd(clean), {}, ['--manual']);
t('pc clean silent', r.out === '' && r.code === 0, r);
r = run(PC, mkcwd({ ...clean, workflow_stack: [WF] }), {}, ['--manual']);
t('pc clean + active WF silent', r.out === '' && r.code === 0, r);
r = run(PC, mkcwd(), {}, ['--manual']);
t('pc no state silent', r.out === '' && r.code === 0, r);
r = run(PC, mkcwd('{corrupt'), {}, ['--manual']);
t('pc corrupt state silent', r.out === '' && r.code === 0, r);
t('pc empty stdin + flag blocks', run(PC, mkcwd(dirty), '', ['--manual']).out.includes('"block"'), 0);
t('pc garbage stdin + flag blocks', run(PC, mkcwd(dirty), 'xx', ['--manual']).out.includes('"block"'), 0);
t('pc never emits systemMessage', !fs.readFileSync(path.join(H, PC), 'utf8').includes('systemMessage:'), 0);

// ---------- status: resume intent ----------
const ST = 'orchestrate-status.js', RES = 'RESUME intent';
const yes = ['resume', 'resume bitte', 'was können wir besser machen, resume', 'weiter', 'Weiter!', 'wo waren wir?', 'mach weiter', 'machen wir weiter', 'keep going', 'where were we', 'continue', 'fortsetzen', 'weitermachen', 'Resume\r\n'];
const no = ['weiter unten steht', 'fix bug', 'continue the loop in foo.pas', '/mxOrchestrate resume', '<task-notification> resume it', '[SYSTEM NOTIFICATION] resume', '<agent-message from=x> resume', '<command-name>/mxSave</command-name> resume', 'resumeFromRunId param', ''];
for (const p of yes) t('resume yes: ' + p, run(ST, mkcwd(clean), { prompt: p, session_id: 'S' }).out.includes(RES), p);
for (const p of no) t('resume no: ' + p, !run(ST, mkcwd(clean), { prompt: p, session_id: 'S' }).out.includes(RES), p);
t('resume intent without state file', run(ST, mkcwd(), { prompt: 'resume' }).out.includes(RES), 0);
for (const p of [42, ['resume'], null, { x: 1 }]) t('status non-string prompt ' + JSON.stringify(p), run(ST, mkcwd(clean), { prompt: p }).code === 0, p);

// ---------- status: NO_WORKFLOW dedupe / JUST_COMPLETED ----------
d = mkcwd(clean);
a = run(ST, d, { prompt: 'x', session_id: 'S1' }).out;
b = run(ST, d, { prompt: 'x', session_id: 'S1' }).out;
c = run(ST, d, { prompt: 'x', session_id: 'S2' }).out;
t('nowf first full', a.includes('MUST run'), a);
t('nowf second short', !b.includes('MUST run') && b.includes('NO_WORKFLOW'), b);
t('nowf new session full again', c.includes('MUST run'), c);
t('nowf no session_id -> full', run(ST, mkcwd(clean), { prompt: 'x' }).out.includes('MUST run'), 0);
t('nowf corrupt seen file -> full', run(ST, mkcwd(clean, { 'orchestrate-hook-seen.json': '{x' }), { prompt: 'x', session_id: 'S1' }).out.includes('MUST run'), 0);
t('status never writes the state file', (() => { const dd = mkcwd(clean); const before = rawOf(dd); run(ST, dd, { prompt: 'x', session_id: 'S' }); return rawOf(dd) === before; })(), 0);
d = mkcwd(clean);
a = run(ST, d, { hook_event_name: 'SessionStart', source: 'startup', session_id: 'S9' }).out;
b = run(ST, d, { prompt: 'fix x', session_id: 'S9' }).out;
t('sessionstart full, no resume', a.includes('MUST run') && !a.includes(RES), a);
t('first prompt after start short', b.includes('NO_WORKFLOW') && !b.includes('MUST run'), b);
t('just completed (<5min)', run(ST, mkcwd({ ...clean, events_log: [{ type: 'completed', ts: new Date().toISOString() }] }), { prompt: 'x' }).out.includes('JUST_COMPLETED'), 0);
t('completed long ago -> NO_WORKFLOW', run(ST, mkcwd({ ...clean, events_log: [{ type: 'completed', ts: new Date(Date.now() - 600000).toISOString() }] }), { prompt: 'x' }).out.includes('NO_WORKFLOW'), 0);

// ---------- status: active workflow ----------
t('status no state silent', run(ST, mkcwd(), { prompt: 'x' }).out === '', 0);
t('status empty state file silent', run(ST, mkcwd(''), { prompt: 'x' }).out === '', 0);
t('status corrupt state silent', run(ST, mkcwd('{corrupt'), { prompt: 'x' }).out === '', 0);
r = run(ST, mkcwd(dirty), { prompt: 'x' });
t('status active WF 3 lines', r.out.includes('WF-X') && r.out.includes('deltas since save: 5') && r.out.includes('last:'), r);
t('status legacy active_workflows', run(ST, mkcwd({ active_workflows: [WF] }), { prompt: 'x' }).out.includes('WF-X'), 0);
t('status +subagent', run(ST, mkcwd({ ...dirty, subagent_ran_since_save: true }), { prompt: 'x' }).out.includes('+subagent'), 0);
t('status 10 deltas tip', run(ST, mkcwd({ ...dirty, state_deltas: 12 }), { prompt: 'x' }).out.includes('consider /mxSave soon'), 0);
t('status 15 deltas compact', run(ST, mkcwd({ ...dirty, state_deltas: 15 }), { prompt: 'x' }).out.includes('cycle recommended'), 0);
t('status >3 parked', run(ST, mkcwd({ ...dirty, workflow_stack: [WF, WF, WF, WF, WF] }), { prompt: 'x' }).out.includes('4 parked workflows'), 0);
t('status garbage stdin exit 0', run(ST, mkcwd(clean), 'garbage').code === 0, 0);
t('status empty stdin exit 0', run(ST, mkcwd(dirty), '').out.includes('WF-X'), 0);

// ---------- reconcile: context flag per source ----------
const RC = 'orchestrate-reconcile.js';
for (const src of ['startup', 'clear', 'compact', 'resume', 'fork']) {
  d = mkcwd({ ...clean });
  r = run(RC, d, { source: src });
  const gone = ['startup', 'clear', 'compact'].includes(src);
  t('reconcile ' + src + ' flag', !!stateOf(d).context_cleared_at === gone && r.code === 0, r);
  t('reconcile ' + src + ' never stamps last_reconciliation', stateOf(d).last_reconciliation === null, 0);
}
d = mkcwd(full); r = run(RC, d, { source: 'banana' });
t('reconcile unknown source warns, no flag', r.out.includes("unknown SessionStart source 'banana'") && !stateOf(d).context_cleared_at, r);
d = mkcwd(full); r = run(RC, d, '');
t('reconcile empty stdin: no flag, silent', r.out === '' && !stateOf(d).context_cleared_at && r.code === 0, r);
d = mkcwd(full); a = rawOf(d); run(RC, d, { source: 'resume' });
t('reconcile resume on complete state: no write', rawOf(d) === a, 0);
r = run(RC, mkcwd(), { source: 'clear' });
t('reconcile no state silent', r.out === '' && r.code === 0, r);
d = mkcwd('{corrupt'); r = run(RC, d, { source: 'clear' });
t('reconcile corrupt: warns, file untouched', r.out.includes('corrupt') && rawOf(d) === '{corrupt', r);

// ---------- reconcile: repair / migration ----------
d = mkcwd({ active_workflows: [{ wf_id: 'WF-1', title: 'T', doc_id: 5 }] }); r = run(RC, d, { source: 'resume' });
a = stateOf(d);
t('reconcile v1 migration', a.schema_version === 2 && a.workflow_stack[0].id === 'WF-1' && a.workflow_stack[0].name === 'T' && !a.active_workflows && r.out.includes('schema v2'), { a, out: r.out });
d = mkcwd({ ...full, workflow_stack: [{ name: 'x' }, WF] }); r = run(RC, d, { source: 'resume' });
t('reconcile drops malformed WF loudly', r.out.includes('dropped 1 malformed') && stateOf(d).workflow_stack.length === 1, r);
const evs = [];
for (let i = 0; i < 15; i++) evs.push({ ts: new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString(), type: 'x', synced: true });
evs.push({ ts: '2026-01-01T00:00Z', type: 'u1', synced: false }, { ts: '2026-01-01T00:01Z', type: 'u2', synced: false });
d = mkcwd({ ...full, events_log: evs }); r = run(RC, d, { source: 'resume' });
a = stateOf(d).events_log;
t('reconcile events cap keeps 10 synced + all unsynced', a.length === 12 && a.filter(e => !e.synced).length === 2 && a.filter(e => e.synced)[0].ts.includes('00:05'), { n: a.length });
t('reconcile unsynced warning', r.out.includes('2 unsynced events'), r);
t('reconcile future last_save warns', run(RC, mkcwd({ ...full, last_save: '2099-01-01T00:00Z' }), { source: 'resume' }).out.includes('in the future'), 0);
t('reconcile timestamp without Z warns', run(RC, mkcwd({ ...full, last_save: '2026-09-29T16:09' }), { source: 'resume' }).out.includes('without a `Z` suffix'), 0);

// ---------- reconcile: handoff ----------
const HN = 'resume-handoff.md';
const hs = { ...full, last_save: '2026-09-29T16:09Z', last_save_session_note_doc_id: 4242 };
const hdr = '<!-- resume-handoff note_id=4242 last_save=2026-09-29T16:09Z -->\n## Quickstart\nX';
const REQ = 'briefing REQUIRED', LOADED = 'Resume handoff loaded';
t('handoff absent -> REQUIRED with note id', (o => o.includes(REQ) && o.includes('#4242'))(run(RC, mkcwd(hs), { source: 'clear' }).out), 0);
r = run(RC, mkcwd(hs, { [HN]: hdr }), { source: 'clear' });
t('handoff loaded: wording', r.out.includes(LOADED) && r.out.includes('UNLESS the user') && r.out.includes('## Quickstart') && r.out.includes('mx_session_start(') && r.out.includes('since="2026-09-29T16:09Z"') && r.out.includes('delete context_cleared_at') && r.out.includes('re-read the file to verify') && !r.out.includes('No MCP session is open yet') && !r.out.includes(REQ), r);
t('handoff loaded: no behind-warning when clean', !r.out.includes('handoff is behind'), r);
for (const src of ['startup', 'compact']) t('handoff loads on ' + src, run(RC, mkcwd(hs, { [HN]: hdr }), { source: src }).out.includes(LOADED), 0);
for (const src of ['resume', 'fork']) t('handoff not on ' + src, !run(RC, mkcwd(hs, { [HN]: hdr }), { source: src }).out.includes('handoff'), 0);
t('handoff with BOM loads', run(RC, mkcwd(hs, { [HN]: String.fromCharCode(0xFEFF) + hdr }), { source: 'clear' }).out.includes(LOADED), 0);
t('handoff with CRLF loads', run(RC, mkcwd(hs, { [HN]: hdr.replace(/\n/g, '\r\n') }), { source: 'clear' }).out.includes(LOADED), 0);
t('handoff umlauts survive', run(RC, mkcwd(hs, { [HN]: hdr + '\nÄnderung geprüft' }), { source: 'clear' }).out.includes('Änderung geprüft'), 0);
r = run(RC, mkcwd({ ...hs, state_deltas: 2 }, { [HN]: hdr }), { source: 'compact' });
t('handoff behind: one instruction only', r.out.includes(LOADED) && r.out.includes('handoff is behind') && r.out.includes('recommend /mxSave') && !r.out.includes('for the MCP delta'), r);
t('handoff behind: subagent flag', run(RC, mkcwd({ ...hs, subagent_ran_since_save: true }, { [HN]: hdr }), { source: 'compact' }).out.includes('subagent ran since save'), 0);
const falls = {
  'note id mismatch': [{ ...hs, last_save_session_note_doc_id: 1 }, hdr],
  'last_save mismatch': [{ ...hs, last_save: '2026-09-29T16:10Z' }, hdr],
  'active workflow': [{ ...hs, workflow_stack: [WF] }, hdr],
  'no last_save in state': [{ ...hs, last_save: undefined }, hdr],
  'malformed header': [hs, '## Quickstart\nX'],
  'header only, no newline': [hs, '<!-- resume-handoff note_id=4242 last_save=2026-09-29T16:09Z -->'],
  'empty body': [hs, '<!-- resume-handoff note_id=4242 last_save=2026-09-29T16:09Z -->\n   \n'],
  'oversize (>2048 bytes)': [hs, hdr + '\n' + 'x'.repeat(2048)],
};
for (const [name, [st, body]] of Object.entries(falls)) {
  r = run(RC, mkcwd(st, { [HN]: body }), { source: 'clear' });
  t('handoff falls back: ' + name, r.out.includes(REQ) && !r.out.includes(LOADED), r);
}
const maxBody = hdr + '\n' + 'y'.repeat(2048 - Buffer.byteLength(hdr) - 1);
r = run(RC, mkcwd(hs, { [HN]: maxBody }), { source: 'clear' });
t('handoff at the 2048-byte limit loads, output < 10000 chars', Buffer.byteLength(maxBody) === 2048 && r.out.includes(LOADED) && r.out.length < 10000, { len: r.out.length });

// ---------- subagent flag ----------
const SF = 'orchestrate-subagent-flag.js';
const flag = (payload, state = { state_deltas: 0 }) => { const dd = mkcwd(state); const rr = run(SF, dd, payload); return { d: dd, r: rr }; };
a = flag({ hook_event_name: 'SubagentStop', agent_id: 'a1', agent_type: 'general-purpose' });
t('flag: real subagent sets it', stateOf(a.d).subagent_ran_since_save === true && a.r.code === 0 && a.r.out === '', a.r);
b = rawOf(a.d); run(SF, a.d, { agent_id: 'a2', agent_type: 'Explore' });
t('flag: idempotent, no rewrite', rawOf(a.d) === b, 0);
for (const [name, p] of Object.entries({ 'no agent fields (compaction)': { hook_event_name: 'SubagentStop' }, 'empty agent_type (compaction)': { agent_id: 'a1', agent_type: '' }, 'empty stdin': '', 'garbage': 'xx' })) {
  a = flag(p);
  t('flag: ignored — ' + name, !stateOf(a.d).subagent_ran_since_save && a.r.code === 0, a.r);
}
a = flag({ agent_id: 'a1', agent_type: 'x' }, '{corrupt');
t('flag: corrupt state untouched', rawOf(a.d) === '{corrupt' && a.r.code === 0, a.r);
t('flag: no state silent', run(SF, mkcwd(), { agent_id: 'a1', agent_type: 'x' }).code === 0, 0);

// ---------- robustness: odd cwd, big state ----------
d = mkcwd(dirty, {}, 'hk spaces äö-');
t('cwd with spaces + umlauts: status', run(ST, d, { prompt: 'x' }).out.includes('WF-X'), 0);
t('cwd with spaces + umlauts: precompact', run(PC, d, {}, ['--manual']).out.includes('"block"'), 0);
t('cwd with spaces + umlauts: reconcile', !!(run(RC, d, { source: 'clear' }), stateOf(d).context_cleared_at), 0);
const big = { ...full, events_log: Array.from({ length: 3000 }, (_, i) => ({ ts: new Date(1767225600000 + i * 60000).toISOString(), type: 'x', detail: 'd'.repeat(80), synced: false })) };
for (const [hook, payload, args] of [[ST, { prompt: 'x' }, []], [RC, { source: 'clear' }, []], [PC, {}, ['--manual']], [SF, { agent_id: 'a', agent_type: 'x' }, []]]) {
  const t0 = Date.now(); r = run(hook, mkcwd(big), payload, args);
  t('big state (3000 events) ' + hook + ' < 1500ms', r.code === 0 && Date.now() - t0 < 1500, { ms: Date.now() - t0 });
}
for (const hook of [ST, RC, PC, SF]) t('stderr stays empty: ' + hook, run(hook, mkcwd(dirty), {}).err === '', 0);

// ---------- installed registration matches the shipped docs (canonical dir only) ----------
if (CANONICAL) {
  const home = path.join(os.homedir(), '.claude');
  const settings = JSON.parse(fs.readFileSync(path.join(home, 'settings.json'), 'utf8'));
  const cmds = [];
  for (const [ev, entries] of Object.entries(settings.hooks || {})) for (const e of entries) for (const h of e.hooks || []) cmds.push({ ev, matcher: e.matcher, command: h.command, timeout: h.timeout });
  // timeout unit is seconds: a ms-sized value (>= 1000) means a hung hook blocks for minutes
  for (const cm of cmds) t('timeout in seconds (< 1000): ' + cm.command, cm.timeout === undefined || cm.timeout < 1000, cm);
  t('retired step-check not registered', !cmds.some(x => /orchestrate-step-check/.test(x.command)), cmds);
  for (const cm of cmds) {
    const m = /~\/\.claude\/hooks\/([\w.-]+)/.exec(cm.command);
    if (m) t('registered hook file exists: ' + m[1], fs.existsSync(path.join(H, m[1])), cm);
  }
  const pc = settings.hooks.PreCompact || [];
  t('settings: PreCompact = one entry, matcher manual, --manual', pc.length === 1 && pc[0].matcher === 'manual' && pc[0].hooks[0].command.endsWith('orchestrate-precompact.js --manual'), pc);
  const setup = fs.readFileSync(path.join(home, 'skills', 'mxSetup', 'SKILL.md'), 'utf8');
  const snip = /"PreCompact": (\[[\s\S]*?\n\])/.exec(setup);
  t('mxSetup PreCompact snippet == installed entry', !!snip && JSON.stringify(JSON.parse(snip[1])) === JSON.stringify(pc), snip && snip[1]);
  const table = fs.readFileSync(path.join(home, 'skills', 'mxSetup', 'references', 'hooks-table.md'), 'utf8');
  for (const cm of cmds.filter(x => /orchestrate-/.test(x.command))) t('hooks-table lists: ' + cm.command, table.includes(cm.command), cm);
  const nodeRegs = table.split('`node ~/.claude/hooks/').length - 1;
  t('hooks-table: degrade count matches its rows (' + nodeRegs + ' of ' + (nodeRegs + 1) + ')', table.includes(nodeRegs + ' of ' + (nodeRegs + 1) + ' hook registrations') && setup.split(nodeRegs + ' of ' + (nodeRegs + 1) + ' hook registrations').length === 4, nodeRegs);
  const docs = ['skills/mxSetup/SKILL.md', 'skills/mxSetup/references/hooks-table.md', 'skills/mxOrchestrate/references/hooks.md', 'skills/mxOrchestrate/SKILL.md', 'skills/mxSave/references/step6-final-block.md', 'CLAUDE.md'];
  for (const f of docs) {
    const txt = fs.readFileSync(path.join(home, f), 'utf8');
    t('no stale compact claims in ' + f, !/injects anchors|shows anchors|with anchors|matcher `auto`|"matcher":"auto"|hooks dormant/.test(txt), f);
  }
}

console.log(`${H}\nPASS ${pass}  FAIL ${fail}`);
process.exit(fail ? 1 : 0);
