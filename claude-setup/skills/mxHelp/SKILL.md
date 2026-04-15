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
| (empty)         | List all public mx*-skills grouped by category |
| `<skillname>`   | Detail view: purpose + modes + examples for one skill |

## Mode 1: List (default, `--verbose` for full descriptions)

- **Zero-result handling:** If the glob returns zero matches OR all matches are filtered out by the allowlist, render exactly: `No public mx*-skills installed. Run /mxSetup to install the mxLore-skills bundle.` and return. Do NOT render empty category headers.

1. Glob: `~/.claude/skills/mx*/SKILL.md` (glob is case-insensitive on Windows NTFS; matches mxPlan, mxsave, MXSPEC alike. On case-sensitive Linux FS, exact casing required — but mxLore canonical is Windows-only.)
2. For each match: Read first ~15 lines, extract YAML frontmatter fields `name` and `description`.
   **Malformed frontmatter handling:** If a SKILL.md has no `---` block, broken YAML, or missing `name`/`description` fields → render as `<dirname> — (no frontmatter)` and continue. NEVER abort the entire list. NEVER hallucinate field values.
3. For each glob match, compare frontmatter name against the Public Skill Allowlist (case-insensitive). Skills NOT in allowlist → silently skip (private/customer-only). Skills in allowlist → group by their category from the allowlist table.
4. Render compact bulleted list grouped by category:
   ```
   ## Core workflow
   - **mxPlan** — <first sentence of description>
   - **mxSpec** — ...
   ```
5. Default truncation: stop at first '.', '!', '?' OR at 120 UTF-8 characters (NEVER split a multi-byte sequence — use codepoint count, not byte count). Whichever comes first.
6. With `--verbose`: full description, no truncation
7. Footer: `Tip: /mxHelp <name> for details on one skill.`

### Public Skill Allowlist

⚡ mxHelp ONLY renders skills from the public mxLore-skills GitHub bundle. Internal/customer-specific skills (mxerptrigger, mxTicketSystemHannes, etc.) are FILTERED OUT — they are not part of the public distribution and must not appear in mxHelp output.

| Category | Public skills (allowlist) |
|----------|---------------------------|
| Core workflow | mxPlan, mxSpec, mxDecision, mxSave, mxOrchestrate |
| Analysis | mxBugChecker, mxDesignChecker, mxHealth |
| Setup / Migration | mxSetup, mxInitProject, mxMigrateToDb, mxDelphiAnsi2UTF8 |
| Discoverability | mxHelp |

**Total public skills:** 13. Any glob match whose frontmatter `name` is NOT in this allowlist (case-insensitive compare) → SILENTLY SKIPPED. Do NOT render under "Other". Do NOT emit drift warnings for non-allowlisted skills — they are intentionally private.

**Drift warning ONLY fires** when an allowlisted skill is missing from disk: `Note: public allowlist references N missing skill(s): <names>` — this surfaces real distribution gaps.

## Mode 2: Detail (`/mxHelp <skillname>`)

1. **Sanitize** `<skillname>`: REJECT input containing `/`, `\`, `..`, or any absolute-path marker. Allowed pattern: `[A-Za-z0-9_-]+` only. On reject → respond "Invalid skill name: only alphanumeric + underscore + hyphen allowed" and stop.
2. **Normalize**: strip trailing `.md`, strip leading `/`. If no `mx` prefix → prepend `mx` and retry exact match before fuzzy.
3. **Allowlist check**: if the normalized name is NOT in the Public Skill Allowlist → respond "Skill `<name>` is not part of the public mxLore-skills bundle" and stop. Internal skills must not be discoverable via mxHelp.
4. Resolve path: `~/.claude/skills/<skillname>/SKILL.md` (case-insensitive match)
5. ∅exact match → glob `~/.claude/skills/mx*` →
   **Fuzzy match algorithm (specified):**
   1. Case-insensitive substring match against allowlist names → if 1+ matches, list up to 3 sorted by name length (shortest first)
   2. If 0 substring matches → Levenshtein distance ≤3 against allowlist → list up to 3 sorted by distance ascending
   3. If still 0 matches → respond "No public mx-skill matches `<query>`. Try `/mxHelp` for the full list."
   4. Tie-break: alphabetical
6. Read full file
7. Render structured sections:
   - **Purpose** — first paragraph after the H1 heading
   - **Modes / Arguments** — extract from any `## Modes` table or `## Mode N:` headings
   - **Examples** — first fenced code block after an "Example" or "Usage" heading; omit section entirely if none found
8. Footer: `Source: ~/.claude/skills/<name>/SKILL.md`

⚡ Detail mode is read-only. NO side effects. NO state writes. NO MCP calls.

## Rules
- Token discipline: List mode reads only the frontmatter region of each file (~15 lines × N skills).
- Detail mode reads ONE target file in full, no others.
- !duplicate skill content — only render what already exists in SKILL.md
- !invent skills — if an allowlisted skill does not exist on disk, omit from render AND append a one-line footer warning: `Note: public allowlist references N missing skill(s): <names>` (surfaces drift without breaking reads)
- Include `mxHelp` itself in the list under "Discoverability"
