---
name: mxPlan
description: Use when the user says "/plan", "/mxPlan", "create a plan", "update the plan", "write a plan for X", "plan this feature", or otherwise wants to structure a multi-step implementation task before coding. Creates or updates plans via MCP-Tools in the mxLore knowledge DB; maintains task checklists with auto-archive on completion.
allowed-tools: Read, Write, Edit, Grep, Glob
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
`mx_search(project, doc_type='plan', query='<slug>', include_content=false, limit=1)` →match=Update(3, use returned doc_id; call mx_detail only if current content needed) | ∅=New(2)

### 2) New plan

Template → `assets/plan-template.md` (goal, related, non-goals, milestones, tasks, risks, notes — 10 sections, ready to populate from chat context).

**MCP:** `mx_create_doc(project, doc_type='plan', title='PLAN: <Title>', content)` (body assembled in this subagent from the template; !echo to parent — see Tokens rule).
Related handling: `mx_search` → resolve target doc_id → `mx_add_relation(source=<new plan doc_id>, target=<spec or decision doc_id>, relation_type='references')`. ⚡ **Source is always the new plan**, target is the referenced spec/decision/other doc. Never reverse.

**Local (Fallback):** `docs/plans/PLAN-<slug>.md` + index.md update + warning

### 3) Update plan
**MCP:** `mx_detail(doc_id)` → modify only the target section(s) → `mx_update_doc(doc_id, content, change_reason)`. ⚡ **Preserve all headers and existing sections**; edit in place. For adding a new task, append under `## Tasks`; do NOT replace the whole section. For completing a task, flip `- [ ]` to `- [x]`; do NOT remove the line.
⚡ `change_reason` is VARCHAR-clamped on the server (Bug#2889 ClampChangeReason) — keep it concise (max ~200 chars). Long reasons are silently truncated.
**Local:** Read → Edit → index update if status changed.

### 4) Status transition (on update)
After step 3: count task lines in content.
- **M = total tasks** (`- [ ]` + `- [x]`). **⚡ If M == 0 → skip transition** (empty checklist is not "complete"; output `Plan has no tasks yet`).
- **M > 0 AND N = M (all `- [x]`, zero `- [ ]`)** AND status still `active`:
  - Content: `**Status:** active` → `**Status:** completed`
  - `mx_update_doc(doc_id, content, status='archived', change_reason='All tasks completed')`
  - Output: `Plan #<doc_id> archived — all tasks completed`
- **Mixed (N < M):** ∅change, info only: `<N>/<M> tasks completed`
- ⚡ Only for clearly completed plans. Doubt → leave open + ?user

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
