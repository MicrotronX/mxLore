# MCP Tools — Load Before First Call (Shared)

Single source-of-truth for the step that MUST precede the first `mx_*` call in
every mx*-skill, whether the skill runs in the main context or inside a
subagent. Edit here, reference from the skills, mirror to consumers.

## Why this step exists

In sessions with **deferred tools**, the `mcp__mxai-knowledge__mx_*` tools are
not in the loaded tool set until `ToolSearch` has fetched their schemas. A call
to `mx_ping` then fails with a tool-not-found / validation error — NOT with a
server error. A skill that reads that failure as "MCP unreachable" drops into
its local fallback, persists nothing (findings, docs, session notes) and still
reports a successful run. Observed live 2026-08-31: a checker spawned as a
subagent reported "MCP-Server nicht erreichbar", 6 findings were never
persisted, the server was answering the main session the whole time. Same
failure class as an "erledigt" marker written before the proof.

## The step (run once, before the first `mx_*` call)

1. **Is `mx_ping` in the loaded tool set?** If the tool is callable, skip to 3.
2. **Not loaded → load in ONE `ToolSearch` call:**
   `ToolSearch("select:mcp__mxai-knowledge__mx_ping,mcp__mxai-knowledge__mx_search,mcp__mxai-knowledge__mx_detail,mcp__mxai-knowledge__mx_create_doc,mcp__mxai-knowledge__mx_update_doc,mcp__mxai-knowledge__mx_skill_feedback")`
   — add the further `mx_*` tools the skill uses to the same `select:` list;
   never one `ToolSearch` per tool. `ToolSearch` itself unavailable → the tools
   are not deferred in this session; proceed.
3. **Now `mx_ping()`.** Only a response from the tool decides availability.

## ⚡ Two failures, two meanings — never merge them

| Signal | Meaning | Action |
|---|---|---|
| tool not found / unknown tool / InputValidationError before any request | tool not LOADED | step 2, then retry once |
| `mx_ping` returns an error or times out | server not REACHABLE | the skill's documented local fallback / abort |

"MCP unreachable" may only be reported after a real `mx_ping` error. A skill
running as a subagent MUST state the `mx_ping` result (version + build) in its
report, so a silent fallback is visible to the caller.
