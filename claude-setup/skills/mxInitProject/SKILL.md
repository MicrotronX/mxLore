---
name: mxInitProject
description: "You are a repo bootstrap agent. Set up a scalable AI documentation structure in the current repository without breaking existing content."
user-invocable: true
effort: low
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill
---

You are a repo bootstrap agent. Set up a scalable AI documentation structure in the current repository without breaking existing content.

## Idempotency Guarantee ⚡

This skill is **safe for repeated invocation**. Pre-flight check BEFORE all steps:

1. Glob: `CLAUDE.md` in project root → exists?
2. Glob: `docs/status.md` → exists?
3. Glob: `docs/decisions/`, `docs/specs/`, `docs/plans/`, `docs/ops/`, `docs/reference/` → exist?
4. If CLAUDE.md exists: Grep `AI Start Here` → block present?
5. If MCP mode: `mx_briefing(project)` → project registered?

**Decision matrix:**
| CLAUDE.md | AI-Start-Here | Directories | MCP-Project | status.md | Result |
|-----------|---------------|-------------|-------------|-----------|--------|
| ✓ | ✓ | ✓ | ✓ | ✓ | `"Everything present — no changes needed."` → **ABORT IMMEDIATELY** |
| ✓ | ✗ | ✓ | ✓ | ✓ | Only insert AI-Start-Here block |
| ✗ | — | ✗ | ✗ | ✗ | Full bootstrap (all steps) |
| ✓ | ✓ | ✓ | ✗ | ✓ | Only MCP registration (step 2) |
| any | any | any | any | any | Only create missing parts, skip existing ones |

⚡ **Each step individually checks whether its artifact exists → skip if yes.**
⚡ **Never overwrite, delete, or duplicate existing content.**

## Project Context / MCP Detection

MCP availability is checked as follows (in this order):

1. **Call `mx_ping()`** — if successful: MCP mode (server configured globally or per project)
2. If mx_ping fails: check `.mcp.json` in project directory (fallback)
3. If both negative: non-MCP mode (local files)

**MCP mode:** Do not create local index files — the Knowledge-DB is the source of truth.
**Non-MCP mode:** Create local index files (decisions/index.md, specs/index.md, plans/index.md).

## 0. Project-specific MCP Server (optional)

Enables multi-team scenarios: different projects can use different mxLore servers.

**When to ask:** Only during initial setup (CLAUDE.md does NOT exist yet) and MCP is globally available (mx_ping OK).
**Do not ask:** On idempotency skip, in non-MCP mode, or for already configured projects.

?user: "MCP server for this project? (Enter=use global server, or enter custom URL)"

**If Enter (default/global):** Continue as before — global user-scope MCP is used. Do not write `.mcp.json`, no local proxy.

**If custom URL:**
1. Validate URL: must start with `https://` and end with `/mcp`
2. Request API key: ?user: "API key for this server? (starts with mxk_)"
3. **Create proxy INI:** `.claude/mxMCPProxy.ini` in the project directory:
   ```ini
   [Server]
   BaseUrl=<URL without /mcp suffix>
   ApiKey=<API-KEY>
   McpEndpoint=/mcp

   [Agent]
   Polling=1
   PollInterval=15
   ```
4. **Proxy EXE:** Link global `~/.claude/mxMCPProxy.exe` or note the path
5. **Create/update `.mcp.json`** in the project directory:
   ```json
   {
     "mcpServers": {
       "mxai-knowledge": {
         "command": "<absolute-path-to>/.claude/mxMCPProxy.exe",
         "args": ["<absolute-path-to-project>/.claude/mxMCPProxy.ini"]
       }
     }
   }
   ```
   (Proxy takes INI path as first argument, no flag needed)
   ⚡ If `.mcp.json` already exists: only add/replace the `mxai-knowledge` key, keep the rest
6. **Test:** Call `mx_ping()` — must reach the project-specific server
   - Success: "Project MCP configured: <URL>"
   - Failure: Check URL/key, abort with notice
7. Add `.claude/` to `.gitignore` (INI contains API key)

⚡ **Transparency:** After this step, all mx*-skills automatically communicate with the project server instead of the global one. No further changes needed.

## 1. Create directories (if missing)

Create these directories if they do not already exist:
- docs/decisions
- docs/specs
- docs/plans
- docs/ops
- docs/reference

## 1b. Workflow Log (non-MCP projects only)

If non-MCP mode (mx_ping failed) AND `docs/ops/workflow-log.md` does not exist, create:

```markdown
# Workflow Log

<!-- Entries are added automatically via /mxOrchestrate. Do not edit manually. -->
```

For MCP projects, workflows are stored in the DB.

## 2. Index files (non-MCP projects only)

**If MCP mode (mx_ping successful):** Do not create index files. Instead check if the project is registered in the DB:
1. Read slug from CLAUDE.md (`**Slug:**` line). If no slug: derive from directory name and ask the user: "Suggested project slug: `<slug>` — does that work?"
2. Call `mx_briefing(project='<slug>')`
3. If "Project not found":
   - **STOP — MUST ask the user!** Question: "Project name for `<slug>`? (e.g. 'My Project — Short description')"
   - **Wait for response.** Only THEN call `mx_init_project(project_name='<response>')`.
   - **NEVER** use the slug or a self-invented name as the project name!
