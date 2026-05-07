# Migration Mapping (doc_type / status / relations / excludes)

## doc_type Mapping (client-side)

| Filename pattern | doc_type |
|---|---|
| `PLAN-*` | plan |
| `SPEC-*` | spec |
| `ADR-*` | decision |
| `*session-notes*` | session_note |
| `workflow-log*` | workflow_log |
| Everything else | reference |

## Status Mapping (Content → DB)

| Content `**Status:**` | DB status |
|---|---|
| accepted | active |
| proposed | draft |
| active | active |
| completed | archived |
| superseded | superseded |
| deprecated | archived |
| paused | draft |
| cancelled | archived |
| (not found) | draft (default) |

## Relations Phase (after import loop)

After ALL files are imported, analyze Markdown links between documents:

1. For each imported document: Scan content for links to other docs/ files
   - Regex: `\[.*?\]\((.*?\.md)\)` (case-insensitive; reject matches where the captured path starts with `http://`, `https://`, or `//` — those are remote URLs, not local slugs). Also text patterns `(?i)\bsee\s+(plan|adr|spec)[-_]` for case-insensitive inline mentions.
2. Extract target slug from link path
3. Look up in import map (filename → doc_id)
4. If match: Call `mx_add_relation()`:
   - ADR → PLAN: `leads_to`
   - PLAN → PLAN: `leads_to`
   - SPEC → PLAN: `implements`
   - Other: `references`
5. Result: `N relations created`

## Excluded files (do NOT import)

- `index.md` (index files)
- `status.md` (stays local)
- `CLAUDE.md` (stays local)

## All other files

All *.md files that don't match a known prefix are imported as `reference`. This includes: design docs, findings, numbered session notes, brainstormings, meeting notes etc. **Nothing is lost — everything in docs/ is project knowledge!**
