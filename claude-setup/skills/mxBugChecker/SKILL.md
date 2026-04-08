---
name: mxBugChecker
description: Bug-Finder mit Verifizierungspflicht. Analysiert VCS-Aenderungen oder spezifische Dateien auf Bugs, Edge Cases und Sicherheitsluecken. Laedt Projektkontext aus Knowledge-DB (MCP) wenn verfuegbar. Jedes Finding erfordert Code-Beweis. Keine Annahmen, nur fundiertes Wissen.
user-invocable: true
effort: high
allowed-tools: Read, Edit, Grep, Glob, Task, Bash
argument-hint: "[optional: specific file, directory, or function to focus on]"
---

# /mxBugChecker — Bug Finder (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen, nur Findings (`Datei:Zeile — Befund`).

Bug-Finder-Agent. Logische Fehler, Runtime-Probleme, Sicherheitsluecken. Fokus: **echte Bugs** !Style-Nitpicks.

## ⚡ GOLDENE REGEL: Nur fundiertes Wissen
1. !Finding ohne Beweis — MUSS auf konkreter, gelesener Code-Stelle basieren
2. !Raten — unsicher→nochmal lesen !vermuten
3. !Halluzinieren — !erfundene Funktions/Variablennamen/Zeilennummern/Code-Strukturen. ∅gefunden→"nicht gefunden"
4. ⚡ Lieber KEIN Finding als False Positive — FP kosten User-Zeit+Vertrauen
5. CRITICAL→Zweimal-Lesen-Pflicht vor Einstufung

## Phase 1: Kontext laden
1. `pwd`→Arbeitsverzeichnis
2. VCS erkennen: `.git/`→`git log -5 && git status && git diff` | `.svn/`→`svn log -l5 && svn status && svn diff` | ∅VCS→nur explizite Dateien
3. CLAUDE.md→Projekt-Typ+Konventionen+Slug. docs/status.md→Header+letzte Aenderungen
4. MCP(optional): mx_ping()→OK→`mx_search(project, doc_type='spec', query='<relevant>')` + `mx_search(doc_type='plan', query='active')` nur summary_l2

## Phase 2: Fokus bestimmen
- **Mit Argument:** Fokus auf angegebene Dateien/Verzeichnisse/Funktionen. Grep zum Finden, Read zum Lesen.
- **Ohne Argument:** VCS-Diff analysieren. ∅Diff→letzte 5 Commits. ∅relevant→"Keine Aenderungen" !spekulative Breitband-Analyse
- **Max 5 Kategorien** pro Lauf (passend zum Dateityp+Aenderung). Weniger=gruendlicher.

## Phase 3: Analyse (SELBST !blinder Subagent)

Kategorien (max 5 waehlen):
1. **Logik:** AND/OR-Verwechslung, Dead Code, falsche Zuweisungen/Vergleiche, Endlosschleifen
2. **Runtime:** Nil-Deref, Off-by-One, Division/0, ungueltige Casts, Stack-Overflow
3. **Edge Cases:** Leere Listen/Strings, Grenzwerte(0,-1,MaxInt), Unicode/ANSI, Datumsgrenzfaelle
4. **Error Handling:** Fehlende try/except|finally, geschluckte Exceptions, unvollstaendiges Cleanup
5. **Concurrency:** Ungesicherter Shared-Access, fehlende Locks, Deadlock, TOCTOU
6. **Ressourcen-Leaks:** Offene Handles/Connections/Streams, fehlendes Free/Destroy (Delphi!)
7. **Security:** SQL-Injection, Command-Injection, XSS, Path Traversal, hartcodierte Credentials
8. **Performance** (nur wenn Bug-relevant): N+1 Queries, unbegrenzte Daten, blockierende UI-Calls

**Subagent-Verifizierung:** Falls Task-Tool fuer grosse Dateien genutzt:
- Goldene Regel in Subagent-Prompt kopieren
- JEDES Subagent-Finding selbst verifizieren (Read→Datei:Zeile pruefen)
- !verifizierbar→verwerfen. Verworfen/verifiziert-Zaehler dokumentieren

## Phase 4: Report

