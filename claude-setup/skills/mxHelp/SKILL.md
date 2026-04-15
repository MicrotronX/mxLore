---
name: mxHelp
description: Use when the user says "/mxHelp", "/mxHelp <name>", or asks which mx-skill does what. Lists all installed mx*-skills grouped by category, or explains one skill in detail. Pure reader — no side effects.
allowed-tools: Glob, Grep, Read
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

⚡ **Tool budget: max 2 tool calls (1× Glob + 1× Grep). NO per-file Reads. NO Bash.** Each Read on a fresh session triggers a permission prompt — multiplied by N skills this is unusable. Stay within Glob+Grep.

- **Zero-result handling:** If Glob returns zero matches OR all matches are filtered out by the allowlist, render exactly: `No public mx*-skills installed. Run /mxSetup to install the mxLore-skills bundle.` and return. Do NOT render empty category headers.

1. **Glob (1 call):** `~/.claude/skills/mx*/SKILL.md` — case-insensitive on Windows NTFS. Confirms which skills exist on disk.
2. **Grep (1 call) — extract all frontmatter at once:**
   - `pattern: '^(name|description):'`
   - `path: '~/.claude/skills'`
   - `glob: 'mx*/SKILL.md'`
   - `output_mode: 'content'`
   - `-n: true` (line numbers)
   - Result: every `name:` and `description:` line for ALL mx-skills in a single tool call. Format: `<filepath>:<lineno>:<content>`
   - **Malformed frontmatter handling:** if a SKILL.md is missing `name:` or `description:` → render as `<dirname> — (no frontmatter)` and continue. NEVER abort the entire list. NEVER hallucinate field values.
3. **Filter against allowlist:** parse the grep output, group `name`/`description` pairs by file path. For each, compare the `name` value against the Public Skill Allowlist (case-insensitive). Skills NOT in allowlist → silently skip (private/customer-only).
4. **Render** compact bulleted list grouped by category from the allowlist:
   ```
   ## Core workflow
   - **mxPlan** — <first sentence of description>
   - **mxSpec** — ...
   ```
5. Default truncation: stop at first '.', '!', '?' OR at 120 UTF-8 codepoints (NEVER split a multi-byte sequence). Whichever comes first.
6. With `--verbose`: full description, no truncation.
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
- ⚡ **Tool budget — List mode: max 2 calls (1 Glob + 1 Grep). Detail mode: max 2 calls (1 Glob + 1 Read).** Exceeding the budget = bug. NEVER use Bash. NEVER use per-file Read in List mode.
- ⚡ **Output language: match the user's prompt language.** This SKILL.md is in English for sync hygiene (public mxLore-skills GitHub repo requires English), but the rendered output (category headers, descriptions, footer tip, error messages) MUST be translated to match the user's language. If the user wrote in German → render German. Italian → Italian. English → English. Default English when the language is ambiguous.
- !duplicate skill content — only render what already exists in SKILL.md
- !invent skills — if an allowlisted skill does not exist on disk, omit from render AND append a one-line footer warning (in the user's language): `Note: public allowlist references N missing skill(s): <names>` (surfaces drift without breaking reads)
- Include `mxHelp` itself in the list under "Discoverability"
