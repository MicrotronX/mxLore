# Decision-Marker — Canonical Regex + Fence-Exclusion (Shared)

Single source-of-truth for mx*-skills (mxSpec Section 3b, mxOrchestrate Mode 5 Step 6).
Edit here, mirror to consumers.

## Regex

```
# ASCII-only — no Unicode operators (mcp body corruption rule)
DECISION_MARKER_REGEX = (?m)^(\*\*)?Decision:\s+\S|^Q\d+\s*=\s*\S|^Approval-Modell:|^Konsens:
```

Bias: safer to miss real markers than to false-positive on example payloads.

## Fence-Exclusion Algorithm

Skip lines inside fenced code blocks. Column-zero ` ``` ` toggles the flag;
language-tag is fine. Indented fences are ignored. An unclosed fence bails to
file-end as in-fence (conservative — drops markers rather than risking a false
positive on example content).

```
in_fence = false
markers = []  # list of (line_number, line_text)
for each line in body:
  if line.trim() starts with "```": in_fence = !in_fence; continue
  if in_fence: continue
  if line matches DECISION_MARKER_REGEX:
    markers.append((line_number, line_text))
```
