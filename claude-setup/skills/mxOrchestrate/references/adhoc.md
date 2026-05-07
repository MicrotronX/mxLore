# Mode 3 — Track (Ad-hoc Task)

Detail behind the 3-line summary in `SKILL.md` Mode 3.

## Steps

1. Create ad-hoc object: `{note, created: now(), origin_workflow:
   stack[0].id, mcp_note_id: null}`.
2. Push to `adhoc_tasks[]`.
3. Persist to MCP: `mx_create_doc(project, doc_type='todo', title=note,
   content='Origin: <WF-ID>')` -> set `mcp_note_id`. On error -> null (local
   only).
4. Log event (`type='track_adhoc'`).
5. **Escalation check** (Claude decides based on context):
   - **note** (default): only noted, workflow continues.
   - **park+start:** park current WF -> Mode 4 (park) + Mode 2 (start).
   - **spawn:** start team agent -> see `references/team-agents.md`.
6. Output: `Ad-hoc tracked: "<note>" (origin: <WF-ID>). Escalation: <note|park|spawn>.`
