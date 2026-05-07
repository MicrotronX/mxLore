# Follow-ups Scope Algorithm (canonical)

Used by `mxDecision` step 5b to count completed vs. total live follow-up checkboxes inside an ADR.

## Scope rules

- Only count `- [ ]` / `- [x]` / `- [X]` checkboxes inside the H3 `### Follow-ups` block that lives DIRECTLY under the H2 `## Consequences` section.
- Any other H2 resets the H3 scope (so an unrelated `### Follow-ups` under a different H2 is NOT counted).
- Skip lines inside fenced code blocks (```), so code samples that look like checkboxes are ignored.
- Drop strikethrough lines that contain both `~~` and `(dropped)` — these are explicitly retired follow-ups and must NOT inflate M.
- Checkbox detection requires NO leading whitespace (must start at column 0 with `- [ ]` / `- [x]` / `- [X]`).

## Algorithm (pseudocode)

```
in_fence = false
in_followups = false
in_consequences = false
M = 0; N = 0
for each line in content:
  if line.trim() starts with "```": in_fence = !in_fence; continue
  if in_fence: continue
  if line matches /^## /:
    in_consequences = (line == "## Consequences")
    in_followups = false  # any H2 resets H3 scope
    continue
  if line matches /^### / and in_consequences:
    in_followups = (line == "### Follow-ups")
    continue
  if line matches /^### / and !in_consequences:
    in_followups = false  # H3 outside Consequences is NOT follow-ups
    continue
  if !in_followups: continue
  if line matches /^- \[[ xX]\] / (no leading whitespace):
    if line contains "~~" AND "(dropped)": continue  # exclude dropped follow-ups
    M += 1
    if line matches /^- \[[xX]\] /: N += 1
```

## Outputs

- `M` = total live follow-ups (open + done, excluding dropped).
- `N` = completed live follow-ups.
- `M == 0` → no transition (skip step 5b).
- `M > 0 AND N == M AND DB-status == active` → flip content `**Status:** accepted` → `**Status:** implemented` and `mx_update_doc(..., status='archived', change_reason='All follow-ups completed')`.
- `0 < N < M` → info only (`<N>/<M> follow-ups completed`), no write.

## Localization note

The H2 may also appear as `## Konsequenzen` (German). The caller is responsible for matching either `Consequences` or `Konsequenzen` when setting `in_consequences`.