4. Add slug to CLAUDE.md if not already present

**If non-MCP mode:** Create index files as before:

### docs/decisions/index.md
```markdown
# Architecture Decision Records (ADR)

Decisions are created exclusively via `/mxDecision`.

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| — | _No entries yet_ | — | — |
```

### docs/specs/index.md
```markdown
# Specifications (Specs)

Specs are created exclusively via `/mxSpec`.

| Spec | Title | Date |
|------|-------|------|
| — | _No entries yet_ | — |
```

### docs/plans/index.md
```markdown
# Plans

Plans are created exclusively via `/mxPlan`.

| Plan | Title | Status | Date |
|------|-------|--------|------|
| — | _No entries yet_ | — | — |
```

## 3. Adjust CLAUDE.md

If CLAUDE.md exists: Insert an "AI Start Here" block at the TOP (after the first H1 line). Do NOT overwrite anything — insert only.

If CLAUDE.md does not exist: Create a minimal CLAUDE.md using the following template.
**IMPORTANT:** ONLY project-specific info. No global rules (security, encoding, etc.) — those are in `~/.claude/CLAUDE.md`.

### Project CLAUDE.md Template (when newly created)

```markdown
# <ProjectName>

> **AI Start Here** — [AI Start Here Block as below]

## Project

- **Slug:** <slug>
- **Stack:** <detected stack, e.g. "Delphi + FireDAC" or "PHP + Laravel">
- **Status:** Initialized

## Architecture

_(will be expanded as the project progresses)_

## Rules (project-specific)

_(only rules that apply ONLY to this project, do not duplicate global rules)_
```

If CLAUDE.md exists: Insert ONLY the "AI Start Here" block (after the first H1 line). Do NOT overwrite anything.

### Block to insert (MCP project)

If MCP mode:

```markdown
> **AI Start Here** — Read these files to get started:
>
> | Document | Purpose |
> |----------|---------|
> | [CLAUDE.md](./CLAUDE.md) | Architecture, conventions, rules (this file) |
> | [docs/status.md](./docs/status.md) | Current project status, open items |
>
> **Documentation rules (MCP-based):**
> - Decisions ONLY via `/mxDecision` → Knowledge-DB (doc_type='decision')
> - Plans ONLY via `/mxPlan` → Knowledge-DB (doc_type='plan')
> - Specs ONLY via `/mxSpec` → Knowledge-DB (doc_type='spec')
> - `/mxSave` updates CLAUDE.md + docs/status.md (local) + session notes (DB)
> - Search documents: `mx_search(project='<slug>', ...)` or `mx_briefing(project='<slug>')`
> - CLAUDE.md stays compact: links + rules + architecture. No long backlogs.
```

### Block to insert (non-MCP project)

If no MCP server:

```markdown
> **AI Start Here** — Read these files to get started:
>
> | Document | Purpose |
> |----------|---------|
> | [CLAUDE.md](./CLAUDE.md) | Architecture, conventions, rules (this file) |
> | [docs/status.md](./docs/status.md) | Current project status, open items |
> | [docs/decisions/index.md](./docs/decisions/index.md) | Architecture Decision Records (ADR) |
> | [docs/specs/index.md](./docs/specs/index.md) | Specifications |
> | [docs/plans/](./docs/plans/) | Plans and session notes |
>
> **Documentation rules:**
> - Decisions ONLY via `/mxDecision` → `docs/decisions/ADR-XXXX-slug.md`
> - Plans ONLY via `/mxPlan` → `docs/plans/PLAN-XXXX-slug.md`
> - Specs ONLY via `/mxSpec` → `docs/specs/SPEC-slug.md`
> - `/mxSave` updates `docs/status.md` + session notes
> - CLAUDE.md stays compact: links + rules + architecture. No long backlogs.
```

## 4. Create docs/status.md (if missing)

If `docs/status.md` does not exist, create a minimal file:

```markdown
# Project Status

_Created via /mxInitProject_

## Implemented Features

- (none yet)

## Open Items

- (none yet)
```

## 5. Summary Report

Output a table with all created/modified files and the respective action (created / modified / already present / skipped (MCP)).

## 6. Migration (MCP projects)

If MCP mode and project registered in DB:
- Check if `docs/status.md` contains migratable task lists (backlog, ToDo, open tasks, etc.)
  - If yes: Automatically run `/mxMigrateToDb --extract-backlog` via Skill tool
  - If no task lists: "No legacy backlogs found — extraction skipped."
- Check if `docs/` contains local .md files (PLAN-*, SPEC-*, ADR-*, session-notes-*)
  - If yes: Automatically run `/mxMigrateToDb --sync` via Skill tool
  - If no migratable files: "No local documents found for migration."

## Important Rules

- **Never** overwrite or delete existing content
- **Never** create files that already exist (only check and report "already present")
- For CLAUDE.md ONLY insert the "AI Start Here" block if it is not already present
- All files in UTF-8 without BOM
- **Idempotency:** On repeated invocation, abort immediately if everything is present (pre-flight check)
- **Summary report ALWAYS:** Even on immediate abort, output the table with status "already present"
