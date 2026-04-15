# Auto-Detect: Project Setup

Runs in pre-routing after session setup. ⚡ 0 extra MCP calls — uses the `mx_session_start` response plus at most 2x Glob.

## 1. CLAUDE.md check (always, 1x Glob)

- Glob `CLAUDE.md` in project root → ∅match = setup missing.
- → User: "Project has no AI config. Run `/mxInitProject`? (1=yes / 2=no)"
- ⚡ Only suggest, never auto-execute.

## 2. MCP project check (MCP-mode only, only if `mx_session_start` ran)

- `mx_session_start` response contains "project not found" → project not registered.
- If CLAUDE.md present: → User: "Project not in MCP. `/mxInitProject` registers it. (1=yes / 2=no)"
- If CLAUDE.md missing: integrate into the suggestion from step 1.

## 3. Local migration candidates (MCP-mode only + project exists, 1x Glob)

- Glob `docs/*.md` (NOT recursive).
- Allow-list: `status.md`, `workflows.md`.
- Matches outside allow-list → User: "N local docs found (list). Run `/mxMigrateToDb`? (1=yes / 2=no)"
- ⚡ Only suggest, never auto-execute.

## 4. All checks OK → no message

No noise for correctly configured projects.
