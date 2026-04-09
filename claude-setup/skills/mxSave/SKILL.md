---
name: mxSave
description: Use when the user says "Zustand speichern", "/mxSave", or wants to persist the current project state for seamless continuation in a new session. Cleans settings, updates CLAUDE.md, docs/status.md (local), and creates session notes in DB. Loop-tauglich.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
argument-hint: "[optionale-notizen] [--loop]"
---

# /mxSave — Projektzustand sichern (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** Hybrid-Modus. MCP-Arbeit→Subagent(Background). `.claude/`-Dateien→Hauptkontext (Subagents haben keine Write-Permission fuer `.claude/`). Ergebnis: max 20 Zeilen.

Save-Agent. Sichert Projektzustand fuer nahtlose Session-Fortsetzung.
**Hybrid:** CLAUDE.md+status.md=lokal. Session-Notes=MCP-DB.

## Ausfuehrungsmodus ⚡
**Parallel starten:**
- **Agent(Background):** Steps 3, 5, 6 (reine MCP-Calls)
- **Hauptkontext:** Steps 1, 2, 4 (lokale Dateien lesen+schreiben, `.claude/`-Dateien syncen. Step 2 Zombie-Check nutzt MCP→bei MCP-Fehler skip)
Grund: Subagents bekommen keine Write-Permission fuer `.claude/`-Dateien.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→MCP-Verfuegbarkeit pruefen

## 6 Schritte (sequentiell)

### 1) settings.local.json bereinigen (LOKAL)
`.claude/settings.local.json` lesen+bereinigen:
- Duplikate entfernen (z.B. `python:*`+`python3:*`→einen behalten)
- Veraltete/einmalige Bash-Permissions entfernen
- Bash(grep/find/ls/dir:*)→entfernen (Glob/Grep/Read existieren)
- Sinnvolles behalten (WebSearch, WebFetch-Domains, python)
- Logisch sortieren: WebSearch→WebFetch→Bash

### 2) CLAUDE.md + status.md aktualisieren (HYBRID — lokal + MCP fuer Zombie-Check)
**CLAUDE.md:**
- **Gewicht:** `wc -l` pruefen. Ziel: max 200 Zeilen.
- Ueberschritten→Domain-Details nach `docs/reference/` auslagern, nur Verweis in CLAUDE.md.
- AI-Start-Here-Links aktuell. Arch-Aenderungen high-level (1-3Z/Feature). !lange Backlogs→DB(/mxPlan). Kompakt: Links+Regeln+Architektur.

**status.md:**
- Neue Features(+Datum) ergaenzen. Offene Punkte aktualisieren.
- Aktive Workflows: aus mx_session_start(include_briefing=true) active_workflows nutzen, ∅separater mx_search noetig
- Verweise auf Docs statt Inhalte kopieren
- ⚡ **Zombie-Referenz-Check:** Alle `#NNNN` Doc-IDs in "Naechste Schritte" extrahieren→`mx_batch_detail(doc_ids=[...])` (max 10 pro Call, bei >10 IDs chunken)→status pruefen. Archived/superseded→aus "Naechste Schritte" entfernen. MCP-Fehler→Zombie-Check skip+Warnung. Output: `Zombie-Refs entfernt: #X, #Y (archived)`

### 3) MCP-Docs aktualisieren (nur MCP)
**Verwaiste Workflows bereinigen (ADR-0006):**
`mx_search(project, doc_type='workflow_log', query='active')`→IDs sammeln→`mx_batch_detail(doc_ids=[...])`→pro WF pruefen:
- WF-Titel referenziert Feature das in CLAUDE.md/status.md als fertig gilt→archivieren
- Alle zu archivierenden WFs sammeln→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup by mxSave"}, ...]')` — ein Call statt N
- ⚡ Nur eindeutig erledigte WFs schliessen. Zweifel→offen lassen.

