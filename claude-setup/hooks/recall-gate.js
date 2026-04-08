#!/usr/bin/env node
// Institutional Memory PreToolUse Gate (Spec#1198, B3 Plan#1231)
// Fires before Edit/Write on source files.
// Cooldown: max 1 recall per file:intent per session.
// Gate-Level interpretation: INFO/WARN/BLOCK.
// Performance target: <50ms.

const fs = require('fs');
const path = require('path');
const os = require('os');

// Cooldown file persists across hook invocations within a session
const COOLDOWN_FILE = path.join(os.tmpdir(), 'claude-recall-cooldown.json');
const COOLDOWN_MAX_AGE_MS = 8 * 60 * 60 * 1000; // 8h session max

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

try {
  const toolInput = process.env.CLAUDE_TOOL_INPUT || '';

  let filePath = '';
  try {
    const parsed = JSON.parse(toolInput);
    filePath = parsed.file_path || parsed.path || '';
  } catch (e) {
    process.exit(0);
  }

  if (!filePath) process.exit(0);

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
  console.log(`[Recall Gate] Bevor du "${fileName}" aenderst:
1. Rufe mx_recall(project='${project}', query='${fileName}', intent='${intent}', target_file='${filePath}') auf.
2. Merke dir die recall_id aus der Response fuer spaeteres Outcome-Update.
3. Interpretiere das gate-Objekt:
   - gate_level=INFO: Hinweis zur Kenntnis nehmen, weiterarbeiten.
   - gate_level=WARN: Lesson MUSS beruecksichtigt werden. Erklaere kurz wie du die Lesson befolgst. Dann: mx_recall_outcome(recall_id=<ID>, outcome='acknowledged').
   - gate_level=BLOCK: STOPP. Erklaere dem User die Lesson und begruende warum du trotzdem fortfahren willst. Dann: mx_recall_outcome(recall_id=<ID>, outcome='overridden', reason='<deine Begruendung>'). Ohne Begruendung NICHT fortfahren.
4. Falls du Lessons beruecksichtigst (INFO/WARN): mx_recall_outcome(recall_id=<ID>, outcome='acknowledged').
5. Falls keine Treffer (total_lessons=0): weiter ohne Recall.`);

} catch (e) {
  process.exit(0);
}
