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

⚡ **Slug derivation + normalization** (slug is derived from title for the local file path; MCP path uses auto-numbering): Read ~/.claude/skills/_shared/slug-normalization.md.

## Workflow

### 1) ADR Number
**MCP:** Auto-number via `mx_create_doc(doc_type='decision')` — no separate query needed.
**Local:** `docs/decisions/index.md`→highest number+1

### 2) Create ADR

Template → `~/.claude/skills/mxDecision/assets/adr-template.md` (6 sections: Status/Date meta, Context, Decision, Consequences with Advantages/Disadvantages/Follow-ups subsections). ⚡ **Absolute path** — subagent CWD is the project root, not the skill dir, so a relative `assets/…` read silently fails. If the template file is unreadable, fall back to a minimal inline skeleton (Context + Decision + Consequences) and warn the user.

Status values: `accepted`=decided in chat | `proposed`=still to be confirmed | `superseded`=replaced by another ADR | `deprecated`=no longer in use

⚡ **ADR numbering contract:** the `NNNN` placeholder in the template title is resolved AFTER `mx_create_doc` returns the new `doc_id` — the server auto-assigns the number. Workflow: (a) create with placeholder title `ADR-NNNN: <Title>`; (b) read returned `doc_id`; (c) immediately `mx_update_doc(doc_id, content-with-resolved-title, change_reason='Assign ADR number')`. Never compute the number locally — that would race with parallel creates. ⚡ **Visibility window:** between (a) and (c) there is a brief window (<1s typical) where a concurrent `mx_search` reader sees the literal placeholder title `ADR-NNNN:`. This is acceptable — the window is short, the doc is correctly tagged `doc_type='decision'`, and the `mx_update_doc` in (c) finalizes the title atomically.

