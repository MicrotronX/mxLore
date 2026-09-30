# mxOrchestrate Hook Integration

mxOrchestrate is hook-driven. The hooks live in `~/.claude/hooks/` and are registered in `~/.claude/settings.json`.

## SessionStart hook

- **Fires:** once per session start.
- **Role:** loads `.claude/orchestrate-state.json`, parses active workflows, injects a state summary into Claude's initial context. Never asks questions — just informs.
- **Output format:** single-line banner with active WF name + step counter, plus parked count and team-agent status.

## UserPromptSubmit hook

- **Fires:** on every user prompt, before the LLM turn begins.
- **Role:** injects a 3-line context block so Claude always sees the current workflow state.
- **Line 1:** active WF summary (name, step X/Y, delta count).
- **Line 2:** team status (idle / N running / recent results).
- **Line 3:** rule reminder. Examples: `NO_WORKFLOW` auto-track hint, `JUST_COMPLETED` warning, staleness nudge.
- **Auto-tracking signals:** see "Auto-Tracking" section in SKILL.md (Rules 1-3).
- Agent messages: delivered via the mxMCPProxy session-inbox delivery (proxy >= 1.0.9, `CLAUDE_CODE_MESSAGING_SOCKET`) — no client-side hook or watcher involved.

## PreCompact hook — ACTIVE (command type)

- **Script:** `orchestrate-precompact.js` (one registration: matcher `manual`, flag `--manual`).
- **Manual `/compact`:** with unsaved work (state_deltas > 0 or subagent_ran_since_save) it is blocked once with "run /mxSave first"; a second `/compact` within 2 minutes passes.
- **Auto compact:** not hooked, never blocked. PreCompact output cannot reach the model or the summary (`systemMessage` is user-only, no `hookSpecificOutput`) — the unsaved-work hint after a compact comes from SessionStart.
- **Alternative:** `/mxSave --delta-check` for the threshold emit without a full save.

## PostCompact hook — intentionally not installed

- PostCompact cannot inject context. Re-briefing after a compact is covered by SessionStart (`source=compact`) via `orchestrate-reconcile.js`.
