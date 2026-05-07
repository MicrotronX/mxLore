---
name: mxHealth
description: Use when the user says "/health", "/mxHealth", "health check", "check knowledge db", "verify consistency", "db health", or otherwise wants to verify Knowledge-DB and docs/ consistency via MCP. Runs 14 consistency checks (document metadata, cross-references, orphaned relations, status consistency, CLAUDE.md weight, local/DB sync, AI-Steno format, skill-evolution metrics, AI-Batch status) and persists findings via Skill Evolution. Loop-capable. ⚡ MCP-required — aborts if Knowledge-DB is unreachable.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /mxHealth — Knowledge-DB Consistency Checker (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS run as subagent(Agent-Tool) !main-context. Result: max 20 lines, problems only.

Health-Check-Agent. Verify consistency of Knowledge-DB + local docs/.

## Trigger phrases

This skill fires on:
- `/health`, `/mxHealth`
- Natural language: "health check", "check knowledge db", "verify consistency", "db health", "audit the project state"
- Programmatic: pre-release validation, periodic `/loop` invocation, pre-commit integrity sweep

## MCP Required
⚡ mxHealth is MCP-dependent by design. Phases P1-P14 all query the Knowledge-DB. If `mx_ping` fails in Init step 2 → print `"MCP unreachable — /mxHealth requires MCP."` and ABORT. No partial runs, no local-only fallback mode. The caller should retry once MCP is back.

## Init
1. CLAUDE.md→`**Slug:**`=project. ∅slug→?user
2. mx_ping()→OK=continue | Error→"MCP unreachable — /mxHealth requires MCP." ABORT

## Phase 1: Load Inventory
Execute in parallel:
1. `mx_briefing(project)` — Overview
2. `mx_search(project, doc_type='plan')` + `spec` + `decision` + `workflow_log`
3. Glob local: `docs/reference/*.md`
4. Read CLAUDE.md + docs/status.md
5. Count: DB-Docs total, local reference files, CLAUDE.md line count

## Phase 2: 14 Checks

Per-check details (trigger, what is checked, severity, persistence target) →
`Read ~/.claude/skills/mxHealth/references/checks.md.`

| #   | Check                          | Severity         |
|-----|--------------------------------|------------------|
| P1  | Document Metadata (DB)         | ERROR/WARNING    |
| P2  | Format Consistency (sample)    | INFO             |
| P3  | Cross-Reference Consistency    | ERROR/WARNING    |
| P4  | Status Consistency (PLAN/ADR)  | WARNING          |
| P5  | Workflow Consistency           | WARNING          |
| P6  | Local/DB Sync                  | WARNING/INFO     |
| P7  | CLAUDE.md + Reference          | ERROR/WARNING/INFO |
| P8  | Orphaned Local Files           | INFO             |
| P9  | Content Depth (token<50)       | WARNING          |
| P10 | Auto-Relations Scan            | INFO             |
| P11 | CLAUDE.md Duplicate Check      | WARNING          |
| P12 | AI-Steno Format Check          | WARNING          |
| P13 | Skill Evolution Metrics        | WARNING/INFO     |
| P14 | AI-Batch Status                | WARNING/INFO     |

ERROR vs WARNING is binding: ERROR = invariant violation (must fix); WARNING
= drift/risk (should fix); INFO = advisory (no persistence).

## Phase 3: Report

```markdown
## /mxHealth Report — YYYY-MM-DD HH:MM
**Project:** <slug> | **Scope:** <all|decisions|plans|specs|workflows>

### DB Inventory
| doc_type | Count |
|----------|-------|

### Findings
| # | Severity | Check | Finding | Document |
|---|----------|-------|---------|----------|

### Summary
X ERROR | Y WARNING | Z INFO | Checked: N DB docs, M local files
```
∅problems→`/mxHealth: All checks passed. DB+docs/ consistent.`

### Phase 3b: Persist Findings→MCP Notes (Spec#1139)
For each finding with severity ERROR or WARNING:
1. Deduplication: mx_search(project, doc_type='note', query='[Health] <title>', limit=1)
   - Match with same title→skip
2. mx_create_doc(project, doc_type='note', title='[Health] <finding-title>', content='Severity: <sev>\n<details>\nFound: YYYY-MM-DD', tags=["health-finding","<severity-tag>"])
   - ERROR→tag 'bug', WARNING→tag 'improvement'
3. Output: `Auto-Notes: N created, M skipped (duplicate)`
∅findings or INFO only→skip

## Phase 4: Auto-Bugreport + Persist Findings (ERROR/WARNING)
**Project routing:** Store findings in target project, NOT blanket in mxHannesMCP.
- Skill/Setup/Tool findings (affect mx* infrastructure)→`project='mxHannesMCP'`
- Project-specific findings (stubs, local docs, missing relations)→`project=<target-project>`
`mx_create_doc(project=<see routing>, doc_type='bugreport', title='mxHealth: N Findings...', tags=["mxhealth-auto"], status='reported')`
Deduplication: mx_search before creating. ∅ERROR/WARNING→no report.

⚡ Tags param contract (Phase 3b + Phase 4): `Read ~/.claude/skills/_shared/mcp-tags-array.md.`

**Skill Evolution:** For each finding (ERROR+WARNING): `mx_skill_manage(action='record_finding', skill='mxHealth', rule_id='<pN-lowercase>' (e.g. p1-metadata, p3-crossref, p4-status), project='<slug>', severity='<error|warning>', title='<finding summary>', details='<document + finding>')`
- context_hash='<check>:<document-slug>' for dedup across runs
- ∅MCP→skip (already captured in bugreport)

## Phase 5: Auto-Fix (P9)
P9 findings→removed (B6.5). ∅P9→skip.

## Loop Mode (--loop or /loop context)
- Compact output: only `mxHealth: X ERROR Y WARNING Z INFO` + findings one-liners
- !report header !inventory table !summary block
- !prompts, !interactive steps
- Auto-Fix(P9) run silently, report only on changes
- Bugreport only on ERROR (WARNING→skip in loop)
- ∅findings→single line: `mxHealth OK — 0 problems`

⚡ **Delta semantics:** each iteration fires P1-P14 fresh; finding is "new" if `context_hash` (`<check>:<document-slug>`) was not persisted via `mx_skill_manage(action='record_finding', ...)` in a prior iteration. Matching hash → suppress output line.
⚡ **INFO findings in loop mode:** suppress entirely from output (Phase 4 persists only ERROR+WARNING, so INFOs would re-print every iteration).

## Rules
- Read-only + bug notes + summary fix. !modify document contents
- MCP error→ERROR in report, !abort
- >20 docs/type→sampling(max 10 via mx_batch_detail). P1 on all(from mx_search). ⚡ !individual mx_detail calls→always mx_batch_detail(doc_ids=[...], level='full')
- IP protection: metadata+structure only. UTF-8 without BOM. !assumptions→facts only
- ⚡ **VARCHAR clamps for persisted findings:** `Read ~/.claude/skills/_shared/mcp-clamp-limits.md.` `rule_id` max 100 chars (pN-kebab-case slugs are short, safe), `file_path` max 500 chars, `details` is TEXT (unclamped but keep focused).
- ⚡ **Severity mapping** (report → MCP): `ERROR` → `error`, `WARNING` → `warning`, `INFO` → `info`. Canonical lowercase on the wire.
- ⚡ **Self-check recursion guard:** if mxHealth runs on a project slug named `mxHealth` (none exists), skip Phase 3b/4 persistence. Self-review findings are reported inline only.
- ⚡ **Mirror sync:** `Read ~/.claude/skills/_shared/mirror-sync.md.`
