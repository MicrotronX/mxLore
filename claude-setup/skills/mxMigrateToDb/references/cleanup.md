# Cleanup Phase Details (--cleanup / --sync)

## Protected files (NEVER delete)

- `CLAUDE.md` — always stays local
- `docs/status.md` — always stays local
- `docs/ops/workflow-log.md` — stays as local fallback
- `docs/reference/*.md` — stay as local reference
- `*/index.md` — index files stay

## Deletable files (only after DB verification)

- `docs/plans/PLAN-*.md` — if present in DB
- `docs/specs/SPEC-*.md` — if present in DB
- `docs/decisions/ADR-*.md` — if present in DB
- `docs/plans/session-notes-*.md` — if present in DB

## Index file cleanup

- Remove lines from `docs/plans/index.md`, `docs/specs/index.md`, `docs/decisions/index.md` that reference deleted files
- If index is empty afterwards: Insert placeholder line (`_No local entries — documents in Knowledge-DB_`)

## Reference update (MANDATORY after each file deletion)

For each deleted file, search for the filename (without path) in local files and update links:
- Grep for filename in: `CLAUDE.md`, `docs/status.md`, `docs/*/index.md`
- Replace each Markdown link `[text](path/file.md)` with: `text (Knowledge-DB, doc_id=X)`
- `docs/status.md` is NOT deleted but MUST be searched for dead links

## Output result

```
Cleanup completed:
- Deleted: X files (verified in DB)
- Kept: Y files (protected or not in DB)

| File | Action | Reason |
|------|--------|--------|
| docs/plans/PLAN-foo.md | deleted | in DB (doc_id=42) |
| docs/status.md | kept | protected |
```
