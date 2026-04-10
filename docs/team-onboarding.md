# Team Onboarding

How to connect AI clients to your mxLore server and invite team members.

## Connect Claude Code

### Automatic setup (recommended)

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

Enter your server URL (`http://localhost:8080/mcp`) and API key when prompted. mxSetup installs all 11 skills, hooks, proxy, and configures the MCP connection automatically.

### Manual setup

If you prefer manual configuration, add to your `.claude/settings.json`:

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

## Connect claude.ai

mxLore works with claude.ai (web and desktop app) — no terminal needed:

1. Open [claude.ai](https://claude.ai) → Settings → Integrations → **Add MCP Server**
2. Name: `mxLore`
3. URL: `http://your-server:8080/mcp?api_key=mxk_your_api_key`

> **Note:** claude.ai uses URL-based authentication. Ensure `AllowUrlApiKey=1` is set in the `[Security]` section of your INI file. This is safe because the URL is sent over HTTPS.

All 39 MCP tools are available in claude.ai conversations. Available on Claude Pro, Team, and Enterprise plans.

**Limitation:** Skills (`/mxOrchestrate`, `/mxSave`, etc.) are Claude Code only — they require the Claude Code CLI.

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

## Connect Other MCP Clients

Any MCP-compatible client can connect using:

- **URL:** `http://your-server:8080/mcp`
- **Auth:** `Authorization: Bearer mxk_your_api_key` header
- **Protocol:** MCP 2024-11-05 (JSON-RPC 2.0 over HTTP)

## Invite Team Members

Instead of sharing API keys manually, use the **Team Connect** feature:

1. Open the Admin UI (`http://localhost:8081`)
2. Go to **Connect Team**
3. Click **"New Invite"**
4. Select the team member, set expiry (24h/48h/7d), and click **Generate**
5. Copy the invite link and send it to your team member

The recipient opens the link and sees a landing page with copy-paste instructions for their specific client (Claude Code, claude.ai, Cursor, etc.). One click to copy, done.

### Invite lifecycle

```
Created → Viewed → Confirmed → (auto-archived)
                               └→ Expired (if not used in time)
           └→ Revoked (by admin)
```

- **Active invites** show a lifecycle strip (invited → viewed → confirmed)
- **Confirmed invites** move to history automatically
- **Revoked/expired** invites can be deleted individually or via "Clear History"

### Quick onboarding flow

The fastest way to onboard a new team member:

1. Go to **Team Members** → click **"New member"**
2. Enter name, role, click Create
3. The invite dialog opens automatically with the new member pre-selected
4. Generate the link and send it

The new member is connected in under a minute.

## Skills Overview

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

All skills are installed automatically by `/mxSetup`.
