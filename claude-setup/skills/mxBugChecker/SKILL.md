---
name: mxBugChecker
description: Use when the user says "/bugcheck", "/mxBugChecker", "check for bugs", "find bugs", "audit for vulnerabilities", "verify the code", "look for issues in this file", or otherwise requests bug analysis on VCS changes or specific files. Verified-knowledge bug finder — every finding requires concrete code proof. Analyzes logic errors, runtime issues, edge cases, error handling, concurrency, resource leaks, security vulnerabilities, and performance regressions. Loads project context from the mxLore Knowledge-DB via MCP and persists findings via Skill Evolution.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

## Output Format ⚡

**FIRST line of every response = `### REPORT ###` EXACTLY. Position 0. Nothing before.**

Read ~/.claude/skills/_shared/reasoning-leak-rule.md.

# /mxBugChecker — Bug Finder (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines, findings only (`File:Line — Finding`).

Bug finder agent. Logic errors, runtime issues, security vulnerabilities. Focus: **real bugs** !style-nitpicks.

## ⚡ GOLDEN RULE: Only verified knowledge
1. !Finding without proof — MUST be based on concrete, read code location
2. !Guessing — uncertain→re-read !assume
3. !Hallucinating — !invented function/variable names/line numbers/code structures. ∅found→"not found"
4. ⚡ Rather NO finding than false positive — FP cost user-time+trust
5. CRITICAL→mandatory-double-read before classification

## Phase 1: Load context
1. `pwd`→working directory
2. Detect VCS → load a **file index, NEVER a whole-tree diff**. Files named as argument→skip this step, go straight to them. ∅argument: `.git/`→`git log -5 2>/dev/null || echo none` + `git status --porcelain 2>/dev/null || echo none` | `.svn/`→`svn log -l5 2>/dev/null || echo none` + `svn status 2>/dev/null || echo none` | ∅VCS→explicit files only. ⚡ The `|| echo none` is part of the command, not a footnote — an empty/detached repo, or a `.svn/` dir on a machine without the `svn` binary (common on a mounted network share), must degrade to "no index" and continue, never abort the phase.
   - ⚡ **NEVER an unbounded `git diff` / `svn diff`.** A single generated file can be megabytes; the agent then dies on the tool output before ANY check runs, and reports itself as idle/available — a silent pass (measured in the wild: 7,584,548 bytes of diff, driven by a single 9 MB generated `.dfm`). This applies whether or not an argument was given.
   - Per-file diff, focus files only, size-gated: `git diff -- <file> | wc -c` (`svn diff <file> | wc -c`; the `--` is git-only, svn takes the bare path) → **< 200000 → read the diff, else skip it** and read the file itself instead.  Never pipe a diff into the context without that gate.
   - ⚡ Status `D` (deleted) → do NOT diff and do NOT try to read it: a deleted 9 MB file yields a 9 MB all-minus diff, and the file it tells you to fall back to is gone. Record it as deleted and move on — a removed file holds no bug to find.
   - Skipped files are NOT silently dropped: name each one in the report header as `not diffed: <file> (diff <N> bytes) — read directly`, deleted ones as `deleted`. ⚡ `<N>` is the **diff size the gate just measured**, NOT the file size — that is the number showing whether the gate fired correctly, and the two differ a lot (measured live: 9,059,038-byte file, 5,246,288-byte diff).
   - ⚡ Git safety: `git log` / `git status` / `git diff` are read-only — they only ever print.
3. CLAUDE.md→project type+conventions+slug. docs/status.md→header+recent changes
4. MCP(optional): mx_ping()→OK→`mx_search(project, doc_type='spec', query='<relevant>', status='active', include_content=false, limit=5)` + `mx_search(doc_type='plan', status='active', limit=5)` summary_l2 only. For full body re-reads of referenced specs/plans use `mx_detail(doc_id, max_content_tokens=0)` to avoid silent truncation. ⚡ **MCP down → continue with CLAUDE.md + status.md only; never abort Phase 1.**

## Phase 2: Determine focus
- **With argument:** Focus on specified files/directories/functions. Grep to find, Read to read.
- **Without argument:** Pick the focus files from the Phase-1 file index, then pull per-file diffs under the Phase-1 size gate. ∅changes→last 5 commits (same gate). ∅relevant→"No changes" !speculative broad-sweep analysis
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
Fallback: mxDesignChecker/references missing → proceed without Delphi taxonomy, note 'delphi-rules unavailable' in output header !abort.

**Subagent verification:** if the Agent tool is used for large files:
- Copy the Golden Rule into the subagent prompt
- EVERY subagent finding must be self-verified (Read → File:Line check)
- Verification reads of independent findings → parallel tool-calls in one message !sequential
- !verifiable → discard. Document discarded/verified counters.

### Gate-check (before report, findings > 0 only)
⚡ `Read ~/.claude/skills/_shared/skill-metrics-gate.md` (SSoT). One `mx_skill_metrics(skill='mxBugChecker', project=<slug>)` call HERE — end of Analysis, before Phase 4 builds the report table. Calling it later (inside Phase 4b, after the table is already rendered) cannot annotate a table that has already been printed. Mark gated-rule findings for the Phase 4 table: append `⚠ low-precision rule` to their row.

## Phase 4: Report

