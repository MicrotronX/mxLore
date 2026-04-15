---
name: mxMigrateToDb
description: Use when the user says "/mxMigrateToDb", "migrate to db", "migrate local docs to mcp", "sync local docs", "import docs to knowledge db", "--extract-backlog", "extract legacy backlog", or otherwise wants to import local `docs/*.md` fallback files into the MCP Knowledge-DB. Runs after MCP outages (when offline-fallback created local files) or once after initial MCP setup. Supports dry-run, cleanup, sync, scan, and --extract-backlog modes. ⚡ MCP-required — aborts if Knowledge-DB is unreachable.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /mxMigrateToDb — Import local documents into Knowledge-DB

> **Context rule:** ALWAYS run this skill as subagent (Agent tool), never in main context. MCP responses and edit diffs fill the context unnecessarily otherwise. Result: compact report, max 20 lines.

## Trigger phrases

This skill fires on:
- `/mxMigrateToDb`, `--extract-backlog`
- Natural language: "migrate to db", "migrate local docs to mcp", "sync local docs", "import docs to knowledge db", "extract legacy backlog", "offline-fallback cleanup"
- Programmatic: mxInitProject step 6 (Migration) auto-invokes this after MCP project registration when local legacy files are detected

## MCP Required
⚡ mxMigrateToDb is MCP-dependent by design. Every mode (--dry-run, --cleanup, --sync, --scan, --extract-backlog) writes to the Knowledge-DB via `mx_migrate_project`, `mx_batch_create`, or `mx_create_doc`. If `mx_ping` fails in the prerequisite phase → print `"MCP unreachable — /mxMigrateToDb requires MCP."` and ABORT. No partial runs, no local-only fallback mode. The caller should retry once MCP is back.

Migration agent. Import local `docs/*.md` files of a project into the central Knowledge-DB via MCP tool `mx_migrate_project`.

## Determine project context (IMPORTANT: avoid duplicates!)

1. Read CLAUDE.md and find the `**Slug:**` line → that is the `project_slug`
2. If no slug in CLAUDE.md:
   a. **Check DB first:** Call `mx_search(query='<directoryname>')` to see if the project already exists (possibly under a different slug name). Also check the path in the search results.
   b. If match with matching project: Use that slug and inform the user ("Project already exists as `<slug>` in the DB")
   c. If no match: Derive a suggestion from the directory name and ask the user for confirmation (e.g. "Slug suggestion: `my-project` — does that work, or a different one?")
   d. **NEVER adopt a slug automatically without confirmation!**
3. Once the slug is determined: Write it into CLAUDE.md as `**Slug:** <slug>` (so it is found next time)

## Check prerequisites

1. **MCP server reachable?** — Call `mx_ping()`. On error: Up to 3 retries with short pause (5s). Only after 3 failures: abort.
2. **Project registered?** — Call `mx_briefing(project='<slug>')`.
   - If "Project not found": Ask the user for the **project name** (e.g. "Project name for `<slug>`? (e.g. 'My Project — Short description')"). Then call `mx_init_project(project_name='<answer>')`.
   - **NEVER** use the slug as project name without asking!
   - If present: Note project_id and existing document count.
3. **Local documents present?** — Check if `docs/` contains any .md files (recursively all subdirectories).
   - The server imports ALL *.md files from docs/ and all subdirectories
   - Only `index.md` and `status.md` are skipped
   - doc_type is determined automatically based on the filename (PLAN-→plan, SPEC-→spec, ADR-→decision, session-notes→session_note, workflow-log→workflow_log, everything else→reference)
   - If no .md files found: "No migratable documents found."
   - **IMPORTANT:** Legacy files without standard prefix (design docs, findings, numbered notes etc.) are also imported as `reference` — everything in docs/ is project knowledge!

## Modes

| Argument | Mode |
|----------|------|
| (no argument) | Import: Import local files into DB |
| `--dry-run` | Only show what would be imported, change nothing |
| `--cleanup` | Cleanup only: Delete local files already present in DB |
| `--sync` | Import + Cleanup in one step (recommended after MCP outage) |
| `--scan` | Auto-scan: Compare local docs against DB + stub detection |
| `--extract-backlog` | Extract legacy backlog from status.md and create directly as MCP docs |

### Extract-Backlog Mode (--extract-backlog)

Extracts backlog/todo lists from `docs/status.md` and creates them directly as MCP documents (plans/todos). Replaces the former mxMigratelegacy skill.

1. **Analyze status.md:**
   - Read `docs/status.md` and identify backlog sections:
     - Long bullet lists with open items (>3 consecutive bullets)
     - Sections: "Backlog", "ToDo", "Open Tasks", "Next Steps", "Naechste Aufgaben", "Spaetere Features", "Offene Punkte"
   - **Do not extract** (keep in status.md):
     - "Implemented Features" lists (history)
     - "Migrations" lists (reference)
     - "Known Issues" (short lists, max 5 entries)
     - Single references or one-liners

