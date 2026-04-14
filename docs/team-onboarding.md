# Team Onboarding

How to connect AI clients to your mxLore server and onboard team members.

## Which client should I pick?

| You are… | Use… | Why |
|---|---|---|
| Developer writing code | **Claude Code** (CLI) | Full skill set — `/mxPlan`, `/mxSave`, `/mxBugChecker`, `/mxOrchestrate`, etc. This is the primary mxLore experience. |
| PM / CTO / Architect — reading, searching, documenting from a browser | **claude.ai** (web / desktop) | No terminal. Raw MCP tools for search and document creation. **No skills**, no orchestration, no session state. |
| Cursor / Windsurf / Cline user | Manual JSON below | Basic MCP tool access, no skills, no proxy. |

> **Important:** The real value of mxLore is in the **skills** (`/mxPlan`, `/mxDecision`, `/mxSave`, `/mxHealth`, etc.). Skills only run in Claude Code. claude.ai and Cursor get the raw 39 MCP tools and have to invoke them manually. If you're a developer, start with Claude Code — don't pick claude.ai "because it's simpler", you'll miss the whole orchestration layer.

## Before you start: Get an API key

Every host (laptop, workstation, CI runner) that connects to mxLore needs **its own API key**. Keys are issued by an admin from the Admin UI; one developer can hold multiple keys, one per host, each individually revocable.

### If you're the admin (or a solo installer)

1. Open the **Admin UI** at **<http://localhost:8081>** (or whatever URL your server uses).
2. **Team Members → "New member"** — enter the team member's name, save.
   *First-time install?* You are automatically the first member and an admin key is created for you and shown prominently.
3. **For each host the member works on**, click **"New Key"**:
   - **Name:** something host-specific, e.g. `laptop-alice`, `office-desktop`, `ci-runner`. You will see this label later when revoking access.
   - **Permissions:** `readwrite` (standard) or `readonly`.
   - **Expires:** optional.
4. Copy the generated `mxk_…` key and send it to the team member through a secure channel (password manager, encrypted chat, etc.).

