# PreCompact / PostCompact — retired note

Retired: PreCompact is now a command hook (`orchestrate-precompact.js`, see `hooks-table.md`); PostCompact intentionally not installed because it cannot inject context (SessionStart `source=compact` via `orchestrate-reconcile.js` covers re-briefing). The old prompt-type variant is gone: the block decision reads the state file, which needs a command hook.