2. **Create MCP docs (directly in DB, no local files):**
   - Per identified backlog group: `mx_create_doc(project, doc_type='plan', title='PLAN: Legacy Backlog — <groupname>', content, status='draft')`
   - Content template:
     ```markdown
     # PLAN: Legacy Backlog — <groupname>
     **Created:** YYYY-MM-DD | **Status:** draft | **Source:** docs/status.md

     ## Tasks
     - [ ] Task 1
     - [ ] Task 2
     - [x] Completed task
     ```
   - Items marked as done → `[x]`
   - Unclear status → `[ ]` with note "(status unclear)"

3. **Shorten status.md:**
   - Replace extracted task lists with reference:
     `> Backlog migrated to Knowledge-DB (doc_id=X, YYYY-MM-DD)`
   - Keep non-backlog content

4. **Report:**
   ```
   Backlog extraction completed:
   - Created: X MCP docs (plans)
   - Extracted tasks: Y (of which Z completed)
   - status.md shortened: N lines removed
   ```

### Scan Mode (--scan)

Checks local docs/ against DB and detects stubs. No import, report only.

1. **Find non-migrated files:**
   - `mx_search(project, limit=50)` → load all DB docs → build `existing_slugs` set (⚡ 1 call instead of N)
   - List all *.md in docs/ (recursive, except index.md, status.md, CLAUDE.md)
   - Per file: Check file slug against `existing_slugs`. !mx_search per file
   - No match = not migrated → include in report
2. **Stub detection in DB:**
   - `mx_search(project, limit=50)` → load all docs
   - For each doc: Check token estimate from mx_search response
   - Docs with token_estimate < 50 = stub → include in report
3. **Output report:**
   ```
   ## Auto-Scan Report

   ### Non-migrated local files
   | File | doc_type (estimated) |
   |------|----------------------|
   | docs/plans/PLAN-foo.md | plan |

   ### Stub documents in DB (<50 tokens)
   | doc_id | Title | doc_type | Tokens |
   |--------|-------|----------|--------|
   | 360 | PLAN: Stub | plan | 12 |

   ### Recommendation
   - X files not migrated → run `/mxMigrateToDb`
   - Y stubs in DB → fill in or delete
   ```
4. **Do not make any changes** — report only

### Dry-Run Mode

- Only show which files would be migrated (table with file → doc_type mapping)
- Do NOT perform migration
- Output summary and ask whether migration should start

## Execute migration

### Strategy: Client-side batch migration (always works — including remote)

The skill reads files LOCALLY (Claude Code has file access) and sends them in batch to the DB via `mx_batch_create`. No filesystem access from server needed.

**Workflow (batch strategy — collect all files, then one call):**

0. **Pre-load DB inventory (⚡ MANDATORY — avoids N+1 searches):**
   `mx_search(project='<slug>', limit=50)` → load all existing docs. If >50: second call with offset. Build set from this: `existing_slugs: set of string` (from slug field). Use this set for ALL duplicate checks. !individual mx_search per file.
1. **Collection phase:** For each file in docs/:
   a. Read file locally (Read tool)
   b. Determine doc_type based on filename (see mapping)
   c. Parse status: Search content for `**Status:** <value>` (regex: `\*\*Status:\*\*\s*(\w+)`). If found: Map to DB status (see status mapping). If not: no status parameter (default 'draft').
   d. Duplicate check: Check file slug against `existing_slugs` set — if match with same doc_type: skip. ⚡ !mx_search per file
   e. Collect non-duplicates in items array: `{project, doc_type, title, content, status}`
2. **Batch import:** `mx_batch_create(items='[{...}, {...}, ...]')` — all documents in one transaction. Returns: array with doc_ids. Maintain import map: filename → doc_id (for relations phase).
3. Log result (imported / skipped / errors)

**Batch limit:** If >20 files: split into groups of 20 (multiple mx_batch_create calls).
**On connection error:** Up to 3 retry attempts with 5s pause per batch. After 3 failures: mark batch as failed, continue to next.

### doc_type Mapping (client-side)

| Filename pattern | doc_type |
|---|---|
| `PLAN-*` | plan |
| `SPEC-*` | spec |
| `ADR-*` | decision |
| `*session-notes*` | session_note |
| `workflow-log*` | workflow_log |
| Everything else | reference |

### Status Mapping (Content → DB)

| Content `**Status:**` | DB status |
|---|---|
| accepted | active |
| proposed | draft |
| active | active |
| completed | archived |
| superseded | superseded |
| deprecated | archived |
| paused | draft |
| cancelled | archived |
| (not found) | draft (default) |

### Relations Phase (after import loop)

After ALL files are imported, analyze Markdown links between documents:

1. For each imported document: Scan content for links to other docs/ files
   - Regex: `\[.*?\]\((.*?\.md)\)` or text patterns `See (PLAN|ADR|SPEC)-...`
2. Extract target slug from link path
3. Look up in import map (filename → doc_id)
4. If match: Call `mx_add_relation()`:
   - ADR → PLAN: `leads_to`
   - PLAN → PLAN: `leads_to`
   - SPEC → PLAN: `implements`
   - Other: `references`
