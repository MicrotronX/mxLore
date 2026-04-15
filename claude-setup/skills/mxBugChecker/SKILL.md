---
name: mxBugChecker
description: Use when the user says "/bugcheck", "/mxBugChecker", "check for bugs", "find bugs", "audit for vulnerabilities", "verify the code", "look for issues in this file", or otherwise requests bug analysis on VCS changes or specific files. Verified-knowledge bug finder — every finding requires concrete code proof. Analyzes logic errors, runtime issues, edge cases, error handling, concurrency, resource leaks, security vulnerabilities, and performance regressions. Loads project context from the mxLore Knowledge-DB via MCP and persists findings via Skill Evolution.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

## Output Format ⚡ (Bug#2989 F6 — Reasoning-Leak Fix)

**FIRST line of every response = `### REPORT ###` EXACTLY. Position 0. Nothing before.**

Forbidden pre-marker content: prosa, reasoning sentences, "I will now...", "All done.", "Producing final report.", blank lines, markdown heading prefixes. The marker IS the first character-run of the first line, or the report is INVALID.

Why: Cross-skill reasoning-leak pattern — 5/5 mx*-Skill-Subagents leaked internal reasoning above report body in Live-Test Session 2026-04-15 (doc#3017). Observed even after partial rule introduction ("All done. Producing final report." pre-marker prosa). Strict Position-0 anchors the rule.

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

Technology-specific rules live under `mxDesignChecker/references/` (delphi-rules.md, web-rules.md, general-rules.md) — mxBugChecker inherits the same taxonomy but does not duplicate the files. If detailed Delphi/web patterns are needed during analysis, cross-read from `~/.claude/skills/mxDesignChecker/references/`.

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
- `details` → TEXT column (unclamped), but keep it focused (Code Proof max 3 lines + Root Cause max 2 sentences).

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

## Severity Calibration ⚡ (Bug#2989 F8 — Inflation Fix)

Existing report severities (Phase 4) stay `CRITICAL / WARNING / INFO`. This section tightens what each level MEANS and introduces a reachability gate. `INFO` is now explicitly the bucket for defensive-only / unreachable findings — do NOT promote them to `WARNING` or `CRITICAL`.

**Categories (lowest to highest):**
- **INFO** — defensive-only suggestion OR improvement. Edge case NOT reachable from any current code path, OR style-level polish, OR hardening for a future change. !WARNING !CRITICAL. Maps to MCP `info`.
- **WARNING** — reachable code path, measurable risk (edge case, recoverable error, degraded behavior). User-visible or runtime-visible. Maps to MCP `warning`.
- **CRITICAL** — reachable code path, bug/crash/data-loss/security breach. Double-read mandatory before classification (existing Golden Rule #5). Maps to MCP `critical`.

**Reachability Gate ⚡ (required before assigning WARNING or CRITICAL):**
Before tagging any finding above INFO, answer in the finding body (Root Cause or Code Proof column):
1. Is the offending code path reachable from a public entry point? (HTTP handler, CLI command, scheduled job, DB trigger, user action, IPC message, hook)  yes/no
2. If yes → cite the entry point as `File:Line` in the Root Cause.
3. If no → downgrade to `INFO` with a `reachability: unverified` or `reachability: dead-code` note. Do NOT omit — the finding still exists in the record, just at the honest severity.

**Rationale:** Live-Test Session 2026-04-15 (doc#3017 §4.3, Bug#2989 F8) documented Severity-Inflation where defensive-only edge cases were reported as WARNING, diluting finding-density and training the user to ignore the output. A finding that is unreachable in the current code is a hardening opportunity, not a bug. Report it as INFO so the record is honest without inflating the severity histogram.

**Anti-pattern examples (all → INFO, not WARNING):**
- "Function X could divide by zero IF called with 0" — but no caller passes 0, and no external input reaches it.
- "Variable Y could be nil" — but every call site guards it with an `if Assigned` check.
- "SQL string could be injected" — but the query is built from a hardcoded const, not user input.

## Language Semantics ⚡ (Bug#2989 F7 — isset Overclaim Fix)

Before claiming a language-level bug, verify against actual language semantics. Cross-reference this section during Phase 3 analysis for any finding that depends on how a language treats undefined/null/missing values. Common false-positive traps:

### PHP null-safety primitives — NONE emit "Undefined variable" warnings

- `isset($var)` / `isset($arr['k'])` — returns `false` on undefined OR null. No warning. No notice. Array-access form does NOT require the key to exist.
- `empty($var)` — returns `true` on undefined/null/0/`""`/`"0"`/`[]`/`false`. No warning even if `$var` was never set.
- `$a ?? $b` (null-coalesce) — short-circuits on undefined/null and returns `$b`. No warning. `$arr['k'] ?? 'default'` is safe even if `'k'` is missing.
- `array_key_exists('k', $arr)` — checks key presence without triggering on null values. No warning if `$arr` is an array. !confuse with `isset` — `isset` returns `false` for `null` values, `array_key_exists` returns `true`.
- `??=` (null-coalesce assignment, PHP 7.4+) — same semantics as `??`, null-safe.

**PHP constructs that DO warn on undefined:**
- Direct read: `$var` (bare access outside a null-safe primitive)
- String interpolation: `"hello $var"` or `"hello {$arr['k']}"`
- Array access without `isset`/`??` guard: `$arr['k']` when `'k'` may be missing
- Passing to functions that don't null-check the argument
- Concatenation: `'x' . $var` when `$var` may be undefined

**Verification protocol before filing a PHP undefined-variable/index finding:**
1. `Grep` the surrounding 5 lines around the alleged bug site.
2. Confirm the variable is read via a BARE access, not wrapped in `isset` / `empty` / `??` / `array_key_exists`.
3. If the bare access is on a branch guarded by an earlier `isset` in the same scope → no bug.
4. If unsure → mark the finding as `INFO` with `reachability: unverified` per the Severity Calibration section above. Do NOT file as WARNING.

### Other languages

Delphi/Pascal, JS/TS, Python, Go null-safety primitives live in `mxDesignChecker/references/` (language-specific rule files). Cross-read those when a finding hinges on language semantics. If the target language is NOT covered in the references and you are uncertain → finding goes to `INFO` with an explicit `language-semantics: unverified` note.
