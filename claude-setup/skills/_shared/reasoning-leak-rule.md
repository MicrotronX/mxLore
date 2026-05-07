# Reasoning-Leak Rule — Position-0 Marker (Shared)

Single source-of-truth for the report-marker contract that all mx*-skill
subagents MUST honor. Anchors the fix for cross-skill reasoning-leak.

## Rule

FIRST line of every response = `### REPORT ###` EXACTLY. Position 0.
Nothing before.

No prosa, reasoning, blank lines, or heading prefixes ahead of the marker.
The marker line is the literal seven-character sequence `### REPORT ###`
followed by a newline — no leading space, no surrounding fence, no bold.

## Rationale

Cross-skill reasoning-leak pattern observed in live testing: subagents
prepend status prosa such as `All done. Producing final report.` ahead of
the report body, even when the rule was partially introduced. This breaks
parent-agent parsers that key off the marker line.

Strict Position-0 anchoring closes the gap: the parent splits on the first
occurrence of `### REPORT ###`, treats anything above it as leaked
reasoning, and surfaces a warning if leak bytes are non-zero.

## Failure mode

If the subagent emits any byte before the marker, the parent treats the
report as malformed and may re-dispatch. Skills that wrap their report in
fenced code blocks or markdown headings violate the rule — emit the marker
plain, at column zero, on line 1.
