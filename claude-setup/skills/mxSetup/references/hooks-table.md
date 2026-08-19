# Hooks Table — mxSetup Phase 5b

Installed into `~/.claude/settings.json` during Phase 5b. Each row lists the event, hooks installed in order, and the runtime they need.

| Event | Hooks (in order) | Language | Requires | Role |
|-------|------------------|----------|----------|------|
| `SessionStart` | `node ~/.claude/hooks/orchestrate-reconcile.js` (2000ms), `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Node.js | Node.js | Orchestrate reconciles workflow stack vs MCP on session start, then injects status line |
| `UserPromptSubmit` | `bash ~/.claude/hooks/agent_inbox_check.sh` (2000ms), `node ~/.claude/hooks/orchestrate-status.js` (2000ms) | Bash + Node.js | Bash + Node.js | Agent-inbox check (multi-agent notifications) + Orchestrate status injection on every prompt. ⚡ This hook fires ONLY on a user prompt, so it never delivers to an instance that is *waiting* for a message — that gap is covered by the slug-filtered Monitor armed in mxOrchestrate Init step 3a, not here |
| `SubagentStop` | `node ~/.claude/hooks/orchestrate-subagent-flag.js` (2000ms) | Node.js | Node.js | Sets `subagent_ran_since_save: true` in orchestrate-state.json — tracker-gap bridge: subagent MCP-writes bypass the deltas counter; the flag keeps the save-band from reporting a false "nothing unsaved" |
| `Stop` | `node ~/.claude/hooks/orchestrate-step-check.js` (3000ms) | Node.js | Node.js | After-turn step-completion check: mark steps done + sync to MCP |
| `PreToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-gate.js` (2000ms) | Node.js | Node.js | Recall-Gate: before Edit/Write, check if related lessons/decisions exist and surface them |
| `PostToolUse` (matcher: `Edit\|Write`) | `node ~/.claude/hooks/recall-outcome-hook.js` (2000ms) | Node.js | Node.js | Recall-Outcome: after Edit/Write, track whether the recalled item was actually useful |

## Node.js degradation (load-bearing)

⚡ Without Node.js, **6 of 9 hooks degrade**:
- Orchestrate reconcile / status / step-check / subagent-flag (4 hooks) → no workflow state tracking, no step auto-complete, no subagent tracker-gap flag
- Recall-Gate + Recall-Outcome (2 hooks) → no pre-edit recall, no outcome tracking

Only `agent_inbox_check.sh` and the Bash-based `statusline-command.sh` keep working.

Installation check (in Phase 5b):
```bash
node --version 2>/dev/null
```
If `node` not found: warn the user, install only the Bash hooks (`agent_inbox_check`, `statusline-command`), skip the 6 JS hooks, and note that the session runs with limited functionality. Installation pointer: https://nodejs.org/

## Not installed (DORMANT)
`PreCompact` and `PostCompact` prompt-type hooks are **not installed** — see `dormant-precompact.md` for details.
