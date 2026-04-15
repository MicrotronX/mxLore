---
name: mxSetup
description: This skill should be used when a developer sets up mxLore on a new PC, runs a fresh Claude Code install, updates the global mx-rules block in ~/.claude/CLAUDE.md, refreshes skills/hooks from GitHub, or reinstalls the mxMCPProxy. Triggers "neuer PC", "fresh install", "onboard me", "/mxSetup", "update mx-rules", "mx-rules block veraltet", "reinstall proxy", "skills aktualisieren".
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: "<api-key> | --update | --update-rules | --update-proxy"
---

# /mxSetup — Developer Onboarding (~30 seconds)

> AI-Steno: !=forbidden →=use ⚡=critical ?=ask
> ⚡ **!Python !jq !sed for file operations.** Only Write/Read/Edit tools + Bash for `claude mcp` and `curl`.
> ⚡ **Bash: Single-line.** !Multi-line !Heredocs !Newlines in commands.

## When to trigger this skill
- `claude mcp list` returns empty or lacks `mxai-knowledge`
- `mxMCPProxy.exe` missing or version mismatch vs server
- mx-rules marker block in `~/.claude/CLAUDE.md` outdated or missing
- New PC / fresh Claude Code install
- User says "/mxSetup", "onboard me", or "neuer PC"
- Skills folder out of date (upstream updates in `MicrotronX/mxLore-skills`)

## Prerequisites
- **Required CLI tools:** `curl`, `unzip`, `claude` (Claude Code CLI). Git-Bash on Windows includes curl+unzip.
- **Node.js** — Recommended. Required for 5 of 8 hooks (Orchestrate, Recall-Gate, Recall-Outcome). Without Node.js the session runs with limited functionality (no state tracking, no Recall-Gate). Installation: https://nodejs.org/

## First Installation (with API key)

### Phase 1: MCP Connection

1. Check `claude mcp list` → already has `mxai-knowledge`? → "Use `--update`"
2. ?user: "Server URL? (e.g. http://localhost:8080/mcp)"
   - URL must end with `/mcp`
3. Register MCP:
```bash
claude mcp add -s user --transport http mxai-knowledge "<SERVER-URL>" --header "Authorization: Bearer <API-KEY>"
```
4. `mx_ping()` → Success? Note admin_port. Error? → Abort.

### Phase 2: Install Skills from GitHub (~5 seconds)

⚡ **EXACT URL — DO NOT invent!** Source: `MicrotronX/mxLore-skills` (GitHub). !mxai-org !mxai-tech !other repos.

Downloads the zip, extracts skills into `~/.claude/skills/`, hooks into `~/.claude/hooks/`, reference into `~/.claude/reference/`, and stages `CLAUDE.md` as `/tmp/mxLore-skills-CLAUDE.md` for Phase 5c:
```bash
bash ~/.claude/skills/mxSetup/scripts/install-skills.sh
```

⚡ **Scope limit:** `install-skills.sh` copies hook FILES into `~/.claude/hooks/` but does **NOT** modify `~/.claude/settings.json`. Hook **registration** (`PreToolUse` / `PostToolUse` / `Stop` / etc. entries) happens in Phase 5b below — running `install-skills.sh` standalone leaves hook files on disk but inactive until settings.json is updated.

Optional: `REPO_REF=v2.4.0 bash ~/.claude/skills/mxSetup/scripts/install-skills.sh` pins a release tag instead of `main` HEAD (default remains `main` until `mxLore-skills` cuts tagged releases).

⚡ !PowerShell !Invoke-WebRequest — always use curl+unzip in Bash (works everywhere).

### Phase 3: Install Proxy

1. **Resolve Download URL** from mx_ping response:
   - Use `proxy_download_url` — always set when `admin_port > 0` (external URL if configured, otherwise localhost)
   - If `admin_port` missing in mx_ping response: warning, skip proxy install.
2. Downloads the proxy EXE to `~/.claude/mxMCPProxy.exe` and verifies size (>100KB):
```bash
PROXY_URL="<RESOLVED-URL>" bash ~/.claude/skills/mxSetup/scripts/install-proxy.sh
```
3. Create proxy INI (Write tool → `~/.claude/mxMCPProxy.ini`):
```ini
[Server]
Url=<SERVER-URL>
ApiKey=<API-KEY>
ConnectionTimeout=10000
ReadTimeout=120000

[Agent]
Polling=1
PollInterval=15
```

### Phase 4: Switch MCP to Proxy

```bash
claude mcp remove mxai-knowledge -s user
claude mcp add -s user mxai-knowledge -- "<HOME>/.claude/mxMCPProxy.exe"
```
`mx_ping()` → Success? Continue. Error? Offer HTTP fallback.

