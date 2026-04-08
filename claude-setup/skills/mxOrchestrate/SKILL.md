---
name: mxOrchestrate
description: "Persistent Session Orchestrator. Always-on via Hooks. Manages workflows (stack), ad-hoc tasks, team agents, and skill chains. Central coordinator for all session activities via MCP."
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Skill, Agent
argument-hint: "init | start <typ> | track <notiz> | park [reason] | resume [id] | status | suggest | --resume"
---

# /mxOrchestrate — Persistent Session Orchestrator (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen.

Zentraler Session-Manager. Verwaltet Workflow-Stack, Ad-hoc Tasks, Team Agents.
Skills **vollautomatisch ausfuehren**. Nur bei **optionalen Schritten** User fragen.
**Spec:** #1089 | **Plan:** #1090

## Architektur
```
SessionStart Hook → laedt State, informiert Claude (kein Fragen!)
UserPromptSubmit Hook → injiziert 3-Zeilen-Kontext bei jedem Prompt
mxOrchestrate Skill → Gehirn: Routing, Tracking, Steuerung
MCP = Source of Truth | .claude/orchestrate-state.json = Cache
```

## Init (Pre-Routing, JEDER Aufruf)
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. State laden: `.claude/orchestrate-state.json`→parse. ∅Datei oder korrupt→Modus `init`
3. **Session sicherstellen:**
   - state.session_id vorhanden UND Modus≠`init` → mx_ping()→OK=MCP-Modus | Fehler=Lokal
   - ∅session_id ODER Modus=`init` → **Setup-Version:** `~/.claude/setup-version.json`→parse→`version`. ∅Datei→`''`
     → `mx_session_start(project, include_briefing=true, setup_version=<version>)`→session_id+Response in State
     → Fehler=Lokal(`docs/ops/workflow-log.md`+Warnung)
4. **Auto-Detect: Projekt-Setup** (siehe unten)
5. → Modus-Routing nach Argument

## Auto-Detect: Projekt-Setup
Laeuft im Pre-Routing nach Session-Aufbau. ⚡ 0 Extra-MCP-Calls — nutzt mx_session_start Response + max 2x Glob.

1. **CLAUDE.md Pruefung** (immer, 1x Glob):
   - Glob: `CLAUDE.md` im Projektroot → ∅Treffer = Setup fehlt
   - → User: "Projekt hat keine AI-Config. `/mxInitProject` ausfuehren? (1=ja/2=nein)"
   - ⚡ Nur vorschlagen, nie auto-ausfuehren
2. **MCP-Projekt Pruefung** (nur MCP-Modus, nur wenn mx_session_start lief):
   - mx_session_start Response enthaelt "project not found" → Projekt nicht registriert
   - Falls CLAUDE.md vorhanden: → User: "Projekt nicht in MCP. `/mxInitProject` registriert es. (1=ja/2=nein)"
   - Falls CLAUDE.md fehlt: in Vorschlag aus Schritt 1 integriert
3. **Lokale Migrations-Kandidaten** (nur MCP-Modus + Projekt existiert, 1x Glob):
   - Glob: `docs/*.md` (NICHT rekursiv)
   - Erlaubt-Liste: `status.md`, `workflows.md`
   - Treffer ausserhalb Erlaubt-Liste → User: "N lokale Docs gefunden (Liste). `/mxMigrateToDb` ausfuehren? (1=ja/2=nein)"
   - ⚡ Nur vorschlagen, nie auto-ausfuehren
4. **Alle Checks OK → keine Meldung** (kein Rauschen bei korrekt eingerichteten Projekten)

## Modi
| Argument | Modus |
|----------|-------|
| `init` | 1: State aus MCP initialisieren |
| `start <typ>` (`neues-feature`, `bugfix`, `entscheidung`, `<custom>`) | 2: Workflow starten (Stack push) |
| `track <notiz>` | 3: Ad-hoc Task loggen |
| `park [reason]` | 4: Aktiven WF parken (Stack push-down) |
| `resume [id]` | 5: WF fortsetzen (Stack pop / ID select) |
| `--resume` | 5: Alias fuer resume (Rueckwaertskompatibel) |
| `status` | 6: Vollstaendige Uebersicht |
| `suggest` | 7: Naechsten Schritt vorschlagen |

