# Resume Enrichment — Mode 5 Step 6 (Bug#3230 + FR#3566)

Detailed rules behind the 6-line summary in `SKILL.md` Mode 5 Step 6.

## Origin

- **Bug#3230** (Session 268d, canonical SKILL.md md5 `3acaed86`): closed the
  stack-pop path. Pre-fix, the session-note search was silently skipped when
  the WF Result-Column "looked rich".
- **FR#3566:** extends closure to the empty-stack path (post-WF-completion,
  fresh-session resumes, `/clear` + `/mxOrchestrate resume` cycles). Pre-fix,
  the empty-stack branch silently omitted both the session-note search and the
  resume-event marker, re-opening Bug#3230 for every empty-stack resume.

## Stack-pop / ID-select path (stack >= 1)

After WF `mx_detail`, you MUST always run the session-note search — even if
the WF Result-Column looks rich. Skipping is a skill-rule violation that
reintroduces Bug#3230.

1. **Required call:** `mx_search(project, doc_type='session_note',
   query='<WF-ID> OR <primary_artifact_IDs>', limit=2)` — ALWAYS runs. 0-hit
   is a valid outcome, NOT a reason to skip the call.
2. If hit: `mx_detail(note_id, max_content_tokens=1500)` on first match.
   `1500` = full session_note body for Mode 5 enrichment.
3. Also: follow WF outbound relations (references / implements) if WF body
   lists `Spec#NNNN` / `Plan#NNNN` / `Decision#NNNN` with `in-progress` or
   `draft` status -> `mx_detail(primary_artifact, max_content_tokens=600)`.
   `600` server-default = status / next-action peek only.
4. Merge surfaced pivot-decisions, next-action hints, and open-OQ-state into
   the Resume output. This prevents "orphan resume" where Mode 5 technically
   succeeds but the user is blind to pivot decisions captured post-save.

## Empty-stack path (stack = [])

`--resume` without active stack still loads the open-items list, BUT Step 6
(Context-Note Enrichment) and the `events_log` resume-event are
STACK-INDEPENDENT and STILL RUN.

- **Unconditional `mx_detail`:** if `state.last_save_session_note_doc_id !=
  null` -> `mx_detail(note_id, max_content_tokens=1500)`. Loads the last
  session_note regardless of stack state.
- **Unconditional `mx_search` fallback:** `mx_search(project,
  doc_type='session_note', limit=2)` ordered by `updated_at DESC` (most
  recent). 0-hit is valid, NOT a reason to skip.
- **Unconditional resume-event:** write `events_log` entry `{type: 'resume',
  wf: null, detail: '...context-note=<id|none>...'}`. `wf=null` explicitly
  signals the empty-stack path and keeps the audit-grep catchable.
- Merge surfaced pivot-decisions, next-action hints, and open-OQ-state from
  the loaded session_note into the open-items output — same enrichment-bullets
  format as the stack-pop path.

## Event-log invariant (both paths)

The resume event you write MUST include either `context-note=<note_id>` or
`context-note=none` in its `detail` field. Missing = rule violation. Allows
audit grep over `events_log` for `type='resume'` entries without
`context-note=` — any match (including `wf=null` entries) = missed enrichment
= skill-rule breach.

## Unbacked-decision tag detection (decoupled detect-time vs render-time)

Immediately after the primary_artifact `mx_detail` returns (within Step 6),
inspect the returned tags array for `unbacked-decision`. If present, run a
regex-scan over the body to count Decision-Markers using the canonical regex
+ fence-exclusion algorithm in `~/.claude/skills/_shared/decision-marker.md`.

Store result in local variable:

```
unbacked_decision_warning = {
  tag_present: bool,
  marker_count: int,
  spec_id:     int,
}
```

Rendering happens at Step 8:

- `tag_present == true AND marker_count > 0` -> render at TOP of output
  (BEFORE bullet-summary, AFTER `Next step:` line):
  `WARNING: spec#<spec_id> carries unbacked-decision tag - <N> decision-markers in body without ADR. Run /mxDecision or override.`
- **Double-check guard:** `tag_present == true AND marker_count == 0` -> log
  INFO `stale tag detected on spec#<spec_id>` and SKIP warning render
  (defends against AC4 stale-tag false-positives that escaped AC3 cleanup).
