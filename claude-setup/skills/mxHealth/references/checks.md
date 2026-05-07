# mxHealth — 14 Checks Detail Reference

Canonical per-check details for `/mxHealth` Phase 2. SKILL.md keeps a one-line
summary table; this file holds the full trigger condition, what is checked,
ERROR vs WARNING level, and persistence target for each P1-P14 check.

All findings of severity `ERROR` or `WARNING` are persisted via
`mx_create_doc(doc_type='note', tags=["health-finding", "<severity-tag>"])` in
Phase 3b and additionally surfaced as a single bugreport in Phase 4. INFO
findings are advisory-only and never persisted (loop mode suppresses them
entirely from output).

---

## P1: Document Metadata (DB)

- **Trigger:** Always (every run).
- **Source:** `mx_search` results from Phase 1.
- **Checks:** `title` not empty, `summary_l1` present, `slug` unique per
  `(project, doc_type)`.
- **Severity:** `ERROR` for empty titles | `WARNING` for missing summaries.
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P2: Format Consistency (DB sample)

- **Trigger:** Always; samples max 5 docs via
  `mx_batch_detail(doc_ids=[...], level='full')`.
- **Checks:**
  - ADRs: `**Status:**` is one of `accepted | proposed | superseded |
    deprecated`.
  - PLANs: `**Status:**` is one of `active | completed | paused | cancelled`.
  - SPECs: contains `**Created:**` or `**Slug:**`.
  - All: H1 heading present.
- **Severity:** `INFO`.
- **Persistence:** None (INFO).

## P3: Cross-Reference Consistency (DB)

- **Trigger:** Always; uses `mx_search(include_details=true)` relation data.
- **Checks:** Each relation's target exists and is not deleted; A->B implies
  B->A bidirectional.
- **Severity:** `ERROR` for relation pointing at deleted doc | `WARNING` for
  missing reverse relation.
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P4: Status Consistency (DB content)

- **Trigger:** IDs collected in P1 -> single
  `mx_batch_detail(doc_ids=[...], level='full')` for active/completed PLANs +
  proposed ADRs (max 10).
- **Checks:**
  - Active PLANs MUST contain `- [ ]` outside fenced code blocks. Strip
    ` ``` ... ``` ` regions before counting; nested example checkboxes do not
    count.
  - Completed PLANs MUST NOT have any `- [ ]` outside fenced code blocks.
  - Proposed ADRs older than 30 days -> `WARNING`.
- **Severity:** `WARNING`.
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P5: Workflow Consistency (DB content)

- **Trigger:** IDs from P1 `mx_search(doc_type='workflow_log')` ->
  `mx_batch_detail(doc_ids=[...], level='full')` for all active workflows.
- **Checks:** Active workflows must have pending steps; active workflows
  older than 30 days -> `WARNING` (forgotten?).
- **Severity:** `WARNING`.
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P6: Local/DB Sync

- **Trigger:** Always.
- **Source:** Glob `docs/plans/PLAN-*.md`, `docs/specs/SPEC-*.md`,
  `docs/decisions/ADR-*.md` -> extract slug -> `mx_search`.
- **Checks:**
  - Local file without DB doc -> `WARNING("Not migrated -> /mxMigrateToDb")`.
  - DB doc without local file -> `INFO` (normal).
- **Severity:** `WARNING` (local-only) | `INFO` (DB-only).
- **Persistence:** Phase 3b note for `WARNING` only.

## P7: CLAUDE.md + Reference Consistency (local)

- **Trigger:** Always.
- **Checks:**
  - CLAUDE.md > 200 lines -> `WARNING`; > 300 lines -> `ERROR` (urgently
    offload).
  - `docs/reference/` files without reference in CLAUDE.md -> `WARNING`.
  - Dead markdown links -> `ERROR` (local files) | `INFO` (migrated docs/).
- **Severity:** `ERROR | WARNING | INFO`.
- **Persistence:** Phase 3b note + Phase 4 bugreport for `ERROR | WARNING`.

## P8: Orphaned Local Files

- **Trigger:** Always.
- **Checks:** Files in `docs/plans|specs|decisions/` without naming
  convention; `index.md` while MCP is reachable.
