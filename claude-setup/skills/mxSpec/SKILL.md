---
name: mxSpec
description: Use when the user says "/spec", wants to write a specification for a feature or component, or needs to define requirements and acceptance criteria before planning or implementation. Creates specs via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<slug z.B. notification-system>"
---

# /mxSpec — Spezifikation anlegen/aktualisieren (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen.

Spec-Agent. Erstellt/aktualisiert Spezifikationen in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-Modus | Fehler=Lokal(`docs/specs/SPEC-<slug>.md`+Warnung→/mxMigrateToDb)

## Input
Slug aus Command-Argument. ∅arg→?user. Slug: `a-z 0-9 -` only.

## Ablauf

### 0) PRD-Kontext
- Brainstorming in Session→PRD aus Chat ableiten, keine Rueckfragen
- ∅Brainstorming→4 Fragen: (1) Problem? (2) Wer profitiert? (3) Was wenn nichts tun? (4) Teilloesungen?
- Update bestehender Spec→Phase 0 skip

### 1) Existenz pruefen
`mx_search(project, doc_type='spec', query='<slug>', include_details=true, limit=1)` →Treffer=Update(3, doc_id+content direkt) | ∅=Neu(2)

### 2) Neue Spec

**Template:**
```markdown
# SPEC: <Titel>
**Slug:** <slug> | **Erstellt:** YYYY-MM-DD | **Letzte Aenderung:** YYYY-MM-DD

## Overview
<2-4 Saetze>

## Related
- **ADR:** [ADR-xxxx] — <Bezug> (nur wenn im Chat erkennbar)
- **Plan:** [PLAN-xxx] — <Bezug> (nur wenn im Chat erkennbar)

## Goals
- <Ziele>

## Non-goals
- <Was NICHT in Spec>

## Requirements
1. <Anforderung>

## Acceptance Criteria
- [ ] <Pruefbares Kriterium>

## Interfaces / Data
<DB-Tabellen, API — nur falls relevant>

## Edge Cases
- <Sonderfall>

## Open Questions
- <Offene Frage>
```

**MCP:** `mx_create_doc(project, doc_type='spec', title='SPEC: <Titel>', content)`
Related→`mx_search`→target_id→`mx_add_relation(source, target, 'references')`

**Lokal(Fallback):** `docs/specs/SPEC-<slug>.md` + index.md update + Warnung

### 3) Spec aktualisieren
**MCP:** mx_detail(doc_id)→Abschnitte aendern→"Letzte Aenderung"=heute→mx_update_doc(doc_id, content, change_reason) !bestehende Inhalte loeschen
**Lokal:** Read→Edit→"Letzte Aenderung"=heute

### 4) Status-Transition (bei Update)
Nach Schritt 3: Acceptance Criteria im Content pruefen.
- **Alle `- [x]`** (keine `- [ ]` mehr) UND kein offenes Open Question:
  - Content: `**Status:** implemented` ergaenzen (nach Letzte Aenderung)
  - `mx_update_doc(doc_id, content, status='archived', change_reason='Alle AC erfuellt')`
  - Output: `Spec #<doc_id> archiviert — alle Acceptance Criteria erfuellt`
- **Gemischt:** ∅Aenderung, nur Info: `<N>/<M> AC erfuellt`
- **Open Questions vorhanden:** ∅archivieren, auch wenn AC komplett. Hinweis: `AC komplett aber offene Fragen verbleiben`
- ⚡ Nur bei eindeutig implementierten Specs. Zweifel→offen lassen+?user

## Regeln
- ⚡ Nur fundiertes Wissen aus Chat !erfinden. ∅info→?user oder Open Question
- ⚡ Related: mx_search verifizieren VOR mx_add_relation
- !erfundene Metriken in AC. !Implementierungsdetails→/mxPlan
- Requirements nummeriert. AC klar pruefbar !vage
- MCP bevorzugen, lokal=Fallback

## Abschluss
Output: (1) doc_id (2) Top 3-5 Acceptance Criteria (3) Relationen falls erstellt
Empfehlung: `/mxDecision` falls ADR noetig, `/mxPlan <slug>` fuer Implementierung
Aktiver Workflow→naechsten Schritt
