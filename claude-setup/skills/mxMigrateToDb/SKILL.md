---
name: mxMigrateToDb
description: "Migriert lokale docs/*.md Fallback-Dateien in die MCP Knowledge-DB. Ausfuehren nach MCP-Ausfall wenn lokale Dateien durch Offline-Fallback entstanden sind, oder einmalig nach MCP-Setup. Mit --extract-backlog: Extrahiert Legacy-Backlogs aus status.md direkt in MCP-Docs (ersetzt mxMigratelegacy)."
user-invocable: true
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
argument-hint: "[--dry-run | --cleanup | --sync | --scan | --extract-backlog]"
---

# /mxMigrateToDb — Lokale Dokumente in Knowledge-DB importieren

> **Context-Regel:** Diesen Skill IMMER als Subagent (Agent-Tool) ausfuehren, nie im Hauptkontext. MCP-Responses und Edit-Diffs fuellen sonst den Context unnoetig. Ergebnis: kompakter Report, max 20 Zeilen.

Du bist ein Migrations-Agent. Importiere lokale `docs/*.md`-Dateien eines Projekts in die zentrale Knowledge-DB via MCP-Tool `mx_migrate_project`.

## Projekt-Kontext ermitteln (WICHTIG: Duplikate vermeiden!)

1. Lies CLAUDE.md und finde die `**Slug:**`-Zeile → das ist der `project_slug`
2. Falls kein Slug in CLAUDE.md:
   a. **Zuerst in DB pruefen:** Rufe `mx_search(query='<verzeichnisname>')` auf um zu schauen ob das Projekt bereits existiert (unter anderem Slug-Namen). Pruefe auch den Pfad in den Suchergebnissen.
   b. Falls Treffer mit passendem Projekt: Diesen Slug verwenden und Benutzer informieren ("Projekt existiert bereits als `<slug>` in der DB")
   c. Falls kein Treffer: Leite einen Vorschlag aus dem Verzeichnisnamen ab und frage den Benutzer zur Bestaetigung (z.B. "Slug-Vorschlag: `mein-projekt` — passt das, oder ein anderer?")
   d. **NIEMALS einen Slug automatisch uebernehmen ohne Bestaetigung!**
3. Sobald der Slug feststeht: Schreibe ihn in CLAUDE.md als `**Slug:** <slug>` (damit er beim naechsten Mal gefunden wird)

## Voraussetzungen pruefen

1. **MCP-Server erreichbar?** — Rufe `mx_ping()` auf. Falls Fehler: Bis zu 3 Versuche mit kurzer Pause (5s). Erst nach 3 Fehlschlaegen: Abbruch.
2. **Projekt registriert?** — Rufe `mx_briefing(project='<slug>')` auf.
   - Falls "Project not found": Frage den Benutzer nach dem **Projektnamen** (z.B. "Projektname fuer `<slug>`? (z.B. 'Mein Projekt — Kurzbeschreibung')"). Dann `mx_init_project(project_name='<antwort>')` aufrufen.
   - **NIEMALS** den Slug als Projektnamen verwenden ohne Rueckfrage!
   - Falls vorhanden: Notiere project_id und bestehende Dokument-Anzahl.
3. **Lokale Dokumente vorhanden?** — Pruefe ob `docs/` irgendwelche .md-Dateien enthaelt (rekursiv alle Unterverzeichnisse).
   - Der Server importiert ALLE *.md-Dateien aus docs/ und allen Unterverzeichnissen
   - Nur `index.md` und `status.md` werden uebersprungen
   - doc_type wird automatisch anhand des Dateinamens bestimmt (PLAN-→plan, SPEC-→spec, ADR-→decision, session-notes→session_note, workflow-log→workflow_log, alles andere→reference)
   - Falls keine .md-Dateien gefunden: "Keine migrierbaren Dokumente gefunden."
   - **WICHTIG:** Auch Legacy-Dateien ohne Standard-Prefix (Design-Docs, Findings, nummerierte Notes etc.) werden als `reference` importiert — alles in docs/ ist Projektwissen!

## Modi

| Argument | Modus |
|----------|-------|
| (kein Argument) | Import: Lokale Dateien in DB importieren |
| `--dry-run` | Nur anzeigen was importiert wuerde, nichts aendern |
| `--cleanup` | Nur Cleanup: Bereits in DB vorhandene lokale Dateien loeschen |
| `--sync` | Import + Cleanup in einem Schritt (empfohlen nach MCP-Ausfall) |
| `--scan` | Auto-Scan: Lokale Docs gegen DB abgleichen + Stub-Erkennung |
| `--extract-backlog` | Legacy-Backlog aus status.md extrahieren und direkt als MCP-Docs anlegen |

