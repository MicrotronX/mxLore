# PreCompact / PostCompact Prompt Hooks — DORMANT

## Why dormant
Both `type: "prompt"` hooks for `PreCompact` and `PostCompact` are **not executed** by the current Claude Code version. This is an Anthropic-side limitation: the runtime accepts the hook registration but never fires the prompt before/after compaction. Installing them would only sleep silently and reintroduce the marketing/reality mismatch we had before Spec#2152.

## What mxSetup does
- The `PreCompact` and `PostCompact` rows are **not** added to `~/.claude/settings.json` during Phase 5b.
- Original prompt JSON blocks are archived in `~/.claude/hooks/dormant-pre-post-compact.md` as a copy-ready re-activation backup.

## Manual workaround (current)
Users run the cycle themselves:
1. `/mxSave` **before** `/compact`
2. `/compact`
3. `mx_briefing` **after** `/compact` (new session or after compact)

The `last_save_deltas` mechanism in `mxSave` Step 4 plus `orchestrate-state.json` stays fully functional code-side. Only the trigger is manual.

## Re-activation (when Anthropic ships prompt-type Pre/PostCompact support)
1. Open `~/.claude/hooks/dormant-pre-post-compact.md` — contains the two ready-to-paste JSON blocks.
2. Edit `~/.claude/settings.json` and paste both blocks into `hooks.PreCompact` and `hooks.PostCompact` arrays.
3. Restart Claude Code.
4. Verify via `/mxSave` followed by `/compact` that the PreCompact prompt fires (should inject a reminder).

## Related
- Spec#2152 (Compact cycle), Lesson#2161 (prompt-type hooks blocked upstream).
