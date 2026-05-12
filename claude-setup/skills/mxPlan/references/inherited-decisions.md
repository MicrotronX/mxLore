# mxPlan — Inherited-Decisions Scan (FR#5177)

> Lazy-loaded by mxPlan New-plan path (step 2) only. Goal: surface Decision-Markers
> that live inline in the referenced spec chain so they are visible at plan-time
> (root cause of BR#5172). Consumes — does NOT duplicate — the canonical regex.
> ⚡ Fail-soft: any read/MCP error in this scan → skip the whole scan, log one line
> in mxPlan output (`Inherited-Decisions scan skipped: <reason>`), create the plan
> normally with no `## Inherited Decisions` section. Never abort plan creation.

## When it runs

After the Related section is parsed (the spec/decision resolution mxPlan already
does for `mx_add_relation`), BEFORE the `mx_create_doc` call. Reuses the
`mx_search(doc_type='spec,decision', status='active')` results — no extra search.
Local-fallback mode (MCP down, no `mx_detail`) → skip entirely.

## Algorithm

1. **Collect target specs:**
   - Every spec resolved from the plan's Related section = level-0 specs.
   - For each level-0 spec: `mx_detail(spec_id, max_content_tokens=0)` ⚡ (the `=0` is
     mandatory — the 600-token default silently truncates and the scan would miss
     markers past the cut). From its body, parse its OWN `## Related` section for
     referenced specs (`[SPEC-slug]` / `Spec#NNNN`) → level-1 sub-specs. Resolve
     each via `mx_search(doc_type='spec', status='active', limit=3)` and
     `mx_detail(sub_spec_id, max_content_tokens=0)`. **Stop at 1 hop** — do not
     recurse into level-1's Related.
   - Result: a set of `(spec_id, body, tags)` tuples (level-0 ∪ level-1, deduped by spec_id).

2. **Scan each body for markers:** Read `~/.claude/skills/_shared/decision-marker.md`
   for `DECISION_MARKER_REGEX` + the fence-exclusion pseudocode. Apply it to each
   body → list of `(spec_id, line_number, line_text)`.

3. **Render:** If the combined marker list is empty → emit NO section (do not write
   an empty `## Inherited Decisions`). If ≥ 1 marker → add this section to the plan
   body, immediately after `## Related`:

   ```
   ## Inherited Decisions
   - [from #<spec_id> L<line>] <line_text, trimmed + truncated to ~120 chars>[ — (unbacked; consider /mxDecision)]
   ```

   The `(unbacked; consider /mxDecision)` suffix is appended to a bullet iff the
   source spec's `tags` array (from its `mx_detail`) contains `unbacked-decision`.
   Same marker text from two different specs → two bullets (different `#<spec_id>` —
   not deduplicated; cheap and audit-honest).

4. **Counting:** `## Inherited Decisions` bullets are informational — they are NOT
   tasks and do NOT count toward the step-4 status-transition `M`/`N` totals.

## Token cost

`mx_detail` calls = (level-0 specs) + (their level-1 sub-specs) — typically 1-4
total. Bodies are assembled in the mxPlan subagent, not echoed to the parent. This
file's load cost (~700 tokens) is paid only on the New-plan path, only when the
plan has ≥ 1 Related spec.

## Out of scope

- The Update path (`/mxPlan` on an existing plan) — Inherited-Decisions is
  create-time-only, mirroring mxSpec's supersedes-FR handling.
- ADRs in the Related section (markers are about *unbacked* spec-body decisions,
  not the ADR graph — those are already traversable via `mx_detail` relations).
- Recursion deeper than 1 hop; auto-creating ADRs from inherited markers.