- **Severity:** `INFO`.
- **Persistence:** None (INFO).

## P9: Content Depth (DB)

- **Trigger:** Always.
- **Source:** `mx_search` results (no `mx_detail` needed).
- **Checks:** All non-archived/non-deleted docs (excluding `session_note`,
  `workflow_log`) with `token_estimate < 50`.
- **Severity:** `WARNING`.
- **Persistence:** Phase 3b note + Phase 4 bugreport. Phase 5 auto-fix
  removes P9 stubs (B6.5).

## P10: Auto-Relations (Cross-Reference Scan)

- **Trigger:** Always; samples max 20 docs via
  `mx_batch_detail(doc_ids=[...], level='full')` (2 calls of 10).
- **Checks:** Scan content for `doc_id=NNN`, `#NNN`, `ADR-XXXX`, `PLAN-xxx`,
  `SPEC-xxx`. Map context phrases to relation type:
  `"based on"->assumes`, `"replaces"->supersedes`, `"leads to"->leads_to`,
  `"caused by"->caused_by`, `"depends on"->depends_on`,
  `"rejected in favor of"->rejected_in_favor_of`, default -> `references`.
  Duplicate-check before `mx_add_relation`. Reference: doc_id=620 conventions.
- **Severity:** `INFO`.
- **Persistence:** None (INFO); creates relations directly.

## P11: CLAUDE.md Duplicate Check (local)

- **Trigger:** Always.
- **Checks:** Compare global `~/.claude/CLAUDE.md` sections vs project
  `CLAUDE.md`. Typical duplicates: Security, Encoding, Context-Management,
  Shell, Skill-Routing, Delphi/PHP-Mindset. Project CLAUDE.md > 100 lines ->
  `WARNING` (target: <= 100 lines project-specific). No auto-fix; report only.
- **Severity:** `WARNING`.
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P12: AI-Steno Format Check (local)

- **Trigger:** Always.
- **Checks:**
  1. Project `CLAUDE.md`: first line contains `AI-Steno:` OR content uses
     steno markers (`!`, `->`, `(critical)`, `(empty)`).
  2. Global `~/.claude/CLAUDE.md`: same check.
  3. No steno markers found -> `WARNING`: "CLAUDE.md not in AI-Steno format.
     ~50% token savings possible. Recommendation: convert manually or re-run
     `/mxInitProject`."
  4. Steno present but > 200 lines (global) or > 100 lines (project) ->
     `WARNING`: "AI-Steno CLAUDE.md too long".
- **Severity:** `WARNING`.
- **Reference:** ADR-0010 (AI-Steno standard format).
- **Persistence:** Phase 3b note + Phase 4 bugreport.

## P13: Skill Evolution Metrics

- **Trigger:** Always; iterate canonical evolution-enabled skill list:
  `[mxBugChecker, mxDesignChecker, mxHealth, mxSave, mxOrchestrate, mxPlan,
  mxSpec, mxDecision, mxMigrateToDb, mxInitProject]`. For each, call
  `mx_skill_metrics(skill=<name>, project=<slug>, days=90)`.
- **Checks:**
  - FP rate > 50% for a rule -> `WARNING("Rule {rule_id} has {fp_rate}%
    false positives — mx_skill_manage(action='tune', ...) recommended")`.
  - More than 20 pending findings -> `INFO("N findings awaiting feedback")`.
  - No `skill_findings` table or error -> skip (feature not active for that
    skill).
- **Severity:** `WARNING` (high FP) | `INFO` (pending).
- **Persistence:** Phase 3b note + Phase 4 bugreport for `WARNING` only.

## P14: AI-Batch Status

- **Trigger:** Always.
- **Source:** `mx_ai_batch_pending()`.
- **Checks:**
  - Errors > 0 in last boot -> `WARNING("AI-Batch {job_type}: {c} errors
    since {last_run}")`.
  - No entries AND batch feature active -> `INFO("AI-Batch active but never
    run")`.
  - Error or empty response -> skip (feature not active).
- **Severity:** `WARNING` (errors) | `INFO` (empty).
- **Persistence:** Phase 3b note + Phase 4 bugreport for `WARNING` only.
