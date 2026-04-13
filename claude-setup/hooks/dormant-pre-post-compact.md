# PreCompact / PostCompact Hooks — DORMANT

**Status:** Removed from `~/.claude/settings.json`.
**Reason:** `type: "prompt"` hooks for `PreCompact` and `PostCompact` are not executed by the current Claude Code version (Anthropic-side limitation). They fired silently with no visible effect, creating a marketing/reality mismatch (CLAUDE.md previously promised auto-mxSave + auto-briefing).

**Re-activate:** Once Anthropic supports prompt-type hooks for Pre/PostCompact, paste the two blocks below back into `~/.claude/settings.json` under `"hooks"` — directly after the `PostToolUse` block, before the closing `}` of the hooks section. Add a comma after the `PostToolUse` closing `]`.

## Original PreCompact block

```json
"PreCompact": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "prompt",
        "prompt": "CONTEXT COMPACTING IS IMMINENT! Execute these 2 steps IMMEDIATELY:\n\n1. AUTO-ADR EXTRACT (BEFORE mxSave!): Analyze chat history for significant decisions (signal dictionary: ~/.claude/reference/auto-adr.md). Per detected decision (level 1+2): mx_create_doc(project, doc_type='note', title='ADR-Candidate: <summary>', content=<template from auto-adr.md>, tags='adr-candidate'). Deduplicate first via mx_search(tag='adr-candidate') + mx_search(doc_type='decision'). No user prompts. Output: 'Auto-ADR: N candidates extracted'.\n\n2. Run /mxSave to persist the current project state.\n\nNo prompts, no explanations — just execute and then allow compacting to proceed."
      }
    ]
  }
]
```

## Original PostCompact block

```json
"PostCompact": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "prompt",
        "prompt": "STEP 1: Check 2 mandatory conditions:\n  - CLAUDE.md in current Working Dir exists AND contains **Slug:** entry\n  - mx_ping() successful\n  If EITHER condition fails → SILENT (no output, nothing at all). On next user prompt just continue normally.\n\nSTEP 2: (only if both conditions OK) mx_briefing(project='<slug>', include_content=false, token_budget=1500)\n\nSTEP 3: (optional, soft-fail) Check if .claude/projects/<project>/.claude/orchestrate-state.json exists. If yes: Read and parse last_save_deltas (default 0 if field missing). If no: skip, no error.\n\nSTEP 4: Output max 3 lines:\n  Project: <slug> | Session: #<id> | <N> active WFs\n  Open items: <X>\n  Last save: <last_save_deltas> deltas processed   ← ONLY if STEP 3 successful AND last_save_deltas > 0\n\nNo explanations, no prompts — execute and continue working."
      }
    ]
  }
]
```

## Until re-activation

Manual replacement:
1. **Before** `/compact`: call `/mxSave` yourself.
2. **After** `/compact`: call `mx_briefing(project='<slug>', include_content=false, token_budget=1500)` yourself.

The `last_save_deltas` mechanism in `mxSave` Step 4 + `orchestrate-state.json` is fully functional code-side — it just waits for the trigger.
