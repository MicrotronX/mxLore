---
name: mxInitProject
description: "Du bist ein Repo-Bootstrap-Agent. Lege im aktuellen Repository eine skalierbare AI-Dokumentationsstruktur an, ohne bestehende Inhalte kaputt zu machen."
user-invocable: true
effort: low
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill
---

Du bist ein Repo-Bootstrap-Agent. Lege im aktuellen Repository eine skalierbare AI-Dokumentationsstruktur an, ohne bestehende Inhalte kaputt zu machen.

## Idempotenz-Garantie ⚡

Dieser Skill ist **sicher bei Mehrfachaufruf**. Pre-Flight-Check VOR allen Schritten:

1. Glob: `CLAUDE.md` im Projektroot → existiert?
2. Glob: `docs/status.md` → existiert?
3. Glob: `docs/decisions/`, `docs/specs/`, `docs/plans/`, `docs/ops/`, `docs/reference/` → existieren?
4. Falls CLAUDE.md existiert: Grep `AI Start Here` → Block vorhanden?
5. Falls MCP-Modus: `mx_briefing(project)` → Projekt registriert?

**Entscheidungsmatrix:**
| CLAUDE.md | AI-Start-Here | Verzeichnisse | MCP-Projekt | status.md | Ergebnis |
|-----------|---------------|---------------|-------------|-----------|----------|
| ✓ | ✓ | ✓ | ✓ | ✓ | `"Alles vorhanden — keine Aenderungen noetig."` → **SOFORT ABBRECHEN** |
| ✓ | ✗ | ✓ | ✓ | ✓ | Nur AI-Start-Here-Block einfuegen |
| ✗ | — | ✗ | ✗ | ✗ | Voller Bootstrap (alle Schritte) |
| ✓ | ✓ | ✓ | ✗ | ✓ | Nur MCP-Registrierung (Schritt 2) |
| beliebig | beliebig | beliebig | beliebig | beliebig | Nur fehlende Teile erstellen, vorhandene ueberspringen |

⚡ **Jeder Schritt prueft individuell ob sein Artefakt existiert → skip wenn ja.**
⚡ **Niemals bestehende Inhalte ueberschreiben, loeschen oder duplizieren.**

## Projekt-Kontext / MCP-Erkennung

MCP-Verfuegbarkeit wird so geprueft (in dieser Reihenfolge):

1. **`mx_ping()` aufrufen** — wenn erfolgreich: MCP-Modus (Server global oder per Projekt konfiguriert)
2. Falls mx_ping fehlschlaegt: `.mcp.json` im Projektverzeichnis pruefen (Fallback)
3. Falls beides negativ: Nicht-MCP-Modus (lokale Dateien)

**MCP-Modus:** Keine lokalen Index-Dateien anlegen — die Knowledge-DB ist die Wahrheitsquelle.
**Nicht-MCP-Modus:** Lokale Index-Dateien anlegen (decisions/index.md, specs/index.md, plans/index.md).

## 0. Projekt-spezifischer MCP-Server (optional)

Ermoeglicht Multi-Team-Szenarien: Verschiedene Projekte koennen unterschiedliche mxLore-Server nutzen.

**Wann fragen:** Nur bei Ersteinrichtung (CLAUDE.md existiert noch NICHT) und MCP ist global verfuegbar (mx_ping OK).
**Nicht fragen:** Bei Idempotenz-Skip, bei Nicht-MCP-Modus, bei bereits eingerichtetem Projekt.

?user: "MCP-Server fuer dieses Projekt? (Enter=globalen Server nutzen, oder eigene URL eingeben)"

**Falls Enter (Default/global):** Weiter wie bisher — globaler user-scope MCP wird genutzt. Keine `.mcp.json` schreiben, kein lokaler Proxy.

**Falls eigene URL:**
1. URL validieren: muss mit `https://` beginnen und auf `/mcp` enden
2. API-Key abfragen: ?user: "API-Key fuer diesen Server? (beginnt mit mxk_)"
3. **Proxy-INI erstellen:** `.claude/mxMCPProxy.ini` im Projektverzeichnis:
   ```ini
   [Server]
   BaseUrl=<URL ohne /mcp Suffix>
   ApiKey=<API-KEY>
   McpEndpoint=/mcp

   [Agent]
   Polling=1
   PollInterval=15
   ```
