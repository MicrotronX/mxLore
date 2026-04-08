# mx_* Custom Tools – Referenz

> NUR bei Bedarf laden. Parameter/Typen liefert das MCP-Schema automatisch.
> Hier steht nur was das Schema NICHT sagt: Wann, Warum, Zusammenhaenge.

---

## Pfad-Fund-Regel (WICHTIG)

1. **Vor** Pfad-Suche: `mx_get_env(key='<name>_path')` pruefen
2. Neu entdeckte Pfade: sofort `mx_set_env(key='<name>_path', env_value='...', project='_global')`

| Key-Pattern | Beispiel |
|---|---|
| `<tool>_path` | `delphi_path`, `php_path` |
| `<lib>_path` | `tms_path` |

---

## Analyse-Skills (IMMER als Subagent)

| Skill | Modus | Wann |
|---|---|---|
| `/mxDesignChecker` | `design` / `code` | Nach Spec-Genehmigung / nach Code-Aenderungen |
| `/mxBugChecker` | — | Bei Fehler-Analyse, VCS-Diff-Review |
| `/mxHealth` | — | Periodisch, vor Releases. Phase 4: Auto-Bugreport |

---

## Persistenz-Skills (Wann aufrufen?)

| Skill | Trigger |
|---|---|
| `/mxSave` | Session-Ende, vor Compacting, nach 15-20 Tool-Aufrufen, nach Milestones |
| `/mxPlan` | Nach Brainstorming, Spec-Ergebnis |
| `/mxSpec` | Vor Planung, bei Feature-Definition |
| `/mxDecision` | Bei Architektur-/Technologie-Entscheidungen |
| `/mxOrchestrate` | Multi-Step-Workflows, Status-Check (`suggest`) |

---

## doc_type Referenz (ADR-0007)

| doc_type | Status-Werte |
|----------|-------------|
| `plan`, `spec`, `decision` | draft, active, archived, superseded |
| `session_note`, `workflow_log`, `reference`, `note` | draft, active, archived |
| `bugreport`, `feature_request` | reported, confirmed, in_progress, resolved, rejected, deferred |

---

## Tipps & Fallstricke

- **Parametername:** Einheitlich `project` (nicht `project_slug`)
- **mx_search:** Kein Wildcard-Only Query (`*` allein funktioniert nicht)
- **mx_briefing:** `token_budget` default 2000, bei Session-Start aufrufen
- **mx_get_env Fallback:** Key→Developer→_global (mit `source`-Feld in Response)
- **Notes vs. Docs:** `mx_create_note` fuer Notes/Bugreports/Feature-Requests, `mx_create_doc` fuer Specs/Plans/Decisions
