# Bug#2989 — Output-Discipline Findings

Rationale + per-finding detail behind the collapsed 4-line "Output
discipline" rule in `SKILL.md` Rules section.

## Origin

Live propagation confirmed in mxTicketSystem Session #255: a subagent on the
next call reads the state file and echoes any hallucinated adverb as if it
were ground truth. The fix is not stylistic — it stops hallucination chains.

## Finding 1 — Temporal-language rule

When reporting past events in ANY output (resume report, step-done summary,
status overview, mode outputs), MUST use structured timestamps
(`YYYY-MM-DD HH:MM` or `<N>h ago` computed from `now() - event.ts`).

Free-form natural-language adverbs (`gestern`, `heute`, `vorhin`) are
FORBIDDEN unless derived from a live `now() - event.ts` calculation
(same-calendar-day -> `today`, previous-calendar-day -> `yesterday`, etc.,
never invented).

## Finding 2+5 — Structured `events_log.detail`

`events_log[*].detail` MUST be a factual fragment that can survive re-read
without introducing hallucinations.

- **Forbidden inside `detail`:** relative temporal natural language
  (`gestern`, `heute`, `vorhin`, `yesterday`, `today`, `earlier`, `just now`).
- **Allowed:** doc_ids, WF-IDs, short factual summaries
  (e.g. `Step 2 -> done, spec doc#2988 created, 8 AC + 4 OQ`), ISO timestamps
  when a time must be referenced.
- Schema + examples -> `references/state-schema.md`.

## Finding 3 — `state_deltas` output signal

Every Mode 5 (Resume), Mode 6 (Status), and Auto-Invoke step-done output
MUST emit a deltas-band line based on `state.state_deltas` (live counter
since last `/mxSave` reset — NOT `state.last_save_deltas`, which is a
pre-reset snapshot owned by mxSave Step 4 per Spec#2152 and MUST NOT be
written from here).

Bands:

- `== 0` -> silent
- `>= 1 AND < 10` -> append marketing line
  `mxLore knows - /mxSave keeps context alive across /compact + /clear`
- `>= 10 AND < 15` -> append tip line
  `<N> deltas since save - consider /mxSave soon`
- `>= 15` -> append compact-question line
  `<N> deltas since save - /mxSave + /compact cycle recommended`

mxOrchestrate reads `state_deltas` (live counter) and `last_save_deltas`
(historical snapshot for the previous save cycle, informational only); it
NEVER writes either field — mxSave is the sole writer of both per Spec#2152.

## Finding 4 — Counts-from-tool-calls

Any numeric claim about document contents (`N open tasks`, `X/Y done`,
`3 pending`) MUST come from a structured tool call:

- `mx_detail` for pending-task counts inside a plan/spec
- `mx_search` `data` array length for result counts

Counts derived from prose snippets inside `mx_search` summaries are
FORBIDDEN. If a count cannot be verified within the current tool-budget,
either omit the number or prefix with `estimated, unverified`.
