# Team Agents (Ad-hoc Escalation: spawn)

Detail behind the 2-line pointer in `SKILL.md`.

## Deferred-tool note

`TeamCreate` is a deferred tool — not in this skill's `allowed-tools`
frontmatter. Before the first spawn, load its schema via `ToolSearch` with
query `select:TeamCreate`, then invoke.

## Spawn flow

1. Claude recognizes: ad-hoc task is independent + parallelizable.
2. **TeamCreate** call with context:
   - Project slug + MCP access
   - Task description
   - Instruction: persist result as MCP note (tag: `team-result`)
3. Update `team_agents[]`: `{id, task, origin_workflow, spawned, status: 'running'}`
4. Log event (`type='spawn'`)
5. **Isolation:** Team agent has NO access to `orchestrate-state.json`. MCP only.
6. **Return flow:** Team agent done -> MCP note with tag `team-result` ->
   Proactive Notification.
7. Hook shows team status in line 2.
