#!/usr/bin/env node
// Institutional Memory PreToolUse Gate
// Two branches, one file (knowledge-dossier spec R16 — a second hook file would duplicate
// the cooldown and perf mechanics, and two copies drift apart):
//   default        -> recall gate, fires before Edit/Write on source files.
//   --knowledge    -> knowledge dossier hint, fires before Read/Grep on a path
//                     covered by a dossier in the _knowledge project.
// Cooldown: max 1 trigger per file:intent per session.
// Gate-Level interpretation: INFO/WARN/BLOCK.
// Performance: ~120ms per invocation, measured 2026-08-31 (10 runs). Almost all of
// it is the node process start itself — an empty `node -e ""` costs ~115ms on this
// machine. The "<50ms" target in the dossier spec R17 is unreachable for ANY node-based
// PreToolUse hook and was corrected in the spec rather than quietly missed.
// What IS optimised is everything after the process start: the --knowledge branch
// never reads CLAUDE.md, and on a non-matching path it returns after a single
// existsSync — no project lookup, no cooldown I/O. Read/Grep are the hottest tool
// path there is, so nothing avoidable may run there.

const fs = require('fs');
const path = require('path');
const os = require('os');

// Cooldown file persists across hook invocations within a session
const COOLDOWN_FILE = path.join(os.tmpdir(), 'claude-recall-cooldown.json');
const COOLDOWN_MAX_AGE_MS = 8 * 60 * 60 * 1000; // 8h session max

// Watch list for the --knowledge branch. Derived from the mandatory "file location"
// field of each dossier (dossier spec R8/R15) — it is never hand-maintained.
// Absent file = no dossiers = fresh install: the branch costs one existsSync and exits.
// That is the bootstrap invariant (R4): nothing needed to operate mxLore comes from the DB.
const KNOWLEDGE_CACHE = path.join(os.homedir(), '.claude', 'knowledge-paths.json');

function loadCooldown() {
  try {
    if (!fs.existsSync(COOLDOWN_FILE)) return {};
    const data = JSON.parse(fs.readFileSync(COOLDOWN_FILE, 'utf8'));
    // Expire stale cooldown data
    if (data._ts && (Date.now() - data._ts > COOLDOWN_MAX_AGE_MS)) return {};
    return data;
  } catch { return {}; }
}

function saveCooldown(cache) {
  try {
    cache._ts = Date.now();
    fs.writeFileSync(COOLDOWN_FILE, JSON.stringify(cache));
  } catch { /* best-effort */ }
}

// Hook payload arrives as JSON on STDIN ({session_id, tool_name, tool_input,
// cwd, ...}) — the same channel env-guard.js and orchestrate-reconcile.js read.
// The former env-only read (CLAUDE_TOOL_INPUT) is kept as a fallback for manual
// tests; live it was always empty, JSON.parse('') threw, and BOTH branches of
// this hook exited silently on every call (found 2026-09-01 by the first
// no-prior-knowledge test run: no hint, no cooldown file ever written).
function readHookInput() {
  try {
    if (!process.stdin.isTTY) {
      const raw = fs.readFileSync(0, 'utf8');
      if (raw && raw.trim()) return JSON.parse(raw);
    }
  } catch { /* fall through */ }
  try { return JSON.parse(process.env.CLAUDE_TOOL_INPUT || ''); } catch { return null; }
}

