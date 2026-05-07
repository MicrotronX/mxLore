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

Migration agent. Import local `docs/*.md` files of a project into the central Knowledge-DB. Primary tool is `mx_batch_create` (client-side batch strategy, works for all deployments including remote). `mx_migrate_project` exists as a server-side variant but is NOT the primary path — this skill uses the client-side batch approach for consistency and retriability.

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
   - If "Project not found": Ask the user for the **project name** (e.g. "Project name for `<slug>`? (e.g. 'My Project — Short description')"). Then call `mx_init_project(slug='<slug>', project_name='<answer>')`. ⚡ The `slug` parameter is REQUIRED per `mx.Tool.Write.Meta.pas:46-47` — server raises `EMxValidation('Parameter "slug" is required')` if omitted. Param name is literally `slug` (NOT `project_slug`).
   - **NEVER** use the slug as project name without asking!
   - If present: Note project_id and existing document count.
3. **Local documents present?** — Check if `docs/` contains any .md files (recursively all subdirectories).
   - The server imports ALL *.md files from docs/ and all subdirectories
   - Only `index.md` and `status.md` are skipped
   - doc_type is determined automatically based on the filename (PLAN-→plan, SPEC-→spec, ADR-→decision, session-notes→session_note, workflow-log→workflow_log, everything else→reference)
   - If no .md files found: "No migratable documents found."
   - **IMPORTANT:** Legacy files without standard prefix (design docs, findings, numbered notes etc.) are also imported as `reference` — everything in docs/ is project knowledge!

## Modes

| Argument | Mode | Detail |
|----------|------|--------|
| (no argument) | Import local files into DB | inline below |
| `--dry-run` | Show what would be imported, change nothing | inline below |
| `--cleanup` | Delete local files already present in DB | inline below |
| `--sync` | Import + Cleanup in one step (recommended after MCP outage) | inline below |
| `--scan` | Compare local docs against DB + stub detection | `references/modes/scan.md` |
| `--extract-backlog` | Extract legacy backlog from status.md → MCP plans | `references/modes/extract-backlog.md` |

⚡ **Mode dispatch:** Argument → mode is fixed by the table above. Each mode has DISTINCT safety contracts; do not blend behaviors.

### Dry-Run Mode

- Only show which files would be migrated (table with file → doc_type mapping)
- Do NOT perform migration
- Output summary and ask whether migration should start

## Execute migration

### Strategy: Client-side batch migration (always works — including remote)

The skill reads files LOCALLY (Claude Code has file access) and sends them in batch to the DB via `mx_batch_create`. No filesystem access from server needed.

**Workflow (batch strategy — collect all files, then one call):**

0. **Pre-load DB inventory (⚡ MANDATORY — avoids N+1 searches):**
   Iterate `mx_search(project='<slug>', doc_type=<dt>, limit=50)` once per `doc_type` and merge results into `existing_slugs` set. Use this set for ALL duplicate checks. !individual mx_search per file.
   ⚡ **50-cap fail-safe (inline-mandatory):** `mx_search` is hard-capped at 50 results per call and has NO offset/pagination. If any per-doc_type call returns exactly 50, log a coverage warning — the project may have un-seen docs and import duplicate-detection may be incomplete.
   Read `references/mx_search-pagination.md` for the per-doc_type loop pattern, full doc_type list, and rationale.
1. **Collection phase:** For each file in docs/:
   a. Read file locally (Read tool)
   b. Determine doc_type based on filename (see `references/migration-mapping.md`)
   c. Parse status: Search content for `**Status:** <value>` using a **case-insensitive** regex `(?i)\*\*status:\*\*\s*(\w+)` to catch `Status:`, `status:`, `STATUS:`, and mixed-case legacy files. Normalize the captured group to lowercase before the mapping lookup. If found: Map to DB status (see `references/migration-mapping.md`). If not: no status parameter (default 'draft').
   d. **Idempotency:** Check file slug against `existing_slugs` set — if match with same doc_type: skip. ⚡ Don't re-migrate already-imported docs. !mx_search per file.
   e. Collect non-duplicates in items array: `{project, doc_type, title, content, status}`
2. **Batch import:** `mx_batch_create(items='[{...}, {...}, ...]')` — all documents in one transaction. Returns: array with doc_ids. Maintain import map: filename → doc_id (for relations phase).
3. Log result (imported / skipped / errors)

**Batch limit:** If >20 files: split into groups of 20 (multiple mx_batch_create calls).
**On connection error:** Up to 3 retry attempts with 5s pause per batch. After 3 failures: mark batch as failed, continue to next.
**Backup-before-modify:** This phase is read-only on local files. Cleanup phase is the destructive one — see safety rails below.

### Mappings (doc_type, status, relations, excludes)

Read `references/migration-mapping.md` for the complete tables. The rule itself is unchanged: filename pattern → `doc_type`, content `**Status:**` → DB status; relations are derived from inter-doc Markdown links after import.

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

⚡ **Safety-rail invariants (inline-mandatory contract):**
- **Pre-load DB inventory by per-doc_type loop, NOT pagination.** mx_search has no offset; hard-capped at 50.
- **50-cap hard fail-safe:** if any per-doc_type call returns exactly 50, ABORT cleanup with explicit error — silent data-loss risk (un-fetched DB matches would be mis-reported as "not in DB" and the local file kept; the inverse would never delete unsafely, but the report is wrong). The user must wait for server-side pagination support.
- **Protected files NEVER deleted:** `CLAUDE.md`, `docs/status.md`, `docs/ops/workflow-log.md`, `docs/reference/*.md`, `*/index.md`. Full annotated list → `references/cleanup.md`.
- **Verify-before-delete:** a local file is deleted ONLY if its slug matches a DB doc with the same doc_type AND content matches. No DB match → keep file.

### Cleanup workflow

1. Pre-load DB inventory using the per-doc_type loop (see `references/mx_search-pagination.md`); apply the 50-cap fail-safe above.
2. **For each local file** in `docs/plans/`, `docs/specs/`, `docs/decisions/`:
   - Check file slug against `existing_slugs`. !mx_search per file.
   - If YES and content matches → delete file.
   - If NO → keep file (not yet imported).
3. Update index files and dead links per `references/cleanup.md` (index-cleanup steps + Markdown-link rewrites in CLAUDE.md / status.md / `docs/*/index.md`).
4. Report deleted vs kept counts (template in `references/cleanup.md`).

## Rules

- **Idempotent:** Duplicates are detected client-side via `existing_slugs` and skipped; the server is the secondary safety net.
- **Cleanup only after verification:** Local file is ONLY deleted if the document is verifiably present in the DB (mx_search match).
- **Protected files:** CLAUDE.md, status.md, workflow-log.md, reference/, index.md are NEVER deleted.
- **Forward slashes:** Path parameters always with `/` instead of `\` (ADR-0001 TMS bug).
- **Encoding:** Server detects ANSI vs. UTF-8 automatically.
- **MCP errors:** On error → show error message, inform user. NO cleanup if import failed.
- **Connection loss during migration:** If an MCP call fails (timeout, connection reset), up to 3 retry attempts with 5s pause. Only after 3 failures mark the step as failed and continue to the next. Final summary: X successful, Y failed (with filenames).
- ⚡ **Clamp limits before every write:** Read `~/.claude/skills/_shared/mcp-clamp-limits.md`.
- ⚡ **Mirror sync:** Read `~/.claude/skills/_shared/mirror-sync.md`.
