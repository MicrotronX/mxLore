---
name: mxSpec
description: Use when the user says "/spec", "/mxSpec", "write a spec", "write a specification", "requirements doc", "acceptance criteria", "define requirements", or needs to specify a feature or component before planning or implementation. Creates or updates specifications via MCP-Tools in the mxLore knowledge DB; tracks acceptance criteria with auto-archive on full completion.
allowed-tools: Read, Write, Edit, Grep, Glob
---

# /mxSpec — Create/Update Specification (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

Spec-Agent. Creates/updates specifications in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-mode | Error=Local(`docs/specs/SPEC-<slug>.md`+Warning→/mxMigrateToDb)

## Input
Slug from command argument. ∅arg→?user.

⚡ **Slug validation + normalization (order matters):**
1. Lowercase everything
2. Replace `[^a-z0-9-]` with `-`
3. Collapse multiple `-` and strip leading/trailing `-`
4. **Then** enforce length max 100 chars — truncate at a `-` boundary if possible, strip any trailing `-` after truncation. (Server ClampSlug=100, Bug#2889 — do this locally AFTER normalization to avoid mid-truncation of multi-byte characters or stranded leading `-`.)
5. Verify the result matches `^[a-z0-9-]+$`
6. If the normalized slug differs from input → show both and ask user to confirm before proceeding

## Workflow

### 0) PRD Context
- **Full brainstorming in session** → derive PRD from chat, no follow-up questions
- **Partial brainstorming** (some of the 4 PRD facets already surfaced) → identify which facets are missing and ask ONLY those; do NOT re-ask already-covered ground
- **∅brainstorming** → ask all 4 questions: (1) Problem? (2) Who benefits? (3) What if nothing done? (4) Partial solutions that already exist?
- **Updating existing spec** → Phase 0 skip entirely

### 1) Check existence

⚡ `mx_search(project, doc_type='spec', query='<slug>', status='active', include_content=false, limit=5)` — **MUST pass `status='active'`** or an archived spec with the same slug will hijack the Update path and mutate historical records.

For each result, verify the slug field matches the normalized input EXACTLY (mx_search uses full-text, so `foo` can match `foo-v2`). Only an exact-slug active hit goes to Update (step 3) with that doc_id; ∅exact match → New (step 2).

⚡ **TOCTOU guard:** after step 2 creates a new spec, re-query once with the same filter. If >1 active spec with this exact slug now exists, a parallel run raced us — warn user and keep the oldest, delete the new one (or ask which to keep).

### 2) New Spec

Template → `~/.claude/skills/mxSpec/assets/spec-template.md` (9 sections: Overview, Related, Goals, Non-goals, Requirements, Acceptance Criteria, Interfaces/Data, Edge Cases, Open Questions — plus title/meta lines). ⚡ **Absolute path** — the subagent CWD is the project root, not the skill dir, so a relative `assets/…` read silently fails. If the template file is unreadable, fall back to a minimal inline skeleton (Overview + Requirements + Acceptance Criteria) and warn the user.

⚡ **Title clamp:** server ClampTitle=255 (Bug#2889). Keep titles short.

**MCP:** `mx_create_doc(project, doc_type='spec', slug='<slug>', title='SPEC: <Title>', content)` — pass `slug` as an explicit parameter (not only inside the content body) so the server can dedupe and the mx_search slug-exact check in step 1 actually works.

**Related handling (iterate, do not stop at first):**
1. Parse the Related section for ALL referenced ADRs + plans. **Canonical reference format:** `[ADR-NNNN]` or `[PLAN-slug]` in brackets. Accept case-insensitive variants (`[adr-1234]`, `[Plan-foo]`) by normalizing to uppercase TYPE + original ID. Reject ambiguous formats like `ADR#123` or `adr 123` — log a warning and skip that reference (do not guess).
2. For each referenced item → `mx_search(project, doc_type='decision,plan', query='<id-or-slug>', status='active', limit=3)` to resolve target_id
3. For each resolved target → `mx_add_relation(source=<new spec doc_id>, target=<target doc_id>, relation_type='references')` — ⚡ **Source is ALWAYS the new spec**, target is the referenced ADR/plan. Never reverse. The server dedupes duplicate edges, so no pre-check required.
4. Loop until all Related items processed.

**Local (Fallback):** ensure `docs/specs/` exists (`mkdir -p docs/specs`); if `index.md` is absent create it with a minimal header, otherwise APPEND the new entry to the existing index (never overwrite). Write `docs/specs/SPEC-<slug>.md` + warning. ⚡ This fallback violates the ADR-0004 "local docs/ = only CLAUDE.md+status.md" rule — only used when MCP is unavailable; re-sync via `/mxMigrateToDb` once MCP is back.

### 3) Update Spec
**MCP:** `mx_detail(doc_id, max_content_tokens=0)` → modify only the target section(s) → update `Last Modified` to **today in UTC, `YYYY-MM-DD` format** (compute via system clock in UTC to avoid TZ-boundary churn across sessions) → `mx_update_doc(doc_id, content, change_reason)`.

⚡ **TOCTOU guard also applies to Update path:** pin the doc_id from step 1 throughout step 3. Do not re-query by slug mid-update — if a parallel write happens, the reconciliation during the next step 1 will catch the divergence. If `mx_update_doc` returns a revision conflict, surface it to the user; do not silently retry.

⚡ **`max_content_tokens=0` is REQUIRED for updates** — the server default (600) silently truncates long spec bodies. Writing the truncated content back via `mx_update_doc` causes SILENT DATA LOSS of everything past the cut. The 600-token default is for queries, not edits.

⚡ **Preserve all headers and existing sections**; edit in place. Editing rules:
- **Add a requirement / AC:** append a new numbered line under `## Requirements` or a new `- [ ]` under `## Acceptance Criteria`; do NOT replace the whole section.
- **Complete an AC:** flip `- [ ]` to `- [x]` (or `- [X]`); do NOT remove the line.
- **Remove an obsolete AC:** annotate as `- [x] ~~original text~~ (dropped)` rather than deleting the line. The strike-through preserves audit history. ⚡ **Dropped AC do NOT count toward `M` or `N`** — they are excluded from the status-transition totals (see step 4). Do NOT delete AC lines silently.
- **Resolve an Open Question:** prepend `[resolved] ` (case-insensitive — `[Resolved]`, `[RESOLVED]`, `[done]`, `[DONE]` all accepted) and the resolution text; keep the original line. The status-transition check matches any of these prefixes as resolved.

⚡ **Server clamp limits (Bug#2889 ClampVarchar family):** title=255, slug=100, change_reason=500. Keep change_reason concise but the budget is 500 chars. Long values past the limit are silently truncated.

**Local:** Read → Edit → "Last Modified" to today → index update if status changed.

### 4) Status Transition (on update)
After step 3: count Acceptance Criteria lines in the `## Acceptance Criteria` section.

⚡ **AC counting algorithm (explicit, so all agents count the same way):**

```
in_fence = false
in_ac_section = false
M = 0; N = 0
for each line in content:
  if line.trim() starts with "```": in_fence = !in_fence; continue
  if in_fence: continue
  if line starts with "## ": in_ac_section = (line == "## Acceptance Criteria"); continue
  if !in_ac_section: continue
  if line matches /^- \[[ xX]\] / (no leading whitespace):
    if line contains "~~" AND "(dropped)": continue  # exclude dropped AC
    M += 1
    if line matches /^- \[[xX]\] /: N += 1
```

Counts:
- **M = total live AC** (excluding dropped). **⚡ If M == 0 → skip transition** (empty AC list is not "implemented"; output `Spec has no acceptance criteria yet`).
- **Status whitelist:** auto-transition only applies when current status is `active`. Skip for `superseded`, `rejected`, `blocked`, or any other non-active status.
- **Open Questions regex (case-insensitive):** a question is "resolved" if it matches `^\s*\[(resolved|done)\]` (any case). Any line NOT matching is an unresolved question.
- **M > 0 AND N = M (all done) AND no unresolved Open Questions AND current status == `active`**:
  - Content: add `**Status:** implemented` (after Last Modified)
  - `mx_update_doc(doc_id, content, status='archived', change_reason='All AC fulfilled')`
  - Output: `Spec #<doc_id> archived — all Acceptance Criteria fulfilled`
- **Mixed (N < M):** ∅change, info only: `<N>/<M> AC fulfilled`
- **Open Questions present (unresolved):** ∅archive, even if AC complete. Note: `AC complete but open questions remain`
- **Dropped-AC safety:** if any AC is marked `(dropped)` AND the remaining live AC are all done, warn user: `Auto-archive skipped — spec has <K> dropped AC. Confirm intent before archiving.` Only archive after user confirmation.
- ⚡ Only for clearly implemented specs with status=`active`. Doubt → leave open + ?user

## Rules
- ⚡ Only verified knowledge from chat !invent. ∅info→?user or Open Question
- ⚡ Related: mx_search verify BEFORE mx_add_relation
- !invented metrics in AC. !implementation details→/mxPlan
- Requirements numbered. AC clearly testable !vague
- MCP preferred, local=fallback

## Completion
Output (max 20 lines, truncate aggressively):
1. doc_id
2. Top 3-5 Acceptance Criteria (truncate each to 60 chars)
3. Up to 3 relations if created (show target title + doc_id only)
4. Recommendations:
   - `/mxDesignChecker` for a spec review pass (catches gaps + inconsistencies before implementation)
   - `/mxDecision` if an ADR is needed for an architectural choice surfaced by the spec
   - `/mxPlan <slug>` to derive an implementation plan from the spec
5. If active workflow → name next step

If more AC or relations exist than shown, append `... and N more (see mx_detail <doc_id>)`.