### Extract-Backlog Modus (--extract-backlog)

Extrahiert Backlog/ToDo-Listen aus `docs/status.md` und erstellt sie direkt als MCP-Dokumente (Plans/Todos). Ersetzt den frueheren mxMigratelegacy-Skill.

1. **status.md analysieren:**
   - Lies `docs/status.md` und identifiziere Backlog-Abschnitte:
     - Lange Bullet-Listen mit offenen Punkten (>3 zusammenhaengende Bullets)
     - Sektionen: "Backlog", "ToDo", "Open Tasks", "Next Steps", "Naechste Aufgaben", "Spaetere Features", "Offene Punkte"
   - **Nicht extrahieren** (in status.md belassen):
     - "Implementierte Features"-Listen (Historie)
     - "Migrationen"-Listen (Referenz)
     - "Bekannte Probleme" (kurze Listen, max 5 Eintraege)
     - Einzelne Verweise oder 1-Zeiler

2. **MCP-Docs erstellen (direkt in DB, keine lokalen Dateien):**
   - Pro identifizierter Backlog-Gruppe: `mx_create_doc(project, doc_type='plan', title='PLAN: Legacy Backlog — <Gruppenname>', content, status='draft')`
   - Content-Template:
     ```markdown
     # PLAN: Legacy Backlog — <Gruppenname>
     **Erstellt:** YYYY-MM-DD | **Status:** draft | **Quelle:** docs/status.md

     ## Tasks
     - [ ] Task 1
     - [ ] Task 2
     - [x] Erledigter Task
     ```
   - Punkte die als erledigt markiert sind → `[x]`
   - Unklarer Status → `[ ]` mit Vermerk "(Status unklar)"

3. **status.md kuerzen:**
   - Extrahierte Tasklisten durch Verweis ersetzen:
     `> Backlog migriert in Knowledge-DB (doc_id=X, YYYY-MM-DD)`
   - Nicht-Backlog-Inhalte belassen

4. **Report:**
   ```
   Backlog-Extraktion abgeschlossen:
   - Erstellt: X MCP-Docs (Plans)
   - Extrahierte Tasks: Y (davon Z erledigt)
   - status.md gekuerzt: N Zeilen entfernt
   ```

### Scan-Modus (--scan)

Prueft lokale docs/ gegen DB und erkennt Stubs. Kein Import, nur Report.

1. **Nicht-migrierte Dateien finden:**
   - `mx_search(project, limit=50)` → alle DB-Docs laden → `existing_slugs` Set bilden (⚡ 1 Call statt N)
   - Alle *.md in docs/ (rekursiv, ausser index.md, status.md, CLAUDE.md) auflisten
   - Pro Datei: Datei-Slug gegen `existing_slugs` pruefen. !mx_search pro Datei
   - Kein Treffer = nicht migriert → in Report aufnehmen
2. **Stub-Erkennung in DB:**
   - `mx_search(project, limit=50)` → alle Docs laden
   - Fuer jedes Doc: Token-Estimate aus mx_search Response pruefen
   - Docs mit token_estimate < 50 = Stub → in Report aufnehmen
3. **Report ausgeben:**
   ```
   ## Auto-Scan Report

   ### Nicht-migrierte lokale Dateien
   | Datei | doc_type (geschaetzt) |
   |-------|-----------------------|
   | docs/plans/PLAN-foo.md | plan |

   ### Stub-Dokumente in DB (<50 Tokens)
   | doc_id | Titel | doc_type | Tokens |
   |--------|-------|----------|--------|
   | 360 | PLAN: Stub | plan | 12 |

   ### Empfehlung
   - X Dateien nicht migriert → `/mxMigrateToDb` ausfuehren
   - Y Stubs in DB → Auffuellen oder loeschen
   ```
4. **Keine Aenderungen durchfuehren** — nur Report

### Dry-Run Modus

- Zeige nur welche Dateien migriert wuerden (Tabelle mit Datei → doc_type Mapping)
- Fuehre KEINE Migration durch
- Gib Zusammenfassung aus und frage ob Migration starten soll

## Migration ausfuehren

### Strategie: Client-seitige Batch-Migration (funktioniert immer — auch remote)

Der Skill liest die Dateien LOKAL (Claude Code hat Dateizugriff) und sendet sie gesammelt an die DB via `mx_batch_create`. Kein Dateisystem-Zugriff vom Server noetig.

**Ablauf (Batch-Strategie — alle Dateien sammeln, dann ein Call):**

