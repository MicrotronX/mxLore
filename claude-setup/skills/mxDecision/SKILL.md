---
name: mxDecision
description: Use when the user says "/decision", wants to document an architectural decision, or when a significant technical choice was made in the conversation. Creates ADRs via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<Titel der Entscheidung>"
---

# /mxDecision — ADR anlegen (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen.

ADR-Agent. Legt Entscheidungen als ADR in Knowledge-DB an via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project_slug. ∅slug→?user
2. mx_ping()→OK=MCP-Modus | Fehler=Lokal(`docs/decisions/ADR-NNNN-<slug>.md`+Warnung→/mxMigrateToDb)

## Input
Titel aus Command-Argument. ∅arg→?user

## Ablauf

### 1) ADR-Nummer
**MCP:** Auto-Nummer bei `mx_create_doc(doc_type='decision')` — keine separate Abfrage noetig.
**Lokal:** `docs/decisions/index.md`→hoechste Nummer+1

### 2) ADR erstellen

**Template:**
```markdown
# ADR-XXXX: <Titel>
**Status:** <accepted|proposed> | **Datum:** YYYY-MM-DD

## Context
<Problem/Anlass — 2-5 Saetze>

## Decision
<Klare, testbare Regel — 2-5 Saetze>

## Consequences
### Vorteile
- ...
### Nachteile / Risiken
- ...
### Follow-ups
- ...
```

Status: `accepted`=im Chat beschlossen | `proposed`=noch zu bestaetigen

**MCP:** `mx_create_doc(project, doc_type='decision', title='ADR-NNNN: <Titel>', content)`
**Lokal:** `docs/decisions/ADR-NNNN-<slug>.md` + index.md update + Warnung

### 3) Existenz-Check bei Bezuegen
Referenzierte Docs: `mx_search(project, query='<ref>', include_details=true, limit=1)` statt mx_search+mx_detail getrennt

### 4) Relations erstellen (nur MCP)

Nach mx_create_doc — 4 optionale Fragen an User (jede mit 'nein' ueberspringbar):

| Frage | Relation | Aktion |
|-------|----------|--------|
| Annahmen die sich aendern koennten? | `assumes` | mx_create_doc(doc_type='assumption')+mx_add_relation |
| Alternativen evaluiert+verworfen? | `rejected_in_favor_of` | mx_create_doc(doc_type='note')+mx_add_relation |
| Was hat dazu gefuehrt? (doc_id oder Text) | `caused_by` | mx_add_relation (oder create+relate) |
| Ersetzt bestehende ADR? (doc_id) | `supersedes` | mx_add_relation+mx_update_doc(old→superseded) |

Ref: Konventions-Doc doc_id=620

### 5) Status-Transition
**Supersedes-Kette:** Bei `supersedes`-Relation in Schritt 4:
- Alter ADR: `mx_update_doc(doc_id, content mit '**Status:** superseded', status='archived', change_reason='Superseded by ADR-NNNN')`
- ⚡ Immer beide Seiten aktualisieren: neuer ADR referenziert alten, alter ADR wird archived

**Follow-ups erledigt:** Wenn alle Follow-ups im Content als erledigt markiert:
- `mx_update_doc(doc_id, content mit '**Status:** implemented', status='archived', change_reason='Alle Follow-ups erledigt')`
- Output: `ADR #<doc_id> archiviert — vollstaendig implementiert`

**Proposed→Accepted:** Wenn User im Chat eine proposed-Decision bestaetigt:
- Content: `**Status:** proposed`→`**Status:** accepted`
- `mx_update_doc(doc_id, content, change_reason='Vom User bestaetigt')`

## Regeln
- ⚡ Nur fundiertes Wissen aus Chat !erfinden. ∅kontext→?user !rekonstruieren
- ⚡ Related: mx_search verifizieren VOR mx_add_relation
- !bestehende ADRs umschreiben/loeschen. Praegnant: Context+Decision je 2-5 Saetze
- MCP bevorzugen, lokal=Fallback

## Abschluss
Output: (1) doc_id+ADR-Nummer (2) Kurzbestaetigung 1-2 Saetze (3) Relationen falls erstellt
Empfehlung: `/mxPlan` oder `/mxSpec` falls sinnvoll. Aktiver Workflow→naechsten Schritt
