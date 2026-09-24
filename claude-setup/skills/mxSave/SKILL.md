---
name: mxSave
description: Use when the user says "save state", "/mxSave", "session end", "before /compact", "wrap up", or otherwise wants to persist the current mx-project state (clean settings, update CLAUDE.md + docs/status.md, create session notes in MCP-DB, sync orchestrate-state deltas, emit clear-cycle tip). Loop-capable. Fires at natural session-end boundaries.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Task, AskUserQuestion
argument-hint: "[optional-notes] [--loop] [--delta-check]"
---

# /mxSave — Persist Project State (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

Thin dispatcher. Each step: read its `references/` file BEFORE executing it (verbatim procedure there). ⚡ Delegating a step to a subagent → put the ABSOLUTE path (skill base dir + `references/<file>`) of that step's file and of every file it names (e.g. `lesson-template.json`) into the spawn prompt; a subagent never sees this skill's base dir.

## Execution Mode ⚡
Phased: Main 1,1b,2 → parallel A (3 bg-subagent sonnet + 4a Main) → Main 5 sync → Main 4b + 5b → B: 6 fire-and-forget. !single fan-out. Context/Init/phases/degraded path → `references/init-and-execution-mode.md`.

## Steps
- **Init** (slug, load deferred tools, mx_ping→`mcp_available`, state-file safety) → `references/init-and-execution-mode.md`
- **1** settings.local.json clean, **1b** artifact sweep (report-only) → `references/step1-settings-artifacts.md`
- **2** CLAUDE.md + status.md (byte gates, `note#PENDING`, zombie check) → `references/step2-claude-status.md`
- **3** MCP docs (WF cleanup, stale sweep, archive, FR/BR closure in Main, lessons, findings) → `references/step3-mcp-docs.md`
- **4a/4b** orchestrate state sync → `references/step4-orchestrate-sync.md`
- **5** session note (Main, sync) → `references/step5-session-note.md` + `references/body-validation.md`
- **5b** resume handoff → `references/step5b-handoff.md`
- **6** peer notify + Final Block → `references/step6-final-block.md`
- Modes `--delta-check` (alias `--clear-cycle`), `--loop` → `references/modes-delta-check-loop.md`
- Rules + Completion output → `references/rules-completion.md`

## Invariants (every run) ⚡
- ⚡ `last_save_deltas = state_deltas` set ONLY in 4a (single writer), BEFORE reset; one deferred state.json write in 4b.
- ⚡ No done-marker before the proven side effect (handoff only after note doc_id + 4b write landed).
- ⚡ Handoff ignore gate: `git check-ignore` exit 1 → no write, delete existing.
- ⚡ Status-entry discipline: exactly ONE `**Status:**` entry + ONE History pointer; replace, never accumulate. Pointers exactly once, verify greps ASCII-only.
- ⚡ status.md: remove a block only if it carries `#NNNN`.
- ⚡ now_utc from `date -u`, never the chat clock.
- ⚡ Note sections `Quickstart after /clear`, `Blocked on me`, `Tooling gotchas + verify` never omitted; `status='active'`.
- ⚡ NO internal reasoning in notes/summary; facts only, confirmed-implemented only.
- ⚡ Batch-dismiss of findings forbidden; mxSave writes no verdicts.
- ⚡ Prompts via AskUserQuestion; never auto-archive FR/BR.
- ⚡ `--delta-check` is not a save.
