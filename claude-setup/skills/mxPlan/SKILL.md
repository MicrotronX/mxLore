---
name: mxPlan
description: Use when the user says "/plan", wants to create or update an implementation plan, or needs to structure a multi-step task before coding. Creates plans via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<slug e.g. edi-parser-refactor>"
---

# /mxPlan — Create/update plan (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Plan agent. Creates/updates plans in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-mode | error=local(`docs/plans/PLAN-<slug>.md`+warning→/mxMigrateToDb)

## Input
Slug from command argument. ∅arg→?user. Slug: `a-z 0-9 -` only.

## Workflow

### 1) Check existence
`mx_search(project, doc_type='plan', query='<slug>', include_details=true, limit=1)` →match=Update(3, doc_id+content directly) | ∅=New(2)

### 2) New plan

**Template:**
```markdown
# PLAN: <Title>
**Slug:** <slug> | **Created:** YYYY-MM-DD | **Status:** active

## Goal
<1-3 sentences from chat context>

## Related
- **Spec:** [SPEC-xxx] (only if identifiable in chat)

## Non-goals
- <What is NOT in plan>

## Milestones
1. <Milestone>

## Tasks
- [ ] Task 1
- [ ] Task 2

## Risks
- <Risk>

## Notes
- <Remarks>
```

**MCP:** `mx_create_doc(project, doc_type='plan', title='PLAN: <Title>', content)`
Related→`mx_search`→target_id→`mx_add_relation(source, target, 'references')`

**Local(Fallback):** `docs/plans/PLAN-<slug>.md` + index.md update + warning

### 3) Update plan
**MCP:** mx_detail(doc_id)→modify sections→mx_update_doc(doc_id, content, change_reason) !delete existing content
**Local:** Read→Edit→index update if status changed

### 4) Status transition (on update)
After step 3: check task lines in content.
- **All `- [x]`** (no `- [ ]` remaining) AND status still `active`:
  - Content: `**Status:** active`→`**Status:** completed`
  - `mx_update_doc(doc_id, content, status='archived', change_reason='All tasks completed')`
  - Output: `Plan #<doc_id> archived — all tasks completed`
- **Mixed:** ∅change, info only: `<N>/<M> tasks completed`
- ⚡ Only for clearly completed plans. Doubt→leave open+?user

## Rules
- Tasks: small+verifiable, `- [ ]`/`- [x]`, max 15-20/plan, 1 session/task
- ⚡ Only verified knowledge from chat !invent. ∅info→?user
- ⚡ Related: mx_search verify BEFORE mx_add_relation !relations to ∅docs
- !ADRs→only /mxDecision. !prose→concise+operational
- MCP preferred, local=fallback

## Conclusion
Output: (1) doc_id (2) top-5 tasks (3) relations if created
Recommendation: `superpowers:executing-plans` or `superpowers:subagent-driven-development`
If active workflow→name next step
