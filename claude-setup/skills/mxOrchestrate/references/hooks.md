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

## PreCompact hook — ⚡ DORMANT

- **Status:** NOT installed. Spec#2152 + Lesson#2161 — prompt-type PreCompact hook is blocked upstream in Claude Code's harness.
- **Dormant marker file:** `~/.claude/hooks/dormant-pre-post-compact.md` (contains re-activation instructions if upstream lifts the block).
- **Manual workaround:** run `/mxSave` manually BEFORE `/compact`, then invoke `mx_briefing` manually in the new context after the compact.
- **Alternative:** use `/mxSave --clear-cycle` for the threshold emit without a full save.
- ⚡ Do NOT install this hook. It will silently fail and mask real compact-cycle bugs.

## PostCompact hook — ⚡ ALSO DORMANT

- **Status:** NOT installed. Same upstream block as PreCompact.
- **Role (if reactivated):** would emit the re-brief-last-save line using `last_save_deltas` from the state file.
- **Manual workaround:** the mxSave Final Block handles the threshold logic on the next manual `/mxSave` invocation.
- ⚡ Do NOT install this hook.

## Re-activation procedure (if upstream lifts the block)

1. Read `~/.claude/hooks/dormant-pre-post-compact.md` for the most recent reactivation notes.
2. Verify with a minimal PreCompact prompt-hook test in a scratch project first.
3. Only after verification, install in global `~/.claude/settings.json`.
4. Update this document + the CLAUDE.md global rule block (`mx-rules` marker).
