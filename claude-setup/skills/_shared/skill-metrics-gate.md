# Skill-Metrics Gate — SSoT (read-path suppression)

Single source of truth for WHEN a rule counts as "measurably low-precision" and
WHAT each consumer does about it. mxHealth P13 (`references/checks.md`) applies
the same condition for its tune-WARNING — the numbers live HERE, not there.

## Gate condition (per rule, from `mx_skill_metrics(skill, project, days=90)`)

A rule is **gated** when BOTH hold:

1. `n = confirmed + false_positives >= 10` (evidence floor)
2. `weighted_precision < 0.5` (use `precision` only if `weighted_precision` is absent)

- `n < 10` -> NOT gated, skip silently (small-n). This also covers the `0/0`
  case: a rule that only ever received `dismissed` verdicts reports
  `weighted_precision = 0` — an ungraded rule, not a bad one.
- Metrics call fails or no `skill_findings` data -> NOT gated (fail-open).

## Metric selection (hard rule)

NEVER gate on `fp_rate`, `confirmation_rate`, `weighted_fp_rate` or
`weighted_confirmation_rate`: all four divide by the reacted total, which
counts `dismissed`. `dismissed` means "the rule was right, the fix is not
worth it" (`_shared/skill-verdicts.md`) — an effort verdict, not an accuracy
verdict. Only `precision` and `weighted_precision` exclude it.
`weighted_precision` additionally decays findings by age
(<30d=1.0, 30-60d=0.7, >60d=0.3), retiring pre-verdict-channel data.

Rationale for one shared threshold with P13 instead of the spec's original
`n >= 5 AND Laplace p_hat < 0.3`: the server returns only the finished
quotients, never the weighted raw sums, so Laplace smoothing on a weighted
basis is not computable (same constraint as the P13 gate's documented
deviation from Laplace smoothing). One
threshold = one story: a rule P13 warns about is the same rule whose findings
stop silting the DB.

## What each consumer does with a gated rule

- **mxHealth** (before Phase 3b + Phase 4): findings from gated rules are
  reported INLINE ONLY — no Phase 3b note, excluded from the Phase 4
  bugreport. Mark them in the report: `(suppressed: rule <rule_id>
  weighted_precision=<X> over n=<Y> — persisted stats only)`. mxHealth already
  has the numbers from P13 — 0 extra MCP calls.
- **mxBugChecker / mxDesignChecker** (at their persist step): they create no
  notes/bugreports, so nothing is suppressed. Annotate gated-rule findings in
  the report table instead: append `⚠ low-precision rule` to the finding line
  so the user can weigh it. One `mx_skill_metrics` call, only when findings > 0.

## Safety rules (never break these)

- `record_finding` is NEVER suppressed — it is cheap and feeds the statistics
  that make this gate possible in the first place.
- Suppression applies ONLY on the individual rule's own numbers. A namespace
  or skill aggregate may warn, but must never silence a rule that lacks its
  own `n >= 10` evidence — a badly rated neighbour must not mute an
  unmeasured, possibly good rule.
- The `downgraded` tune-state is NOT a gate criterion: `mx_skill_metrics`
  reads only `skill_findings`, never `skill_params` — the state is invisible
  to this API.
