# mxLore

Self-hosted MCP server for AI-assisted software development. Stores architectural decisions, specs, plans, findings, and lessons learned — accessed via [Model Context Protocol](https://modelcontextprotocol.io/) tools from AI coding assistants. Works with claude.ai, Claude Code, Cursor, Windsurf, and any MCP client.

> **New here?** Check out the **[product overview at mxlore.dev](https://www.mxlore.dev)** first — see what mxLore does, how it compares, and why your AI assistant needs a memory.

## Features

- **39 MCP Tools** — search, create, update, recall knowledge across projects
- **Multi-Project** — one server, many codebases, cross-project search
- **Skill Evolution** — tracks which AI checker rules actually help, auto-tunes
- **Institutional Memory** — lessons learned with recall, gate levels, graph-based knowledge links
- **Multi-Agent** — agents communicate across projects via message bus
- **Admin UI** — web dashboard for developers, keys, projects, intelligence metrics
- **Team Connect** — invite links with rate-limited landing page, one-click setup for Claude Code, claude.ai, Cursor, and more
- **AI Batch** — automatic summaries, tagging, stale detection at boot time
- **Works in claude.ai** — CTOs and PMs use mxLore from a chat window, developers from Claude Code — same server, same knowledge

## Quick Start (5 minutes)

### Prerequisites

- Windows x64
- MariaDB 10.6+ (recommended: 11.x with vector support for semantic search)
- Claude Code CLI, claude.ai, or any MCP client

### 1. Install MariaDB

Download the Windows MSI installer from [mariadb.org/download](https://mariadb.org/download/) (choose "MariaDB Server" for Windows x86_64). During installation:
- Set a **root password** — you'll need this in step 2
- Keep the default port (3306) and service name
- Select "Enable access from remote machines" only if you plan to run mxLore on a different machine

After installation, open a command prompt and create the database:

```bash
mysql -u root -p -e "CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

Enter the root password you set during installation.

### 2. Configure

Copy and edit the config template:

```bash
copy mxLoreMCP.ini.example mxLoreMCP.ini
```

Set your MariaDB root password (the one from step 1) in `mxLoreMCP.ini`:

```ini
[Database]
Password=your_mariadb_root_password
```

That's the only required change. MariaDB client library (`libmariadb.dll`) is auto-detected from your installation.

### 3. Start

```bash
mxLoreMCP.exe
```

The server will:
- Auto-detect your MariaDB installation (registry, common paths)
- Create the database schema automatically on first boot
- Start the MCP server on port 8080
- Start the Admin UI on port 8081

### 4. Verify

Open `http://localhost:8081` in your browser. You should see the Admin UI login page (or the dashboard directly on first start with no developers).

Quick API test from command line:

```bash
curl http://localhost:8080/mcp -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}},\"id\":1}"
```

You should see a JSON response with `"name":"mxLore"` — the server is running.

### 5. First Setup

The Admin UI is open without login on first start (no team members yet). Create your first team member and API key. Copy the API key — you'll need it to connect AI clients.

### 6. Connect Claude Code

Download the setup skill (one-time):

```bash
# Windows (PowerShell)
mkdir "$env:USERPROFILE\.claude\skills\mxSetup" -Force
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/MicrotronX/mxLore-skills/main/mxSetup/SKILL.md" -OutFile "$env:USERPROFILE\.claude\skills\mxSetup\SKILL.md"

# Linux / macOS
mkdir -p ~/.claude/skills/mxSetup
curl -o ~/.claude/skills/mxSetup/SKILL.md https://raw.githubusercontent.com/MicrotronX/mxLore-skills/main/mxSetup/SKILL.md
```

Then in Claude Code, run:

```
/mxSetup
```

Enter your server URL (`http://localhost:8080/mcp`) and API key when prompted. mxSetup installs all remaining skills, hooks, proxy, and configures the MCP connection automatically.

### 7. Invite Team Members

Open the Admin UI (`http://localhost:8081`), go to **Connect Team**, and generate an invite link. Send the link to your team — the landing page shows copy-paste instructions for their client (Claude Code, claude.ai, Cursor, etc.).

## Network Security

| Scenario | Setup |
|----------|-------|
| **Localhost** (single developer) | HTTP is fine. Default: `BindAddress=127.0.0.1` |
| **LAN** (team, internal network) | Change `BindAddress=0.0.0.0` in INI. HTTP acceptable if network is trusted. |
| **WAN / Cloud** (public internet) | **HTTPS required.** Use a reverse proxy (IIS, nginx, Apache) with TLS certificates. |

## Password Security

The INI file supports two formats for database and API passwords:

- **Plain text** (default, simplest): `Password=mypassword`
- **XOR obfuscation** (optional): `PasswordEnc=<hex>` — generate with `mxLoreMCP.exe --encrypt "mypassword"`

> **Note:** XOR obfuscation prevents casual reading of passwords in the INI file. It is NOT encryption. For real security, restrict file system access to `mxLoreMCP.ini`. Plain text passwords in the INI are automatically XOR-obfuscated on first boot.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **"libmariadb.dll not found"** | The server auto-detects it from your MariaDB installation (registry, `C:\Program Files\MariaDB*`). If auto-detection fails, copy `libmariadb.dll` from your MariaDB `lib/` directory into the mxLore `lib/` folder. |
| **"Connection refused" on port 8080/8081** | Check Windows Firewall: allow inbound TCP for ports 8080 and 8081. For LAN access, set `BindAddress=0.0.0.0` in the INI. |
| **Schema creation fails on first boot** | Ensure the database `mxai_knowledge` exists (step 1). Check the MariaDB password in the INI matches your root password. Check `logs/` for detailed error messages. |
| **Admin UI shows blank page** | Ensure `admin/www/` folder with all HTML/CSS/JS files is next to the EXE. The server serves these files directly. |
| **"Port 8080 already in use"** | Another application uses port 8080. Change `Port=8080` in the INI `[Server]` section to a free port (e.g. 9080). Admin port is always Server port + 1. |
| **MariaDB auto-detect picks wrong version** | Set `VendorHome=C:\Program Files\MariaDB 11.6` explicitly in the INI `[Database]` section. |

## Architecture

- **Stack:** Delphi (RAD Studio) + TMS Sparkle + FireDAC + MariaDB
- **Protocol:** MCP 2024-11-05 (JSON-RPC 2.0 over HTTP+SSE)
- **Auth:** PBKDF2-HMAC-SHA256 API keys, per-project ACL
- **Units:** 53 Delphi units, dot-notation (`mx.*.pas`), 5 layers

## Directory Structure

```
mxLoreMCP.exe          — Server (console)
mxLoreMCPGui.exe       — Server (GUI with tray icon)
mxLoreMCP.ini          — Configuration (create from .example)
mxLoreMCP.ini.example  — Config template with documentation
sql/
  setup.sql            — Database schema (auto-run on first boot)
admin/
  www/                 — Admin UI (HTML/CSS/JS, served by the server)
lib/
  libmariadb.dll     — MariaDB client (or auto-detected from your MariaDB installation)
logs/                  — Auto-created, log rotation at 5 MB
backups/               — Auto-created, mysqldump backups
```

## Skills (separate repo: [mxLore-skills](https://github.com/MicrotronX/mxLore-skills))

11 Claude Code skills for AI-assisted workflows:

| Skill | Purpose |
|-------|---------|
| `/mxOrchestrate` | Session orchestrator — workflows, ad-hoc tasks, team agents |
| `/mxSave` | Persist session state to DB |
| `/mxPlan` | Create implementation plans |
| `/mxSpec` | Write specifications |
| `/mxDecision` | Document architectural decisions (ADRs) |
| `/mxDesignChecker` | Review code/design against specs |
| `/mxBugChecker` | Find bugs with verification |
| `/mxHealth` | Knowledge DB consistency checks |
| `/mxSetup` | Developer onboarding (installs skills + proxy) |
| `/mxInitProject` | Bootstrap new project in DB |
| `/mxMigrateToDb` | Migrate local docs to MCP |

Install all via: `/mxSetup` in Claude Code.

### Using claude.ai (web/desktop)

mxLore also works with claude.ai — no terminal needed:

1. Open claude.ai → Settings → Integrations → Add MCP Server
2. Name: `mxLore`
3. URL: `http://your-server:8080/mcp`
4. Auth Header: `Authorization: Bearer mxk_your_api_key`

All 39 MCP tools are available in claude.ai conversations. Available on Claude Pro, Team, and Enterprise plans. Note: Skills (`/mxOrchestrate` etc.) are Claude Code only.

## License

**Server:** BSL 1.1 (Business Source License) — see [LICENSE.txt](LICENSE.txt)
- Source available: read, review, modify
- Pre-built binaries: no Delphi or TMS license needed
- Non-commercial use (personal projects, open source, students, evaluation): free
- Commercial use: €149 one-time — any size team, unlimited everything. Contact info@microtronx.com
- After the change date (4 years), converts to Apache 2.0

**Skills:** MIT — fully open source, no restrictions. See [mxLore-skills](https://github.com/MicrotronX/mxLore-skills).

**Important:** To compile the server from source, you need RAD Studio (Delphi) and TMS Sparkle — both are commercial products. Most users should use the pre-built binaries from [GitHub Releases](https://github.com/MicrotronX/mxLore/releases), which have no such requirement.

### Third-Party

- `libmariadb.dll` — MariaDB Connector/C, LGPL 2.1. [Source](https://github.com/mariadb-corporation/mariadb-connector-c). Not bundled — auto-detected from your MariaDB installation.

## Why mxLore?

AI coding assistants forget everything between sessions. Your specs, decisions, lessons learned — gone. mxLore gives your AI a persistent knowledge base it can search, recall, and learn from. Self-hosted, your data stays yours.

**[See how it works at mxlore.dev](https://www.mxlore.dev)** — features, comparison, quick start guide.

## Links

- **[mxlore.dev](https://www.mxlore.dev)** — Features, demo, documentation
- [MicrotronX/mxLore](https://github.com/MicrotronX/mxLore) — Server source code
- [MicrotronX/mxLore-skills](https://github.com/MicrotronX/mxLore-skills) — Claude Code skills
- [MicrotronX](https://github.com/MicrotronX) — More tools by MicrotronX
