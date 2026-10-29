# Backlog Hygiene — fixed-pending-verify marker, auto-close, stale re-audit (SSoT)

Single source for the marker format, the deadlines and who runs what. Skills reference this file; they never restate the numbers.

Why: fixed items stayed `active` forever because closing was a separate manual step. The common case is "code built and released, only a test is still open" — other users and customers test it right after release, so waiting forever gains nothing.

## Marker (both parts required)
1. Tag `fixed-pending-verify` (`mx_add_tags`).
2. Content line, appended: `fixed-pending-verify since YYYY-MM-DD (<build/release>)` via `mx_update_doc(append_content=...)`.

- The deadline counts from the date in the **last** such line — NOT from `days_since_content_change`. A typo fix does not move the deadline; a new marker line restarts it.
- Tag without a parseable line → never auto-closed; reported by mxHealth P15.
- Regression before the deadline → remove the tag, or open a new bugreport that references the id.
- Applies to `bugreport`, `feature_request`, `todo`.

## Deadlines
`today_utc` = `date -u +%Y-%m-%d`, never the chat clock.
- `AUTO_CLOSE_DAYS = 14` (marker date <= today_utc - 14d).
- `STALE_DAYS = 30` (untagged active items, `days_since_content_change` > 30).

## Auto-close — single locus: mxSave Step 3
The ONE place that writes. Runs in normal and `--loop` mode, no prompt (explicit, narrow exception to "never auto-archive FR/BR" — tagged items only).
1. `mx_search(project, tag='fixed-pending-verify', status='active', doc_type='bugreport,feature_request,todo', include_content=false, limit=50)`. ∅ → done.
2. `mx_batch_detail(doc_ids=[...], level='full')` (max 10/call) → take the last line matching `fixed-pending-verify since (\d{4}-\d{2}-\d{2})`.
3. Date <= today_utc - `AUTO_CLOSE_DAYS` → `mx_update_doc(doc_id, status='archived', append_content='auto-closed YYYY-MM-DD: <N>d after fixed-pending-verify without regression; regression -> new bugreport referencing this id', change_reason='auto-close fixed-pending-verify')`.
4. No parseable line → skip (no write).
Output: `Auto-closed: <N> (fixed-pending-verify >= 14d)` — silent if 0. MCP error → skip block, one warning line, never abort the save.

## Stale re-audit — mxHealth P15 (read-only) + mxSave count
- Candidates: `mx_search(project, doc_type='bugreport,feature_request,todo', status='active', include_content=false, limit=50)` MINUS the ids from the tag search above (client-side set difference; mx_search has no tag-exclusion filter).
- Stale = `days_since_content_change` > `STALE_DAYS`. Field missing (older server) → skip silently, never guess.
- Never auto-archived. mxHealth lists them and recommends a code re-audit (subagent, evidence `file:line` per item); the user decides.
- mxSave prints only `Stale open items: <M> (>30d) -> /mxHealth` — silent if 0.

## Setting the marker — mxSave FR/BR closure sweep
Per candidate: `archive` | `pending-verify` (apply both marker parts) | `keep`. No preselected option — the user picks per item (an FR can hold several asks; a plan task may cover only one).

## Plan/Spec -> FR/BR link (`implements`) — closes the gap when an item is built inside another plan
An FR/BR built by a plan/spec must not wait for a session to name its id. Server relation `implements` (existing type, no new one).
- **Link (mxPlan Step 2/3, mxSpec Section 2/3):** every `FR#`/`BR#`/`todo#` id named in the input or in `## Related` as source or co-implemented -> `mx_batch_detail` -> keep `doc_type in {feature_request, bugreport, todo}` -> `mx_add_relation(source_doc_id=<plan|spec>, target_doc_id=<item>, relation_type='implements')`. Server dedupes, re-run is safe. Tags (`spec-<id>` / `plan-<id>`) never create this relation: a tag says related, not implemented, and an `implements` relation would let Mark on archive close the item without a prompt. Tag-linked items surface only in the read-only done-in-plan list below. Output `Linked: <N> FR/BR (implements)` — silent if 0.
- **Mark on archive (mxPlan Step 4, mxSpec Step 4, right after the archiving `mx_update_doc` succeeded):** `mx_detail(<plan|spec>, max_content_tokens=1)` -> relations with `relation_type='implements'` AND `source_doc_id=<plan|spec>` -> `mx_batch_detail(target ids)` -> keep `doc_type in {feature_request, bugreport, todo}` AND `status='active'` AND tag `fixed-pending-verify` absent -> apply BOTH marker parts, line `fixed-pending-verify since YYYY-MM-DD (Plan#<id>)` / `(Spec#<id>)`. No prompt: the finished plan is the evidence, the 14-day window is the safety net. Output `Marked pending-verify: <N> FR/BR` — silent if 0. MCP error -> one warning line, never undo the archive.
- **Net (mxSave Step 3):** plans/specs archived in this session (tool returns) -> same mark rule, also in `--loop` mode. Catches archives done by hand (`mx_update_doc status='archived'`) outside the skills.

## Backlog re-audit — mxOrchestrate resume (background, throttled, read-only)
Closes the gap for items built inside a plan that stays active for months: nobody names the id, so no closure path fires. The developer runs nothing extra: `resume` -> works -> `/mxSave`.
- **When:** Mode 5 after the open-items list, explicit user resume only (not the handoff path, not hooks, not `--loop`), `mcp_available`. Throttle: `mx_get_env(project, key='BACKLOG_REAUDIT_AT')` (⚡ always pass `key`) -> value missing or < `today_utc - REAUDIT_DAYS` (`REAUDIT_DAYS = 7`) -> run; else skip silently.
- **Spawn (Main):** one background Agent, `model: sonnet`, no `name`, prompt = this section's "Agent contract" + project slug + code root (= the session's working directory; a different root only when CLAUDE.md names one) + the active ids from step 1 (limit 50; 50 rows -> the agent prints `re-audit list truncated at 50`). After the spawn returned: `mx_set_env(project, key='BACKLOG_REAUDIT_AT', value=<today_utc>)`.
- **Agent contract:** read-only, never writes MCP, never edits. Per item `mx_detail(id, max_content_tokens=600)` -> derive 1-3 concrete probes from the ask (unit/file, function, route, setting key, UI string) -> Grep/Glob under the code root -> a hit that matches the ask = row `type#id — file:line — <what matched>`. No probe derivable -> count `not checkable`; probes present but nothing found -> no row (still open). Return max 20 lines: rows + one counts line `<N> likely done, <U> not checkable, <O> open`. No prose, no guesses: a row without `file:line` is invalid.
- **Main, when the result arrives:** print `Backlog re-audit: <N> likely done` + the rows (0 rows -> that one line only). These ids are closure-sweep candidates in mxSave Step 3 (source line there): archive / pending-verify / keep, no preselected option. Never auto-archive, never auto-mark.
- **Release gate for changes to this section:** replay the agent on the concrete trigger cases (BR#19933: 11 FRs, status ignored) and record `caught N of M` (lesson 2026-10-29).
