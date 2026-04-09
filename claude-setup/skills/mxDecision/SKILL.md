---
name: mxDecision
description: Use when the user says "/decision", wants to document an architectural decision, or when a significant technical choice was made in the conversation. Creates ADRs via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<Decision title>"
---

# /mxDecision — Create ADR (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.

ADR-Agent. Creates decisions as ADR in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project_slug. ∅slug→?user
2. mx_ping()→OK=MCP-mode | Error=Local(`docs/decisions/ADR-NNNN-<slug>.md`+Warning→/mxMigrateToDb)

## Input
Title from command argument. ∅arg→?user

## Workflow

### 1) ADR Number
**MCP:** Auto-number via `mx_create_doc(doc_type='decision')` — no separate query needed.
**Local:** `docs/decisions/index.md`→highest number+1

### 2) Create ADR

**Template:**
```markdown
# ADR-XXXX: <Title>
**Status:** <accepted|proposed> | **Date:** YYYY-MM-DD

## Context
<Problem/reason — 2-5 sentences>

## Decision
<Clear, testable rule — 2-5 sentences>

## Consequences
### Advantages
- ...
### Disadvantages / Risks
- ...
### Follow-ups
- ...
```

Status: `accepted`=decided in chat | `proposed`=still to be confirmed

**MCP:** `mx_create_doc(project, doc_type='decision', title='ADR-NNNN: <Title>', content)`
**Local:** `docs/decisions/ADR-NNNN-<slug>.md` + index.md update + Warning

### 3) Existence Check for References
Referenced docs: `mx_search(project, query='<ref>', include_details=true, limit=1)` instead of separate mx_search+mx_detail

### 4) Create Relations (MCP only)

After mx_create_doc — 4 optional questions to user (each skippable with 'no'):

| Question | Relation | Action |
|----------|----------|--------|
| Assumptions that could change? | `assumes` | mx_create_doc(doc_type='assumption')+mx_add_relation |
| Alternatives evaluated+rejected? | `rejected_in_favor_of` | mx_create_doc(doc_type='note')+mx_add_relation |
| What caused this? (doc_id or text) | `caused_by` | mx_add_relation (or create+relate) |
| Supersedes existing ADR? (doc_id) | `supersedes` | mx_add_relation+mx_update_doc(old→superseded) |

Ref: Conventions doc doc_id=620

### 5) Status Transition
**Supersedes chain:** On `supersedes` relation in step 4:
- Old ADR: `mx_update_doc(doc_id, content with '**Status:** superseded', status='archived', change_reason='Superseded by ADR-NNNN')`
- ⚡ Always update both sides: new ADR references old, old ADR gets archived

**Follow-ups completed:** When all follow-ups in content marked as done:
- `mx_update_doc(doc_id, content with '**Status:** implemented', status='archived', change_reason='All follow-ups completed')`
- Output: `ADR #<doc_id> archived — fully implemented`

**Proposed→Accepted:** When user confirms a proposed decision in chat:
- Content: `**Status:** proposed`→`**Status:** accepted`
- `mx_update_doc(doc_id, content, change_reason='Confirmed by user')`

## Rules
- ⚡ Only verified knowledge from chat !invent. ∅context→?user !reconstruct
- ⚡ Related: mx_search verify BEFORE mx_add_relation
- !rewrite/delete existing ADRs. Concise: Context+Decision 2-5 sentences each
- MCP preferred, local=fallback

## Completion
Output: (1) doc_id+ADR number (2) Brief confirmation 1-2 sentences (3) Relations if created
Recommendation: `/mxPlan` or `/mxSpec` if appropriate. Active workflow→next step
