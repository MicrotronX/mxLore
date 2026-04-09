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
