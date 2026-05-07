# mx_search Pagination Constraint

⚡ **mx_search has NO server-side pagination** — there is no `offset` parameter (silently ignored), and `limit` is hard-capped at 50 by the server (`mx.Tool.Read.pas:477-479`: `if MaxLimit > 50 then MaxLimit := 50`). A single call is the only option per filter.

⚡ **Coverage warning:** if the project has >50 docs, a single call CANNOT see them all. Use `doc_type` filtering to narrow the scope (e.g. one call per `doc_type='plan'`, `doc_type='spec'`, `doc_type='decision'` etc.) and merge the results.

Doc types to iterate: plan, spec, decision, status, workflow_log, session_note, finding, reference, snippet, note, bugreport, feature_request, todo, assumption, lesson.

If even per-type queries hit 50 docs, log a clear warning that cleanup/import may be incomplete and flag this for server enhancement (TODO: add real pagination to mx_search).

## Per-doc_type loop pattern

```
all_docs = []
for dt in [plan, spec, decision, session_note, workflow_log, reference, note, bugreport, feature_request, todo, assumption, lesson, finding, snippet, status]:
  page = mx_search(project='<slug>', doc_type=dt, limit=50)
  if len(page) >= 50: log_warning("doc_type=" + dt + " hit 50-cap, possible truncation")
  all_docs.extend(page)
```

Build set from `all_docs`: `existing_slugs: set of string` (from slug field). Use this set for ALL duplicate checks. !individual mx_search per file.

## Cleanup hard fail-safe

If any single per-doc_type call returns exactly 50 results during cleanup, abort cleanup with an explicit error — the inventory is incomplete and cleanup is unsafe (silent data loss risk: deletable files whose DB match lives in the un-fetched tail would be kept as "not in DB" and mis-reported). The user must wait for server-side pagination support.
