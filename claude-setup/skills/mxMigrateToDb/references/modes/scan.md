# Scan Mode (--scan)

Checks local docs/ against DB and detects stubs. No import, report only.

1. **Find non-migrated files:**
   - `mx_search(project, limit=50)` → load all DB docs → build `existing_slugs` set (⚡ 1 call instead of N)
   - List all *.md in docs/ (recursive, except index.md, status.md, CLAUDE.md)
   - Per file: Check file slug against `existing_slugs`. !mx_search per file
   - No match = not migrated → include in report
2. **Stub detection in DB:**
   - `mx_search(project, limit=50)` → load all docs
   - For each doc: Check token estimate from mx_search response
   - Docs with token_estimate < 50 = stub → include in report
3. **Output report:**
   ```
   ## Auto-Scan Report

   ### Non-migrated local files
   | File | doc_type (estimated) |
   |------|----------------------|
   | docs/plans/PLAN-foo.md | plan |

   ### Stub documents in DB (<50 tokens)
   | doc_id | Title | doc_type | Tokens |
   |--------|-------|----------|--------|
   | 360 | PLAN: Stub | plan | 12 |

   ### Recommendation
   - X files not migrated → run `/mxMigrateToDb`
   - Y stubs in DB → fill in or delete
   ```
4. **Do not make any changes** — report only
