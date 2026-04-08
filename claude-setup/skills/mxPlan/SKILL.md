---
name: mxPlan
description: Use when the user says "/plan", wants to create or update an implementation plan, or needs to structure a multi-step task before coding. Creates plans via MCP-Tools in the knowledge DB.
user-invocable: true
effort: medium
allowed-tools: Read, Write, Edit, Grep, Glob
argument-hint: "<slug z.B. edi-parser-refactor>"
---

# /mxPlan — Plan anlegen/aktualisieren (AI-Steno: !=forbidden →=use ⚡=critical ?=ask)

> **Context:** IMMER als Subagent(Agent-Tool) !Hauptkontext. Ergebnis: max 20 Zeilen.

Plan-Agent. Erstellt/aktualisiert Plans in Knowledge-DB via MCP.

## Init
1. CLAUDE.md→`**Slug:**`=project-param. ∅slug→?user
2. mx_ping()→OK=MCP-Modus | Fehler=Lokal(`docs/plans/PLAN-<slug>.md`+Warnung→/mxMigrateToDb)

## Input
Slug aus Command-Argument. ∅arg→?user. Slug: `a-z 0-9 -` only.

## Ablauf

### 1) Existenz pruefen
`mx_search(project, doc_type='plan', query='<slug>', include_details=true, limit=1)` →Treffer=Update(3, doc_id+content direkt) | ∅=Neu(2)

### 2) Neuer Plan

**Template:**
```markdown
# PLAN: <Titel>
**Slug:** <slug> | **Erstellt:** YYYY-MM-DD | **Status:** active

## Goal
<1-3 Saetze aus Chat-Kontext>

## Related
- **Spec:** [SPEC-xxx] (nur wenn im Chat erkennbar)

## Non-goals
- <Was NICHT in Plan>

## Milestones
1. <Meilenstein>

## Tasks
- [ ] Task 1
- [ ] Task 2

## Risks
- <Risiko>

## Notes
- <Hinweise>
```

**MCP:** `mx_create_doc(project, doc_type='plan', title='PLAN: <Titel>', content)`
Related→`mx_search`→target_id→`mx_add_relation(source, target, 'references')`

**Lokal(Fallback):** `docs/plans/PLAN-<slug>.md` + index.md update + Warnung

### 3) Plan aktualisieren
**MCP:** mx_detail(doc_id)→Abschnitte aendern→mx_update_doc(doc_id, content, change_reason) !bestehende Inhalte loeschen
**Lokal:** Read→Edit→index update falls Status geaendert

### 4) Status-Transition (bei Update)
Nach Schritt 3: Tasks-Zeilen im Content pruefen.
- **Alle `- [x]`** (keine `- [ ]` mehr) UND Status noch `active`:
  - Content: `**Status:** active`→`**Status:** completed`
  - `mx_update_doc(doc_id, content, status='archived', change_reason='Alle Tasks erledigt')`
  - Output: `Plan #<doc_id> archiviert — alle Tasks erledigt`
- **Gemischt:** ∅Aenderung, nur Info: `<N>/<M> Tasks erledigt`
- ⚡ Nur bei eindeutig erledigten Plans. Zweifel→offen lassen+?user

## Regeln
- Tasks: klein+pruefbar, `- [ ]`/`- [x]`, max 15-20/Plan, 1 Session/Task
- ⚡ Nur fundiertes Wissen aus Chat !erfinden. ∅info→?user
- ⚡ Related: mx_search verifizieren VOR mx_add_relation !Relationen auf ∅docs
- !ADRs→nur /mxDecision. !Prosa→praegnant+operativ
- MCP bevorzugen, lokal=Fallback

## Abschluss
Output: (1) doc_id (2) Top-5 Tasks (3) Relationen falls erstellt
Empfehlung: `superpowers:executing-plans` oder `superpowers:subagent-driven-development`
Falls aktiver Workflow→naechsten Schritt nennen
