# Project CLAUDE.md Template

Use this template when creating a new CLAUDE.md (file does not yet exist).
Substitute the placeholder `[INSERT AI-START-HERE BLOCK]` with the actual block
from `assets/ai-start-here-mcp.md` (MCP mode) or `assets/ai-start-here-local.md`
(non-MCP mode) BEFORE writing the file. Never write the literal placeholder
string to disk.

ONLY project-specific info. No global rules (security, encoding, etc.) — those
live in `~/.claude/CLAUDE.md`.

```markdown
# <ProjectName>

[INSERT AI-START-HERE BLOCK]

## Project

- **Slug:** <slug>
- **Stack:** <detected stack, e.g. "Delphi + FireDAC" or "PHP + Laravel">
- **Status:** Initialized

## Architecture

_(will be expanded as the project progresses)_

## Rules (project-specific)

_(only rules that apply ONLY to this project, do not duplicate global rules)_
```

## Assembly steps

1. Detect MCP mode (mx_ping success = MCP, otherwise non-MCP).
2. Pick the matching block: `ai-start-here-mcp.md` or `ai-start-here-local.md`.
3. Replace `[INSERT AI-START-HERE BLOCK]` in the template with the chosen block
   verbatim.
4. Write the assembled content to `CLAUDE.md`.