## State-Datei (.claude/orchestrate-state.json)

**Schema v2 (Spec#1161):**
```json
{
  "schema_version": 2,
  "session_id": "<int|null>",
  "workflow_stack": [{"id","name","doc_id","doc_revision","status","current_step","total_steps","started","unsynced"}],
  "adhoc_tasks": [{"note","created","origin_workflow","mcp_note_id"}],
  "team_agents": [{"id","task","origin_workflow","spawned","status","workflow_id"}],
  "state_deltas": "<int>",
  "last_save": "<ISO|null>",
  "last_reconciliation": "<ISO|null>",
  "events_log": [{"ts","type","wf","detail","synced"}]
}
```

**Stack-Regeln:**
- workflow_stack[0] = aktiver Workflow
- park = aktiven WF nach Index 1+ schieben, neuen an [0]
- resume = WF an [0] holen (LIFO oder per ID)
- ⚡ Max 5 Stack-Eintraege. >3 geparkt→Warnung "N geparkte WFs — Abschluss empfohlen?"
- state_deltas++: bei jedem Step-Done, Ad-hoc, Park, Resume, Start
- events_log: jeden Event sofort loggen {ts, type, wf, detail}

**State-Operationen (intern):**
- `loadState()`: Datei lesen+parsen. Korrupt/fehlend→leeren State zurueckgeben+Warnung
- `saveState(state)`: JSON.stringify→Datei schreiben
- `addEvent(type, wf, detail)`: Event in events_log pushen + state_deltas++

## Modus 1: Init
1. ⚡ **Erzwingt mx_session_start** im Pre-Routing (Schritt 3, ignoriert gecachte session_id)
2. Aktive Workflows aus mx_session_start Response in workflow_stack laden
3. State-Datei schreiben (session_id + workflows + events_log reset)
4. **Multi-Agent Auto-Listener:** Falls Response `active_peers` enthaelt→`/mxAgentListen` Background-Agent
5. Output: `Orchestrator initialisiert. Session #<id>. <N> aktive Workflows.`

## Modus 2: Start (Workflow erstellen)
1. Workflow-Template suchen: `docs/workflows.md`(projekt) dann `~/.claude/skills/mxOrchestrate/workflows.md`(global). ∅Template→?user→Ad-hoc
2. ID: `WF-YYYY-MM-DD-NNN`
3. `mx_create_doc(project, doc_type='workflow_log', title='WF-...: <Titel>', content)`
4. WF-Objekt auf Stack pushen (wird [0] = aktiv). Bisheriger [0]→parked (falls vorhanden)
5. State speichern + Event loggen (type='start')
6. Output: `Workflow "<Name>" gestartet (WF-xxx, doc_id=<id>). Stack: <N> WFs.`
7. Ersten Schritt auto-invoke

**WF-Markdown (MCP):**
```markdown
**Template:** <name> | **Gestartet:** YYYY-MM-DD HH:MM | **Status:** active

| # | Schritt | Skill | Status | Ergebnis | Timestamp |
|---|---------|-------|--------|----------|-----------|
| 1 | <Beschreibung> | <Skill> | pending | | |
```

## Modus 3: Track (Ad-hoc Task)
1. Ad-hoc Objekt erstellen: `{note, created: now(), origin_workflow: stack[0].id, mcp_note_id: null}`
2. In adhoc_tasks[] pushen
3. MCP persistieren: `mx_create_doc(project, doc_type='todo', title=note, content='Origin: <WF-ID>')`→mcp_note_id setzen. Fehler→null (nur lokal)
4. Event loggen (type='track_adhoc')
4. **Escalation pruefen** (Claude entscheidet basierend auf Kontext):
   - **note** (default): Nur notiert. Workflow laeuft weiter.
   - **park+start**: Aktuellen WF parken→Modus 4(park) + Modus 2(start)
   - **spawn**: Team Agent starten→Modus spawn (siehe Team Agents)
5. Output: `Ad-hoc getrackt: "<notiz>" (origin: <WF-ID>). Escalation: <note|park|spawn>.`

## Modus 4: Park
1. Stack[0].status = 'parked', Stack[0].parked_reason = reason
2. ⚡ Pruefe Stack-Tiefe: >3 geparkt→Warnung + Vorschlag aeltesten abzuschliessen
3. Event loggen (type='park')
4. State speichern
5. Output: `WF "<Name>" geparkt. Grund: <reason>. Stack: <N> WFs.`
6. ∅neuer WF gestartet→suggest Modus aufrufen

## Modus 5: Resume
1. **Ohne ID:** Stack LIFO — obersten geparkten WF (stack[1]) nach [0] holen
2. **Mit ID:** WF per ID im Stack suchen→nach [0] verschieben, Rest nachrücken
3. WF.status = 'active'
4. Event loggen (type='resume')
5. MCP: `mx_detail(doc_id)`→parse→naechsten pending-Schritt identifizieren
6. Output: `WF "<Name>" fortgesetzt. Stand: <X>/<Y>. Naechster Schritt: <Beschreibung>.`
7. Naechsten Schritt auto-invoke

**Rueckwaertskompatibel:** `--resume` ohne aktiven Stack→Offene-Punkte-Liste wie bisher (Phase 1 Kontext laden)

### Kontext laden (bei --resume ohne Stack)
**MCP:** (Session+Briefing bereits aus Pre-Routing verfuegbar)
1. Offene Punkte: `mx_search(project, doc_type='note,bugreport,feature_request', status='active')`
   - Filtern: Tags `todo,bug,feature-request,optimization,next,later` oder ohne session_note/e2e/test
   - ⚡ KEINE _global-Suche (_global nur fuer Env-Variablen, nicht fuer offene Punkte)
   - ⚡ `status='active'` — archivierte/erledigte Docs NICHT anzeigen
3. Offene Plans/Specs: `mx_search(project, doc_type='plan,spec', status='active', limit=10)`
   - Nur Titel+doc_id anzeigen, nicht den vollen Content
4. status.md: "Bekannte offene Punkte"→alle Bullets. "Naechste Schritte"→nur `- [ ]`
   - ⚡ Gegen MCP deduplizieren: Punkt in status.md der bereits als archived in MCP→entfernen aus Anzeige
5. Ergebnis: **Offene-Punkte-Liste** (dedupliziert, Bug→TODO→Feature→Opt→Sonstiges, max 30)

## Modus 6: Status
Vollstaendige Uebersicht:
- **Workflow-Stack:** ID|Name|Step|Status fuer jeden Eintrag
- **Ad-hoc Tasks:** Notiz|Origin|Erstellt
- **Team Agents:** Task|Status|Origin
- **Events (letzte 10):** Timestamp|Type|Detail
- **Aktive MCP-Docs:** `mx_search(project, doc_type='workflow_log,plan,spec', status='active')`→nur offene anzeigen
- **Kuerzlich archiviert:** `mx_search(project, doc_type='workflow_log,plan,spec', status='archived', limit=5)`→letzte 5 erledigte
- **Offene Punkte:** MCP-Notes(status='active') + status.md (dedupliziert gegen MCP)

## Modus 7: Suggest
1. Aktiver WF→naechsten Schritt
2. Geparkte WFs→aeltesten vorschlagen
3. Ad-hoc Tasks→priorisiert: Bug→TODO→Feature→Next/Later
4. ∅Stack→Offene-Punkte-Liste + Chat-Heuristik: ADR→/mxPlan | Plan→Impl | Code→/mxDesignChecker | lange Session→/mxSave

## Team Agents (Ad-hoc Escalation: spawn)
1. Claude erkennt: Ad-hoc Task ist unabhaengig + parallelisierbar
2. **TeamCreate** aufrufen mit Kontext:
   - Projekt-Slug + MCP-Zugang
   - Aufgabenbeschreibung
   - Anweisung: Ergebnis als MCP-Note (tag: team-result) persistieren
3. team_agents[] aktualisieren: {id, task, origin_workflow, spawned, status:'running'}
4. Event loggen (type='spawn')
5. ⚡ **Isolation:** Team-Agent hat KEINEN Zugriff auf orchestrate-state.json. Nur MCP.
6. **Rueckfluss:** Team-Agent fertig→MCP-Note mit tag 'team-result'→Proactive Notification
7. Hook zeigt Team-Status in Zeile 2

## Auto-Invoke (alle Workflow-Modi)
- Nicht-optional→auto ausfuehren→Step `done` + State update + Event loggen
- Optional→?user, "skip"→`skipped`
- Bedingt→Bedingung pruefen, ∅erfuellt→`skipped`
- Analyse-Skills→Agent-Tool: /mxDesignChecker, /mxBugChecker
- Unabhaengige Schritte→parallel per Agent-Tool
- **Skill-Mapping:** mx*/superpowers:*→**Skill-Tool** | mxDesignChecker/mxBugChecker→**Agent-Tool** | frontend-design→**Skill-Tool**(falls installiert, sonst skip)
- ⚡ **MCP-First Step-Update (Spec#1161):**
  1. `mx_update_doc(doc_id, content mit Step=done+Timestamp+Ergebnis, change_reason='Schritt N→done')` → MCP zuerst
  2. State-Datei aus MCP-Response ableiten: current_step++, Event in events_log pushen (synced=true)
  3. state_deltas++
  4. **MCP-Fehler→** State-Datei direkt schreiben + `unsynced=true` auf WF setzen + Event (synced=false)
  5. ⚡ **NIEMALS** State-Datei als done markieren ohne MCP-Update oder unsynced-Flag

## Workflow-Abschluss
Alle Schritte done/skipped:
1. Content aktualisieren: `**Status:** completed` + `**Abgeschlossen:** YYYY-MM-DD HH:MM`
2. ⚡ `mx_update_doc(doc_id, content, status='archived', change_reason='Workflow completed')` — Content UND status synchron in EINEM Call
3. WF vom Stack entfernen + Event loggen (synced=true)
4. **Ad-hoc Rueckbindung:** Alle adhoc_tasks mit origin_workflow==WF-ID anzeigen:
   `N Ad-hoc Tasks entstanden waehrend <WF-ID>: [Liste]. Neuen Workflow starten?`
5. Event loggen (type='completed')
6. Naechsten Stack-WF aktivieren falls vorhanden
7. Output: Artefakte-Liste + Ad-hoc-Rueckbindung + Empfehlung `/mxSave`

## Auto-Tracking (Spec#1615)
Hook injiziert Signal bei jedem Prompt. Claude reagiert basierend auf Kontext.

**Regel 1 — NO_WORKFLOW + substantielle Arbeit:**
Hook meldet `NO_WORKFLOW` + User-Prompt beschreibt Implementierung/Fix/Feature/Refactoring
→ Auto-erstellen: Ad-hoc WF (Template `ad-hoc`, Titel `Ad-hoc: <50Z Zusammenfassung>`)
→ Keine Rueckfrage. Bei Fragen/Smalltalk/Auskuenften/mxSave/mxOrchestrate: ignorieren

**Regel 2 — WF aktiv + Thema-Abweichung:**
Hook zeigt aktiven WF-Namen + User-Prompt betrifft anderes Thema (semantischer Vergleich)
→ Kleiner Seitensprung (1 Antwort): automatisch `track` als Ad-hoc-Task
→ Grosser Seitensprung (>1 Schritt): `park` vorschlagen

**Regel 3 — JUST_COMPLETED + Weiterarbeit:**
Hook meldet `JUST_COMPLETED` (WF <5min abgeschlossen) + substantieller Prompt
→ Neuen Ad-hoc WF erstellen (wie Regel 1)

## Regeln
- Skills auto-aufrufen per Skill/Agent-Tool. !manuell durch User
- Optional→?user. Nicht-optional→ohne Rueckfrage
- ⚡ Max 5 Stack-Eintraege. State-Deltas>=8→Save empfehlen
- ⚡ Team Agents: nur MCP-Zugriff, nie lokale State-Datei
- UTF-8 ohne BOM. MCP bevorzugen, lokal=Fallback
- Workflow-Templates: `docs/workflows.md`(projekt, Vorrang) dann `~/.claude/skills/mxOrchestrate/workflows.md`(global)
