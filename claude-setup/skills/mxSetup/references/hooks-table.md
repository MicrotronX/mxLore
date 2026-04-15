# Hooks Table — mxSetup Phase 5b

Installed into `~/.claude/settings.json` during Phase 5b. Each row lists the event, hooks installed in order, and the runtime they need.

| Event | Hooks (in order) | Language | Requires | Role |
|-------|------------------|----------|----------|------|
| `SessionStart` | `node ~/.claude/hooks/orchestrate-reconcile.js` (2000ms), `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Node.js | Node.js | Orchestrate reconciles workflow stack vs MCP on session start, then injects status line |
| `UserPromptSubmit` | `bash ~/.claude/hooks/agent_inbox_check.sh` (2000ms), `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Bash + Node.js | Bash + Node.js | Agent-inbox check (multi-agent notifications) + Orchestrate status injection on every prompt |
| `Stop` | `node ~/.claude/hooks/orchestrate-step-check.js` (3000ms) | Node.js | Node.js | After-turn step-completion check: mark steps done + sync to MCP |
| `PreToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-gate.js` (2000ms) | Node.js | Node.js | Recall-Gate: before Edit/Write, check if related lessons/decisions exist and surface them |
| `PostToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-outcome-hook.js` (2000ms) | Node.js | Node.js | Recall-Outcome: after Edit/Write, track whether the recalled item was actually useful |

## Node.js degradation (load-bearing)

⚡ Without Node.js, **5 of 8 hooks degrade**:
- Orchestrate reconcile / status / step-check (3 hooks) → no workflow state tracking, no step auto-complete
- Recall-Gate + Recall-Outcome (2 hooks) → no pre-edit recall, no outcome tracking

Only `agent_inbox_check.sh` and the Bash-based `statusline-command.sh` keep working.

Installation check (in Phase 5b):
```bash
node --version 2>/dev/null
```
If `node` not found: warn the user, install only the Bash hooks (`agent_inbox_check`, `statusline-command`), skip the 5 JS hooks, and note that the session runs with limited functionality. Installation pointer: https://nodejs.org/

## Not installed (DORMANT)
`PreCompact` and `PostCompact` prompt-type hooks are **not installed** — see `dormant-precompact.md` for details.