4. **Proxy-EXE:** Globale `~/.claude/mxMCPProxy.exe` verlinken oder Pfad merken
5. **`.mcp.json` erstellen/aktualisieren** im Projektverzeichnis:
   ```json
   {
     "mcpServers": {
       "mxai-knowledge": {
         "command": "<absoluter-pfad-zu>/.claude/mxMCPProxy.exe",
         "args": ["<absoluter-pfad-zu-projekt>/.claude/mxMCPProxy.ini"]
       }
     }
   }
   ```
   (Proxy nimmt INI-Pfad als erstes Argument, kein Flag noetig)
   ⚡ Falls `.mcp.json` bereits existiert: nur `mxai-knowledge` Key ergaenzen/ersetzen, Rest beibehalten
6. **Testen:** `mx_ping()` aufrufen — muss den projekt-spezifischen Server erreichen
   - Erfolg: "Projekt-MCP eingerichtet: <URL>"
   - Fehler: URL/Key pruefen, Abbruch mit Hinweis
7. `.claude/` in `.gitignore` ergaenzen (INI enthaelt API-Key)

⚡ **Transparenz:** Nach diesem Schritt sprechen alle mx*-Skills automatisch mit dem Projekt-Server statt dem globalen. Keine weiteren Aenderungen noetig.

## 1. Verzeichnisse anlegen (falls fehlend)

Erstelle diese Verzeichnisse, falls sie noch nicht existieren:
- docs/decisions
- docs/specs
- docs/plans
- docs/ops
- docs/reference

## 1b. Workflow-Log (nur bei Nicht-MCP-Projekten)

Falls Nicht-MCP-Modus (mx_ping fehlgeschlagen) UND `docs/ops/workflow-log.md` nicht existiert, erstelle:

```markdown
# Workflow Log

<!-- Eintraege werden automatisch via /mxOrchestrate ergaenzt. Nicht manuell bearbeiten. -->
```

Bei MCP-Projekten werden Workflows in der DB gespeichert.

## 2. Index-Dateien (nur bei Nicht-MCP-Projekten)

**Falls MCP-Modus (mx_ping erfolgreich):** Keine Index-Dateien anlegen. Stattdessen pruefen ob Projekt in DB registriert ist:
1. Slug aus CLAUDE.md lesen (`**Slug:**`-Zeile). Falls kein Slug: aus Verzeichnisnamen ableiten und Benutzer fragen: "Projekt-Slug Vorschlag: `<slug>` — passt das?"
2. Rufe `mx_briefing(project='<slug>')` auf
3. Falls "Project not found":
   - **STOPP — MUSS den Benutzer fragen!** Frage: "Projektname fuer `<slug>`? (z.B. 'Mein Projekt — Kurzbeschreibung')"
   - **Warte auf Antwort.** Erst DANACH `mx_init_project(project_name='<antwort>')` aufrufen.
   - **NIEMALS** den Slug oder einen selbst erfundenen Namen als Projektnamen verwenden!
4. Slug in CLAUDE.md eintragen falls noch nicht vorhanden

**Falls Nicht-MCP-Modus:** Lege Index-Dateien an wie bisher:

### docs/decisions/index.md
```markdown
# Architecture Decision Records (ADR)

Entscheidungen werden ausschliesslich via `/mxDecision` angelegt.

| ADR | Titel | Status | Datum |
|-----|-------|--------|-------|
| — | _Noch keine Eintraege_ | — | — |
```

### docs/specs/index.md
```markdown
# Spezifikationen (Specs)

Specs werden ausschliesslich via `/mxSpec` angelegt.

| Spec | Titel | Datum |
|------|-------|-------|
| — | _Noch keine Eintraege_ | — |
```

### docs/plans/index.md
```markdown
# Plaene

Plaene werden ausschliesslich via `/mxPlan` angelegt.

| Plan | Titel | Status | Datum |
|------|-------|--------|-------|
| — | _Noch keine Eintraege_ | — | — |
```

## 3. CLAUDE.md anpassen

Falls CLAUDE.md existiert: Fuege OBEN (nach der ersten H1-Zeile) einen "AI Start Here"-Block ein. Ueberschreibe NICHTS — nur einfuegen.

Falls CLAUDE.md nicht existiert: Erstelle eine minimale CLAUDE.md nach folgendem Template.
**WICHTIG:** NUR projekt-spezifische Infos. Keine globalen Regeln (Sicherheit, Encoding, etc.) — die stehen in `~/.claude/CLAUDE.md`.

### Projekt-CLAUDE.md Template (wenn neu erstellt)

```markdown
# <Projektname>

> **AI Start Here** — [AI Start Here Block wie unten]

## Projekt

- **Slug:** <slug>
- **Stack:** <erkannter Stack, z.B. "Delphi + FireDAC" oder "PHP + Laravel">
- **Status:** Initialisiert

## Architektur

_(wird im Laufe des Projekts ergaenzt)_

## Regeln (projekt-spezifisch)

_(nur Regeln die NUR fuer dieses Projekt gelten, keine globalen Regeln duplizieren)_
```

