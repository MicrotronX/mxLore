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
Per candidate: `archive` | `pending-verify` (apply both marker parts) | `keep`.
