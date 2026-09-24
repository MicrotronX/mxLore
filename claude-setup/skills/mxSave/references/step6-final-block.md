<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
### 6) Peer Notify (MCP, only if delta > 0)
if !mcp_available → skip entire step.
`mx_session_delta(project, session_id=<state.session_id>, limit=50)`→total_changes==0→skip. ⚡ `session_id`, NOT `since`: the server derives the cutoff from `started_at`, so this call carries no client timestamp and cannot inherit a wrong timestamp base. Do not "harmonize" it to `since` — mxOrchestrate needs `since=last_save` only because at resume time the session has just begun.
⚡ `limit=50`, NOT `1`: the Final Block reuses this call's `total_changes` as a MAGNITUDE, not a boolean. Servers before the `COUNT(*)` fix return `RecordCount` of the LIMITed query, so `limit=1` pins `total_changes` to 1 and silently kills the tracker-gap guard. 50 clears every band threshold (max 15), so the band stays correct against old and new servers alike.
`mx_agent_peers(project)`→∅peers→skip.
1 call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 sentences>","changed_files":<count>,"project":"<slug>"}`
- Error→log, don't abort

## Final Block — Clear-Cycle Recommendation

Mode-agnostic threshold emit consuming `N` (normal: `last_save_deltas` set by Step 4; `--delta-check`: `state_deltas` in-flight, see Delta-Check section).

**Skip:** state file missing OR mode-relevant deltas field unset. Do NOT skip on empty workflow_stack — doc-only sessions can have meaningful deltas.

⚡ **Tracker-gap guard:** `N_eff = max(N, total_changes, F)` — ⚡ but a non-empty `warnings` array on that `mx_session_delta` response (server build >= 128: explicit `since` in the server's future) means `total_changes` is meaningless: substitute `total_changes := 1` in the formula (forces `N_eff >= 1` → the save runs) and print the warning text. `warnings` absent (server before build 128) or present-and-empty → use `total_changes` as returned. `total_changes` comes from the `mx_session_delta` call Step 6 already made (reuse, do not re-query; `!mcp_available` OR `--delta-check` (Step 6 skipped, no delta data) → `N_eff = max(N, F)`), and `F = 1` if the state file had `subagent_ran_since_save == true` at Step 4 read-time, else `0` (SubagentStop-hook flag: a subagent ran since the last save; it is a boolean, not a count — the hook cannot know whether the subagent wrote to MCP, so it only prevents a false silent band; the real magnitude still comes from `total_changes`). Subagent MCP-writes bypass the `state_deltas` counter — the band must not fall back to silent when real writes happened.

| N | Output | Notes |
|---|---|---|
| `>=15` | Active prompt via AskUserQuestion tool: question=`Session is large (<N> deltas persisted). /clear + new session + mx_briefing is now worthwhile. Execute?` options: `yes, run /mxSave + suggest /clear` / `no, keep working` | `--loop` downgrades to `>=10` tip (no interactive waits) |
| `>=10` | Tip line: `Tip: <N> deltas persisted. /clear + new session + mx_briefing is worthwhile when convenient.` | |
| `>=1` | Marketing: `Clear-Cycle: <N> deltas persisted. /clear + manual mx_briefing ready.` | No token-multiplier numbers (state_deltas counts DB events not transcript tokens) |
| `==0` | silent | |

⚡ PreCompact/PostCompact hooks dormant (prompt-type hooks blocked upstream); `/clear` + manual `mx_briefing` is the active path. Re-activation: `~/.claude/hooks/dormant-pre-post-compact.md`.
