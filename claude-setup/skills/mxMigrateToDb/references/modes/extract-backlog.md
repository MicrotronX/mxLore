# Extract-Backlog Mode (--extract-backlog)

Extracts backlog/todo lists from `docs/status.md` and creates them directly as MCP documents (plans/todos). Replaces the former mxMigratelegacy skill.

1. **Analyze status.md:**
   - Read `docs/status.md` and identify backlog sections:
     - Long bullet lists with open items (>3 consecutive bullets)
     - Sections: "Backlog", "ToDo", "Open Tasks", "Next Steps", "Naechste Aufgaben", "Spaetere Features", "Offene Punkte"
   - **Do not extract** (keep in status.md):
     - "Implemented Features" lists (history)
     - "Migrations" lists (reference)
     - "Known Issues" (short lists, max 5 entries)
     - Single references or one-liners

2. **Create MCP docs (directly in DB, no local files):**
   - Per identified backlog group: `mx_create_doc(project, doc_type='plan', title='PLAN: Legacy Backlog — <groupname>', content, status='draft')`
   - Content template:
     ```markdown
     # PLAN: Legacy Backlog — <groupname>
     **Created:** YYYY-MM-DD | **Status:** draft | **Source:** docs/status.md

     ## Tasks
     - [ ] Task 1
     - [ ] Task 2
     - [x] Completed task
     ```
   - Items marked as done → `[x]`
   - Unclear status → `[ ]` with note "(status unclear)"

3. **Shorten status.md:**
   - Replace extracted task lists with reference:
     `> Backlog migrated to Knowledge-DB (doc_id=X, YYYY-MM-DD)`
   - Keep non-backlog content

4. **Report:**
   ```
   Backlog extraction completed:
   - Created: X MCP docs (plans)
   - Extracted tasks: Y (of which Z completed)
   - status.md shortened: N lines removed
   ```