```markdown
## /mxBugChecker Report
**Focus:** <Arg or "VCS changes"> | **VCS:** <Git(Branch)|SVN(Rev)|∅>
**MCP:** <Yes(project=slug)|No> | **Files:** <N> | **Categories:** <3-5 list>
**Not diffed:** <file (diff N bytes) — read directly | ∅>   <!-- Phase-1 size gate; N = measured DIFF size, not file size; omit the line when ∅ -->

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
⚡ **Read-path gate:** annotation already applied to the Phase 4 table (see Gate-check step above, end of Phase 3). `record_finding` is NEVER suppressed — persist every finding regardless of gate state.
For each finding: `mx_skill_manage(action='record_finding', skill='mxBugChecker', rule_id='<cat-lowercase>', project='<slug>', severity='<sev-lowercase>', title='<Root Cause summary>', file_path='<File>', line_number=<Line>, context_hash='<File>:<Line>', details='<Code Proof + Root Cause>')`
- rule_id = category slug: `logic`, `runtime`, `edge-cases`, `error-handling`, `concurrency`, `resource-leaks`, `security`, `performance`
- Response contains finding_uid → remember for user feedback
- Duplicate (status=duplicate) → OK, do not report again
- ∅MCP or error → skip, !abort

⚡ **Severity mapping** (report → MCP): `CRITICAL` → `critical`, `WARNING` → `warning`, `INFO` → `info`. Canonical lowercase on the wire.

Read ~/.claude/skills/_shared/mcp-clamp-limits.md.

⚡ **Self-check recursion guard:** if mxBugChecker is asked to check its own SKILL.md, run as a normal review target (Phase 1-4). Do NOT spawn a nested mxBugChecker on the output; do NOT Phase 4b persist findings against project='mxBugChecker' (no such project slug exists). Self-review findings are reported inline only.

After recording note: `**Skill Evolution:** N findings persisted. Feedback: mx_skill_feedback(finding_uid='...', reaction='confirmed|dismissed|false_positive')`

## Phase 5: Fixes + Verdicts
1. CRITICAL→?user whether to apply fix. Show concrete fix.
2. WARNING→list suggestions. User decides.
3. INFO→report only, no fix.
- ⚡ !automatic fixes without confirmation
- Confidence<high or complex bugs→suggest test-first (test red→fix→test green)
- MCP: check active workflow→mention step completion

### Record Verdicts (⚡ MANDATORY — no finding leaves the run undecided)
Read ~/.claude/skills/_shared/skill-verdicts.md — SSoT for what the three reactions mean.
The user's call on each finding→immediately `mx_skill_feedback(finding_uid='...', reaction=<verdict>)`:
- Fix applied (Edit tool successful) → `confirmed` (rule right, defect fixed)
- User says "skip"/"don't fix"/"not worth it" → `dismissed` (rule right, nobody acts)
- User says "wrong"/"incorrect" → `false_positive` (rule wrong, no defect existed)
- ⚡ !route "won't fix" into `false_positive` — that turns `precision` into an effort ratio
- ⚡ !invent a verdict the user did not state. Undecided→stays `pending` and gets reported, !silently dismissed
- Caller (main context/mxOrchestrate) that applies fixes outside the checker→MUST also record the verdict

### Pending-Review (optional, with `--review-pending` argument)
1. `mx_skill_findings_list(project='<slug>', skill='mxBugChecker', status='pending')` → load all open findings
2. For each finding: check File:Line whether the problem still exists
3. ⚡ Present finding + evidence, user picks the verdict. Re-adjudication is a PROPOSAL — !write a reaction on the checker's own findings without the user's word
4. "Code changed" is no verdict by itself: defect was fixed→`confirmed` | defect stopped mattering→`dismissed`

## Rules
- ⚡ !Finding without read code proof. !Exceptions. !Assumptions("probably/likely")
- ⚡ !Confirmation bias — "No bugs" is a valid result
- ⚡ !auto-fix !unverified subagent findings !invented names/lines !"just in case" findings
- Max 5 cat, IP protection(offset/limit), !style-nitpicks, pre-existing→INFO
- Respect context(CLAUDE.md/status.md), VCS-agnostic, ANSI encoding for Delphi
- Read ~/.claude/skills/_shared/mirror-sync.md.

## Severity Calibration ⚡ (Inflation Fix)

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

**Rationale:** Live-Test Session 2026-04-15 documented Severity-Inflation where defensive-only edge cases were reported as WARNING, diluting finding-density and training the user to ignore the output. A finding that is unreachable in the current code is a hardening opportunity, not a bug. Report it as INFO so the record is honest without inflating the severity histogram.

**Anti-pattern examples (all → INFO, not WARNING):**
- "Function X could divide by zero IF called with 0" — but no caller passes 0, and no external input reaches it.
- "Variable Y could be nil" — but every call site guards it with an `if Assigned` check.
- "SQL string could be injected" — but the query is built from a hardcoded const, not user input.

## Adversarial Verify (optional, on request or `--adversarial`)
Each finding above INFO → 1 independent refuter-agent (parallel, prompt: 'Try to refute this finding with code proof'). Refuted → discard; partially refuted → downgrade severity. Output notes refuted-count. Costs ~1 agent/finding — use for release-gates or low-confidence runs.

## Language Semantics ⚡

Language-specific null-safety semantics (PHP, and pointers to mxDesignChecker for Delphi/JS/TS/Python/Go) live in `references/language-semantics.md` — cross-read during Phase 3 for any finding that hinges on undefined/null/missing-value semantics.
