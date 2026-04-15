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

### P1: Document Metadata (DB)
From mx_search results: title!empty, summary_l1 present, slug unique per project+doc_type.
ERROR=empty titles | WARNING=missing summaries

### P2: Format Consistency (Sample max 5 docs via mx_batch_detail(doc_ids=[...], max_content_tokens=0))
- ADRs: `**Status:**` (accepted|proposed|superseded|deprecated)
- PLANs: `**Status:**` (active|completed|paused|cancelled)
- SPECs: `**Created:**` or `**Slug:**`
- All: H1 heading. Severity: INFO

### P3: Cross-Reference Consistency (DB)
Relations per mx_search(include_details=true): Target exists(!deleted), bidirectionality(A→B then B→A).
ERROR=relation to deleted | WARNING=missing reverse relation

### P4: Status Consistency (DB, Content via mx_batch_detail)
IDs from P1 mx_search collected→mx_batch_detail(doc_ids=[...], max_content_tokens=0) for all active/completed PLANs + proposed ADRs (1 call, max 10 IDs).
- active PLANs MUST contain `- [ ]` OUTSIDE fenced code blocks. ⚡ Strip ` ``` ... ``` ` regions before counting checkboxes; nested task examples inside code blocks do NOT count as real pending tasks.
- completed PLANs MUST NOT have any `- [ ]` outside fenced code blocks.
- proposed ADRs >30 days old→WARNING

### P5: Workflow Consistency (DB, Content via mx_batch_detail)
IDs from P1 mx_search(doc_type='workflow_log') collected→mx_batch_detail(doc_ids=[...], max_content_tokens=0) for all active WFs (1 call).
Active Workflows: MUST have pending steps. >30 days old→WARNING(forgotten?)

### P6: Local/DB Sync
Glob `docs/plans/PLAN-*.md`, `docs/specs/SPEC-*.md`, `docs/decisions/ADR-*.md`→extract slug→mx_search.
Local without DB→WARNING("Not migrated→/mxMigrateToDb"). DB without local→INFO(normal).

### P7: CLAUDE.md + Reference Consistency (local)
- CLAUDE.md >200L→WARNING | >300L→ERROR(urgently offload)
- docs/reference/ files without reference in CLAUDE.md→WARNING
- Dead markdown links→ERROR(local files) | INFO(migrated docs/)

### P8: Orphaned Local Files
Files in docs/plans|specs|decisions/ without naming convention→INFO. index.md with MCP→INFO("no longer needed").

### P9: Content Depth (DB)
All non-archived/deleted docs (EXCLUDING session_note, workflow_log): token_estimate<50→WARNING.
Data source: mx_search results (no mx_detail needed).

### P10: Auto-Relations (Cross-Reference Scan)
MCP required. Sample max 20 docs via mx_batch_detail(doc_ids=[...], max_content_tokens=0) (2 calls of 10). Scan content for:
- `doc_id=NNN`, `#NNN`, `ADR-XXXX`, `PLAN-xxx`, `SPEC-xxx`
- Context phrases→relation type: "based on"→assumes | "replaces"→supersedes | "leads to"→leads_to | "caused by"→caused_by | "depends on"→depends_on | "rejected in favor of"→rejected_in_favor_of | default→references
- Duplicate check before mx_add_relation. Ref: doc_id=620 conventions.
Severity: INFO

### P11: CLAUDE.md Duplicate Check (local)
Global `~/.claude/CLAUDE.md` sections vs project CLAUDE.md. Typical duplicates: Security, Encoding, Context-Management, Shell, Skill-Routing, Delphi/PHP-Mindset.
Project CLAUDE.md >100L→WARNING(goal: max 100L project-specific). !auto-fix→report only.

### P12: AI-Steno Format Check (local)
Check whether CLAUDE.md files use AI-Steno:
1. Project CLAUDE.md: first line must contain `AI-Steno:` OR content must use steno markers (`!`, `→`, `⚡`, `∅`)
2. Global `~/.claude/CLAUDE.md`: same check
3. ∅steno markers found→WARNING: "CLAUDE.md not in AI-Steno format. ~50% token savings possible. Recommendation: convert manually or re-run `/mxInitProject`."
4. Steno present but >200L(global) or >100L(project)→WARNING: "AI-Steno CLAUDE.md too long"
- Severity: WARNING
- Ref: ADR-0010 (AI-Steno standard format)

