---
name: mxSetup
description: "Developer onboarding: MCP connection, skills, proxy, config. Run on new PC or after updates."
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: "<api-key> | --update"
---

# /mxSetup — Developer Onboarding (~30 seconds)

> ⚡ **!Python !jq !sed for file operations.** Only Write/Read/Edit tools + Bash for `claude mcp` and `curl`.
> ⚡ **Bash: Single-line.** !Multi-line !Heredocs !Newlines in commands.

## Prerequisites
- **Node.js** — Required for 5 of 8 hooks (Orchestrate, Recall-Gate, Recall-Outcome). Without Node.js the session runs with limited functionality (no state tracking, no Recall-Gate). Installation: https://nodejs.org/

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

⚡ **EXACT URL — DO NOT invent!**
`https://github.com/MicrotronX/mxLore-skills/archive/main.zip`
!mxai-org !mxai-tech !other repos. ONLY `MicrotronX/mxLore-skills`.

**All platforms (curl + unzip, works in Bash/Git-Bash/Linux/macOS):**
```bash
curl -L -o /tmp/mxLore-skills.zip https://github.com/MicrotronX/mxLore-skills/archive/main.zip && unzip -o /tmp/mxLore-skills.zip -d /tmp/mxLore-skills
```

Then copy:
```bash
cp -r /tmp/mxLore-skills/mxLore-skills-main/mx* ~/.claude/skills/
mkdir -p ~/.claude/hooks && cp -r /tmp/mxLore-skills/mxLore-skills-main/hooks/* ~/.claude/hooks/
mkdir -p ~/.claude/reference && cp -r /tmp/mxLore-skills/mxLore-skills-main/reference/* ~/.claude/reference/
cp /tmp/mxLore-skills/mxLore-skills-main/CLAUDE.md /tmp/mxLore-skills-CLAUDE.md 2>/dev/null
rm -rf /tmp/mxLore-skills /tmp/mxLore-skills.zip
```

⚡ !PowerShell !Invoke-WebRequest — always use curl+unzip in Bash (works everywhere).

### Phase 3: Install Proxy

1. **Resolve Download URL** from mx_ping response:
   - Use `proxy_download_url` — always set when `admin_port > 0` (external URL if configured, otherwise localhost)
   - If `admin_port` missing in mx_ping response: warning, skip proxy install.
2. Download:
```bash
curl -f -o ~/.claude/mxMCPProxy.exe "<RESOLVED-URL>"
```
3. Check file size (>100KB). If smaller: warning, skip proxy.
4. Create proxy INI (Write tool → `~/.claude/mxMCPProxy.ini`):
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
→ Only install Bash hooks and PreCompact prompt, skip JS hooks.

| Event | Hooks (in order) | Requires |
|-------|-----------------|----------|
| `SessionStart` | `node ~/.claude/hooks/orchestrate-reconcile.js` (2000ms) + `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Node.js |
| `UserPromptSubmit` | `bash ~/.claude/hooks/agent_inbox_check.sh` (2000ms) + `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Bash + Node.js |
| `Stop` | `node ~/.claude/hooks/orchestrate-step-check.js` (3000ms) | Node.js |
| `PreToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-gate.js` (2000ms) | Node.js |
| `PostToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-outcome-hook.js` (2000ms) | Node.js |
| `PreCompact` | prompt: (Auto-ADR + /mxSave, see below) | — |

**5b-StatusLine** — Add `statusLine` block at top level of settings.json (NOT inside `hooks`):
```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/hooks/statusline-command.sh"
}
```
Shows: `<slug> | <model> | <context%> | <$cost> | <tasks>`. Reads slug from `CLAUDE.md` (`**Slug:**` line, accepts both backticked and plain format). ⚡ Legacy path `~/.claude/statusline-command.sh` (pre-2026-04): delete it and ensure command points to `~/.claude/hooks/statusline-command.sh` — all hooks live under `~/.claude/hooks/` for consistency.

**PreCompact prompt** (adopt verbatim):
```
CONTEXT COMPACTING IS IMMINENT! Execute these 2 steps IMMEDIATELY:

1. AUTO-ADR EXTRACT (BEFORE mxSave!): Analyze chat history for significant decisions (signal dictionary: ~/.claude/reference/auto-adr.md). Per detected decision (level 1+2): mx_create_doc(project, doc_type='note', title='ADR-Candidate: <summary>', content=<template from auto-adr.md>, tags='adr-candidate'). Deduplicate first via mx_search(tag='adr-candidate') + mx_search(doc_type='decision'). No user prompts. Output: 'Auto-ADR: N candidates extracted'.

2. Run /mxSave to persist the current project state.

No prompts, no explanations — just execute and then allow compacting to proceed.
```

**5c. CLAUDE.md** — Use `/tmp/mxLore-skills-CLAUDE.md` (saved in Phase 2):
   - If `~/.claude/CLAUDE.md` does not exist: copy it
   - If exists and has mx-rules marker: replace block between `<!-- mx-rules-start -->` and `<!-- mx-rules-end -->` with new one
   - If exists without marker: append mx-rules block at the end
   - Afterwards: `rm /tmp/mxLore-skills-CLAUDE.md`

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

## Update Mode (--update)

1. Run Phase 2 (skills from GitHub)
2. Run Phase 5 (update config)
3. Proxy update: call `mx_ping()`, resolve URL as Phase 3 step 1 → download new EXE → rename old → move new → delete old
4. Show summary

## Rules

- **!mx_onboard_developer** — Skills come from GitHub, not from the server
- **!Python !jq** — Write/Edit tools for files, Bash only for curl/claude-mcp
- **API key never displayed** — only last 4 characters (`mxk_****15c`)
- **Skills always overwritten** — GitHub = source of truth
- **Encoding:** UTF-8 without BOM
- **MCP scope:** ALWAYS `-s user`
