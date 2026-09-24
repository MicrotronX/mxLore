<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
> **Context:** Hybrid — MCP work→background subagent, `.claude/` files→Main (subagents lack write perm). Long bodies (>300 words) via background subagent; mx_detail default 600 tokens.

Save agent. Persists project state for seamless session continuation.
**Hybrid:** CLAUDE.md+status.md=local. Session notes=MCP-DB.

## Execution Mode ⚡
**Phased sequential-with-parallel** (do NOT collapse into a single fan-out; race + data-dependency hazards):

1. **Main:** Init → Steps 1, 1b, 2 (settings + artifact sweep + CLAUDE.md/status.md + zombie check).
2. **Parallel phase A:** Step 3 (background subagent, `model=sonnet` per mxOrchestrate Model Tiering — MCP CRUD needs no premium; MCP-only) + Step 4a (Main, in-memory mutations). Pass `mcp_available` to Step 3 explicitly; Step 4a sends `expected_updated_at` and skips WFs already archived by Step 3. Stale-sweep: subagent returns candidates ONLY — prompts happen in Main after phase A (see Step 3). ⚡ The **FR/BR Closure-Sweep** (Step 3) runs in **Main**, not the subagent — its candidate source is this session's chat context, which the MCP-only subagent lacks.
3. **Main (synchronous):** Step 5 — `mx_create_doc(session_note)` issued from Main; subagent may build the body string but Main issues the call and captures the doc_id (skill runtime has no await-subagent primitive — running Step 5 in background would regress the deferred-write fix).
4. **Main:** Step 4b — single deferred Write applying ALL 4a + 4b mutations (incl. `last_save_summary` + `last_save_session_note_doc_id` from Step 5's return), then Step 5b — write `.claude/resume-handoff.md`.
5. **Parallel phase B (fire-and-forget):** Step 6 Peer Notify — no join, errors logged not aborted.

Degraded path: Step 5 MCP call fails → Step 4b writes `last_save_summary` (local) + `last_save_session_note_doc_id=null`.

## Init
1. CLAUDE.md→`**Slug:**`=project slug. ∅slug→?user
2. ⚡ tools deferred? → load first per `~/.claude/skills/_shared/mcp-tools-load.md` (tool-missing ≠ server-down — `mcp_available=false` from a missing tool silently skips Steps 3/5/6). mx_ping()→check MCP availability. Set `mcp_available = (ping == ok)`. Steps 3, 5, 6 reference this flag for fallback decisions instead of repeating "MCP error→fallback" inline.
3. ⚡ State file safety: If `.claude/orchestrate-state.json` is missing or unparseable, treat as empty state per the mxOrchestrate `loadState()` contract: `state_deltas=0`, `last_save_deltas=0`, `workflow_stack=[]`, `mcp_available` still set from ping result. Warn user inline ("orchestrate-state.json missing/corrupt — proceeding with empty state"). The `--delta-check` mode in this case emits nothing (N==0 silent path).
