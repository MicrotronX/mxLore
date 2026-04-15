---
name: mxBugChecker
description: Use when the user says "/bugcheck", "/mxBugChecker", "check for bugs", "find bugs", "audit for vulnerabilities", "verify the code", "look for issues in this file", or otherwise requests bug analysis on VCS changes or specific files. Verified-knowledge bug finder — every finding requires concrete code proof. Analyzes logic errors, runtime issues, edge cases, error handling, concurrency, resource leaks, security vulnerabilities, and performance regressions. Loads project context from the mxLore Knowledge-DB via MCP and persists findings via Skill Evolution.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /mxBugChecker — Bug Finder (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines, findings only (`File:Line — Finding`).

Bug finder agent. Logic errors, runtime issues, security vulnerabilities. Focus: **real bugs** !style-nitpicks.

## Trigger phrases

This skill fires on:
- `/bugcheck`, `/mxBugChecker`
- Natural language: "check for bugs", "find bugs", "audit for vulnerabilities", "verify the code", "look for issues in this file", "bug check"
- Programmatic invocation from other skills (e.g. mxOrchestrate workflow steps, mxDecision/mxSpec pre-commit reviews)

## ⚡ GOLDEN RULE: Only verified knowledge
1. !Finding without proof — MUST be based on concrete, read code location
2. !Guessing — uncertain→re-read !assume
3. !Hallucinating — !invented function/variable names/line numbers/code structures. ∅found→"not found"
4. ⚡ Rather NO finding than false positive — FP cost user-time+trust
5. CRITICAL→mandatory-double-read before classification

## Phase 1: Load context
1. `pwd`→working directory
2. Detect VCS: `.git/`→`git log -5 && git status && git diff` | `.svn/`→`svn log -l5 && svn status && svn diff` | ∅VCS→explicit files only. ⚡ Git safety: `git log` / `git diff` are read-only. On empty/detached repos append `2>/dev/null || echo none` to avoid aborting the phase.
3. CLAUDE.md→project type+conventions+slug. docs/status.md→header+recent changes
4. MCP(optional): mx_ping()→OK→`mx_search(project, doc_type='spec', query='<relevant>', status='active', include_content=false, limit=5)` + `mx_search(doc_type='plan', status='active', limit=5)` summary_l2 only. For full body re-reads of referenced specs/plans use `mx_detail(doc_id, max_content_tokens=0)` to avoid silent truncation. ⚡ **MCP down → continue with CLAUDE.md + status.md only; never abort Phase 1.**

## Phase 2: Determine focus
- **With argument:** Focus on specified files/directories/functions. Grep to find, Read to read.
- **Without argument:** Analyze VCS diff. ∅Diff→last 5 commits. ∅relevant→"No changes" !speculative broad-sweep analysis
- **Max 5 categories** per run (matching file type+change). Fewer=more thorough.

## Phase 3: Analysis (SELF !blind subagent)

Category catalog (pick max 5 most relevant to the focus files): full descriptions + Delphi-specific rules → `references/categories.md`. Summary:
1. **Logic** — AND/OR confusion, dead code, wrong assignments, infinite loops
2. **Runtime** — Nil-deref, off-by-one, division/0, invalid casts, stack overflow
3. **Edge Cases** — empty lists/strings, boundary values (0, -1, MaxInt), Unicode/ANSI, date edges
4. **Error Handling** — missing try/except/finally, swallowed exceptions, incomplete cleanup
5. **Concurrency** — unprotected shared access, missing locks, deadlock, TOCTOU
6. **Resource Leaks** — open handles/connections/streams, missing Free/Destroy (Delphi!)
7. **Security** — SQL injection, command injection, XSS, path traversal, hardcoded credentials
8. **Performance** (only when bug-relevant) — N+1 queries, unbounded data, blocking UI calls

Technology-specific rules: Delphi → `references/delphi-rules.md` | web (PHP/JS/HTML) → `references/web-rules.md`

**Subagent verification:** if the Agent tool is used for large files:
- Copy the Golden Rule into the subagent prompt
- EVERY subagent finding must be self-verified (Read → File:Line check)
- !verifiable → discard. Document discarded/verified counters.

## Phase 4: Report

```markdown
## /mxBugChecker Report
**Focus:** <Arg or "VCS changes"> | **VCS:** <Git(Branch)|SVN(Rev)|∅>
**MCP:** <Yes(project=slug)|No> | **Files:** <N> | **Categories:** <3-5 list>

### Findings
| # | Severity | Cat | File:Line | Code Proof | Root Cause | Fix | Confidence |
|---|----------|-----|-----------|------------|------------|-----|------------|

### Summary
X CRITICAL | Y WARNING | Z INFO | **Not checked:** <irrelevant categories>
```

**Severity:** CRITICAL=Bug/Crash/Data loss(double-read!) | WARNING=Risk/Edge-case | INFO=Improvement
**Code Proof:** ⚡ MANDATORY. Exact excerpt(max 3L) read via Read. !paraphrased. ∅Proof=∅Finding.
**Confidence:** high/medium/low. medium/low→explain why+what is missing

## Phase 4b: Persist findings (Skill Evolution)
MCP available (Phase 1 mx_ping OK) AND Findings > 0:
For each finding: `mx_skill_manage(action='record_finding', skill='mxBugChecker', rule_id='<cat-lowercase>', project='<slug>', severity='<sev-lowercase>', title='<Root Cause summary>', file_path='<File>', line_number=<Line>, context_hash='<File>:<Line>', details='<Code Proof + Root Cause>')`
- rule_id = category slug: `logic`, `runtime`, `edge-cases`, `error-handling`, `concurrency`, `resource-leaks`, `security`, `performance`
- Response contains finding_uid → remember for user feedback
- Duplicate (status=duplicate) → OK, do not report again
- ∅MCP or error → skip, !abort

⚡ **Severity mapping** (report → MCP): `CRITICAL` → `critical`, `WARNING` → `warning`, `INFO` → `info`. Canonical lowercase on the wire.

⚡ **ClampVarchar (Bug#2889) limits for persisted fields:**
- `title` → max 255 chars. Trim the Root Cause summary locally; long values silently truncate on the server.
- `rule_id` → max 100 chars. Category slugs are short, safe.
- `file_path` → max 500 chars. Long paths are rare; trim leading repo path if needed.
- `details` → TEXT column (unclamped), but keep it focused (Code Proof ≤3 lines + Root Cause ≤2 sentences).

⚡ **Self-check recursion guard:** if mxBugChecker is asked to check its own SKILL.md, run as a normal review target (Phase 1-4). Do NOT spawn a nested mxBugChecker on the output; do NOT Phase 4b persist findings against project='mxBugChecker' (no such project slug exists). Self-review findings are reported inline only.

After recording note: `**Skill Evolution:** N findings persisted. Feedback: mx_skill_feedback(finding_uid='...', reaction='confirmed|dismissed|false_positive')`

## Phase 5: Fixes + Auto-Confirm
1. CRITICAL→?user whether to apply fix. Show concrete fix.
2. WARNING→list suggestions. User decides.
3. INFO→report only, no fix.
- ⚡ !automatic fixes without confirmation
- Confidence<high or complex bugs→suggest test-first (test red→fix→test green)
- MCP: check active workflow→mention step completion

### Auto-Confirm (⚡ MANDATORY after fix)
Every finding that is fixed+accepted by user→immediately execute `mx_skill_feedback(finding_uid='...', reaction='confirmed')`.
- Fix applied (Edit tool successful) → confirmed
- User says "skip"/"don't fix" → no feedback (remains pending)
- User says "wrong"/"incorrect" → `reaction='false_positive'`
- ⚡ !wait for manual feedback step. !leave findings without confirm.
- Caller (main context/mxOrchestrate) that applies fixes outside the checker→MUST also send auto-confirm

### Pending-Review (optional, with `--review-pending` argument)
1. `mx_skill_findings_list(project='<slug>', skill='mxBugChecker', status='pending')` → load all open findings
2. For each finding: check File:Line whether problem still exists
3. Fixed→`mx_skill_feedback(finding_uid, 'confirmed')` | Still open→skip | Irrelevant→`dismissed`

## Rules
- ⚡ !Finding without read code proof. !Exceptions. !Assumptions("probably/likely")
- ⚡ !Confirmation bias — "No bugs" is a valid result
- ⚡ !auto-fix !unverified subagent findings !invented names/lines !"just in case" findings
- Max 5 cat, IP protection(offset/limit), !style-nitpicks, pre-existing→INFO
- Respect context(CLAUDE.md/status.md), VCS-agnostic, ANSI encoding for Delphi
- ⚡ **Mirror sync:** edits to this skill MUST propagate to `V:\Projekte\MX_Intern\mxLore-skills\mxBugChecker\` + `V:\Projekte\MX_Intern\mxHannesMCP\claude-setup\skills\mxBugChecker\` (per `feedback_mxlore_skill_sync_workflow.md`). Canonical first, then `cp` to both mirrors.
