#!/usr/bin/env node
// Institutional Memory Outcome Hook (Spec#1198, B8.3+B8.4 Plan#1231)
// PostToolUse Hook: Fires after Edit/Write on source files.
// Prompts Claude to call mx_recall_outcome if a recall_id is active.
// Performance target: <50ms.

const fs = require('fs');
const path = require('path');
const os = require('os');

// B8.4: Outcome window — edits beyond this window are not linked to recall
const OUTCOME_WINDOW_MINUTES = 15;

// Shared cooldown file from recall-gate.js — contains recall timestamps
const COOLDOWN_FILE = path.join(os.tmpdir(), 'claude-recall-cooldown.json');

// Outcome-tracking file — prevents duplicate outcome prompts per file
const OUTCOME_FILE = path.join(os.tmpdir(), 'claude-recall-outcome.json');

function loadJson(filePath) {
  try {
    if (!fs.existsSync(filePath)) return {};
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch { return {}; }
}

function saveJson(filePath, data) {
  try {
    fs.writeFileSync(filePath, JSON.stringify(data));
  } catch { /* best-effort */ }
}

try {
  const toolInput = process.env.CLAUDE_TOOL_INPUT || '';

  let filePath = '';
  try {
    const parsed = JSON.parse(toolInput);
    filePath = parsed.file_path || parsed.path || '';
  } catch {
    process.exit(0);
  }

  if (!filePath) process.exit(0);

  // Only trigger for source files (same filter as recall-gate.js)
  const normPath = filePath.replace(/\\/g, '/').toLowerCase();
  const isSourceFile = normPath.includes('/src/') ||
                       normPath.includes('/admin/') ||
                       normPath.includes('/skills/') ||
                       normPath.includes('/hooks/') ||
                       normPath.endsWith('.pas') ||
                       normPath.endsWith('.js') ||
                       normPath.endsWith('.ts');

  if (!isSourceFile) process.exit(0);

  // Check if there was a recent recall for this file (within outcome window)
  const cooldown = loadJson(COOLDOWN_FILE);
  const fileName = path.basename(filePath);
  const cooldownKey = `${fileName}:implement`;
  const recallTimestamp = cooldown[cooldownKey];

  if (!recallTimestamp) process.exit(0);

  // B8.4: Check outcome window
  const elapsedMs = Date.now() - recallTimestamp;
  const windowMs = OUTCOME_WINDOW_MINUTES * 60 * 1000;
  if (elapsedMs > windowMs) process.exit(0);

  // Prevent duplicate outcome prompts for the same file in this session
  const outcomes = loadJson(OUTCOME_FILE);
  if (outcomes[cooldownKey]) process.exit(0);

  // Mark outcome as prompted
  outcomes[cooldownKey] = Date.now();
  outcomes._ts = Date.now();
  saveJson(OUTCOME_FILE, outcomes);

  // Prompt Claude to call mx_recall_outcome
  console.log(`[Recall Outcome] File "${fileName}" was successfully edited. If you have an active recall_id from a previous mx_recall call for this file, call mx_recall_outcome(recall_id=<ID>, outcome='edited_after_recall') now.`);

} catch {
  process.exit(0);
}
