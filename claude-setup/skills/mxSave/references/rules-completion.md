<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
## Rules
- ⚡ Only record confirmed-implemented as "done" !assumptions. **Exception:** Step 4a Step-State Delta Check (intent signal — see `references/step-state-sync.md`).
- ⚡ Session notes derived from chat, facts only !speculation. ∅info→"Open question"
- !auto-create ADRs→suggest /mxDecision. !delete existing content→supplement/compact
- Encoding: UTF-8 without BOM. Prefer MCP, local=fallback
- ⚡ events_log append (Step 4a/4b): skip the append if identical to the current LAST entry (same type+wf+detail) — consecutive-duplicate guard (duplicate step_done observed 2026-06-10; mirrors the mxOrchestrate dedupe-guard rule — keep in sync)
- ⚡ Interactive questions (all `?user` prompts incl. stale-sweep y/n/skip)→AskUserQuestion tool. !freetext-numbered-prompts

## Completion
Output: (1) Table: file/DB-entry+action (created/changed/unchanged) (2) Active workflows+current step (3) Next step (4) ADR hint if decisions were made in chat
