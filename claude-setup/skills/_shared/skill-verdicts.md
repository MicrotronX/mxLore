# Skill-Evolution Verdicts (SSoT)

Read by: mxBugChecker, mxDesignChecker, mxHealth, mxSave.
Anything that calls `mx_skill_feedback` obeys this file.

## The three verdicts

A verdict judges **the rule**, not the fix, and not the effort.

| Verdict | Meaning | The defect | Someone acted |
|---------|---------|-----------|---------------|
| `confirmed` | the rule was right | existed | yes |
| `dismissed` | the rule was right | exists, stands | no |
| `false_positive` | the rule was **wrong** | never existed | n/a |

`pending` is not a fourth verdict. It means a checker produced a finding and
ended without recording the user's call. Treat it as a defect in the checker.

## Who writes a verdict

⚡ **The human states it; the agent only records it.** An agent never grades its
own findings — that fabricates the ground truth the metric exists to measure.

The review surface is the conversation that produced the finding, at the moment
the user decides what to do about it. There is no separate review queue to visit
later, and none should be built: a queue nobody opens produces no verdicts.

| The user says | Verdict |
|---------------|---------|
| "fix it" / applies the fix | `confirmed` |
| "skip" / "don't fix" / "not worth it" / "later" | `dismissed` |
| "that's wrong" / "no bug there" / "you misread it" | `false_positive` |
| nothing — session ended, no decision | stays `pending` (anomaly, report it) |

Re-adjudicating old findings against current code is a **proposal**, never a
write: present the finding plus the evidence, let the user choose the verdict.
"The code changed" is not by itself a verdict — a defect that was fixed is
`confirmed`; a defect that stopped mattering is `dismissed`.

## Why the distinction is load-bearing

The server computes `precision = confirmed / (confirmed + false_positive)`.
`dismissed` is excluded from numerator and denominator, on purpose: declining to
act on a true finding says nothing about the rule's accuracy.

Route "won't fix" into `false_positive` and the formula silently becomes
`fixed / (fixed + not-worth-fixing)` — an effort ratio wearing the name of an
accuracy metric. Good rules that surface true-but-minor findings then score
*worse* than lazy ones. This is the same split SonarQube and CodeQL draw between
a false positive and a won't-fix, and the reason SARIF carries a suppression
`justification` alongside the suppression itself.

## Forbidden

- ⚡ **Batch-dismiss.** Marking unreviewed findings `dismissed` in bulk (no
  `finding_uid`) empties the queue without anyone looking. `confirmed` and
  `false_positive` then never accumulate, `precision` stays `0/0`, and the
  server renders that as `0.0` — indistinguishable from "always wrong".
- ⚡ An agent writing `confirmed` or `false_positive` on a finding it produced.
- ⚡ Treating `pending` as a backlog to be cleared rather than a signal to fix
  the checker that dropped the verdict.