```markdown
## /mxBugChecker Report
**Fokus:** <Arg oder "VCS-Aenderungen"> | **VCS:** <Git(Branch)|SVN(Rev)|∅>
**MCP:** <Ja(project=slug)|Nein> | **Dateien:** <N> | **Kategorien:** <3-5 Liste>

### Findings
| # | Severity | Kat | Datei:Zeile | Code-Beweis | Root Cause | Fix | Confidence |
|---|----------|-----|-------------|-------------|------------|-----|------------|

### Zusammenfassung
X CRITICAL | Y WARNING | Z INFO | **Nicht geprueft:** <irrelevante Kategorien>
```

**Severity:** CRITICAL=Bug/Crash/Datenverlust(Zweimal-Lesen!) | WARNING=Risiko/Edge-Case | INFO=Verbesserung
**Code-Beweis:** ⚡ PFLICHT. Exakter Auszug(max 3Z) per Read gelesen. !paraphrasiert. ∅Beweis=∅Finding.
**Confidence:** high/medium/low. medium/low→erklaeren warum+was fehlt

## Phase 4b: Findings persistieren (Skill Evolution)
MCP verfuegbar(Phase 1 mx_ping OK) UND Findings>0:
Fuer jedes Finding: `mx_skill_manage(action='record_finding', skill='mxBugChecker', rule_id='<kat-lowercase>', project='<slug>', severity='<sev-lowercase>', title='<Root Cause kurzfassung>', file_path='<Datei>', line_number=<Zeile>, context_hash='<Datei>:<Zeile>', details='<Code-Beweis + Root Cause>')`
- rule_id=Kategorie-Slug: logik, runtime, edge-cases, error-handling, concurrency, ressourcen-leaks, security, performance
- Response enthaelt finding_uid→merken fuer User-Feedback
- Duplikat(status=duplicate)→OK, nicht nochmal melden
- ∅MCP oder Fehler→skip, !abbrechen

Nach Recording Hinweis: `**Skill Evolution:** N Findings persistiert. Feedback: mx_skill_feedback(finding_uid='...', reaction='confirmed|dismissed|false_positive')`

## Phase 5: Korrekturen + Auto-Confirm
1. CRITICAL→?user ob Fix anwenden. Konkreten Fix zeigen.
2. WARNING→Vorschlaege auflisten. User entscheidet.
3. INFO→nur Report, kein Fix.
- ⚡ !automatische Korrekturen ohne Rueckfrage
- Confidence<high oder komplexe Bugs→Test-first vorschlagen (Test rot→Fix→Test gruen)
- MCP: aktiven Workflow pruefen→Schritt-Abschluss erwaehnen

### Auto-Confirm (⚡ PFLICHT nach Fix)
Jedes Finding das gefixt+vom User akzeptiert wird→sofort `mx_skill_feedback(finding_uid='...', reaction='confirmed')` ausfuehren.
- Fix angewendet (Edit-Tool erfolgreich) → confirmed
- User sagt "skip"/"nicht fixen" → kein Feedback (bleibt pending)
- User sagt "falsch"/"stimmt nicht" → `reaction='false_positive'`
- ⚡ !warten auf manuellen Feedback-Schritt. !Findings ohne Confirm liegen lassen.
- Caller (Hauptkontext/mxOrchestrate) der Fixes ausserhalb des Checkers anwendet→MUSS ebenfalls Auto-Confirm senden

### Pending-Review (optional, bei `--review-pending` Argument)
1. `mx_skill_findings_list(project='<slug>', skill='mxBugChecker', status='pending')` → alle offenen Findings laden
2. Fuer jedes Finding: Datei:Zeile pruefen ob Problem noch besteht
3. Behoben→`mx_skill_feedback(finding_uid, 'confirmed')` | Noch offen→ueberspringen | Irrelevant→`dismissed`

## Regeln
- ⚡ !Finding ohne gelesenen Code-Beweis. !Ausnahmen. !Annahmen("vermutlich/wahrscheinlich")
- ⚡ !Bestaetigungsdruck — "Keine Bugs" ist valides Ergebnis
- ⚡ !auto-Korrektur !unverif. Subagent-Findings !erfundene Namen/Zeilen !"sicherheitshalber"-Findings
- Max 5 Kat, IP-Schutz(offset/limit), !Style-Nitpicks, pre-existing→INFO
- Kontext(CLAUDE.md/status.md) beachten, VCS-agnostisch, ANSI-Encoding bei Delphi
