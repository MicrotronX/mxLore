# mxSpec Bug-History Citation Archive

Inline `Bug#NNNN` citations were lifted out of SKILL.md to keep the rule body
lean. The rules they cite are still active in SKILL.md — this file is the
audit trail for *why* each rule exists.

## Server clamps (Bug#2889 — ClampVarchar family)

- `title` = 255 chars
- `slug` = 100 chars
- `change_reason` = 500 chars

Long values past the limit are silently truncated server-side. Callers should
clamp + verify before write rather than rely on truncation.

## Slug auto-generation (Bug#2262)

The `slug=` param does NOT exist on `mx_create_doc` and is silently ignored.
Slugs are generated server-side from the title via `GenerateSlug(Title)` at
`mx.Tool.Write.pas:541-542`. Server handles dedup via `ClampSlug` + retry-with-
suffix at `mx.Tool.Write.pas:588-599`.

## mx_add_relation param names (Bug-context, mx.Tool.Write.Meta.pas:365-366)

Param names are literally `source_doc_id` / `target_doc_id` — NOT
`source` / `target`. Confirmed against the unit at the cited lines.

## Reasoning-leak Position-0 marker (Bug#2989 F6)

5/5 mx*-Skill-Subagents leaked internal reasoning above report body in
Live-Test Session 2026-04-15 (doc#3017). Observed even after partial rule
introduction ("All done. Producing final report." pre-marker prosa). Strict
Position-0 marker rule anchors the fix in SKILL.md Output Format.

## Verification protocol (Bug#3010 F1-F4 + Bug#2989 F4)

Live-Test 2026-04-15 (WF-2026-04-15-007) documented 4 hallucinations in a
single spec run:

- `storeTicket()` vs actual `store()`
- `views/notification_filters/create.php` vs actual `views/notification-filters/form.php`
- 18 vs actual 19 AC cases
- `notification_filter.*` vs actual `notification_filters.*` namespace

Parallel run surfaced unverified `Plan#145` citation (Bug#2989 F4). Root
cause: mxSpec did not Grep/Glob-verify names against filesystem before
writing the body. The Verification section in SKILL.md plus
`references/verification-examples.md` close this gap.