### P13: Skill Evolution Metrics
MCP required. Iterate over the canonical list of evolution-enabled skills: `[mxBugChecker, mxDesignChecker, mxHealth, mxSave, mxOrchestrate, mxPlan, mxSpec, mxDecision, mxMigrateToDb, mxInitProject]`. For each, call `mx_skill_metrics(skill=<name>, project=<slug>, days=90)`.
- FP rate >50% for a rule→WARNING("Rule {rule_id} has {fp_rate}% false positives — mx_skill_manage(action='tune', ...) recommended")
- >20 pending findings→INFO("N findings awaiting feedback")
- ∅skill_findings table or error→skip (feature not active for that skill)
Severity: WARNING(high FP rate) | INFO(pending)

### P14: AI-Batch Status
`mx_ai_batch_pending()`→evaluate batch status.
- Errors >0 in last boot→WARNING("AI-Batch {job_type}: {c} errors since {last_run}")
- ∅entries AND batch feature active→INFO("AI-Batch active but never run")
- Error or empty response→skip (feature not active)
Severity: WARNING(errors) | INFO(empty)

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
2. mx_create_doc(project, doc_type='note', title='[Health] <finding-title>', content='Severity: <sev>\n<details>\nFound: YYYY-MM-DD', tags='["health-finding","<severity-tag>"]')
   - ERROR→tag 'bug', WARNING→tag 'improvement'
3. Output: `Auto-Notes: N created, M skipped (duplicate)`
∅findings or INFO only→skip

## Phase 4: Auto-Bugreport + Persist Findings (ERROR/WARNING)
**Project routing:** Store findings in target project, NOT blanket in mxHannesMCP.
- Skill/Setup/Tool findings (affect mx* infrastructure)→`project='mxHannesMCP'`
- Project-specific findings (stubs, local docs, missing relations)→`project=<target-project>`
`mx_create_doc(project=<see routing>, doc_type='bugreport', title='mxHealth: N Findings...', tags='["mxhealth-auto"]', status='reported')`
Deduplication: mx_search before creating. ∅ERROR/WARNING→no report.

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

⚡ **Delta semantics across iterations:** each iteration fires P1-P14 fresh. A finding is "new" if its `context_hash` (`<check>:<document-slug>`) has not been persisted via `mx_skill_manage(action='record_finding', ...)` in a prior iteration. Findings with matching `context_hash` → suppress the output line (they're duplicates). This keeps the loop output noise-free while preserving the full audit trail in MCP.

⚡ **INFO findings in loop mode:** Phase 4 persists only ERROR+WARNING, so INFO findings would otherwise re-print every iteration. In loop mode, SUPPRESS all INFO findings from output entirely — they are one-shot advisory items, not recurring health signals.

## Rules
- Read-only + bug notes + summary fix. !modify document contents
- MCP error→ERROR in report, !abort
- >20 docs/type→sampling(max 10 via mx_batch_detail). P1 on all(from mx_search). ⚡ !individual mx_detail calls→always mx_batch_detail(doc_ids=[...], max_content_tokens=0)
- IP protection: metadata+structure only. UTF-8 without BOM. !assumptions→facts only
- ⚡ **ClampVarchar (Bug#2889) for persisted findings:** `title` max 255 chars (trim the finding summary locally), `rule_id` max 100 chars (pN-kebab-case slugs are short, safe), `file_path` max 500 chars, `details` is TEXT (unclamped but keep focused).
- ⚡ **Severity mapping** (report → MCP): `ERROR` → `error`, `WARNING` → `warning`, `INFO` → `info`. Canonical lowercase on the wire.
- ⚡ **Self-check recursion guard:** if mxHealth runs on a project slug named `mxHealth` (none exists), skip Phase 3b/4 persistence. Self-review findings are reported inline only.
- ⚡ **Mirror sync:** edits to this skill MUST propagate to `V:\Projekte\MX_Intern\mxLore-skills\mxHealth\` + `V:\Projekte\MX_Intern\mxHannesMCP\claude-setup\skills\mxHealth\` (per `feedback_mxlore_skill_sync_workflow.md`). Canonical first, then `cp` to both mirrors.
