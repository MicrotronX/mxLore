---
name: mxHealth
description: "Use to verify Knowledge-DB and docs/ consistency via MCP. Checks document metadata, cross-references, orphaned relations, status consistency, CLAUDE.md weight, and local/DB sync. Run periodically or before major releases. Loop-tauglich."
user-invocable: true
effort: medium
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[--scope decisions|plans|specs|workflows|all] [--loop]"
---

# /mxHealth — Knowledge-DB Konsistenz-Pruefer (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen, nur Probleme.

Health-Check-Agent. Konsistenz von Knowledge-DB + lokalen docs/ pruefen.

## Init
1. CLAUDE.md→`**Slug:**`=project. ∅slug→?user
2. mx_ping()→OK=weiter | Fehler→"MCP nicht erreichbar — /mxHealth erfordert MCP." ABBRUCH

## Phase 1: Inventar laden
Parallel ausfuehren:
1. `mx_briefing(project)` — Uebersicht
2. `mx_search(project, doc_type='plan')` + `spec` + `decision` + `workflow_log`
3. Glob lokal: `docs/reference/*.md`
4. CLAUDE.md + docs/status.md lesen
5. Zaehlen: DB-Docs gesamt, lokale Reference-Dateien, CLAUDE.md Zeilenanzahl

## Phase 2: 11 Pruefungen

### P1: Dokument-Metadaten (DB)
Aus mx_search Ergebnissen: title!empty, summary_l1 vorhanden, Slug eindeutig pro project+doc_type.
ERROR=leere Titel | WARNING=fehlende Summaries

### P2: Format-Konsistenz (Stichprobe max 5 Docs via mx_batch_detail(doc_ids=[...]))
- ADRs: `**Status:**` (accepted|proposed|superseded|deprecated)
- PLANs: `**Status:**` (active|completed|paused|cancelled)
- SPECs: `**Erstellt:**` oder `**Slug:**`
- Alle: H1-Ueberschrift. Severity: INFO

### P3: Cross-Reference-Konsistenz (DB)
Relations per mx_search(include_details=true): Ziel existiert(!deleted), Bidirektionalitaet(A→B dann B→A).
ERROR=Relation auf deleted | WARNING=fehlende Rueckwaerts-Relation

### P4: Status-Konsistenz (DB, Content via mx_batch_detail)
IDs aus P1 mx_search sammeln→mx_batch_detail(doc_ids=[...]) fuer alle active/completed PLANs + proposed ADRs (1 Call, max 10 IDs).
- active PLANs MUESSEN `- [ ]` enthalten | completed PLANs DUERFEN KEINE `- [ ]` haben
- proposed ADRs >30 Tage alt→WARNING

### P5: Workflow-Konsistenz (DB, Content via mx_batch_detail)
IDs aus P1 mx_search(doc_type='workflow_log') sammeln→mx_batch_detail(doc_ids=[...]) fuer alle active WFs (1 Call).
Active Workflows: MUESSEN pending-Schritte haben. >30 Tage alt→WARNING(vergessen?)

### P6: Lokal/DB-Sync
Glob `docs/plans/PLAN-*.md`, `docs/specs/SPEC-*.md`, `docs/decisions/ADR-*.md`→Slug extrahieren→mx_search.
Lokal ohne DB→WARNING("Nicht migriert→/mxMigrateToDb"). DB ohne lokal→INFO(normal).

### P7: CLAUDE.md + Reference-Konsistenz (lokal)
- CLAUDE.md >200Z→WARNING | >300Z→ERROR(dringend auslagern)
- docs/reference/ Dateien ohne Verweis in CLAUDE.md→WARNING
- Tote Markdown-Links→ERROR(lokale Dateien) | INFO(migrierte docs/)

### P8: Verwaiste lokale Dateien
Dateien in docs/plans|specs|decisions/ ohne Namensschema→INFO. index.md bei MCP→INFO("nicht mehr noetig").

### P9: Content-Tiefe (DB)
Alle nicht-archivierten/deleted Docs (OHNE session_note, workflow_log): token_estimate<50→WARNING.
Datenquelle: mx_search Ergebnisse (kein mx_detail noetig).

### P10: Auto-Relations (Cross-Reference Scan)
MCP required. Stichprobe max 20 Docs via mx_batch_detail(doc_ids=[...], level='full') (2 Calls à 10). Content scannen nach:
- `doc_id=NNN`, `#NNN`, `ADR-XXXX`, `PLAN-xxx`, `SPEC-xxx`
- Kontext-Phrasen→Relation-Type: "basiert auf"→assumes | "ersetzt"→supersedes | "fuehrt zu"→leads_to | "verursacht durch"→caused_by | "haengt ab von"→depends_on | "verworfen zugunsten"→rejected_in_favor_of | default→references
- Duplikat-Check vor mx_add_relation. Ref: doc_id=620 Konventionen.
Severity: INFO

### P11: CLAUDE.md Duplikat-Check (lokal)
Global `~/.claude/CLAUDE.md` Sektionen vs Projekt-CLAUDE.md. Typische Duplikate: Security, Encoding, Context-Management, Shell, Skill-Routing, Delphi/PHP-Mindset.
Projekt-CLAUDE.md >100Z→WARNING(Ziel: max 100Z projekt-spezifisch). !Auto-Fix→nur melden.