> **Faster path — Team Connect invite links:** Instead of sending raw keys, the admin can generate a one-time invite link (see [Invite Team Members](#invite-team-members) below). The link opens a landing page with copy-paste instructions pre-filled for the member's client of choice. Preferred for onboarding multiple people.

### If you're a team member

Ask your admin for an API key (or an invite link). If they give you a raw `mxk_…` key, keep reading. If they send you an invite URL, open it in a browser and follow the on-screen instructions — the page has the copy-paste for your client pre-filled.

---

## Connect Claude Code (recommended for developers)

**Prerequisites:** Node.js installed (required by 5 of 8 hooks). Get it from <https://nodejs.org>. Without Node, the session still works but state tracking, Recall-Gate, and Orchestrator are disabled.

### Step 1 — Bootstrap the mxSetup skill (one-time, per host)

mxSetup is the skill that installs everything else. You only need to fetch **this one file** by hand — from then on, mxSetup handles skills, hooks, proxy, and settings.

```bash
# Windows (PowerShell)
mkdir "$env:USERPROFILE\.claude\skills\mxSetup" -Force
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/MicrotronX/mxLore-skills/main/mxSetup/SKILL.md" -OutFile "$env:USERPROFILE\.claude\skills\mxSetup\SKILL.md"

# Linux / macOS / Git Bash
mkdir -p ~/.claude/skills/mxSetup
curl -o ~/.claude/skills/mxSetup/SKILL.md https://raw.githubusercontent.com/MicrotronX/mxLore-skills/main/mxSetup/SKILL.md
```

### Step 2 — Run /mxSetup with your API key

In any Claude Code session:

```
/mxSetup mxk_your_api_key_here
```

mxSetup will:
1. **Ask for the server URL** — enter something like `http://localhost:8080/mcp` (local install) or `http://your-server:8080/mcp` (remote). URL must end with `/mcp`.
2. Register the MCP connection (`claude mcp add … -s user`).
3. Download the full skill set (`/mxOrchestrate`, `/mxPlan`, `/mxSpec`, `/mxDecision`, `/mxSave`, `/mxDesignChecker`, `/mxBugChecker`, `/mxHealth`, `/mxInitProject`, `/mxMigrateToDb`) from GitHub.
4. Install the hooks into `~/.claude/hooks/`.
5. Download `mxMCPProxy.exe` from your server (via `proxy_download_url` from `mx_ping`).
6. Switch the MCP connection from direct HTTP to the local proxy.
7. Patch `~/.claude/settings.json` with the required permissions, hooks, and status line — preserving existing entries, never overwriting.

Total time: ~30 seconds.

### Step 3 — Restart and verify

1. Quit and restart Claude Code so hooks and skills are loaded fresh.
2. Switch to a project directory.
3. Ask Claude: *"ping the mxLore server"* — you should see `version: 2.4.0` and your server URL.
4. Run `/mxInitProject` to register the current directory in mxLore.

### Updating later

When a new version ships, run `/mxSetup --update` (no key argument). It refreshes skills, hooks, settings, and proxy without touching your MCP connection.

### Manual Claude Code setup (advanced, not recommended)

If you cannot or will not use `/mxSetup`, add this to `~/.claude/settings.json` manually:

```json
{
  "mcpServers": {
    "mxai-knowledge": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "Bearer mxk_your_api_key"
      }
    }
  }
}
```

This gets you the raw 39 MCP tools but **no skills, no hooks, no proxy, no status line**. You are on your own.

---

## Connect claude.ai (for browser-based read / search / document)

Use this if you want to use mxLore from the claude.ai web or desktop app without a terminal. Good fit for **PMs, CTOs, architects, and reviewers** who consume and annotate existing knowledge but don't run Claude Code. **Not a replacement for Claude Code if you write code** — you will lose all the skill automation.

1. Open [claude.ai](https://claude.ai) → Settings → Integrations → **Add MCP Server**.
2. **Name:** `mxLore`
3. **URL:** `http://your-server:8080/mcp?api_key=mxk_your_api_key`

> **INI setting required:** claude.ai uses URL-based authentication (key in the query string). Make sure `AllowUrlApiKey=1` is set under `[Security]` in `mxLoreMCP.ini` on the server side. Over HTTPS this is safe; over plain HTTP only use it inside a trusted network.

All 39 MCP tools are available in claude.ai conversations. Available on Claude Pro, Team, and Enterprise plans.

**What you get:** `mx_search`, `mx_create_doc`, `mx_recall`, `mx_briefing`, `mx_graph_query`, etc. — invoked by name or let Claude pick them.

**What you don't get:** Any skill. `/mxOrchestrate`, `/mxPlan`, `/mxSave`, `/mxDecision`, `/mxDesignChecker`, `/mxBugChecker`, `/mxHealth` are Claude-Code-only. If you want plans, specs, decisions, or session state, either also install Claude Code on one machine, or ask a Claude Code user to run those skills for you.

---

## Connect Cursor / Windsurf / Cline

Add to your MCP configuration (usually `.cursor/mcp.json` or similar):

```json
{
  "mcpServers": {
    "mxai-knowledge": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "Bearer mxk_your_api_key"
      }
    }
  }
}
```

Raw MCP tools only — no skills, no proxy, no hooks.

## Connect Other MCP Clients

Any MCP-compatible client can connect using:

- **URL:** `http://your-server:8080/mcp`
- **Auth:** `Authorization: Bearer mxk_your_api_key` header
- **Protocol:** MCP 2024-11-05 (JSON-RPC 2.0 over HTTP)

---

## Invite Team Members

This section is for **admins** onboarding new team members. Instead of sending API keys manually, use the **Team Connect** feature to generate one-time invite links.

### Quick onboarding flow

The fastest way to onboard a new team member:

1. Open the Admin UI (`http://localhost:8081`).
2. Go to **Team Members** → click **"New member"**.
3. Enter name, role, click Create. The invite dialog opens automatically with the new member pre-selected.
4. Set expiry (24h / 48h / 7d), click **Generate**.
5. Copy the invite link and send it to the new member.

The new member opens the link and sees a landing page with copy-paste instructions for their specific client (Claude Code, claude.ai, Cursor, etc.). One click to copy, done.

### Manual invite (existing member, additional host)

If a member already exists and just needs a key for an additional host:

1. Admin UI → **Team Members** → open the member.
2. **"New Key"** → name it after the host (e.g. `laptop-alice`, `ci-runner`), pick permissions, optional expiry.
3. Send the `mxk_…` key to the member through a secure channel.

### Invite lifecycle

```
Created → Viewed → Confirmed → (auto-archived)
                               └→ Expired (if not used in time)
           └→ Revoked (by admin)
```

- **Active invites** show a lifecycle strip (invited → viewed → confirmed).
- **Confirmed invites** move to history automatically.
- **Revoked / expired** invites can be deleted individually or via "Clear History".

---

## Skills Overview

11 Claude Code skills for AI-assisted workflows — installed automatically by `/mxSetup`:

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