0. **DB-Inventar vorab laden (⚡ PFLICHT — vermeidet N+1 Searches):**
   `mx_search(project='<slug>', limit=50)` → alle existierenden Docs laden. Falls >50: zweiten Call mit offset. Daraus Set bilden: `existing_slugs: set of string` (aus slug-Feld). Dieses Set fuer ALLE Duplikat-Checks verwenden. !einzelne mx_search pro Datei.
1. **Sammel-Phase:** Fuer jede Datei in docs/:
   a. Datei lokal lesen (Read-Tool)
   b. doc_type anhand Dateiname bestimmen (siehe Mapping)
   c. Status parsen: Suche im Content nach `**Status:** <value>` (Regex: `\*\*Status:\*\*\s*(\w+)`). Falls gefunden: Mappe auf DB-Status (siehe Status-Mapping). Falls nicht: kein status-Parameter (Default 'draft').
   d. Duplikat-Check: Datei-Slug gegen `existing_slugs` Set pruefen — falls Treffer mit gleichem doc_type: ueberspringen. ⚡ !mx_search pro Datei
   e. Nicht-Duplikate in Items-Array sammeln: `{project, doc_type, title, content, status}`
2. **Batch-Import:** `mx_batch_create(items='[{...}, {...}, ...]')` — alle Dokumente in einer Transaktion. Rueckgabe: Array mit doc_ids. Import-Map fuehren: Dateiname → doc_id (fuer Relations-Phase).
3. Ergebnis protokollieren (importiert / uebersprungen / fehler)

**Batch-Limit:** Falls >20 Dateien: in Gruppen à 20 aufteilen (mehrere mx_batch_create Calls).
**Bei Verbindungsfehler:** Bis zu 3 Retry-Versuche mit 5s Pause pro Batch. Nach 3 Fehlschlaegen: Batch als fehlgeschlagen markieren, weiter zum naechsten.

### doc_type Mapping (client-seitig)

| Dateiname-Muster | doc_type |
|---|---|
| `PLAN-*` | plan |
| `SPEC-*` | spec |
| `ADR-*` | decision |
| `*session-notes*` | session_note |
| `workflow-log*` | workflow_log |
| Alles andere | reference |

### Status-Mapping (Content → DB)

| Content `**Status:**` | DB status |
|---|---|
| accepted | active |
| proposed | draft |
| active | active |
| completed | archived |
| superseded | superseded |
| deprecated | archived |
| paused | draft |
| cancelled | archived |
| (nicht gefunden) | draft (Default) |

### Relations-Phase (nach dem Import-Loop)

Nachdem ALLE Dateien importiert sind, Markdown-Links zwischen Dokumenten analysieren:

1. Fuer jedes importierte Dokument: Content nach Links auf andere docs/-Dateien scannen
   - Regex: `\[.*?\]\((.*?\.md)\)` oder Textmuster `Siehe (PLAN|ADR|SPEC)-...`
2. Ziel-Slug aus Link-Pfad extrahieren
3. In der Import-Map (Dateiname → doc_id) nachschlagen
4. Falls Treffer: `mx_add_relation()` aufrufen:
   - ADR → PLAN: `leads_to`
   - PLAN → PLAN: `leads_to`
   - SPEC → PLAN: `implements`
   - Sonstige: `references`
5. Ergebnis: `N Relations erstellt`

### Ausgeschlossene Dateien (NICHT importieren)

- `index.md` (Index-Dateien)
- `status.md` (bleibt lokal)
- `CLAUDE.md` (bleibt lokal)

### Alle anderen Dateien

Alle *.md-Dateien die keinem bekannten Prefix entsprechen werden als `reference` importiert. Das schliesst ein: Design-Docs, Findings, nummerierte Session-Notes, Brainstormings, Meeting-Notes etc. **Nichts geht verloren — alles in docs/ ist Projektwissen!**

## Nach der Migration

1. **Ergebnis anzeigen:**

```
Migration abgeschlossen:
- Importiert: X Dokumente
- Uebersprungen (Duplikate): Y
- Fehler: Z

| doc_type | Anzahl |
|----------|--------|
| plan | ... |
| spec | ... |
| decision | ... |
| session_note | ... |
| workflow_log | ... |
| reference | ... |
```

2. **Summaries:** Entfernt (B6.5) — server-autonomer Batch-Job, kein manueller Aufruf noetig.

3. **Verifizierung:** Rufe `mx_briefing(project='<slug>')` auf und zeige die aktuelle Dokumenten-Uebersicht.

4. **Health-Check:** `/mxHealth` als Subagent ausfuehren — prueft Import-Qualitaet (fehlende Relations, schlechte Summaries, falsche Status).

