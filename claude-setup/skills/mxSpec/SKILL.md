---
name: mxSpec
description: Use when the user says "/spec", "/mxSpec", "write a spec", "write a specification", "requirements doc", "acceptance criteria", "define requirements", or needs to specify a feature or component before planning or implementation. Creates or updates specifications via MCP-Tools in the mxLore knowledge DB; tracks acceptance criteria with auto-archive on full completion.
allowed-tools: Read, Write, Edit, Grep, Glob
---

## Output Format ⚡

**FIRST line of every response = `### REPORT ###` EXACTLY. Position 0. Nothing before.** No prosa, reasoning, blank lines, or heading prefixes ahead of the marker.

Why: cross-skill reasoning-leak pattern observed when subagents prepend status prosa; strict Position-0 anchors the rule. See `references/bug-history.md`.

# /mxSpec — Create/Update Specification (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

Spec-Agent. Creates/updates specifications in Knowledge-DB via MCP.

## Verification ⚡

!invent structural facts. Verify via `Grep`/`Read`/`mx_search` BEFORE writing — 6 targets:

- Class names | Method/function names | File paths | i18n namespaces | AC/test counts | Plan/ADR/doc IDs

Verification fails -> drop the claim, or tag inline `**unverified:** <reason>`. See `references/verification-examples.md` for per-target Grep/Glob commands and rationale.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-mode | Error=Local(`docs/specs/SPEC-<slug>.md`+Warning→/mxMigrateToDb)

## Input
Slug from command argument. ∅arg→?user.

⚡ **Slug normalization:**
1. Lowercase, replace `[^a-z0-9-]` with `-`, collapse + strip outer `-`. Then truncate to 100 chars at a `-` boundary, strip trailing `-`. Verify `^[a-z0-9-]+$`.
2. If normalized slug differs from input → show both and confirm with user.

## Workflow

### 0) PRD Context
- **Full brainstorming in session** → derive PRD from chat, no follow-up questions.
- Otherwise (partial / no brainstorming, PRD-gaps): delegate to `superpowers:brainstorming` skill, then return here.
- **Updating existing spec** → skip Phase 0 entirely.

### 0b) Supersedes-FR Body-Load ⚡

When input lists `supersedes:` / `consolidates:` / `merges:` (case-insensitive):
1. Parse the supersedes-list (`FR#NNNN`, `[FR-NNNN]`, `Spec#NNNN`, `[SPEC-slug]`).
2. `mx_detail(doc_id, max_content_tokens=1500)` for each merged doc body.
3. Embed `## Konsens (aus supersedeten FRs)` section in the new spec — one bullet per merged doc with Goal/target extract.
4. Conflicts → explicit `## Decision` block (fires Section 3b auto-suggest) OR `## Open Questions` entry. Never silently pick one body's answer.
5. In Section 2, add `mx_add_relation(..., relation_type='supersedes')` per merged FR (alongside `references` edges).
6. Out-of-scope: Section 3 Update path (supersedes is CREATE-time-only).

### 1) Check existence

⚡ `mx_search(project, doc_type='spec', query='<slug>', status='active', include_content=false, limit=5)` — **MUST pass `status='active'`** or an archived spec with the same slug will hijack the Update path and mutate historical records.

For each result, verify the slug field matches the normalized input EXACTLY (mx_search uses full-text, so `foo` can match `foo-v2`). Only an exact-slug active hit goes to Update (step 3) with that doc_id; ∅exact match → New (step 2).

### 2) New Spec

Template → `~/.claude/skills/mxSpec/assets/spec-template.md` (9 sections: Overview, Related, Goals, Non-goals, Requirements, Acceptance Criteria, Interfaces/Data, Edge Cases, Open Questions — plus title/meta lines). ⚡ **Absolute path** — the subagent CWD is the project root, not the skill dir, so a relative `assets/…` read silently fails. If the template file is unreadable, fall back to a minimal inline skeleton (Overview + Requirements + Acceptance Criteria) and warn the user.

⚡ **Title clamp:** server ClampTitle=255. Keep titles short.

**MCP:** `mx_create_doc(project, doc_type='spec', title='SPEC: <Title>', content)` — ⚡ Slug is auto-generated server-side from the title; the `slug=` param does not exist on `mx_create_doc` and is silently ignored. Server handles dedup via ClampSlug + retry-with-suffix (see `references/bug-history.md`).

**Related handling (iterate, do not stop at first):**
1. Parse the Related section for ALL referenced ADRs + plans. Canonical bracket form: `[ADR-NNNN]`, `[PLAN-slug]`. Reject ambiguous formats like `ADR#123` — warn and skip.
2. For each → `mx_search(project, doc_type='decision,plan', query='<id-or-slug>', status='active', limit=3)` to resolve target_id.
3. For each resolved target → `mx_add_relation(source_doc_id=<new spec doc_id>, target_doc_id=<target doc_id>, relation_type='references')`. ⚡ source = new spec, target = ADR/plan; never reverse. Server dedupes.
4. Loop until all Related items processed.