5. Result: `N relations created`

### Excluded files (do NOT import)

- `index.md` (index files)
- `status.md` (stays local)
- `CLAUDE.md` (stays local)

### All other files

All *.md files that don't match a known prefix are imported as `reference`. This includes: design docs, findings, numbered session notes, brainstormings, meeting notes etc. **Nothing is lost — everything in docs/ is project knowledge!**

## After migration

1. **Show result:**

```
Migration completed:
- Imported: X documents
- Skipped (duplicates): Y
- Errors: Z

| doc_type | Count |
|----------|-------|
| plan | ... |
| spec | ... |
| decision | ... |
| session_note | ... |
| workflow_log | ... |
| reference | ... |
```

2. **Summaries:** Removed (B6.5) — server-autonomous batch job, no manual call needed.

3. **Verification:** Call `mx_briefing(project='<slug>')` and show the current document overview.

4. **Health check:** Run `/mxHealth` as subagent — checks import quality (missing relations, bad summaries, wrong statuses).

5. **Output notes:**
   - "Local index files (index.md) are no longer needed — the DB is the source of truth."
   - "docs/status.md and CLAUDE.md stay local (maintained by /mxSave)."
   - If `docs/reference/` exists: "Reference files additionally remain local."

## Cleanup Phase (with --cleanup or --sync)

After successful import (or separately with `--cleanup`): Remove local fallback files that are now in the DB.

### Cleanup workflow

1. **Pre-load DB inventory (⚡ 1 call instead of N):** `mx_search(project, limit=50)` → build `existing_slugs` set (same as import phase).
   **For each local file** in `docs/plans/`, `docs/specs/`, `docs/decisions/`:
   - Check file slug against `existing_slugs`. !mx_search per file
   - If YES and content matches → delete file
   - If NO → keep file (not yet imported)

2. **Protected files (NEVER delete):**
   - `CLAUDE.md` — always stays local
   - `docs/status.md` — always stays local
   - `docs/ops/workflow-log.md` — stays as local fallback
   - `docs/reference/*.md` — stay as local reference
   - `*/index.md` — index files stay

3. **Deletable files (only after DB verification):**
   - `docs/plans/PLAN-*.md` — if present in DB
   - `docs/specs/SPEC-*.md` — if present in DB
   - `docs/decisions/ADR-*.md` — if present in DB
   - `docs/plans/session-notes-*.md` — if present in DB

4. **Clean up index files:**
   - Remove lines from `docs/plans/index.md`, `docs/specs/index.md`, `docs/decisions/index.md` that reference deleted files
   - If index is empty afterwards: Insert placeholder line (`_No local entries — documents in Knowledge-DB_`)

5. **Reference update (MANDATORY after each file deletion):**
   For each deleted file, search for the filename (without path) in local files and update links:
   - Grep for filename in: `CLAUDE.md`, `docs/status.md`, `docs/*/index.md`
   - Replace each Markdown link `[text](path/file.md)` with: `text (Knowledge-DB, doc_id=X)`
   - `docs/status.md` is NOT deleted but MUST be searched for dead links

6. **Output result:**

```
Cleanup completed:
- Deleted: X files (verified in DB)
- Kept: Y files (protected or not in DB)

| File | Action | Reason |
|------|--------|--------|
| docs/plans/PLAN-foo.md | deleted | in DB (doc_id=42) |
| docs/status.md | kept | protected |
```

## Rules

- **Idempotent:** Duplicates are detected by the server and skipped.
- **Cleanup only after verification:** Local file is ONLY deleted if the document is verifiably present in the DB (mx_search match).
- **Protected files:** CLAUDE.md, status.md, workflow-log.md, reference/, index.md are NEVER deleted.
- **Forward slashes:** Path parameters always with `/` instead of `\` (ADR-0001 TMS bug).
- **Encoding:** Server detects ANSI vs. UTF-8 automatically.
- **MCP errors:** On error → show error message, inform user. NO cleanup if import failed.
- **Connection loss during migration:** If an MCP call fails (timeout, connection reset), up to 3 retry attempts with 5s pause. Only after 3 failures mark the step as failed and continue to the next. Final summary: X successful, Y failed (with filenames).
- ⚡ **ClampVarchar (Bug#2889) before every write:** `title` max 255 chars (long legacy filenames like `PLAN-some-very-long-descriptive-name-with-many-words.md` can exceed this — trim locally), `slug` max 100 chars (derived from filename, truncate at `-` boundary after normalize), `change_reason` max 500 chars. Long values silently clamp server-side.
- ⚡ **Mirror sync:** edits to this skill MUST propagate to `V:\Projekte\MX_Intern\mxLore-skills\mxMigrateToDb\` + `V:\Projekte\MX_Intern\mxHannesMCP\claude-setup\skills\mxMigrateToDb\` (per `feedback_mxlore_skill_sync_workflow.md`). Canonical first, then `cp` to both mirrors.