5. **Hinweise ausgeben:**
   - "Lokale Index-Dateien (index.md) werden nicht mehr benoetigt — die DB ist die Wahrheitsquelle."
   - "docs/status.md und CLAUDE.md bleiben lokal (werden von /mxSave gepflegt)."
   - Falls `docs/reference/` existiert: "Reference-Dateien bleiben zusaetzlich lokal erhalten."

## Cleanup-Phase (bei --cleanup oder --sync)

Nach erfolgreichem Import (oder separat mit `--cleanup`): Lokale Fallback-Dateien entfernen die jetzt in der DB sind.

### Cleanup-Ablauf

1. **DB-Inventar vorab laden (⚡ 1 Call statt N):** `mx_search(project, limit=50)` → `existing_slugs` Set bilden (wie in Import-Phase).
   **Fuer jede lokale Datei** in `docs/plans/`, `docs/specs/`, `docs/decisions/`:
   - Datei-Slug gegen `existing_slugs` pruefen. !mx_search pro Datei
   - Falls JA und Inhalt uebereinstimmt → Datei loeschen
   - Falls NEIN → Datei behalten (wurde noch nicht importiert)

2. **Geschuetzte Dateien (NIEMALS loeschen):**
   - `CLAUDE.md` — bleibt immer lokal
   - `docs/status.md` — bleibt immer lokal
   - `docs/ops/workflow-log.md` — bleibt als lokaler Fallback
   - `docs/reference/*.md` — bleiben als lokale Referenz
   - `*/index.md` — Index-Dateien bleiben

3. **Loeschbare Dateien (nur nach DB-Verifizierung):**
   - `docs/plans/PLAN-*.md` — wenn in DB vorhanden
   - `docs/specs/SPEC-*.md` — wenn in DB vorhanden
   - `docs/decisions/ADR-*.md` — wenn in DB vorhanden
   - `docs/plans/session-notes-*.md` — wenn in DB vorhanden

4. **Index-Dateien bereinigen:**
   - Entferne Zeilen aus `docs/plans/index.md`, `docs/specs/index.md`, `docs/decisions/index.md` die auf geloeschte Dateien verweisen
   - Falls Index danach leer: Platzhalter-Zeile einfuegen (`_Keine lokalen Eintraege — Dokumente in Knowledge-DB_`)

5. **Referenz-Update (PFLICHT nach jeder Datei-Loeschung):**
   Fuer jede geloeschte Datei den Dateinamen (ohne Pfad) in lokalen Dateien suchen und Links aktualisieren:
   - Grep nach Dateiname in: `CLAUDE.md`, `docs/status.md`, `docs/*/index.md`
   - Jeden Markdown-Link `[text](pfad/datei.md)` ersetzen durch: `text (Knowledge-DB, doc_id=X)`
   - `docs/status.md` wird NICHT geloescht aber MUSS nach toten Links durchsucht werden

6. **Ergebnis ausgeben:**

```
Cleanup abgeschlossen:
- Geloescht: X Dateien (in DB verifiziert)
- Behalten: Y Dateien (geschuetzt oder nicht in DB)

| Datei | Aktion | Grund |
|-------|--------|-------|
| docs/plans/PLAN-foo.md | geloescht | in DB (doc_id=42) |
| docs/status.md | behalten | geschuetzt |
```

## Regeln

- **Idempotent:** Duplikate werden vom Server erkannt und uebersprungen.
- **Cleanup nur nach Verifizierung:** Lokale Datei wird NUR geloescht wenn das Dokument nachweislich in der DB existiert (mx_search Treffer).
- **Geschuetzte Dateien:** CLAUDE.md, status.md, workflow-log.md, reference/, index.md werden NIEMALS geloescht.
- **Forward-Slashes:** Pfad-Parameter immer mit `/` statt `\` (ADR-0001 TMS-Bug).
- **Encoding:** Server erkennt ANSI vs. UTF-8 automatisch.
- **MCP-Fehler:** Bei Fehler → Fehlermeldung anzeigen, Benutzer informieren. KEIN Cleanup wenn Import fehlgeschlagen.
- **Verbindungsabbruch waehrend Migration:** Falls ein MCP-Aufruf fehlschlaegt (Timeout, Connection Reset), bis zu 3 Retry-Versuche mit 5s Pause. Erst nach 3 Fehlschlaegen den Schritt als fehlgeschlagen markieren und mit dem naechsten weitermachen. Am Ende Zusammenfassung: X erfolgreich, Y fehlgeschlagen (mit Dateinamen).
