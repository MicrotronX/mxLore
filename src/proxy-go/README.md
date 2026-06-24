# mxMCPProxy (Go-Port)

Cross-Platform-Neufassung des `mxMCPProxy` (ursprünglich Delphi, `src/proxy/`).
Verhalten **1:1 identisch** — eine einzige, dependency-freie Binary für
**macOS (Apple Silicon/Intel)** und **Windows**. Kein Xcode, kein PAServer,
keine DLLs.

Hintergrund: Der Delphi-Proxy enthielt zahlreiche Win32-API-Workarounds
(`SetNamedPipeHandleState`, rohe `ReadFile`/`WriteFile`, `SetConsoleCtrlHandler`)
— die existierten **nur**, um Delphi-RTL-Pipe-Bugs unter Windows zu umgehen.
In Go gibt es diese Bugs nicht; die Workarounds entfallen ersatzlos.

## Was der Proxy macht

stdio ↔ HTTP-Bridge für MCP:
1. Liest JSON-RPC-Zeilen von **stdin** (von Claude Code).
2. Forwarded sie per HTTP-POST an den mxLore-Server (Bearer-Auth,
   `Mcp-Session-Id`-Session-Handling, SSE-Parsing, Auto-Re-Init bei
   abgelaufener Session, 1× Connection-Retry).
3. Schreibt die Antworten zeilenweise auf **stdout**.
4. Optionaler Hintergrund-Thread: pollt `?agent_inbox=<slug>`, schreibt neue
   Nachrichten atomar in `agent_inbox_<slug>.json` (vom Claude-Code-Hook
   konsumiert) und ACKt via `?agent_ack=<ids>`.

## Bauen (auf dem Mac M4)

Go installieren (einmalig):

```bash
brew install go        # oder: https://go.dev/dl  (pkg-Installer)
```

Bauen:

```bash
cd src/proxy-go
./build.sh             # → bin/mxMCPProxy  (nativer arm64-Build)
```

Oder direkt:

```bash
cd src/proxy-go
GOFLAGS=-buildvcs=false go build -o bin/mxMCPProxy .
```

> `-buildvcs=false` ist nötig, weil das Repo unter git **und** svn liegt —
> sonst bricht `go build` mit "multiple VCS detected" ab.

### Cross-Compile (optional, z. B. Windows-Binary vom Mac aus)

```bash
GOOS=windows GOARCH=amd64 GOFLAGS=-buildvcs=false go build -o bin/mxMCPProxy.exe .
GOOS=darwin  GOARCH=amd64 GOFLAGS=-buildvcs=false go build -o bin/mxMCPProxy-intel .
```

## Konfiguration

INI **neben die Binary** legen (oder Pfad als 1. Argument übergeben).
Beim ersten Start ohne INI schreibt der Proxy ein Default-Template und beendet
sich mit Exit-Code 1 — dann `Url` + `ApiKey` eintragen und neu starten.

```ini
[Server]
Url=https://YOUR-SERVER/mxLore/mcp   ; oder http://127.0.0.1:8080/mcp lokal
ApiKey=mxk_...
ConnectionTimeout=10000
ReadTimeout=120000

[General]
LogLevel=info        ; debug = Hot-Path-Tracing für Bug-Hunts

[Agent]
Polling=1            ; Multi-Agent-Inbox-Polling
PollInterval=15
; InboxDir=/Users/<du>/.claude/agent_inbox   ; Default: <ini-dir>/agent_inbox
; WorkDir=/Pfad/zum/Projekt                  ; überschreibt CWD für Slug-Detection
```

Der Projekt-Slug wird automatisch aus `**Slug:**` in der `CLAUDE.md` des
Arbeitsverzeichnisses gelesen (oder aus dem ersten `tools/call` mit
`project`-Parameter).

## In Claude Code registrieren (Mac)

```bash
claude mcp add mxlore -- /Pfad/zu/src/proxy-go/bin/mxMCPProxy /Pfad/zu/mxMCPProxy.ini
```

oder in `.mcp.json` / `~/.claude.json`:

```json
{
  "mcpServers": {
    "mxlore": {
      "command": "/Pfad/zu/bin/mxMCPProxy",
      "args": ["/Pfad/zu/mxMCPProxy.ini"]
    }
  }
}
```

Logs: `mxMCPProxy.log` neben der Binary (+ stderr).

## Dateien

| Datei         | Inhalt                                            |
|---------------|---------------------------------------------------|
| `main.go`     | Bootstrap, First-Run-INI, Signal-Handling         |
| `config.go`   | INI-Parser (dependency-frei) + Default-Template   |
| `logx.go`     | Logging (Datei + stderr, thread-safe)             |
| `httpfwd.go`  | HTTP-Forward, SSE-Parsing, Session-Re-Init        |
| `proxy.go`    | stdio-Loop, Slug-/Projekt-Detection               |
| `poll.go`     | Agent-Inbox-Polling, atomare File-Writes, ACK     |
| `util.go`     | Helfer                                            |

Parität-Referenz: `src/proxy/*.pas` (Delphi-Original, v1.0.6).
