<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
## Delta-Check Mode (`--delta-check`)

⚡ **Not a save:** `--delta-check` runs ONLY the Final Block (the "/clear worthwhile?" deltas recommendation). It writes no session note, no CLAUDE.md/status.md pointer, and no state. The full resume-capable save is the DEFAULT `/mxSave` (Steps 1-6, incl. the ⚡ALWAYS Quickstart + Tooling-gotchas sections in Step 5). Difference between save modes is Cleanup-DEPTH (loop = light, full = pre-clear), never "resume-capable or not" — every real save is resume-capable.

⚡ **Legacy flag:** `--clear-cycle` was the former name. It falsely implied the flag performed the Clear-Cycle *save*; it never did. Accept `--clear-cycle` as a deprecated alias for `--delta-check` and warn once (`--clear-cycle is deprecated, use --delta-check`). Do NOT silently ignore it — a dropped flag looks like a completed check.

⚡ Check only, not a save. Skips Steps 1-6 and runs ONLY the Final Block, using **`N = state.state_deltas`** (in-flight, NOT the stale `last_save_deltas` — Step 4 snapshot is skipped in this mode). Flag precedence: `--delta-check` — and its deprecated `--clear-cycle` alias, which resolves to `--delta-check` BEFORE precedence is evaluated — wins over `--loop`.

Sequence:
1. Init (read state file only — no MCP roundtrip; loadState contract: corrupt/missing → empty state).
2. Skip Steps 1-6.
3. Final Block with `N = state.state_deltas`.
4. Exit (do NOT touch state_deltas, CLAUDE.md, status.md).

## Re-stamp Mode (`--restamp`)

A save is rarely the last step of a session. Writes after it leave `last_save` and the handoff header behind, so the next resume reports a gap or discards the handoff. Re-stamp carries those writes into the existing note instead of writing a second one.

**Routing (default run with no flags, before Step 1; `--loop` never routes here):** needs `mcp_available`, then two calls:
- `mx_session_delta(project, session_id=<state.session_id>, limit=50)` lists `state.last_save_session_note_doc_id` (the note belongs to this session).
- `mx_session_delta(project, since=state.last_save, limit=50)` returns `total_changes <= 5` with empty `warnings`, and `state.state_deltas == 0`.

All true → re-stamp. Else → full save. `--restamp` with a note from another session → full save, with one line saying why. `total_changes == 0` and no local edits since the save → output `mxSave: nothing since last save`, write nothing.

**Sequence (order matters, no done-marker before the proven side effect):**
1. `mx_update_doc(<note>, append_content='## After save <now_utc>\n<facts: each change since the save, confirmed only>', change_reason='re-stamp')`. Error → stop, change nothing.
2. Local edits since the save belong in CLAUDE.md/status.md as usual; a changed next step also goes into the handoff body.
3. `date -u` AFTER step 1, then one state write: `last_save`, `last_reconciliation` = now_utc; `last_save_deltas += state_deltas`; `state_deltas = 0`; `subagent_ran_since_save = false`. Note id unchanged.
4. Edit handoff line 1 to the new `last_save` (only if the file exists; same note_id). Body over the Step 5b cap → cut per Step 5b.
5. Output `mxSave: re-stamped note <id> (<N> changes)`. Skips Steps 1-6 and the Final Block.

## Loop Mode (--loop or /loop context)

**Idempotency:** `mx_session_delta(project, session_id=<state.session_id>, limit=1)` → `total_changes`. ⚡ `limit=1` is CORRECT here: this is a boolean `==0` test, and `total_changes==0` iff zero rows match on every server build. Contrast Step 6, whose `total_changes` the Final Block reads as a MAGNITUDE and which therefore needs `limit=50`. Null session_id → skip check, normal save. **Step 4a always runs** (detects local-only divergence that produces no MCP activity); the Step-3 backlog auto-close block also always runs (deadlines pass without any MCP activity); Step 4b + Step 5 skipped on idempotent branch.

**Output decision (after Step 4a counters):**

| Condition | Output |
|---|---|
| `total_changes==0` AND `N==K==W==0` AND ∅unsynced-push | `mxSave: No changes` |
| `total_changes==0` AND `any(N,K,W,unsynced)>0` | `mxSave: No session-delta; local-sync: <X> unsynced pushed, <N> step-syncs (<K> failed, <W> MCP-ahead)` |
| `total_changes>0` | normal save, compact 1-line-per-step output |

Constraints: !settings.local.json cleanup (manual only), !Prompts, !interactive steps, shorter session note (changes since last save). ⚡ Whenever a loop note IS written (the `total_changes>0` branch — the idempotent `total_changes==0` branch writes no note and this does not apply), that shorter note STILL carries the two ⚡ALWAYS Step-5 sections (`## Quickstart after /clear` ≥1 line + `## Tooling gotchas + verify`) — loop is the light CLEANUP stage, not a resume-less save. Final Block downgrades N>=15 active prompt to >=10 tip line (no interactive waits).