**MCP:** `mx_create_doc(project, doc_type='decision', title='ADR-NNNN: <Title>', content)` — ⚡ Slug is auto-generated server-side from the title via `GenerateSlug(Title)` at `mx.Tool.Write.pas:541-542`, then the ADR-number prefix is prepended at `mx.Tool.Write.pas:579-585`. The server param `slug=` does not exist on `mx_create_doc` and is silently ignored. Ensure the title is canonical and unique; the server handles dedup via `ClampSlug` + retry-with-suffix (Bug#2262, `mx.Tool.Write.pas:588-599`).

**Local (Fallback):** ensure `docs/decisions/` exists (`mkdir -p docs/decisions`); if `index.md` absent create it with a minimal header, otherwise APPEND the new entry. Write `docs/decisions/ADR-NNNN-<slug>.md` + warning. ⚡ This fallback violates ADR-0004 "local docs/ = only CLAUDE.md+status.md" — only used when MCP is down; re-sync via `/mxMigrateToDb` once MCP is back.

### 3) Existence Check for References + Duplicate Guard

⚡ **Slug collision check first:** `mx_search(project, doc_type='decision', query='<slug>', status='active', include_content=false, limit=5)`. Verify each result's slug field matches the normalized input EXACTLY (mx_search uses full-text — `foo` can match `foo-v2`). Only an exact-slug active hit goes to Update path; ∅exact match → proceed with New.

⚡ **TOCTOU guard:** after step 2 creates the new ADR, re-query once with the same filter. If >1 active ADR with this exact slug now exists, a parallel run raced us — warn user and keep the oldest, archive the new one (or ask).

**Referenced docs lookup:** for each reference surfaced in step 4 (assumes / rejected_in_favor_of / caused_by / supersedes), use `mx_search(project, doc_type='decision,spec,plan,note', query='<ref-title-or-id>', status='active', include_content=false, limit=5)` to resolve target doc_id. ⚡ **Exact-verify step:** mx_search is full-text and may tokenize hyphens, so `foo-bar` can match `foo-bar-v2`. For each candidate, verify the returned slug or title matches the caller's reference EXACTLY before proceeding; on ambiguous matches, ask the user to pick a doc_id. Only call `mx_detail` if you need the body for an Update; never for a simple relation lookup.

### 4) Create Relations (MCP only)

After mx_create_doc — 4 optional questions to user (each skippable).

⚡ **Skip grammar:** treat any of `no` / `n` / `nein` / `skip` / `-` / empty line / EOF as "skip this question and continue". Anything else is treated as the answer. Case-insensitive. Parser must be robust — never loop on empty input, never treat `""` as an empty-title assumption doc.



| Question | Relation | Action |
|----------|----------|--------|
| Assumptions that could change? | `assumes` | mx_create_doc(doc_type='assumption')+mx_add_relation |
| Alternatives evaluated+rejected? | `rejected_in_favor_of` | mx_create_doc(doc_type='note')+mx_add_relation |
| What caused this? (doc_id or text) | `caused_by` | mx_add_relation (or create+relate) |
| Supersedes existing ADR(s)? (one or more doc_ids) | `supersedes` | **Loop:** for each old ADR → mx_add_relation + step 5 supersede update |

⚡ **mx_add_relation direction:** `source_doc_id` is ALWAYS the new ADR, `target_doc_id` is the referenced doc (assumption/note/spec/plan/old ADR). Never reverse. The server dedupes duplicate edges, so no pre-check required. ⚡ **Param names:** the server expects literally `source_doc_id` and `target_doc_id` (NOT `source` / `target`). Confirmed at `mx.Tool.Write.Meta.pas:365-366`.

⚡ **Supersedes loop:** an ADR can supersede multiple predecessors (e.g. merging two competing approaches). Iterate over ALL supplied old doc_ids — do not stop at first. Each iteration: add relation + flip old ADR status (see step 5).

**Auto-scan for motivating spec/plan:** after the 4 questions, run `mx_search(project, doc_type='spec,plan', query='<ADR title>', status='active', limit=5)` and filter results to avoid full-text noise:
- Require relevance score ≥ 0.5 (or the server's default threshold) OR title-token overlap ≥ 2 tokens (split title on whitespace, count shared tokens with each candidate title after lowercasing)
- Cap at top 3 after filtering
- If ∅candidates pass the filter → skip silently (do not ask)
- If candidates pass → surface as: `Spec/Plan candidates that may have motivated this ADR: [list]. Enter doc_id to link, or 'no' to skip:`. ⚡ **Require explicit doc_id entry** — never a yes/no on an ambiguous full-text match, to avoid corrupting the graph with wrong-target `motivated_by` edges.
- User-confirmed doc_id → `mx_add_relation(source_doc_id=<new ADR>, target_doc_id=<doc_id>, relation_type='references')`. ⚡ Param names are literally `source_doc_id`/`target_doc_id` (`mx.Tool.Write.Meta.pas:365-366`). ⚠ NOTE: `motivated_by` is NOT in the server's allowed `relation_type` list (`mx.Tool.Write.Meta.pas:376-380` → `leads_to, implements, contradicts, depends_on, supersedes, references, caused_by, rejected_in_favor_of, assumes`). Use `references` until a `motivated_by` enum is added server-side.

### 5) Status Transition

⚡ **Required before every `mx_update_doc`:** `mx_detail(doc_id, max_content_tokens=0)` to fetch the full body — the server default (600 tokens) silently truncates, and writing the truncated content back causes SILENT DATA LOSS. The 600-token default is for queries, not edits. This is the #1 hazard for ADRs because superseded ADRs often have long Context sections.

⚡ **Status whitelist:** auto-transition only runs when the current MCP status is `active`. Skip for already-`archived`, `superseded`, `deprecated`. Check current status via `mx_detail` before flipping.

⚡ **Server-clamp limits:** Read ~/.claude/skills/_shared/mcp-clamp-limits.md. Note: title prefix `ADR-NNNN: ` eats ~12 chars from the 255 budget. Keep change_reason concise; long values silently truncate.

**Editing rules (preserve audit history):**
- **Flip status line:** match the current status line with a **case-insensitive** regex `(?i)^\*\*Status:\*\*\s*(active|accepted|proposed|implemented|superseded|deprecated)` — users routinely type `Accepted`/`PROPOSED`/mixed case. Replace in place with the new status (preserving the line prefix); do NOT remove the line. Literal lowercase-only matching is a silent no-op bug (same family as mxSpec `[resolved]` case-sensitivity).
- **Mark follow-up done:** flip `- [ ]` to `- [x]` (or `- [X]`); do NOT remove the line.
- **Remove obsolete follow-up:** annotate as `- [x] ~~original~~ (dropped)` — never delete silently.

**Supersedes chain (step 5a):** For each `supersedes` relation created in step 4, update the OLD ADR. ⚡ **Two-phase contract:**

- **Phase A — Read:** for each old doc_id call `mx_detail(old_doc_id, max_content_tokens=0)` (the 600-token default truncates and writing it back causes silent data loss).
- **Phase B — Flip:** for each old ADR call `mx_update_doc(old_doc_id, content, status='archived', change_reason='Superseded by ADR-NNNN')` with the case-insensitive content status flip to `superseded` + appended `**Superseded by:** ADR-NNNN (doc_id=<new_doc_id>)` footer. Status flips ONE WAY ONLY (old ADR → `superseded`); never flip the new ADR backwards. Skip any old ADR whose current DB status is not `active` (already `archived`/`superseded`/`deprecated`) and warn — do not re-flip. Collect a per-iteration outcome `{old_doc_id, prev_status, new_status, error?}` for every iteration.
- **Partial-failure recovery:** on a failed iteration do NOT abort the loop and do NOT roll back successful flips — continue the remaining old doc_ids and surface a combined report at the end (`N/M old ADRs archived as superseded. Failed: [list with errors]. Completed: [list].`). The `supersedes` relations from step 4 stay valid; the user reconciles the failures manually.
- **Order:** the new ADR (this skill's `mx_create_doc`) is ALREADY created at step 2. The supersede-flips here run AFTER the new ADR exists but BEFORE the skill returns success — so the chain is: (1) create new ADR, (2) add `supersedes` relations [step 4], (3) flip every old ADR's status [Phase A+B above], (4) report. If you ever invoke this skill in a mode where the new ADR is not yet created, the supersedes-flips MUST wait until after creation (or after explicit partial-failure acknowledgement).

⚡ **change_reason clamp safety:** the `Superseded by ADR-NNNN` string is ~28 chars, safe. If the caller wants to append a rationale, enforce a local 497-char cap and append `...` if longer (see `_shared/mcp-clamp-limits.md`).

**Follow-ups completed (step 5b):** Scan H3 `### Follow-ups` under H2 `## Consequences` (or first matching H2 carrying `Consequences` / `Konsequenzen`). Skip fenced code blocks. Drop strikethrough lines containing `~~` AND `(dropped)`. See `~/.claude/skills/mxDecision/references/followup-scope.md` for the canonical algorithm. Outputs `M` (total live follow-ups) and `N` (completed).

1. `M == 0` → skip transition (no follow-ups to check).
2. Status whitelist: only transition when current MCP status is `active`.
3. `M > 0 AND N == M AND DB-status == active`:
   - `mx_detail(doc_id, max_content_tokens=0)` → full body
   - Case-insensitive flip: `**Status:** accepted` → `**Status:** implemented`
   - `mx_update_doc(doc_id, content, status='archived', change_reason='All follow-ups completed')`
   - Output: `ADR #<doc_id> archived — fully implemented`
4. Mixed (`N < M`): ∅change, info only: `<N>/<M> follow-ups completed`

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