### Phase 5: Config

⚡ Read `~/.claude/settings.json` with Read tool, then extend via Edit tool. !Delete/overwrite existing entries. Only add missing ones.

**5a. Permissions** — Add the following to `permissions.allow` (if not present):
```json
"mcp__mxai-knowledge__*",
"Skill(mxSave)",
"Skill(mxDecision)",
"Skill(mxPlan)",
"Skill(mxSpec)",
"Skill(mxDesignChecker)",
"Skill(mxBugChecker)"
```

**5b. Hooks** — Check each hook block. If entry missing, add it. If present, do not duplicate.

⚡ **Node.js check BEFORE hook installation:**
```bash
node --version 2>/dev/null
```
If `node` not found: show warning:
> "Node.js not found. 5 of 8 hooks (Orchestrate, Recall-Gate, Recall-Outcome) will not work without Node.js. Session runs with limited functionality (no state tracking, no Recall-Gate). Installation: https://nodejs.org/"
→ Only install Bash hooks, skip JS hooks (PreCompact/PostCompact prompts are DORMANT — see pointer below).

Hooks table (Event → hooks → Requires) — see `references/hooks-table.md` for details.
⚡ Load-bearing: without Node.js, 5 of 8 hooks degrade (see references file).

**5b-StatusLine** — Add `statusLine` block at top level of settings.json (NOT inside `hooks`):
```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/hooks/statusline-command.sh"
}
```
Shows: `<slug> | <model> | <context%> | <$cost> | <tasks>`. Reads slug from `CLAUDE.md` (`**Slug:**` line, accepts both backticked and plain format). ⚡ Legacy path `~/.claude/statusline-command.sh` (pre-2026-04): delete it and ensure command points to `~/.claude/hooks/statusline-command.sh` — all hooks live under `~/.claude/hooks/` for consistency.

**PreCompact / PostCompact prompts** — **DORMANT, do NOT install.** See `references/dormant-precompact.md` for rationale and re-activation steps. Manual workaround: user calls `/mxSave` before `/compact` and `mx_briefing` after.

**5c. CLAUDE.md** — Use `/tmp/mxLore-skills-CLAUDE.md` (saved in Phase 2). Three-branch merge logic (no file / marker present / marker absent) — see `references/claude-md-merge.md` for details. Afterwards: `rm /tmp/mxLore-skills-CLAUDE.md`.

**5d. Agent Inbox:** `mkdir -p ~/.claude/agent_inbox`

### Phase 6: Done

```
=== mxLore Setup Complete ===

| Component | Status |
|-----------|--------|
| MCP | Connected (<URL>) |
| Skills | X installed |
| Hooks | Y installed |
| Proxy | OK / MISSING |
| CLAUDE.md | OK |

Next steps:
1. Restart Claude Code
2. Switch to project directory
3. Run /mxInitProject
```

## Update Modes

### `--update` (full refresh)
Runs Phase 2 (skills + hooks + reference from GitHub), Phase 5 (config + `~/.claude/CLAUDE.md` mx-rules marker block), and proxy version-check (same flow as Phase 3, download only if version differs). Use after upstream `mxLore-skills` changes or when several things are out of date.

Optional: `CLEAN=1 ~/.claude/skills/mxSetup/scripts/install-skills.sh` removes stale `mx*/` dirs before re-copy. Use only if you have NO local unsynced edits in your `mx*`-skills.

### `--update-rules` (mx-rules marker only — fast path)
- `--update-rules` — Re-runs Phase 2 (which downloads the full skills bundle) and Phase 5c (CLAUDE.md mx-rules marker merge). Skills + hooks get refreshed as collateral; if you want only the marker block updated without skill refresh, edit `~/.claude/CLAUDE.md` manually between the markers.

### `--update-proxy` (proxy EXE swap only)
Only re-runs Phase 3: `mx_ping()` → resolve URL → `install-proxy.sh` → replace `~/.claude/mxMCPProxy.exe`. INI left untouched. Use when the server build moved ahead of the local proxy.

⚡ Stop the running proxy first (`taskkill /IM mxMCPProxy.exe /F` on Windows) — staging+mv mitigates file lock but a clean swap is more reliable.

## Rules

- **!mx_onboard_developer** — Skills come from GitHub, not from the server
- **!Python !jq** — Write/Edit tools for files, Bash only for curl/claude-mcp
- **API key never displayed** — only last 4 characters (`mxk_****15c`)
- **Skills always overwritten** — GitHub = source of truth
- **Encoding:** UTF-8 without BOM
- **MCP scope:** ALWAYS `-s user`
