#!/usr/bin/env node
// env-guard — PreToolUse hook for Bash|PowerShell.
// Rule: values inside .env files (.env, *.env, .env.*) must never reach the
// context window. permissions.deny Read(//**/.env…) already covers Read/Grep
// and the shell file commands Claude Code recognises; this hook closes the
// rest of the shell: interpreters (python/php/node/perl), `source`, `while read`,
// redirects — anything that can echo a value.
//
// Decision: a command is DENIED when it mentions a token whose basename looks
// like an .env file AND (the file exists | the token is a glob | it cannot be
// resolved), UNLESS every command segment is either the allow-listed helper
// (env-keys.sh — prints key names + value lengths only) or a pure
// file-management verb that never prints content.
// Fail-closed on .env tokens, fail-open on malformed input (never break the shell).

const fs = require('fs');
const path = require('path');
const os = require('os');

const ENV_BASENAME = /^(?:\.env|[^\\/]+\.env|\.env\.[A-Za-z0-9_.-]+)$/i;
const SAFE_VERBS = new Set([
  'ls', 'dir', 'rm', 'test', '[', '[[', 'stat', 'wc', 'cksum',
  'md5sum', 'sha1sum', 'sha256sum', 'touch', 'chmod', 'chown', 'icacls', 'mkdir', 'rmdir',
  'cd', 'pushd', 'popd', 'file', 'du', 'realpath', 'readlink', 'basename', 'dirname',
  'remove-item', 'rename-item', 'test-path', 'get-item',
  'get-childitem', 'new-item', 'set-location', 'gci', 'del', 'ren',
]);
// copy/move verbs: allowed only when the destination is itself an .env file or a directory
// (blocks `cp x.env /dev/stdout`, `cp x.env out.txt && cat out.txt`)
const COPY_VERBS = new Set(['cp', 'mv', 'copy', 'move', 'copy-item', 'move-item']);
// VCS verbs: only subcommands that never print file content (no show/diff/log/cat/blame/grep)
const VCS_VERBS = new Set(['git', 'svn']);
const VCS_SAFE_SUB = new Set(['add', 'rm', 'mv', 'status', 'st', 'commit', 'ci', 'ls-files',
  'check-ignore', 'update-index', 'restore', 'checkout', 'reset', 'revert', 'propset', 'info']);
const HELPER = 'env-keys.sh';