try {
  const parsed = readHookInput();
  if (!parsed) process.exit(0);
  // stdin shape nests the tool arguments under tool_input; the env shape is flat.
  const args = (parsed.tool_input && typeof parsed.tool_input === 'object') ? parsed.tool_input : parsed;
  const filePath = args.file_path || args.path || '';

  if (!filePath) process.exit(0);

  // --- Knowledge branch (Read|Grep matcher) -------------------------------
  // Deliberately placed before the CLAUDE.md read: on a non-matching path this
  // returns after a single existsSync, with no project lookup and no cooldown I/O.
  if (process.argv.includes('--knowledge')) {
    let entries;
    try {
      if (!fs.existsSync(KNOWLEDGE_CACHE)) process.exit(0);
      entries = JSON.parse(fs.readFileSync(KNOWLEDGE_CACHE, 'utf8')).entries;
    } catch { process.exit(0); }
    if (!Array.isArray(entries) || entries.length === 0) process.exit(0);

    const kPath = filePath.replace(/\\/g, '/').toLowerCase();
    const hit = entries.find(e => e && e.prefix && kPath.startsWith(e.prefix));
    if (!hit) process.exit(0);

    const kKey = `${path.basename(filePath)}:knowledge`;
    const kCache = loadCooldown();
    if (kCache[kKey]) process.exit(0);
    kCache[kKey] = Date.now();
    saveCooldown(kCache);

    console.log(`[Knowledge] "${path.basename(filePath)}" is covered by a knowledge dossier.
1. Call mx_detail(doc_id=${hit.doc_id}) before reasoning about ${hit.title || 'this component'}.
2. The dossier carries manufacturer, proven capabilities with file:line evidence, known landmines
   and active call sites. Prefer it over deriving the same facts from the sources again.
3. If the dossier contradicts what you find in the code, the CODE wins — then say so and update
   the dossier via mx_update_doc, so the next session does not re-derive the correction.`);
    process.exit(0);
  }
  // --- End knowledge branch ------------------------------------------------

  // Only trigger for source files
  const normPath = filePath.replace(/\\/g, '/').toLowerCase();
  const isSourceFile = normPath.includes('/src/') ||
                       normPath.includes('/admin/') ||
                       normPath.includes('/skills/') ||
                       normPath.includes('/hooks/') ||
                       normPath.endsWith('.pas') ||
                       normPath.endsWith('.js') ||
                       normPath.endsWith('.ts');

  if (!isSourceFile) process.exit(0);

  // Read CLAUDE.md to get project slug
  const claudeMd = path.join(process.cwd(), 'CLAUDE.md');
  if (!fs.existsSync(claudeMd)) process.exit(0);

  const content = fs.readFileSync(claudeMd, 'utf8');
  const slugMatch = content.match(/\*\*Slug:\*\*\s*(\S+)/);
  if (!slugMatch) process.exit(0);

  const project = slugMatch[1];
  const fileName = path.basename(filePath);
  const intent = 'implement';

  // B3.1: Cooldown — max 1 recall per file:intent per session
  const cooldownKey = `${fileName}:${intent}`;
  const cache = loadCooldown();
  if (cache[cooldownKey]) {
    // Already recalled this file:intent — silent exit
    process.exit(0);
  }

  // Mark as recalled
  cache[cooldownKey] = Date.now();
  saveCooldown(cache);

  // B3.2 + B3.3 + C1.1 + C1.2: Recall prompt with gate interpretation
  console.log(`[Recall Gate] Before you modify "${fileName}":
1. Call mx_recall(project='${project}', query='${fileName}', intent='${intent}', target_file='${filePath}').
2. Remember the recall_id from the response for later outcome update.
3. Interpret the gate object:
   - gate_level=INFO: Acknowledge hint, continue working.
   - gate_level=WARN: Lesson MUST be considered. Briefly explain how you follow the lesson. Then: mx_recall_outcome(recall_id=<ID>, outcome='acknowledged').
   - gate_level=BLOCK: STOP. Explain the lesson to the user and justify why you want to proceed anyway. Then: mx_recall_outcome(recall_id=<ID>, outcome='overridden', reason='<your justification>'). Do NOT proceed without justification.
4. If you consider lessons (INFO/WARN): mx_recall_outcome(recall_id=<ID>, outcome='acknowledged').
5. If no hits (total_lessons=0): continue without recall.`);

} catch (e) {
  process.exit(0);
}
