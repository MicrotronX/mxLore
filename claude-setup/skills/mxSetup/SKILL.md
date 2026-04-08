---
name: mxSetup
description: "Developer-Onboarding: MCP-Verbindung, Skills, Proxy, Config. Ausfuehren auf neuem PC oder nach Updates."
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: "<api-key> | --update"
---

# /mxSetup — Developer Onboarding (~30 Sekunden)

> ⚡ **!Python !jq !sed fuer Datei-Operationen.** Nur Write/Read/Edit-Tools + Bash fuer `claude mcp` und `curl`.
> ⚡ **Bash: Einzeilig.** !Mehrzeiler !Heredocs !Newlines in Befehlen.

## Erstinstallation (mit API-Key)

### Phase 1: MCP-Verbindung

1. Pruefe `claude mcp list` → bereits `mxai-knowledge`? → "Verwende `--update`"
2. ?user: "Server-URL? (z.B. http://localhost:8080/mcp)"
   - URL muss auf `/mcp` enden
3. MCP registrieren:
```bash
claude mcp add -s user --transport http mxai-knowledge "<SERVER-URL>" --header "Authorization: Bearer <API-KEY>"
```
4. `mx_ping()` → Erfolg? admin_port merken. Fehler? → Abbruch.

### Phase 2: Skills von GitHub installieren (~5 Sekunden)

⚡ **EXAKTE URL — NICHT erfinden!**
`https://github.com/MicrotronX/mxLore-skills/archive/main.zip`
!mxai-org !mxai-tech !andere Repos. NUR `MicrotronX/mxLore-skills`.

**Alle Plattformen (curl + unzip, funktioniert in Bash/Git-Bash/Linux/macOS):**
```bash
curl -L -o /tmp/mxLore-skills.zip https://github.com/MicrotronX/mxLore-skills/archive/main.zip && unzip -o /tmp/mxLore-skills.zip -d /tmp/mxLore-skills
```

Dann kopieren:
```bash
cp -r /tmp/mxLore-skills/mxLore-skills-main/mx* ~/.claude/skills/
mkdir -p ~/.claude/hooks && cp -r /tmp/mxLore-skills/mxLore-skills-main/hooks/* ~/.claude/hooks/
mkdir -p ~/.claude/reference && cp -r /tmp/mxLore-skills/mxLore-skills-main/reference/* ~/.claude/reference/
cp /tmp/mxLore-skills/mxLore-skills-main/CLAUDE.md /tmp/mxLore-skills-CLAUDE.md 2>/dev/null
rm -rf /tmp/mxLore-skills /tmp/mxLore-skills.zip
```

⚡ !PowerShell !Invoke-WebRequest — immer curl+unzip in Bash verwenden (funktioniert ueberall).

### Phase 3: Proxy installieren

1. **Admin-URL:** Aus mx_ping `admin_port` → `http://<host>:<admin_port>/api/download/proxy`
   Falls kein admin_port: Server-URL Port+1 (8080→8081)
2. Download:
```bash
curl -f -o ~/.claude/mxMCPProxy.exe "http://<host>:<admin_port>/api/download/proxy"
```
3. Dateigroesse pruefen (>100KB). Falls kleiner: Warnung, skip Proxy.
4. Proxy-INI erzeugen (Write-Tool → `~/.claude/mxMCPProxy.ini`):
```ini
[Server]
Url=<SERVER-URL>
ApiKey=<API-KEY>
ConnectionTimeout=10000
ReadTimeout=120000

[Agent]
Polling=1
PollInterval=15
```

### Phase 4: MCP auf Proxy umstellen

```bash
claude mcp remove mxai-knowledge -s user
claude mcp add -s user mxai-knowledge -- "<HOME>/.claude/mxMCPProxy.exe"
```
`mx_ping()` → Erfolg? Weiter. Fehler? HTTP-Fallback anbieten.

### Phase 5: Config

1. **settings.json** — MCP-Permissions + Hooks:
   - `permissions.allow` → `"mcp__mxai-knowledge__*"` ergaenzen (Edit-Tool)
   - Hooks ergaenzen (Edit-Tool, fehlende hinzufuegen):
     - `UserPromptSubmit`: `bash ~/.claude/hooks/agent_inbox_check.sh` + `node ~/.claude/hooks/orchestrate-status.js`
     - `SessionStart`: `node ~/.claude/hooks/orchestrate-reconcile.js` + `node ~/.claude/hooks/orchestrate-status.js`
     - `Stop`: `node ~/.claude/hooks/orchestrate-step-check.js`
2. **CLAUDE.md** — Verwende `/tmp/mxLore-skills-CLAUDE.md` (in Phase 2 gesichert):
   - Falls `~/.claude/CLAUDE.md` nicht existiert: kopieren
   - Falls existiert und mx-rules Marker hat: Block zwischen `<!-- mx-rules-start -->` und `<!-- mx-rules-end -->` durch neuen ersetzen
   - Falls existiert ohne Marker: mx-rules Block am Ende anhaengen
   - Danach: `rm /tmp/mxLore-skills-CLAUDE.md`
3. **Agent Inbox:** `mkdir -p ~/.claude/agent_inbox`

### Phase 6: Fertig

```
=== mxLore Setup abgeschlossen ===

| Komponente | Status |
|------------|--------|
| MCP | Verbunden (<URL>) |
| Skills | X installiert |
| Hooks | Y installiert |
| Proxy | OK / FEHLT |
| CLAUDE.md | OK |

Naechste Schritte:
1. Claude Code neu starten
2. In Projekt-Verzeichnis wechseln
3. /mxInitProject ausfuehren
```

## Update-Modus (--update)

1. Phase 2 ausfuehren (Skills von GitHub)
2. Phase 5 ausfuehren (Config aktualisieren)
3. Proxy-Update: Download neue EXE → Rename alte → Move neue → Delete alte
4. Zusammenfassung zeigen

## Regeln

- **!mx_onboard_developer** — Skills kommen von GitHub, nicht vom Server
- **!Python !jq** — Write/Edit-Tools fuer Dateien, Bash nur fuer curl/claude-mcp
- **API-Key nie anzeigen** — nur letzte 4 Zeichen (`mxk_****15c`)
- **Skills immer ueberschreiben** — GitHub = Source of Truth
- **Encoding:** UTF-8 ohne BOM
- **MCP-Scope:** IMMER `-s user`
