---
name: mxDesignChecker
description: Use when the user says "/designcheck", "/mxDesignChecker", "review the design", "check the spec", "review this ADR", "audit architecture", "second opinion on this code", or otherwise requests design/spec/ADR review or code-vs-design audit. Verified-knowledge design reviewer — every finding requires concrete proof from spec or code. Loads specs/designs from the mxLore Knowledge-DB via MCP and persists findings via Skill Evolution. NO automatic corrections — all fixes require user confirmation.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /mxDesignChecker — Design & Code Review (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines, findings only. Called from brainstorming(Design) and executing-plans(Code).

Software architect+senior dev. Review design docs and code for risks/bugs. **Second opinion** — thorough, critical, constructive.

## Trigger phrases

This skill fires on:
- `/designcheck`, `/mxDesignChecker`
- Natural language: "review the design", "check the spec", "review this ADR", "audit the architecture", "second opinion on this code", "design review", "code-vs-design check"
- Programmatic invocation from other skills (mxSpec after draft, mxDecision after ADR accept, mxOrchestrate workflow step, pre-commit review)

### Delphi Senior Mindset (MANDATORY for Delphi)
- Compiler awareness: Anonymous Methods→Heap-Frames, var-Param+Closure-Capture divergence(Rule 19 delphi.md), RTTI side-effects
- Fix abstraction>discard. !inline-everything as solution
- Ownership/Lifecycle: Who creates/frees/references? DataSnap-Proxy=new instance on var-Param
- Delphi-idiomatic: TComponent-Ownership, Notification, Property-Setter, Message-Handling

## ⚡ GOLDEN RULE: Only verified knowledge
1. !Finding without proof — MUST be based on concrete, read location
2. !Guessing→read again. !Hallucinating→∅found="not found"
3. ⚡ Better NO finding than false positive
4. CRITICAL→mandatory double-read

## Mode Detection
- Slug/DB-Ref(SPEC-xxx, PLAN-xxx, doc_id=N)→load from DB→Spec-Review(3) or Design-Check(1)
- Local `SPEC-*.md`→Spec-Review(3) | `*-design.md`→Design-Check(1)
- Source file(.pas/.php/.js/.ts/.html)→Code-Check(2)
- ∅Argument→search newest design doc(DB or docs/plans/)→Mode 1

## Phase 1: Load context
1. CLAUDE.md→project type+slug. Keywords: Delphi/VCL/FMX→`references/delphi-rules.md` | PHP/HTML/JS/TS→`references/web-rules.md` | Always: `references/general-rules.md` | Mode 3: +`references/spec-review.md`. ⚡ **Canonical source is `references/` only.** A `rules/` folder may still exist for backward-compat on older installs, but it is STALE — never read from it, never write to it, and surface a warning if found during Phase 1.
2. docs/status.md→header+recent changes
3. **Load document:** MCP(Slug)→`mx_search(project, doc_type='spec,plan,decision', query='<slug>', status='active', include_content=false, limit=5)` then `mx_detail(doc_id, max_content_tokens=0)` for the full body. ⚡ **`max_content_tokens=0` is REQUIRED** — the 600-token default silently truncates and causes false "not found" / "section missing" findings. Local fallback → Read file directly.
4. ⚡ **MCP down → continue with CLAUDE.md + status.md + local files only; never abort Phase 1.**

## Phase 2: Analysis (max 5 categories from rules files)

### Mode 1: Design-Check
Read design completely(DB/local)→identify affected source files→read relevant sections(ONLY affected methods !entire files)→check rules: change safe? Code examples=codebase?

### Mode 2: Code-Check
Read code→search related design(MCP: mx_search doc_type='spec'/'plan' | local: docs/specs/+docs/plans/)→check code vs design→apply rules

### Mode 3: Spec-Review
Read spec completely→apply spec-review.md rules→check technical feasibility

## Phase 3: Report

```markdown
## /mxDesignChecker Report — <Name>
**Type:** <from CLAUDE.md> | **Source:** <DB(doc_id=X)|local(path)>
**Rules:** general.md, <tech>.md | **Categories:** <3-5> | **Locations read:** <N>

### Findings
| # | Severity | Cat | File:Line | Code-Proof | Finding | Fix-Suggestion |
|---|----------|-----|-----------|------------|---------|----------------|

### Summary
X CRITICAL | Y WARNING | Z INFO | **Not checked:** <irrelevant cats>
```

**Severity:** CRITICAL=Bug/Crash/Dataloss(double-read!) | WARNING=Risk/suboptimal | INFO=Improvement
**Code-Proof:** ⚡ MANDATORY. Exact(max 3L) via Read. !paraphrased. ∅Proof=∅Finding.

## Phase 3b: Persist findings (Skill Evolution)
MCP available (Phase 1 mx_ping OK) AND Findings > 0:
For each finding: `mx_skill_manage(action='record_finding', skill='mxDesignChecker', rule_id='<cat-lowercase>', project='<slug>', severity='<sev-lowercase>', title='<finding summary>', file_path='<file>', line_number=<line>, context_hash='<file>:<line>', details='<code-proof + finding>')`

⚡ **Canonical rule_id slugs (English, lowercase with dashes):** `ownership-lifecycle`, `error-handling`, `api-design`, `threading`, `spec-feasibility`, `architecture`, `naming`, `testability`, `security-design`, `data-flow`. Derived from `references/delphi-rules.md`, `references/web-rules.md`, `references/general-rules.md`, `references/spec-review.md`. Do NOT use ad-hoc German / mixed slugs.

⚡ **Severity mapping** (report → MCP): `CRITICAL` → `critical`, `WARNING` → `warning`, `INFO` → `info`. Canonical lowercase on the wire.

⚡ **ClampVarchar (Bug#2889) limits for persisted fields:**
- `title` → max 255 chars. Trim the finding summary locally.
- `rule_id` → max 100 chars. Slugs are short, safe.
- `file_path` → max 500 chars. Long paths are rare; trim leading repo path if needed.
- `details` → TEXT column (unclamped), keep it focused (Code Proof max 3 lines + Finding max 2 sentences).

- Duplicate (status=duplicate) → OK. ∅MCP or error → skip, !abort.
- Response contains finding_uid → remember for user feedback.

⚡ **Self-check recursion guard:** if mxDesignChecker is asked to review its own SKILL.md, run as a normal review target (Phase 1-3). Do NOT spawn a nested mxDesignChecker on the output; do NOT Phase 3b persist findings against project='mxDesignChecker' (no such project slug exists). Self-review findings are reported inline only.

After recording: `**Skill Evolution:** N findings persisted. Feedback: mx_skill_feedback(finding_uid='...', reaction='confirmed|dismissed|false_positive')`

## Phase 4: Corrections + Auto-Confirm
⚡ !automatic corrections — ALL require user confirmation
1. CRITICAL→?user whether to apply fix+show concrete fix
2. WARNING→list suggestions, user decides
3. INFO→report only
∅Findings→`/mxDesignChecker: No issues in <N> categories. Design/code clean.`
MCP: check active workflow→mention step completion

### Auto-Confirm (⚡ MANDATORY after fix)
Every finding that is fixed+accepted by user→immediately execute `mx_skill_feedback(finding_uid='...', reaction='confirmed')`.
- Fix applied (Edit-Tool successful) → confirmed
- User says "skip"/"don't fix" → no feedback (stays pending)
- User says "wrong"/"incorrect" → `reaction='false_positive'`
- ⚡ !wait for manual feedback step. !leave findings without confirm.
- Caller (main context/mxOrchestrate) applying fixes outside the checker→MUST also send Auto-Confirm

### Pending-Review (optional, with `--review-pending` argument)
1. `mx_skill_findings_list(project='<slug>', skill='mxDesignChecker', status='pending')` → load all open findings
2. For each finding: check file:line whether issue still exists
3. Fixed→`mx_skill_feedback(finding_uid, 'confirmed')` | Still open→skip | Irrelevant→`dismissed`

## Rules
- ⚡ !Finding without code-proof. !Assumptions("probably"). !Confirmation bias→"∅issues" is good
- ⚡ !auto-correction !invented names/lines !"just in case"-findings
- Max 5 cats, thorough+pragmatic, pre-existing→INFO, IP-protection(offset/limit)
- !Style-nitpicks(unless functional issue). Consider context(CLAUDE.md/status.md)
- ⚡ **Mirror sync:** edits to this skill MUST propagate to `V:\Projekte\MX_Intern\mxLore-skills\mxDesignChecker\` + `V:\Projekte\MX_Intern\mxHannesMCP\claude-setup\skills\mxDesignChecker\` (per `feedback_mxlore_skill_sync_workflow.md`). Canonical first, then `cp` to both mirrors.
