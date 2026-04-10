# mxLore

Self-hosted MCP server for AI-assisted software development. Stores architectural decisions, specs, plans, findings, and lessons learned — accessed via [Model Context Protocol](https://modelcontextprotocol.io/) tools from AI coding assistants. Works with claude.ai, Claude Code, Cursor, Windsurf, and any MCP client.

> **New here?** Check out the **[product overview at mxlore.dev](https://www.mxlore.dev)** first — see what mxLore does, how it compares, and why your AI assistant needs a memory.

## Features

- **39 MCP Tools** — search, create, update, recall knowledge across projects
- **Multi-Project** — one server, many codebases, cross-project search
- **Skill Evolution** — tracks which AI checker rules actually help, auto-tunes
- **Institutional Memory** — lessons learned with recall, gate levels, graph-based knowledge links
- **Multi-Agent** — agents communicate across projects via message bus
- **Admin UI** — web dashboard for team members, keys, projects, intelligence metrics
- **Team Connect** — invite links with rate-limited landing page, one-click setup for Claude Code, claude.ai, Cursor, and more
- **Semantic Search** — hybrid vector + full-text search (MariaDB 11.6+ with VECTOR support)
- **AI Batch** — automatic summaries, tagging, stale detection at boot time
- **Works in claude.ai** — CTOs and PMs use mxLore from a chat window, developers from Claude Code — same server, same knowledge

## Quick Start

**Prerequisites:** Windows x64, MariaDB 10.6+, any MCP client.

| Step | What | Details |
|------|------|---------|
| **1** | Install MariaDB | [mariadb.org/download](https://mariadb.org/download/) (Windows MSI) |
| **2** | Create database | `mysql -u root -p -e "CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"` |
| **3** | Configure | `copy mxLoreMCP.ini.example mxLoreMCP.ini` — set `Password=` to your MariaDB root password |
| **4** | Start | `mxLoreMCP.exe` — auto-detects MariaDB, creates schema, starts on port 8080 + 8081 |
| **5** | Verify | Open `http://localhost:8081` — Admin UI should appear |
| **6** | Create member | First start has no login. Create a team member + API key |
| **7** | Connect client | **[Team Onboarding Guide](docs/team-onboarding.md)** — Claude Code, claude.ai, Cursor, etc. |

**Detailed instructions:** [Installation Guide](docs/installation.md) | **Problems?** [Troubleshooting](docs/troubleshooting.md)

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
- **Units:** 53 Delphi units, dot-notation (`mx.*.pas`), 5 layers

## Skills

11 Claude Code skills via [mxLore-skills](https://github.com/MicrotronX/mxLore-skills) (MIT licensed):

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
| `/mxSetup` | Team member onboarding (installs all skills + proxy) |
| `/mxInitProject` | Bootstrap new project in DB |
| `/mxMigrateToDb` | Migrate local docs to MCP |

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