function readInput() {
  try {
    const raw = fs.readFileSync(0, 'utf8');
    if (raw && raw.trim()) return JSON.parse(raw);
  } catch { /* fall through */ }
  try { return JSON.parse(process.env.CLAUDE_TOOL_INPUT || '{}'); } catch { return {}; }
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

function expandHome(t) {
  if (t.startsWith('~')) return path.join(os.homedir(), t.slice(1));
  return t.replace(/^\$HOME(?=[\\/])/, os.homedir()).replace(/^\$\{HOME\}(?=[\\/])/, os.homedir());
}

function isEnvToken(tok, cwd) {
  const base = path.basename(tok.replace(/\\/g, '/'));
  if (!ENV_BASENAME.test(base)) return false;
  if (/[*?\[]/.test(tok)) return true;            // glob → cannot verify → closed
  if (/^[^:\\/]{2,}:/.test(tok)) return true;      // `HEAD:path`, `rev:path` → VCS object → closed
  let t = expandHome(tok);
  if (/\$/.test(t)) return true;                   // unresolved variable → closed
  if (process.platform === 'win32' && t.startsWith('/')) {
    const m = /^\/([a-zA-Z])(\/|$)/.exec(t);       // Git-Bash `/c/Users/...` → `C:/Users/...`
    if (m) t = m[1].toUpperCase() + ':' + t.slice(2);
    else return true;                              // `/tmp/...`, `/home/...` → cannot resolve → closed
  }
  if (!path.isAbsolute(t) && cwdChanged) return true; // `cd X && cat .env` → relative to unknown dir → closed
  try {
    const p = path.isAbsolute(t) ? t : path.join(cwd || process.cwd(), t);
    return fs.existsSync(p) && fs.statSync(p).isFile();
  } catch { return true; }
}
let cwdChanged = false;

function segments(cmd) {
  // split on command separators; strip subshell parens; keep it simple
  return cmd.split(/&&|\|\||;|\||\n/).map(s => s.replace(/^[\s(]+|[\s)]+$/g, '')).filter(Boolean);
}

function verbOf(seg) {
  const words = seg.split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) i++; // env assignments
  const w = (words[i] || '').replace(/^["']|["']$/g, '');
  return { verb: path.basename(w.replace(/\\/g, '/')).toLowerCase(), words: words.slice(i) };
}

function isHelper(v) {
  if (v.words.length < 2) return false;
  const prog = v.verb;
  const script = v.words[1].replace(/^["']|["']$/g, '').replace(/\\/g, '/');
  return (prog === 'bash' || prog === 'sh') && path.basename(script) === HELPER;
}

try {
  const input = readInput();
  const tool = input.tool_name || '';
  if (tool !== 'Bash' && tool !== 'PowerShell') process.exit(0);
  const cmd = (input.tool_input && input.tool_input.command) || '';
  if (!cmd) process.exit(0);
  const cwd = input.cwd || process.cwd();
  cwdChanged = /(^|[\s;&|(])(cd|pushd|set-location|sl)\s/i.test(cmd);

  // candidate tokens: split on whitespace, quotes, separators, redirects, '='
  const tokens = cmd.split(/[\s"'`<>|;&()=]+/).filter(Boolean);
  const hits = tokens.filter(t => isEnvToken(t, cwd));
  if (hits.length === 0) process.exit(0);

  const segs = segments(cmd);
  const unq = w => w.replace(/^["']|["']$/g, '');
  const isSafe = (seg) => {
    const v = verbOf(seg);
    if (isHelper(v)) return true;
    if (/<\s*\S*\.env/i.test(seg)) return false;          // never feed an .env via redirect
    if (SAFE_VERBS.has(v.verb)) return true;
    // write-only: `echo 'KEY=' >> x.env` / `printf ... > x.env` — the .env appears ONLY as
    // output-redirect target (Write/Edit tools are blocked by the Read deny, so this is the
    // sanctioned way to create/append an .env). Anything before the `>` must be env-free.
    if (v.verb === 'echo' || v.verb === 'printf') {
      const before = seg.split(/>+/)[0];
      const pre = before.split(/[\s"'`<|;&()=]+/).filter(Boolean);
      return !pre.some(t => isEnvToken(t, cwd)) && !/\$\(|`/.test(before);
    }
    if (VCS_VERBS.has(v.verb)) {
      const sub = (v.words.find((w, i) => i > 0 && !w.startsWith('-')) || '').toLowerCase();
      return VCS_SAFE_SUB.has(sub);
    }
    if (COPY_VERBS.has(v.verb)) {
      const args = v.words.slice(1).filter(w => !w.startsWith('-'));
      const dest = unq(args[args.length - 1] || '');
      if (!dest || /^\/dev\//i.test(dest) || /^(con|prn|nul)$/i.test(dest)) return false;
      if (ENV_BASENAME.test(path.basename(dest.replace(/\\/g, '/')))) return true;
      try {
        const p = path.isAbsolute(expandHome(dest)) ? expandHome(dest) : path.join(cwd, dest);
        return fs.existsSync(p) && fs.statSync(p).isDirectory();
      } catch { return false; }
    }
    return false;
  };
  const offending = segs.find(seg => !isSafe(seg));
  if (!offending) process.exit(0);

  deny(`env-guard: "${hits[0]}" is a .env file — values must never enter the context (chat/MCP/agent messages). ` +
       `Allowed: key names, empty/filled, value length, equal/unequal via ` +
       `bash ~/.claude/hooks/${HELPER} <file> [--cmp KEY_A KEY_B]. ` +
       `Blocked segment: "${offending.slice(0, 80)}"`);
} catch {
  process.exit(0); // fail-open on hook errors; the permissions.deny layer still holds
}
