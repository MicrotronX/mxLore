# AI Start Here Block — MCP project

Insert this block at the top of CLAUDE.md (after the first H1) when the project
runs in MCP mode (mx_ping succeeded).

```markdown
> **AI Start Here** — Read these files to get started:
>
> | Document | Purpose |
> |----------|---------|
> | [CLAUDE.md](./CLAUDE.md) | Architecture, conventions, rules (this file) |
> | [docs/status.md](./docs/status.md) | Current project status, open items |
>
> **Documentation rules (MCP-based):**
> - Decisions ONLY via `/mxDecision` -> Knowledge-DB (doc_type='decision')
> - Plans ONLY via `/mxPlan` -> Knowledge-DB (doc_type='plan')
> - Specs ONLY via `/mxSpec` -> Knowledge-DB (doc_type='spec')
> - `/mxSave` updates CLAUDE.md + docs/status.md (local) + session notes (DB)
> - Search documents: `mx_search(project='<slug>', ...)` or `mx_briefing(project='<slug>')`
> - CLAUDE.md stays compact: links + rules + architecture. No long backlogs.
```