**Ad-hoc WF Auto-Cleanup (Spec#1615):**
Pruefe WFs deren Titel mit "Ad-hoc:" beginnt:
- WF hat nur Schritt 1 UND Titel beginnt mit "Ad-hoc:" UND WF-Content zeigt keine done-Schritte ausser Step 1
  → Still archivieren: `mx_update_doc(doc_id, status='archived', change_reason='auto-cleanup: empty ad-hoc WF')`
  → Kein Output (kein Rauschen)
- WF hat echte Arbeit→normal archivieren wie andere WFs

**Erledigte Plans/Specs/Decisions archivieren:**
`mx_search(project, doc_type='plan,spec,decision', status='active', limit=20)`→IDs sammeln→`mx_batch_detail(doc_ids=[...])`→pro Doc pruefen:
- **Plan:** Alle Tasks `- [x]` (keine `- [ ]`)→archivieren
- **Spec:** Alle AC `- [x]` UND keine offenen Open Questions→archivieren
- **Decision:** Status `proposed` seit >30 Tagen ohne Aenderung→Warnung (nicht auto-archivieren)
- Sammeln→`mx_batch_update(items='[{"doc_id":X,"status":"archived","change_reason":"auto-cleanup: alle Tasks/AC erledigt"}, ...]')`
- ⚡ Nur bei eindeutig erledigten Docs. Gemischte Checkboxen→offen lassen.
- Output: `Archiviert: <N> Plans, <M> Specs. <K> stale Decisions (Warnung).`

**Lesson-Candidates extrahieren (Spec#1198, Auto-Learn, AnsatzC-konform):**
Aus Chat-Verlauf Lesson-Candidates ableiten:
- Typen: pitfall, decision_note, integration_fact, rule, solution
- Dedupe: `mx_search(project, doc_type='lesson', query='<title>', limit=3)`→Treffer→merge, sonst neu
- Gate: confidence >= 0.6→`mx_create_doc(project, doc_type='lesson', ...)`, <0.6→tag `lesson-candidate`
- ∅Lessons→skip. Output: `Lessons: N erstellt, M gemerged, K candidates`

**Lesson-Template (lesson_data JSON, AnsatzC-Pflichtfelder):**
```json
{
  "type": "<rule|pitfall|solution|decision_note|integration_fact>",
  "scope": "<project|shared-domain|global>",
  "severity": "<low|medium|high|critical>",
  "what_happened": "<Was ist passiert? 1-2 Saetze>",
  "what_was_learned": "<Was wurde gelernt? 1-2 Saetze>",
  "recommended_action": "<Empfohlene Aktion>",
  "avoid_action": "<Was vermeiden>",
  "applies_to": "<Komma-getrennte Patterns>",
  "applies_to_files": ["<betroffene Dateipfade>"],
  "applies_to_functions": ["<betroffene Funktionen/Methoden>"],
  "applies_to_patterns": ["<betroffene Code-Patterns>"],
  "source_session": "<aktuelle session_id aus orchestrate-state>",
  "source_docs": [<doc_ids von referenzierten Specs/Plans/ADRs>],
  "last_confirmed_at": "<ISO-Datum der Erstellung>"
}
```
⚡ **Pflicht:** what_happened+what_was_learned aus Chat-Kontext ableiten. applies_to_files aus geaenderten Dateien. source_session aus State.
⚡ **∅info→weglassen** statt erfinden. Leere Arrays erlaubt, leere Strings nicht.

∅MCP→skip

**Pending Findings auto-dismissen:**
Batch-Dismiss aller pending Findings (nicht im Session-Kontext reviewed):
`mx_skill_feedback(project=<slug>, reaction='dismissed')` — ein Call dismissed alle pending Findings des Projekts.
- Output: `Findings: batch-dismissed`
- MCP-Fehler→skip

### 4) Orchestrate-State Sync (HYBRID, Spec#1161)
`.claude/orchestrate-state.json` lesen. Falls vorhanden+nicht leer:

- **Unsynced pushen:** WFs mit `unsynced=true`→`mx_update_doc`→`unsynced=false`. Events mit `synced=false`→Session-Note→`synced=true`
- **Finalisieren:** `state_deltas`→0, `last_save`→now, `last_reconciliation`→now
- ⚡ Workflows NICHT archivieren. Nur sync+reset.
- State-Datei zurueckschreiben
- ∅Datei oder leerer Stack→skip
- Output: `Orchestrate: <N> unsynced pushed, deltas reset`

### 5) Session-Zusammenfassung als MCP-Note (MCP)
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content)
```
**Template:** Was gemacht? | Geaenderte Dateien | Naechster Schritt | Offene Bugs | User-Notizen
**Nummerierung:** mx_search(project=<slug>, doc_type='session_note', query='YYYY-MM-DD')→existiert→Nummer anhaengen
**MCP-Fehler→** Fallback lokal `docs/plans/session-notes-YYYY-MM-DD.md`+Warnung

### 6) Peer-Notify (MCP, nur bei delta > 0)
`mx_session_delta(project)`→delta==0→skip.
`mx_agent_peers(project)`→∅peers→skip.
1 Call: `mx_agent_send(project, target_project=<peer_slug>, message_type='status', ttl_days=7, payload=<summary>)`
- Payload: `{"type":"session_summary","summary":"<1-2 Saetze>","changed_files":<anzahl>,"project":"<slug>"}`
- Fehler→loggen, nicht abbrechen

## Loop-Modus (--loop oder /loop Kontext)
- **Idempotenz:** mx_session_delta(project) pruefen→∅Aenderungen seit letztem Save→einzeilig `mxSave: Keine Aenderungen` + skip
- Aenderungen vorhanden→normaler Save, aber kompakt-output (1 Zeile pro Schritt)
- !settings.local.json bereinigen in Loop (nur bei manuellem Aufruf)
- !Rueckfragen, !interaktive Schritte
- Session Note kuerzer: nur Aenderungen seit letztem Save

## Regeln
- ⚡ Nur bestaetigt-implementiertes als "fertig" eintragen !Annahmen
- ⚡ Session Notes aus Chat ableiten, nur Fakten !Vermutungen. ∅info→"Open question"
- !ADRs auto-erzeugen→Hinweis /mxDecision. !bestehende Inhalte loeschen→ergaenzen/kompaktieren
- Encoding: UTF-8 ohne BOM. MCP bevorzugen, lokal=Fallback
- ⚡ **!Bash fuer MCP-Calls.** NIEMALS `claude --print` oder `claude -p` in Bash ausfuehren. IMMER die MCP-Tools direkt aufrufen (mx_search, mx_detail, mx_update_doc etc.). Bash nur fuer Dateisystem-Operationen (cp, mkdir).

## Abschluss
Output: (1) Tabelle: Datei/DB-Eintrag+Aktion (erstellt/geaendert/unveraendert) (2) Aktive Workflows+aktueller Schritt (3) Naechster Schritt (4) ADR-Hinweis falls Entscheidungen im Chat