**Local (Fallback):** ensure `docs/specs/` exists (`mkdir -p docs/specs`); if `index.md` is absent create it with a minimal header, otherwise APPEND the new entry to the existing index (never overwrite). Write `docs/specs/SPEC-<slug>.md` + warning. ⚡ This fallback violates the ADR-0004 "local docs/ = only CLAUDE.md+status.md" rule — only used when MCP is unavailable; re-sync via `/mxMigrateToDb` once MCP is back.

### 3) Update Spec
**MCP:** `mx_detail(doc_id, max_content_tokens=0)` → modify only the target section(s) → update `Last Modified` to today in UTC (`YYYY-MM-DD`) → `mx_update_doc(doc_id, content, change_reason)`.

⚡ **`max_content_tokens=0` is REQUIRED for updates** — the 600-token default is for queries; using it on edits silently truncates and round-trips data loss.

⚡ **Preserve all headers and existing sections**; edit in place. Editing rules:
- **Add a requirement / AC:** append a new numbered line under `## Requirements` or a new `- [ ]` under `## Acceptance Criteria`; do NOT replace the whole section.
- **Complete an AC:** flip `- [ ]` to `- [x]` (or `- [X]`); do NOT remove the line.
- **Remove an obsolete AC:** annotate as `- [x] ~~original text~~ (dropped)` rather than deleting the line. The strike-through preserves audit history. ⚡ **Dropped AC do NOT count toward `M` or `N`** — they are excluded from the status-transition totals (see step 4). Do NOT delete AC lines silently.
- **Resolve an Open Question:** prepend `[resolved] ` (case-insensitive — `[Resolved]`, `[RESOLVED]`, `[done]`, `[DONE]` all accepted) and the resolution text; keep the original line. The status-transition check matches any of these prefixes as resolved.

⚡ **Server clamp limits:** title=255, slug=100, change_reason=500. Long values past the limit are silently truncated. See `references/bug-history.md`.

**Local:** Read → Edit → "Last Modified" to today → index update if status changed.

### 3b) Decision-Marker Detection + Auto-Suggest /mxDecision

After body-validation passes BUT BEFORE the final `mx_create_doc`/`mx_update_doc` call, scan the spec body for inline Decision-Markers that should live as separate ADRs.

Read `~/.claude/skills/_shared/decision-marker.md` for the canonical regex + fence-exclusion algorithm.

If `len(markers) == 0` → skip prompt, proceed to mx_create_doc/mx_update_doc.

If `len(markers) > 0` → emit ONE batched prompt at end of Create/Update event (not per-marker spam):

```
Detected N decision-marker(s) in spec body. Persist as separate /mxDecision (ADR)? (y / n / skip-once / show)
```

Branches:

- **y** → invoke `/mxDecision` via Skill-Tool with pre-filled args: marker-line + 2 lines context above + 2 lines below + `parent_spec=<spec_id>`. /mxDecision returns `decision_id`. THEN:
  1. `mx_add_relation(source_doc_id=spec_id, target_doc_id=decision_id, relation_type='references')` — **BROAD-SKIP idempotency:** skip if ANY source→target relation exists between this spec_id and decision_id, regardless of relation_type (handles user-manual `supersedes`/`implements` links without creating duplicate edge).
  2. `mx_remove_tags(spec_id, ['unbacked-decision'])` if tag present (stale-tag closure). Idempotent — re-run on already-untagged spec is no-op. On failure: log warning, continue.
  # /mxDecision-abort: skip relation+tag-clear, leave spec untouched
- **n** → `mx_add_tags(spec_id, ['unbacked-decision'])`. Idempotent — re-run on already-tagged spec → no duplicate.
- **skip-once** → no tag, no relation, no prompt. Event-scoped only — next Create/Update re-evaluates from scratch.
- **show** → display all detected markers with line numbers, then re-prompt with same 4 choices.

Multiple markers → list all in single batched prompt with line refs, accept user's single-choice answer for the batch.

### 4) Status Transition (on update)

**AC counting:** Count `- [ ]` / `- [x]` lines under `## Acceptance Criteria`. Skip fenced code blocks. Exclude `~~text~~ (dropped)` lines. M = total live, N = checked. If M == 0: skip transition (output `Spec has no acceptance criteria yet`). Status whitelist: only `active` auto-transitions.

- **Open Questions:** unresolved if line does NOT match case-insensitive `^\s*\[(resolved|done)\]`.
- **M > 0 AND N == M AND no unresolved Open Questions AND status == `active`** → add `**Status:** implemented`, call `mx_update_doc(doc_id, content, status='archived', change_reason='All AC fulfilled')`, output `Spec #<doc_id> archived — all Acceptance Criteria fulfilled`. ⚡ If any AC is `(dropped)`, warn `Auto-archive skipped — spec has <K> dropped AC. Confirm intent before archiving.` and only archive after user confirmation.
- **Mixed (N < M):** info only `<N>/<M> AC fulfilled`. No change.
- **Open Questions unresolved:** no archive even if AC complete. Note `AC complete but open questions remain`.
- ⚡ Doubt → leave open + ?user.

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