Falls CLAUDE.md existiert: Fuege NUR den "AI Start Here"-Block ein (nach der ersten H1-Zeile). Ueberschreibe NICHTS.

### Einzufuegender Block (MCP-Projekt)

Falls MCP-Modus:

```markdown
> **AI Start Here** — Lies diese Dateien zum Einstieg:
>
> | Dokument | Zweck |
> |----------|-------|
> | [CLAUDE.md](./CLAUDE.md) | Architektur, Konventionen, Regeln (diese Datei) |
> | [docs/status.md](./docs/status.md) | Aktueller Projektstatus, offene Punkte |
>
> **Dokumentations-Regeln (MCP-basiert):**
> - Entscheidungen NUR via `/mxDecision` → Knowledge-DB (doc_type='decision')
> - Plaene NUR via `/mxPlan` → Knowledge-DB (doc_type='plan')
> - Specs NUR via `/mxSpec` → Knowledge-DB (doc_type='spec')
> - `/mxSave` aktualisiert CLAUDE.md + docs/status.md (lokal) + Session-Notes (DB)
> - Dokumente suchen: `mx_search(project='<slug>', ...)` oder `mx_briefing(project='<slug>')`
> - CLAUDE.md bleibt kompakt: Links + Regeln + Architektur. Keine langen Backlogs.
```

### Einzufuegender Block (Nicht-MCP-Projekt)

Falls kein MCP-Server:

```markdown
> **AI Start Here** — Lies diese Dateien zum Einstieg:
>
> | Dokument | Zweck |
> |----------|-------|
> | [CLAUDE.md](./CLAUDE.md) | Architektur, Konventionen, Regeln (diese Datei) |
> | [docs/status.md](./docs/status.md) | Aktueller Projektstatus, offene Punkte |
> | [docs/decisions/index.md](./docs/decisions/index.md) | Architecture Decision Records (ADR) |
> | [docs/specs/index.md](./docs/specs/index.md) | Spezifikationen |
> | [docs/plans/](./docs/plans/) | Plaene und Session-Notes |
>
> **Dokumentations-Regeln:**
> - Entscheidungen NUR via `/mxDecision` → `docs/decisions/ADR-XXXX-slug.md`
> - Plaene NUR via `/mxPlan` → `docs/plans/PLAN-XXXX-slug.md`
> - Specs NUR via `/mxSpec` → `docs/specs/SPEC-slug.md`
> - `/mxSave` aktualisiert `docs/status.md` + Session-Notes
> - CLAUDE.md bleibt kompakt: Links + Regeln + Architektur. Keine langen Backlogs.
```

## 4. docs/status.md anlegen (falls fehlend)

Falls `docs/status.md` nicht existiert, erstelle eine minimale Datei:

```markdown
# Projektstatus

_Erstellt via /mxInitProject_

## Implementierte Features

- (noch keine)

## Offene Punkte

- (noch keine)
```

## 5. Abschlussbericht

Gib eine Tabelle aus mit allen angelegten/geaenderten Dateien und der jeweiligen Aktion (erstellt / geaendert / bereits vorhanden / uebersprungen (MCP)).

## 6. Migration (MCP-Projekte)

Falls MCP-Modus und Projekt in DB registriert:
- Pruefe ob `docs/status.md` migrierbare Tasklisten enthaelt (Backlog, ToDo, Open Tasks etc.)
  - Falls ja: Automatisch `/mxMigrateToDb --extract-backlog` per Skill-Tool ausfuehren
  - Falls keine Tasklisten: "Keine Legacy-Backlogs gefunden — Extraktion uebersprungen."
- Pruefe ob `docs/` lokale .md-Dateien enthaelt (PLAN-*, SPEC-*, ADR-*, session-notes-*)
  - Falls ja: Automatisch `/mxMigrateToDb --sync` per Skill-Tool ausfuehren
  - Falls keine migrierbaren Dateien: "Keine lokalen Dokumente zum Migrieren gefunden."

## Wichtige Regeln

- **Niemals** bestehende Inhalte ueberschreiben oder loeschen
- **Niemals** Dateien anlegen, die bereits existieren (nur pruefen und "bereits vorhanden" melden)
- Bei CLAUDE.md NUR den "AI Start Here"-Block einfuegen, wenn er noch nicht vorhanden ist
- Alle Dateien in UTF-8 ohne BOM
- **Idempotenz:** Bei Mehrfachaufruf sofort abbrechen wenn alles vorhanden (Pre-Flight-Check)
- **Abschlussbericht IMMER:** Auch bei Sofort-Abbruch die Tabelle mit Status "bereits vorhanden" ausgeben
