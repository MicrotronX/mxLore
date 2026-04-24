# mxLore

Self-hosted MCP server for AI-assisted software development. Stores architectural decisions, specs, plans, findings, and lessons learned — accessed via [Model Context Protocol](https://modelcontextprotocol.io/) tools from AI coding assistants. Works with claude.ai, Claude Code, Cursor, Windsurf, and any MCP client.

> **New here?** Check out the **[product overview at mxlore.dev](https://www.mxlore.dev)** first — see what mxLore does, how it compares, and why your AI assistant needs a memory.

## Features

- **45 MCP Tools** — search, create, update, recall knowledge across projects
- **Multi-Project** — one server, many codebases, cross-project search
- **Skill Evolution** — tracks which AI checker rules actually help, auto-tunes
- **Institutional Memory** — lessons learned with recall, gate levels, graph-based knowledge links
- **Multi-Agent** — agents communicate across projects via message bus
- **Admin UI** — web dashboard for team members, keys, projects, intelligence metrics
- **Team Connect** — invite links with rate-limited landing page, one-click setup for Claude Code, claude.ai, Cursor, and more
- **Semantic Search** — hybrid vector + full-text search (MariaDB 11.6+ with VECTOR support)
- **AI Batch** — automatic summaries, tagging, stale detection at boot time
- **Works in claude.ai** — CTOs and PMs use mxLore from a chat window, developers from Claude Code — same server, same knowledge

## Install the Server

**Prerequisites:** Windows x64, MariaDB 10.6+.

| Step | What | Details |
|------|------|---------|
| **1** | Install MariaDB | [mariadb.org/download](https://mariadb.org/download/) (Windows MSI) |
| **2** | Create database | `mysql -u root -p -e "CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"` |
| **3** | Configure | `copy mxLoreMCP.ini.example mxLoreMCP.ini` — set `Password=` to your MariaDB root password |
| **4** | Start | `mxLoreMCP.exe` — auto-detects MariaDB, creates schema, starts on port 8080 + 8081 |

The console should show `Admin server listening on 127.0.0.1:8081`. **You're halfway there — don't stop.**

## First Start — From Running Server to Connected AI

> ⚠️ **The server is running, but your AI can't talk to it yet.** The API key you need lives inside the Admin UI. Here's how to pick it up and hand it to Claude Code.

1. **Open the Admin UI** → browse to **<http://localhost:8081>**.
   First start has no login (no team members exist yet, so the UI opens directly).
2. **Create your first team member** — click **"New member"**, enter a name, save. An invite dialog appears right after.
3. **Copy the API key** — format `mxk_...`. You'll paste this into Claude Code in the next step.
4. **Connect Claude Code** — in any Claude Code session, run:
   ```
   /mxSetup mxk_your_api_key_here
   ```
   `mxSetup` downloads the 12 skills, installs the proxy, and writes your `.claude/settings.json`. Takes ~15 seconds.
5. **Verify the handshake** — ask Claude: *"ping the mxLore server"*. You should see `version: 2.4.0` come back.

**That's it.** Your AI now has persistent memory across sessions.

**Other clients (claude.ai, Cursor, Windsurf, team invites):** [Team Onboarding Guide](docs/team-onboarding.md)
**Full walkthrough:** [Installation Guide](docs/installation.md) | **Problems?** [Troubleshooting](docs/troubleshooting.md)

## Documentation

| Guide | Description |
|-------|-------------|
| **[Installation Guide](docs/installation.md)** | Step-by-step setup with MariaDB, configuration, first boot |
| **[Team Onboarding](docs/team-onboarding.md)** | Connect Claude Code, claude.ai, Cursor + invite team members |
| **[Troubleshooting](docs/troubleshooting.md)** | Common issues and solutions |
| **[mxlore.dev](https://www.mxlore.dev)** | Product overview, feature comparison, pricing |

## Network Security

| Scenario | Setup |
|----------|-------|
| **Localhost** (single user) | HTTP is fine. Default: `BindAddress=127.0.0.1` |
| **LAN** (team) | Set `BindAddress=0.0.0.0` in INI. HTTP OK on trusted networks. |
| **WAN / Cloud** | **HTTPS required.** Use a reverse proxy (IIS, nginx, Apache) with TLS. |

## Architecture

- **Stack:** Delphi (RAD Studio) + TMS Sparkle + FireDAC + MariaDB
- **Protocol:** MCP 2024-11-05 (JSON-RPC 2.0 over HTTP+SSE)
- **Auth:** PBKDF2-HMAC-SHA256 API keys, per-project ACL
- **Units:** 65 Delphi units, dot-notation (`mx.*.pas`), 5 layers

## Skills

12 Claude Code skills via [mxLore-skills](https://github.com/MicrotronX/mxLore-skills) (MIT licensed), listed in the order you typically use them:

| # | Skill | When you use it |
|---|-------|-----------------|
| 1 | `/mxSetup` | **Install everything** — run once per host. Downloads skills, hooks, proxy, patches `settings.json`. |
| 2 | `/mxInitProject` | Register a new project in mxLore (creates slug, scaffolds `CLAUDE.md`). |
| 3 | `/mxOrchestrate` | **Session manager.** Run `--resume` at session start to load briefing + context and pick up open workflows. Run `start ad-hoc "<summary>"` at the start of any substantial task — it wraps the work, tracks every step below as a workflow entry, and keeps session state across compacts. |
| 4 | `/mxSpec` | Write a specification for a feature before planning. |
| 5 | `/mxPlan` | Turn a spec into a step-by-step implementation plan. |
| 6 | `/mxDecision` | Capture an architectural decision (ADR) the moment you make it. |
| 7 | `/mxDesignChecker` | Review code/design against the spec before you ship. |
| 8 | `/mxBugChecker` | Find bugs with verified proof (no hand-waving). |
| 9 | `/mxSave` | End-of-session persistence — state, lessons, session notes into the DB. |
| 10 | `/mxHealth` | Periodic consistency check on the knowledge DB and local docs. |
| 11 | `/mxMigrateToDb` | One-time migration of legacy `docs/*.md` files into MCP. |
| 12 | `/mxHelp` | Lists installed mx*-skills grouped by category, or explains one in detail. |

Install all at once: run `/mxSetup` in Claude Code.

## License

**Server:** BSL 1.1 (Business Source License) — [LICENSE.txt](LICENSE.txt)
- Source available: read, review, modify, build
- Non-commercial use: free (personal projects, open source, students, evaluation)
- Commercial use: **EUR 149 one-time** — any size team, unlimited everything. Contact info@microtronx.com
- After the change date (4 years): converts to Apache 2.0

**Skills:** MIT — fully open source, no restrictions.

**Pre-built binaries:** No Delphi or TMS license needed. Download from [GitHub Releases](https://github.com/MicrotronX/mxLore/releases).

## Links

- **[mxlore.dev](https://www.mxlore.dev)** — Features, demo, pricing
- [MicrotronX/mxLore](https://github.com/MicrotronX/mxLore) — Server source
- [MicrotronX/mxLore-skills](https://github.com/MicrotronX/mxLore-skills) — Claude Code skills (MIT)
- [MicrotronX](https://github.com/MicrotronX) — More tools