### P12: AI-Steno Format-Check (lokal)
Pruefe ob CLAUDE.md-Dateien AI-Steno verwenden:
1. Projekt-CLAUDE.md: Erste Zeile muss `AI-Steno:` enthalten ODER Inhalt muss Steno-Marker nutzen (`!`, `→`, `⚡`, `∅`)
2. Globale `~/.claude/CLAUDE.md`: Gleiche Pruefung
3. ∅Steno-Marker gefunden→WARNING: "CLAUDE.md nicht in AI-Steno Format. ~50% Token-Einsparung moeglich. Empfehlung: manuell konvertieren oder `/mxInitProject` neu ausfuehren."
4. Steno vorhanden aber >200Z(global) oder >100Z(projekt)→WARNING: "AI-Steno CLAUDE.md zu lang"
- Severity: WARNING
- Ref: ADR-0010 (AI-Steno Standard-Format)

### P13: Skill Evolution Metriken
MCP required. `mx_skill_metrics(skill='mxBugChecker', project=<slug>, days=90)` + gleich fuer mxDesignChecker, mxHealth.
- FP-Rate >50% fuer eine Regel→WARNING("Regel {rule_id} hat {fp_rate}% False Positives — mx_skill_manage(action='tune', ...) empfohlen")
- >20 pending Findings→INFO("N Findings warten auf Feedback")
- ∅skill_findings Tabelle oder Fehler→skip (Feature nicht aktiv)
Severity: WARNING(hohe FP-Rate) | INFO(pending)

### P14: AI-Batch Status
`mx_ai_batch_pending()`→Batch-Status auswerten.
- Errors >0 in letztem Boot→WARNING("AI-Batch {job_type}: {c} Fehler seit {last_run}")
- ∅Eintraege UND Batch-Feature aktiv→INFO("AI-Batch aktiv aber noch nie gelaufen")
- Fehler oder leere Response→skip (Feature nicht aktiv)
Severity: WARNING(Errors) | INFO(leer)

## Phase 3: Report

```markdown
## /mxHealth Report — YYYY-MM-DD HH:MM
**Projekt:** <slug> | **Scope:** <all|decisions|plans|specs|workflows>

### DB-Inventar
| doc_type | Anzahl |
|----------|--------|

### Findings
| # | Severity | Pruefung | Befund | Dokument |
|---|----------|----------|--------|----------|

### Zusammenfassung
X ERROR | Y WARNING | Z INFO | Geprueft: N DB-Docs, M lokale Dateien
```
∅Probleme→`/mxHealth: Alle Pruefungen bestanden. DB+docs/ konsistent.`

### Phase 3b: Findings→MCP-Notes persistieren (Spec#1139)
Fuer jedes Finding mit Severity ERROR oder WARNING:
1. Deduplizierung: mx_search(project, doc_type='note', query='[Health] <titel>', limit=1)
   - Treffer mit gleichem Titel→skip
2. mx_create_doc(project, doc_type='note', title='[Health] <finding-titel>', content='Severity: <sev>\n<details>\nGefunden: YYYY-MM-DD', tags='["health-finding","<severity-tag>"]')
   - ERROR→tag 'bug', WARNING→tag 'improvement'
3. Output: `Auto-Notes: N erstellt, M uebersprungen (Duplikat)`
∅Findings oder nur INFO→skip

## Phase 4: Auto-Bugreport + Findings persistieren (ERROR/WARNING)
**Projekt-Routing:** Findings im Zielprojekt speichern, NICHT pauschal in mxLore.
- Skill/Setup/Tool-Findings (betreffen mx*-Infrastruktur)→`project='mxLore'`
- Projekt-spezifische Findings (Stubs, lokale Docs, fehlende Relations)→`project=<Zielprojekt>`
`mx_create_doc(project=<siehe Routing>, doc_type='bugreport', title='mxHealth: N Findings...', tags='["mxhealth-auto"]', status='reported')`
Deduplizierung: mx_search vor Erstellen. ∅ERROR/WARNING→kein Report.

**Skill Evolution:** Fuer jedes Finding (ERROR+WARNING): `mx_skill_manage(action='record_finding', skill='mxHealth', rule_id='<pN-lowercase>' (z.B. p1-metadaten, p3-crossref, p4-status), project='<slug>', severity='<error|warning>', title='<Befund kurzfassung>', details='<Dokument + Befund>')`
- context_hash='<pruefung>:<dokument-slug>' fuer Dedup ueber Runs
- ∅MCP→skip (bereits in Bugreport erfasst)

## Phase 5: Auto-Fix (P9)
P9-Findings→Entfernt (B6.5). ∅P9→skip.

## Loop-Modus (--loop oder /loop Kontext)
- Kompakt-Output: nur `mxHealth: X ERROR Y WARNING Z INFO` + Findings-Einzeiler
- !Report-Header !Inventar-Tabelle !Zusammenfassung-Block
- !Rueckfragen, !interaktive Schritte
- Auto-Fix(P9) still ausfuehren, nur bei Aenderung melden
- Bugreport nur bei ERROR erstellen (WARNING→skip in Loop)
- ∅Findings→einzeilig: `mxHealth OK — 0 Probleme`

## Regeln
- Read-only + Bug-Notes + Summary-Fix. !Dokument-Inhalte aendern
- MCP-Fehler→ERROR im Report, !abbrechen
- >20 Docs/Typ→Stichproben(max 10 via mx_batch_detail). P1 auf alle(aus mx_search). ⚡ !einzelne mx_detail Calls→immer mx_batch_detail(doc_ids=[...])
- IP-Schutz: nur Metadaten+Struktur. UTF-8 ohne BOM. !Annahmen→nur Fakten
