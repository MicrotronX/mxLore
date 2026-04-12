---
name: mxSpec
description: Use when the user says "/spec", wants to write a specification for a feature or component, or needs to define requirements and acceptance criteria before planning or implementation. Creates specs via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<slug e.g. notification-system>"
---

# /mxSpec — Create/Update Specification (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Spec-Agent. Creates/updates specifications in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-mode | Error=Local(`docs/specs/SPEC-<slug>.md`+Warning→/mxMigrateToDb)

## Input
Slug from command argument. ∅arg→?user. Slug: `a-z 0-9 -` only.

## Workflow

### 0) PRD Context
- Brainstorming in session→derive PRD from chat, no follow-up questions
- ∅Brainstorming→4 questions: (1) Problem? (2) Who benefits? (3) What if nothing done? (4) Partial solutions?
- Updating existing spec→Phase 0 skip

### 1) Check existence
`mx_search(project, doc_type='spec', query='<slug>', include_details=true, limit=1)` →Hit=Update(3, doc_id+content directly) | ∅=New(2)

### 2) New Spec

**Template:**
```markdown
# SPEC: <Title>
**Slug:** <slug> | **Created:** YYYY-MM-DD | **Last Modified:** YYYY-MM-DD

## Overview
<2-4 sentences>

## Related
- **ADR:** [ADR-xxxx] — <reference> (only if recognizable from chat)
- **Plan:** [PLAN-xxx] — <reference> (only if recognizable from chat)

## Goals
- <goals>

## Non-goals
- <What is NOT in scope>

## Requirements
1. <Requirement>

## Acceptance Criteria
- [ ] <Testable criterion>

## Interfaces / Data
<DB tables, API — only if relevant>

## Edge Cases
- <Edge case>

## Open Questions
- <Open question>
```

**MCP:** `mx_create_doc(project, doc_type='spec', title='SPEC: <Title>', content)`
Related→`mx_search`→target_id→`mx_add_relation(source, target, 'references')`

**Local(Fallback):** `docs/specs/SPEC-<slug>.md` + index.md update + Warning

### 3) Update Spec
**MCP:** mx_detail(doc_id)→modify sections→"Last Modified"=today→mx_update_doc(doc_id, content, change_reason) !delete existing content
**Local:** Read→Edit→"Last Modified"=today

### 4) Status Transition (on update)
After step 3: check Acceptance Criteria in content.
- **All `- [x]`** (no `- [ ]` remaining) AND no open Open Question:
  - Content: add `**Status:** implemented` (after Last Modified)
  - `mx_update_doc(doc_id, content, status='archived', change_reason='All AC fulfilled')`
  - Output: `Spec #<doc_id> archived — all Acceptance Criteria fulfilled`
- **Mixed:** ∅change, info only: `<N>/<M> AC fulfilled`
- **Open Questions present:** ∅archive, even if AC complete. Note: `AC complete but open questions remain`
- ⚡ Only for clearly implemented specs. Doubt→leave open+?user

## Rules
- ⚡ Only verified knowledge from chat !invent. ∅info→?user or Open Question
- ⚡ Related: mx_search verify BEFORE mx_add_relation
- !invented metrics in AC. !implementation details→/mxPlan
- Requirements numbered. AC clearly testable !vague
- MCP preferred, local=fallback

## Completion
Output: (1) doc_id (2) Top 3-5 Acceptance Criteria (3) Relations if created
Recommendation: `/mxDecision` if ADR needed, `/mxPlan <slug>` for implementation
Active workflow→next step
