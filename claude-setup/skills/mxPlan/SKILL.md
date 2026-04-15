---
name: mxPlan
description: Use when the user says "/plan", "/mxPlan", "create a plan", "update the plan", "write a plan for X", "plan this feature", or otherwise wants to structure a multi-step implementation task before coding. Creates or updates plans via MCP-Tools in the mxLore knowledge DB; maintains task checklists with auto-archive on completion.
allowed-tools: Read, Write, Edit, Grep, Glob
---

## Output Format ⚡ (Bug#2989 F6 — Reasoning-Leak Fix)

**FIRST line of every response = `### REPORT ###` EXACTLY. Position 0. Nothing before.**

Forbidden pre-marker content: prosa, reasoning sentences, "I will now...", "All done.", "Producing final report.", blank lines, markdown heading prefixes. The marker IS the first character-run of the first line, or the report is INVALID.

Why: Cross-skill reasoning-leak pattern — 5/5 mx*-Skill-Subagents leaked internal reasoning above report body in Live-Test Session 2026-04-15 (doc#3017). Observed even after partial rule introduction ("All done. Producing final report." pre-marker prosa). Strict Position-0 anchors the rule.

# /mxPlan — Create/update plan (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Plan agent. Creates/updates plans in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-mode | error=local(`docs/plans/PLAN-<slug>.md`+warning→/mxMigrateToDb)

## Input
Slug from command argument. ∅arg→?user.

⚡ **Slug validation + normalization:** Before use, enforce `^[a-z0-9-]+$`. If the raw input contains uppercase, underscores, or other characters:
1. Lowercase everything
2. Replace `[^a-z0-9-]` with `-`
3. Collapse multiple `-` and strip leading/trailing `-`
4. If the normalized slug differs from input → show both and ask user to confirm before proceeding
5. Server clamps slug to 100 chars (ClampSlug, Bug#2889) — truncate locally and warn if longer

## Workflow

### 1) Check existence

⚡ `mx_search(project, doc_type='plan', query='<slug>', status='active', include_content=false, limit=5)` — **MUST pass `status='active'`** or an archived plan with the same slug will hijack the Update path and mutate historical records.

For each result, verify the slug field matches the normalized input EXACTLY (mx_search uses full-text, so `foo` can match `foo-v2`). Only an exact-slug active hit goes to Update (step 3) with that doc_id; ∅exact match → New (step 2).

⚡ **TOCTOU guard:** after step 2 creates a new plan, re-query once with the same filter. If >1 active plan with this exact slug now exists, a parallel run raced us — warn user and keep the oldest, delete the new one (or ask which to keep).

### 2) New plan

Template → `~/.claude/skills/mxPlan/assets/plan-template.md` (7 sections: Goal, Related, Non-goals, Milestones, Tasks, Risks, Notes — plus title/meta lines). ⚡ **Absolute path** — the subagent CWD is the project root, not the skill dir, so a relative `assets/…` read silently fails. If the template file is unreadable, fall back to a minimal inline skeleton (Goal + Tasks + Notes) and warn the user.

⚡ **Title clamp:** server ClampTitle=255 (Bug#2889). Keep titles short.

**MCP:** `mx_create_doc(project, doc_type='plan', title='PLAN: <Title>', content)` (body assembled in this subagent from the template; !echo to parent — see Tokens rule).

**Related handling (iterate, do not stop at first):**
1. Parse the Related section for ALL referenced specs + decisions (multiple common)
2. For each referenced item → `mx_search(project, doc_type='spec,decision', query='<title>', status='active', limit=3)` to resolve target_id
3. For each resolved target → `mx_add_relation(source_doc_id=<new plan doc_id>, target_doc_id=<target doc_id>, relation_type='references')` — ⚡ **source_doc_id is ALWAYS the new plan**, target_doc_id is the referenced spec/decision. Never reverse. The server dedupes duplicate edges, so no pre-check required. ⚡ Param names are literally `source_doc_id`/`target_doc_id` (NOT `source`/`target`) — confirmed at `mx.Tool.Write.Meta.pas:365-366`.
4. Loop until all Related items processed.

**Local (Fallback):** ensure `docs/plans/` exists (`mkdir -p docs/plans`); if absent create + initial `index.md`. Write `docs/plans/PLAN-<slug>.md` + append index entry + warning.

### 3) Update plan
**MCP:** `mx_detail(doc_id, max_content_tokens=0)` → modify only the target section(s) → `mx_update_doc(doc_id, content, change_reason)`.

⚡ **`max_content_tokens=0` is REQUIRED for updates** — the server default (600) silently truncates long plan bodies. Writing the truncated content back via `mx_update_doc` causes SILENT DATA LOSS of everything past the cut. The 600-token default is for queries, not edits.

⚡ **Preserve all headers and existing sections**; edit in place. Editing rules:
- **Add a task:** append a new `- [ ]` line under `## Tasks`; do NOT replace the whole section.
- **Complete a task:** flip `- [ ]` to `- [x]` (or `- [X]`); do NOT remove the line.
- **Remove an obsolete task:** annotate as `- [x] ~~original text~~ (dropped)` rather than deleting the line — the strike-through preserves audit history and still counts toward "all done" in the status transition. Do NOT delete task lines silently.

⚡ **Server clamp limits (Bug#2889 ClampVarchar family):** title=255, slug=100, change_reason=500. Keep change_reason concise but the budget is 500 chars, not 200. Long values past the limit are silently truncated.

**Local:** Read → Edit → index update if status changed.

### 4) Status transition (on update)
After step 3: count task lines in content.

⚡ **Task regex — case-insensitive, column-zero, outside code blocks:**
- Matches: `^- \[[ xX]\] ` at the start of a line (no indentation), outside fenced code blocks (```...```)
- Done: `- [x]` OR `- [X]` (uppercase accepted — users routinely write both)
- Open: `- [ ]` (single space only)
- Exclude: tab-indented tasks, nested-section tasks, any `- [ ]` inside ```code blocks```

Counts:
- **M = total tasks** (open + done). **⚡ If M == 0 → skip transition** (empty checklist is not "complete"; output `Plan has no tasks yet`).
- **Status whitelist:** auto-transition only applies when current status is `active`. Skip for `superseded`, `rejected`, `blocked`, or any other non-active status.
- **M > 0 AND N = M (all done) AND current status == `active`**:
  - Content: `**Status:** active` → `**Status:** completed`
  - `mx_update_doc(doc_id, content, status='archived', change_reason='All tasks completed')`
  - Output: `Plan #<doc_id> archived — all tasks completed`
- **Mixed (N < M):** ∅change, info only: `<N>/<M> tasks completed`
- ⚡ Only for clearly completed plans with status=`active`. Doubt → leave open + ?user

## Rules
- Tasks: small+verifiable, `- [ ]`/`- [x]`, max 15-20/plan, 1 session/task
- ⚡ Only verified knowledge from chat !invent. ∅info→?user
- ⚡ Related: mx_search verify BEFORE mx_add_relation !relations to ∅docs
- !ADRs→only /mxDecision. !prose→concise+operational
- MCP preferred, local=fallback

## Conclusion
Output (max 20 lines, truncate aggressively):
1. doc_id
2. top-5 tasks (truncate each to 60 chars)
3. up to 3 relations if created (show target title + doc_id only)
4. Recommendation: `superpowers:executing-plans` or `superpowers:subagent-driven-development`
5. If active workflow → name next step

If more tasks or relations exist than shown, append `... and N more (see mx_detail <doc_id>)`.
