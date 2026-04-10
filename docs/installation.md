# Installation Guide

Detailed instructions for setting up mxLore on a fresh Windows system.

> **Quick version:** See the [Quick Start](../README.md#quick-start) in README.md.

## Prerequisites

- **Windows x64** (Server 2019+, Windows 10/11)
- **MariaDB 10.6+** (recommended: 11.x for semantic search with VECTOR support)
- **Claude Code CLI**, claude.ai, Cursor, or any MCP-compatible client

## Step 1: Install MariaDB

Download the Windows MSI installer from [mariadb.org/download](https://mariadb.org/download/):
- Choose **"MariaDB Server"** for Windows x86_64
- Pick the latest 11.x stable release

During installation:
1. Set a **root password** and write it down — you'll need it in step 3
2. Keep the default port **3306** and service name
3. Check **"Enable access from remote machines"** only if mxLore will run on a different machine
4. Leave everything else at defaults

### Create the database

After installation, open a command prompt (or PowerShell) and run:

```bash
mysql -u root -p -e "CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

Enter the root password you set during installation. You should see no output (success).

**Verify:** `mysql -u root -p -e "SHOW DATABASES;"` should list `mxai_knowledge`.

## Step 2: Extract mxLore

Download the latest release ZIP from [GitHub Releases](https://github.com/MicrotronX/mxLore/releases) and extract it to a directory of your choice, e.g. `C:\mxLore\`.

You should see:

```
mxLoreMCP.exe          — Server (console mode)
mxLoreMCPGui.exe       — Server (GUI with tray icon)
mxLoreMCP.ini.example  — Configuration template
sql/setup.sql          — Database schema
admin/www/             — Admin UI files
claude-setup/          — Skills, hooks, proxy for Claude Code
```

## Step 3: Configure

```bash
copy mxLoreMCP.ini.example mxLoreMCP.ini
```

Open `mxLoreMCP.ini` in a text editor and set your MariaDB root password:

```ini
[Database]
Password=your_mariadb_root_password
```

**That's the only required change.** All other defaults work out of the box:
- `Host=localhost` / `Port=3306` — standard MariaDB
- `Database=mxai_knowledge` — matches the database you created
- `BindAddress=127.0.0.1` — secure localhost-only access
- MariaDB client library (`libmariadb.dll`) is auto-detected from your installation

### Optional: Team / LAN access

If other machines need to connect to mxLore:

```ini
[Server]
BindAddress=0.0.0.0
```

See [Network Security](../README.md#network-security) for HTTPS requirements.

## Step 4: First Start

```bash
mxLoreMCP.exe
```

Or double-click `mxLoreMCPGui.exe` for the GUI version with tray icon.

The server will:
1. Auto-detect your MariaDB installation (checks registry, `C:\Program Files\MariaDB*`, common paths)
2. Create all database tables automatically on first boot (using `sql/setup.sql`)
3. XOR-obfuscate the plain text password in the INI (auto-encrypt)
4. Start the **MCP server** on port 8080
5. Start the **Admin UI** on port 8081
6. Log everything to `logs/mxLoreMCP.log`

### What to expect

Console output should show:

```
INFO  mxLore v2.4.0 (Build 80) starting...
INFO  Database connected: mxai_knowledge@localhost
INFO  Auto-schema: setup.sql executed (fresh install)
INFO  MCP server listening on 127.0.0.1:8080
INFO  Admin server listening on 127.0.0.1:8081
```

If you see errors, check [Troubleshooting](troubleshooting.md).

## Step 5: Verify

Open `http://localhost:8081` in your browser. You should see the Admin UI.

**API test** from command line:

```bash
curl http://localhost:8080/mcp -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}},\"id\":1}"
```

Expected: JSON response containing `"name":"mxLore"` and `"version":"2.4.0"`.

## Step 6: Create First Team Member

The Admin UI is open without login on first start (no team members exist yet).

1. Click **"New member"** in the Team Members page
2. Enter a name, optional email, and role
3. After creation, you'll be taken to **Connect Team** with an invite dialog
4. Generate an invite link or create an API key manually

**Copy your API key** — you'll need it to connect AI clients.

## Step 7: Connect Your AI Client

See [Team Onboarding](team-onboarding.md) for detailed instructions for each client:
- Claude Code (`/mxSetup`)
- claude.ai (Settings > Integrations)
- Cursor / Windsurf (JSON config)
- Other MCP clients (Bearer header)

## Password Security

The INI file supports two password formats:

| Format | Example | Notes |
|--------|---------|-------|
| **Plain text** | `Password=mypassword` | Simplest. Auto-encrypted on first boot. |
| **XOR obfuscated** | `PasswordEnc=A1B2C3...` | Generate with `mxLoreMCP.exe --encrypt "mypassword"` |

> **Note:** XOR obfuscation prevents casual reading of passwords. It is NOT encryption. For real security, restrict file system access to `mxLoreMCP.ini`.

## Directory Structure (after first boot)

```
mxLoreMCP.exe           — Server (console)
mxLoreMCPGui.exe        — Server (GUI with tray icon)
mxMCPProxy.exe          — MCP proxy for Claude Code integration
mxLoreMCP.ini           — Your configuration
mxLoreMCP.ini.example   — Config template (reference)
sql/
  setup.sql             — Database schema (auto-run on first boot)
  043-embedding-vector.sql — Semantic search (MariaDB 11.6+, optional)
  044-tool-call-log.sql — MCP call metrics (auto-run)
admin/
  www/                  — Admin UI (HTML/CSS/JS, served by the server)
lib/
  libmariadb.dll        — MariaDB client (auto-detected or manually placed)
logs/                   — Auto-created, log rotation at 5 MB
backups/                — Auto-created, mysqldump backups
claude-setup/           — Skills, hooks, proxy, reference docs for Claude Code
```
