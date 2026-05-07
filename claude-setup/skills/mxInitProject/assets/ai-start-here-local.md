# AI Start Here Block — non-MCP project

Insert this block at the top of CLAUDE.md (after the first H1) when no MCP
server is configured.

```markdown
> **AI Start Here** — Read these files to get started:
>
> | Document | Purpose |
> |----------|---------|
> | [CLAUDE.md](./CLAUDE.md) | Architecture, conventions, rules (this file) |
> | [docs/status.md](./docs/status.md) | Current project status, open items |
> | [docs/decisions/index.md](./docs/decisions/index.md) | Architecture Decision Records (ADR) |
> | [docs/specs/index.md](./docs/specs/index.md) | Specifications |
> | [docs/plans/](./docs/plans/) | Plans and session notes |
>
> **Documentation rules:**
> - Decisions ONLY via `/mxDecision` -> `docs/decisions/ADR-XXXX-slug.md`
> - Plans ONLY via `/mxPlan` -> `docs/plans/PLAN-XXXX-slug.md`
> - Specs ONLY via `/mxSpec` -> `docs/specs/SPEC-slug.md`
> - `/mxSave` updates `docs/status.md` + session notes
> - CLAUDE.md stays compact: links + rules + architecture. No long backlogs.
```
