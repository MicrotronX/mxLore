# Workflow-Templates

Deklarative Workflow-Definitionen fuer `/mxOrchestrate`.
Projekte koennen diese Templates in `docs/workflows.md` ueberschreiben oder ergaenzen (Projekt-spezifisch hat Vorrang).

---

## Template: neues-feature

**Trigger-Woerter:** feature, neues feature, neue funktion, implementieren, neuer bereich
**Beschreibung:** Kompletter Workflow fuer ein neues Feature: Von der Idee bis zur Implementierung.

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Anforderungen klaeren | superpowers:brainstorming | nein | - |
| 2 | Spezifikation schreiben | /mxSpec (mit PRD-Phase) | ja | Wenn Feature komplex genug fuer eine eigene Spec |
| 2a | Spec-Review | /mxDesignChecker | wenn-spec | Nur wenn Schritt 2 ausgefuehrt, laedt spec-review.md |
| 2b | Spec korrigieren + Re-Review | /mxSpec + /mxDesignChecker | wenn-findings | Max 2 Iterationen bei CRITICAL/WARNING |
| 3 | Design pruefen | /mxDesignChecker | nein | Design-Dokument aus Schritt 1 pruefen |
| 4 | Entscheidung dokumentieren | /mxDecision | ja | Wenn Architektur-Entscheidung im Brainstorming gefallen |
| 5 | Plan erstellen | /mxPlan | nein | - |
| 6 | Implementieren | superpowers:executing-plans ODER superpowers:subagent-driven-development | nein | - |
| 7 | Code pruefen | /mxDesignChecker | nein | Geaenderte Dateien gegen Design pruefen |
| 8 | Bug-Check | /mxBugChecker | ja | Bei kritischem oder komplexem Code |
| 9 | Zustand sichern | /mxSave | nein | - |

---

## Template: bugfix

**Trigger-Woerter:** bug, fix, fehler, problem, kaputt, crash, exception
**Beschreibung:** Strukturierter Bugfix-Workflow mit Analyse und Verifikation.

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Bug analysieren | /mxBugChecker ODER superpowers:systematic-debugging | nein | - |
| 2 | Fix planen | /mxPlan | ja | Wenn Fix mehrere Dateien oder nicht-triviale Aenderungen betrifft |
| 3 | Fix implementieren | manuell | nein | - |
| 4 | Code pruefen | /mxDesignChecker | nein | Geaenderte Dateien pruefen |
| 5 | Entscheidung dokumentieren | /mxDecision | ja | Wenn Architektur-Aenderung noetig war |
| 6 | Zustand sichern | /mxSave | nein | - |

---

## Template: entscheidung

**Trigger-Woerter:** entscheidung, architektur, adr, design-entscheidung, abwaegung
**Beschreibung:** Strukturierte Architektur-Entscheidung mit Analyse und Dokumentation.

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Optionen diskutieren | superpowers:brainstorming | nein | - |
| 2 | Entscheidung dokumentieren | /mxDecision | nein | - |
| 3 | Betroffene Specs aktualisieren | /mxSpec | ja | Wenn bestehende Specs von der Entscheidung betroffen sind |
| 4 | Betroffene Plaene aktualisieren | /mxPlan | ja | Wenn bestehende Plaene angepasst werden muessen |
| 5 | Zustand sichern | /mxSave | nein | - |

---

## Template: spezifikation

**Trigger-Woerter:** spec, spezifikation, anforderungen, requirements
**Beschreibung:** Feature-Spezifikation erstellen mit Review-Iteration und anschliessender Planung.

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Anforderungen klaeren | superpowers:brainstorming | nein | - |
| 2 | Spezifikation schreiben | /mxSpec (mit PRD-Phase) | nein | - |
| 3 | Spec-Review | /mxDesignChecker | nein | Spec-Datei als Argument, laedt spec-review.md Regeln |
| 3a | Spec korrigieren | /mxSpec (update) | wenn-findings | Nur wenn Review CRITICAL/WARNING Findings hat |
| 3b | Re-Review | /mxDesignChecker | wenn-korrektur | Max 2 Iterationen, dann weiter (mit offenen Findings als Open Questions) |
| 4 | Entscheidung dokumentieren | /mxDecision | ja | Wenn Architektur-Entscheidung gefallen |
| 5 | Plan erstellen | /mxPlan | ja | Wenn direkt in die Planung uebergegangen werden soll |
| 6 | Zustand sichern | /mxSave | nein | - |

---

## Template: ad-hoc

**Trigger-Woerter:** (kein manueller Trigger — wird automatisch durch Auto-Tracking erstellt)
**Beschreibung:** Leichtgewichtiger Tracking-WF fuer Ad-hoc-Arbeit ohne expliziten Workflow-Start. Auto-Cleanup bei 0 Artefakten.

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Arbeit durchfuehren | — | nein | - |
| 2 | Code pruefen | /mxDesignChecker + /mxBugChecker | ja | Nur bei Code-Aenderungen |
| 3 | Zustand sichern | /mxSave | nein | - |

---

## Projekt-spezifische Overrides

Projekte koennen eigene Workflow-Templates in `docs/workflows.md` definieren.
Format identisch zu den Templates oben. Bei Namenskollision hat das Projekt Vorrang.

Beispiel fuer eine projekt-spezifische `docs/workflows.md`:

```markdown
# Projekt-Workflows

## Template: tarif-erweiterung

**Trigger-Woerter:** tarif, rate, zone, preismatrix, tariff
**Beschreibung:** Tarifsystem erweitern (Zonen, Raten, Matrix).

| # | Schritt | Skill | Optional | Bedingung |
|---|---------|-------|----------|-----------|
| 1 | Anforderungen klaeren | superpowers:brainstorming | nein | - |
| 2 | Tarif-Spec schreiben | /mxSpec | nein | Tarif-Aenderungen brauchen Spec |
| 3 | Design pruefen | /mxDesignChecker | nein | - |
| 4 | DB-Migration planen | /mxPlan | nein | install.sql Aenderungen |
| 5 | Entscheidung dokumentieren | /mxDecision | ja | Bei grundlegender Aenderung |
| 6 | Implementieren | superpowers:executing-plans | nein | - |
| 7 | Code + Grid pruefen | /mxDesignChecker | nein | Spreadsheet-Aenderungen kritisch |
| 8 | Zustand sichern | /mxSave | nein | - |
```
