# mx_* Custom Tools – Reference

> Load ONLY when needed. Parameters/types are provided automatically by the MCP schema.
> This file contains only what the schema does NOT say: When, Why, Relationships.

---

## Path-Lookup Rule (IMPORTANT)

1. **Before** path search: check `mx_get_env(key='<name>_path')`
2. Newly discovered paths: immediately `mx_set_env(key='<name>_path', env_value='...', project='_global')`

| Key Pattern | Example |
|---|---|
| `<tool>_path` | `delphi_path`, `php_path` |
| `<lib>_path` | `tms_path` |

---

## Analysis Skills (ALWAYS as Subagent)

| Skill | Mode | When |
|---|---|---|
| `/mxDesignChecker` | `design` / `code` | After spec approval / after code changes |
| `/mxBugChecker` | — | For error analysis, VCS diff review |
| `/mxHealth` | — | Periodically, before releases. Phase 4: Auto-Bugreport |

---

## Persistence Skills (When to call?)

| Skill | Trigger |
|---|---|
| `/mxSave` | Session end, before compacting, after 15-20 tool calls, after milestones |
| `/mxPlan` | After brainstorming, spec result |
| `/mxSpec` | Before planning, when defining features |
| `/mxDecision` | For architecture/technology decisions |
| `/mxOrchestrate` | Multi-step workflows, status check (`suggest`) |

---

## doc_type Reference (ADR-0007)

| doc_type | Status Values |
|----------|-------------|
| `plan`, `spec`, `decision` | draft, active, archived, superseded |
| `session_note`, `workflow_log`, `reference`, `note` | draft, active, archived |
| `bugreport`, `feature_request` | reported, confirmed, in_progress, resolved, rejected, deferred |

---

## Tips & Pitfalls

- **Parameter name:** Consistently `project` (not `project_slug`)
- **mx_search:** No wildcard-only query (`*` alone does not work)
- **mx_briefing:** `token_budget` default 1500, call at session start
- **mx_get_env fallback:** Key→Developer→_global (with `source` field in response)
- **Notes vs. Docs:** `mx_create_note` for notes/bugreports/feature requests, `mx_create_doc` for specs/plans/decisions
