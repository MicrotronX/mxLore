# Slug Normalization — Canonical Algorithm (Shared)

Single source-of-truth for normalizing user-supplied slugs before passing
them to mx_search lookups, mx_init_project, or any local fallback paths.
The MCP server runs ClampSlug=100 on writes — this routine clamps + checks
locally so the caller can confirm with the user before truncation.

## Algorithm

1. Lowercase the input.
2. Replace every character that does not match `[a-z0-9-]` with `-`.
3. Collapse runs of multiple `-` into a single `-`.
4. Strip leading and trailing `-`.
5. If the result is longer than 100 chars, truncate at the last `-`
   boundary at or before position 100. If no boundary exists, hard-cut at
   100.
6. Strip any trailing `-` produced by step 5.
7. Verify the result matches `^[a-z0-9-]+$`. Empty result is invalid —
   ask the user for a different slug.
8. If the normalized slug differs from the raw input, show both forms and
   confirm with the user before proceeding.

## Notes

- The algorithm is idempotent — running it twice on its own output yields
  the same string.
- Non-ASCII letters (umlauts, accented chars) are replaced wholesale; if
  preserving intent matters, ask the user for an ASCII spelling rather
  than guessing transliteration.
- Slug uniqueness per project+doc_type is enforced server-side via
  retry-with-suffix; the local routine does not need to dedupe.
