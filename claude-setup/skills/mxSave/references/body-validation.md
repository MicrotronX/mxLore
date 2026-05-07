# Step 5 — Body-Validation Gate + Subagent Hardening + Archive-Fidelity Rule

Reference offloaded from SKILL.md (Bug#3239 silent-empty body + Bug#3239 archive-fidelity). The 2-line pointer in SKILL.md remains; this file holds the full rules.

## Body-Validation Gate — BEFORE mx_create_doc

The subagent-returned body string MAY be empty/truncated/error-prose when the subagent crashes, hits its token cap, or returns a meta-reply instead of the template content. Persisting such a body produces a session_note whose `content=""` — the next session's resume has no archived context. Gate to prevent that:

Validate the body string against ALL THREE criteria:

1. **Length:** `len(body) >= 500` chars.
2. **Structure:** contains at least 3 of the template section headers (`## What was done`, `## Changed files`, `## Commits`, `## Docs created this session`, `## Next step`).
3. **Archive-Fidelity (Bug#3239 hardening):** if the chat history contains structured decision artefacts — markdown tables with ≥5 rows, `## Step N`, `## Substep`, `## Konsens`, `## Brainstorm`, `## Review` headings, or Q/A-resolution blocks — the returned body MUST contain at least one matching `## Appendix:` heading per detected artefact-class. Regex: detect artefacts via `^\|[^\n]+\|$` ×≥5 consecutive lines OR `^## (Step \d+|Substep|Konsens|Brainstorm|Review)` in chat; body must carry `^## Appendix:` followed by the verbatim block. Missing appendix for a detected artefact = fidelity-fail.

If ANY criterion fails: DO NOT pass the subagent body to `mx_create_doc`. Instead, Main builds a fallback body directly in the current context (no subagent) using the same template, reading from chat history / tool-call returns / git state — and MUST include all detected decision artefacts verbatim under `## Appendix:` sections. Then log once:

`WARN: Step 5 body-subagent returned N chars, K sections, M/X fidelity-artefacts preserved (< threshold); fallback to local prose.`

**Invariant:** the body passed to `mx_create_doc` is NEVER empty AND NEVER shorter than the local fallback AND NEVER drops detected decision artefacts — a degraded fallback beats a silent body-drop or compression-loss.

## Subagent dispatch hardening (Bug#3239)

When spawning the body-builder subagent, pre-scan the chat history for the artefact classes above and pass an explicit `required_appendices` list in the subagent prompt (e.g. `required_appendices: ["Konsens-Tabelle Step 4", "CC2050 Review Outcome", "Q3 Body-Limits 2000/8000"]`). Raise the token budget hint to 8000 for Brainstorm/Review-heavy sessions (already allowed per Archive-Fidelity Rule). The subagent cannot "forget" appendices under compression pressure when they are enumerated as required parameters.

## Archive-Fidelity Rule (Bug#3239)

Session notes must ARCHIVE chat-produced decision artefacts VERBATIM, not compress them.

- Detect structured blocks in chat history: Konsens-Tabellen (markdown tables ≥5 rows with decision content), Step-N-Konsens-Summaries, Brainstorm-Progress outputs, CC2050-Review outcomes, Q/A-resolution blocks.
- Include these blocks 1:1 in session_note.content under `## Appendix: <section-name>` headings.
- The meta-summary (What was done? Next step? etc.) stays at the top; the verbatim blocks follow as appendices.
- Token-budget: session_notes for Brainstorm-heavy or multi-review sessions may grow to ~8000 tokens (default cap 3000 is a suggestion, not a hard limit).
- Rationale: when `/clear` happens, `resume` reads back ONLY the session_note. A compressed summary loses per-step parameters (e.g. "Body-Limits 2000/8000", "Token-Bucket 50/10h") that block subsequent Spec/Plan work. Verbatim archival is cheaper than mid-next-session user-rescue from screen-scrollback.
- When in doubt between brevity and fidelity → choose fidelity.
