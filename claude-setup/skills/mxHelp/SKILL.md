---
name: mxHelp
description: Use when the user says "/mxHelp", "/mxHelp <name>", or asks which mx-skill does what. Lists all installed mx*-skills grouped by category, or explains one skill in detail. Pure reader — no side effects.
---

# /mxHelp — mx-Skill Discoverability (AI-Steno: !=forbidden →=use ⚡=critical)

> Thin renderer over existing SKILL.md files. NO content authoring, NO MCP writes, NO state changes.
> Source of truth = each `~/.claude/skills/mx*/SKILL.md`. This skill only globs, parses frontmatter, and renders.

## Modes

| Argument | Mode |
|----------|------|
| (empty)         | List all mx*-skills grouped by category |
| `<skillname>`   | Detail view: purpose + modes + examples for one skill |

## Mode 1: List (default, `--verbose` for full descriptions)

1. Glob: `~/.claude/skills/mx*/SKILL.md` (glob is case-insensitive; matches mxPlan, mxsave, MXSPEC alike)
2. For each match: Read first ~15 lines, extract YAML frontmatter fields `name` and `description`
3. Map each `name` to a category (see table below). Unknown → "Other".
4. Render compact bulleted list grouped by category:
   ```
   ## Core workflow
   - **mxPlan** — <first sentence of description>
   - **mxSpec** — ...
   ```
5. Default truncation: first sentence or 120 chars, whichever is shorter
6. With `--verbose`: full description, no truncation
7. Footer: `Tip: /mxHelp <name> for details on one skill.`

### Category Mapping

| Category | Skills |
|----------|--------|
| Core workflow | mxPlan, mxSpec, mxDecision, mxSave, mxOrchestrate |
| Analysis | mxBugChecker, mxDesignChecker, mxHealth |
| Setup / Migration | mxSetup, mxInitProject, mxMigrateToDb, mxDelphiAnsi2UTF8 |
| Specialized | mxTicketSystemHannes, mxErpTrigger |
| Discoverability | mxHelp |

⚡ Skills not in the table → render under "Other" so new skills are still discoverable.

## Mode 2: Detail (`/mxHelp <skillname>`)

1. Normalize `<skillname>`: strip trailing `.md`, strip leading `/`. If no `mx` prefix → prepend `mx` and retry exact match before fuzzy
2. Resolve path: `~/.claude/skills/<skillname>/SKILL.md` (case-insensitive match)
3. ∅exact match → glob `~/.claude/skills/mx*` → fuzzy match (substring or Levenshtein) → list top 3 candidates → ask user
4. Read full file
5. Render structured sections:
   - **Purpose** — first paragraph after the H1 heading
   - **Modes / Arguments** — extract from any `## Modes` table or `## Mode N:` headings
   - **Examples** — first fenced code block after an "Example" or "Usage" heading; omit section entirely if none found
6. Footer: `Source: ~/.claude/skills/<name>/SKILL.md`

⚡ Detail mode is read-only. NO side effects. NO state writes. NO MCP calls.

## Rules
- Token discipline: List mode reads only the frontmatter region of each file (~15 lines × N skills).
- Detail mode reads ONE target file in full, no others.
- !duplicate skill content — only render what already exists in SKILL.md
- !invent skills — if a skill name in the category mapping does not exist on disk, omit from render AND append a one-line footer warning: `Note: category table references N missing skill(s): <names>` (surfaces drift without breaking reads)
- Include `mxHelp` itself in the list under "Discoverability"
