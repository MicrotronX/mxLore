---
name: mxDecision
description: Use when the user says "/decision", "/mxDecision", "document decision", "write an ADR", "record a decision", "architectural decision", "ADR", or otherwise wants to capture a significant technical choice made in the conversation. Creates or updates Architecture Decision Records (ADRs) via MCP-Tools in the mxLore knowledge DB; maintains supersedes chain and status transitions.
allowed-tools: Read, Write, Edit, Grep, Glob
---

# /mxDecision — Create ADR (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** ALWAYS as subagent(Agent-Tool) !main-context. Result: max 20 lines.
> **Tokens ⚡:** mx_create_doc/mx_update_doc body >300 words → assemble in this subagent, !echo to parent. mx_detail server default = 600 tokens.

ADR-Agent. Creates decisions as ADR in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project_slug. ∅slug→?user
2. mx_ping()→OK=MCP-mode | Error=Local(`docs/decisions/ADR-NNNN-<slug>.md`+Warning→/mxMigrateToDb)

## Input
Title from command argument. ∅arg→?user.

⚡ **Title clamp:** server ClampTitle=255 (Bug#2889). The final title will be `ADR-NNNN: <Title>` — the `ADR-NNNN: ` prefix eats ~12 chars, so keep the title content under ~240 chars. Truncate locally and warn if longer.

⚡ **Slug derivation + normalization** (slug is derived from title for the local file path; MCP path uses auto-numbering):
1. Lowercase the title
2. Replace `[^a-z0-9-]` with `-`
3. Collapse multiple `-` and strip leading/trailing `-`
4. Enforce max 100 chars — truncate at a `-` boundary, strip trailing `-` after
5. Verify `^[a-z0-9-]+$`
6. If the result differs from an obvious derivation → show and confirm with user (Server ClampSlug=100, Bug#2889)

## Workflow

### 1) ADR Number
**MCP:** Auto-number via `mx_create_doc(doc_type='decision')` — no separate query needed.
**Local:** `docs/decisions/index.md`→highest number+1

### 2) Create ADR

Template → `~/.claude/skills/mxDecision/assets/adr-template.md` (6 sections: Status/Date meta, Context, Decision, Consequences with Advantages/Disadvantages/Follow-ups subsections). ⚡ **Absolute path** — subagent CWD is the project root, not the skill dir, so a relative `assets/…` read silently fails. If the template file is unreadable, fall back to a minimal inline skeleton (Context + Decision + Consequences) and warn the user.

Status values: `accepted`=decided in chat | `proposed`=still to be confirmed | `superseded`=replaced by another ADR | `deprecated`=no longer in use

⚡ **ADR numbering contract:** the `NNNN` placeholder in the template title is resolved AFTER `mx_create_doc` returns the new `doc_id` — the server auto-assigns the number. Workflow: (a) create with placeholder title `ADR-NNNN: <Title>`; (b) read returned `doc_id`; (c) immediately `mx_update_doc(doc_id, content-with-resolved-title, change_reason='Assign ADR number')`. Never compute the number locally — that would race with parallel creates.

**MCP:** `mx_create_doc(project, doc_type='decision', slug='<slug>', title='ADR-NNNN: <Title>', content)` — pass `slug` as an explicit parameter (not only inside the content body) so the server can dedupe and the mx_search slug-exact check in step 3 actually works.

**Local (Fallback):** ensure `docs/decisions/` exists (`mkdir -p docs/decisions`); if `index.md` absent create it with a minimal header, otherwise APPEND the new entry. Write `docs/decisions/ADR-NNNN-<slug>.md` + warning. ⚡ This fallback violates ADR-0004 "local docs/ = only CLAUDE.md+status.md" — only used when MCP is down; re-sync via `/mxMigrateToDb` once MCP is back.

### 3) Existence Check for References + Duplicate Guard

⚡ **Slug collision check first:** `mx_search(project, doc_type='decision', query='<slug>', status='active', include_content=false, limit=5)`. Verify each result's slug field matches the normalized input EXACTLY (mx_search uses full-text — `foo` can match `foo-v2`). Only an exact-slug active hit goes to Update path; ∅exact match → proceed with New.

⚡ **TOCTOU guard:** after step 2 creates the new ADR, re-query once with the same filter. If >1 active ADR with this exact slug now exists, a parallel run raced us — warn user and keep the oldest, archive the new one (or ask).

**Referenced docs lookup:** for each reference surfaced in step 4 (assumes / rejected_in_favor_of / caused_by / supersedes), use `mx_search(project, doc_type='decision,spec,plan,note', query='<ref-title-or-id>', status='active', include_content=false, limit=3)` to resolve target doc_id. Only call `mx_detail` if you need the body for an Update; never for a simple relation lookup.

### 4) Create Relations (MCP only)

After mx_create_doc — 4 optional questions to user (each skippable with 'no'):

| Question | Relation | Action |
|----------|----------|--------|
| Assumptions that could change? | `assumes` | mx_create_doc(doc_type='assumption')+mx_add_relation |
| Alternatives evaluated+rejected? | `rejected_in_favor_of` | mx_create_doc(doc_type='note')+mx_add_relation |
| What caused this? (doc_id or text) | `caused_by` | mx_add_relation (or create+relate) |
| Supersedes existing ADR(s)? (one or more doc_ids) | `supersedes` | **Loop:** for each old ADR → mx_add_relation + step 5 supersede update |

⚡ **mx_add_relation direction:** `source` is ALWAYS the new ADR, `target` is the referenced doc (assumption/note/spec/plan/old ADR). Never reverse. The server dedupes duplicate edges, so no pre-check required.

⚡ **Supersedes loop:** an ADR can supersede multiple predecessors (e.g. merging two competing approaches). Iterate over ALL supplied old doc_ids — do not stop at first. Each iteration: add relation + flip old ADR status (see step 5).

**Auto-scan for motivating spec/plan:** after the 4 questions, run `mx_search(project, doc_type='spec,plan', query='<ADR title>', status='active', limit=3)` and surface candidates as: `Spec/Plan candidates that may have motivated this ADR: [list]. Add 'motivated_by' relation? (1=yes/2=no)`. User-confirmed → `mx_add_relation(source=<new ADR>, target=<spec/plan>, relation_type='motivated_by')`.

### 5) Status Transition

⚡ **Required before every `mx_update_doc`:** `mx_detail(doc_id, max_content_tokens=0)` to fetch the full body — the server default (600 tokens) silently truncates, and writing the truncated content back causes SILENT DATA LOSS. The 600-token default is for queries, not edits. This is the #1 hazard for ADRs because superseded ADRs often have long Context sections.

⚡ **Status whitelist:** auto-transition only runs when the current MCP status is `active`. Skip for already-`archived`, `superseded`, `deprecated`. Check current status via `mx_detail` before flipping.

⚡ **ClampVarchar limits (Bug#2889):** title≤255 (content prefix `ADR-NNNN: ` eats ~12), slug≤100, change_reason≤500. Keep change_reason concise; long values silently truncate.

**Editing rules (preserve audit history):**
- **Flip status line:** change `**Status:** <old>` to `**Status:** <new>` in place; do NOT remove the line.
- **Mark follow-up done:** flip `- [ ]` to `- [x]` (or `- [X]`); do NOT remove the line.
- **Remove obsolete follow-up:** annotate as `- [x] ~~original~~ (dropped)` — never delete silently.

**Supersedes chain (step 5a):** For each `supersedes` relation created in step 4, update the OLD ADR:
1. `mx_detail(old_doc_id, max_content_tokens=0)` → fetch full body
2. Flip `**Status:** active/accepted` → `**Status:** superseded` in content
3. Append footer line: `**Superseded by:** ADR-NNNN (doc_id=<new_doc_id>)`
4. `mx_update_doc(old_doc_id, content, status='archived', change_reason='Superseded by ADR-NNNN')`
5. ⚡ Loop over all old ADRs supplied in step 4 — do not stop at first.

**Follow-ups completed (step 5b):** Detect via checkbox scan of the `### Follow-ups` subsection:
1. Regex `^- \[[ xX]\] ` at column zero, outside fenced code blocks, inside `### Follow-ups`
2. M = total follow-ups (excluding `(dropped)` annotated lines)
3. **If M == 0 → skip transition** (no follow-ups to check)
4. **If M > 0 AND N = M (all done) AND current status == `active`**:
   - `mx_detail` full body
   - Content: `**Status:** accepted` → `**Status:** implemented`
   - `mx_update_doc(doc_id, content, status='archived', change_reason='All follow-ups completed')`
   - Output: `ADR #<doc_id> archived — fully implemented`
5. **Mixed (N < M):** ∅change, info only: `<N>/<M> follow-ups completed`

**Proposed→Accepted (step 5c):** When user confirms a proposed decision in chat:
1. `mx_detail(doc_id, max_content_tokens=0)` → full body
2. Content: `**Status:** proposed` → `**Status:** accepted`
3. `mx_update_doc(doc_id, content, change_reason='Confirmed by user')` (no status='archived' — accepted ADRs stay active at DB level)

**Status mapping (content-level vs DB-level):**
| Content Status | DB Status | Meaning |
|---|---|---|
| `proposed` | `active` | Decision drafted, not yet confirmed |
| `accepted` | `active` | Confirmed, in force |
| `implemented` | `archived` | All follow-ups done, ADR complete |
| `superseded` | `archived` | Replaced by a newer ADR |
| `deprecated` | `archived` | No longer in use, not replaced |

## Rules
- ⚡ Only verified knowledge from chat !invent. ∅context→?user !reconstruct
- ⚡ Related: mx_search verify BEFORE mx_add_relation
- !rewrite/delete existing ADRs. Concise: Context+Decision 2-5 sentences each
- MCP preferred, local=fallback

## Completion
Output (max 20 lines, truncate aggressively):
1. doc_id + ADR number
2. Brief confirmation (1-2 sentences summarizing the Decision section, truncated to 120 chars)
3. Up to 3 relations created (show target title + doc_id only)
4. Recommendations:
   - `/mxSpec` if the ADR needs a matching specification for the implementation details
   - `/mxPlan <slug>` to derive an implementation plan from the accepted ADR
5. If active workflow → name next step

If more relations exist than shown, append `... and N more (see mx_detail <doc_id>)`.
