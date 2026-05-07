# MCP Tags Array — Canonical Rule (Shared)

Single source-of-truth for the `tags` parameter on MCP write tools
(`mx_create_doc`, `mx_update_doc`, `mx_add_tags`, `mx_remove_tags`).

## Rule

`tags` MUST be a real JSON array, NOT a stringified JSON.

The server check at `mx.Tool.Write.pas:514` is
`if AParams.GetValue('tags') is TJSONArray`. A JSON string fails the type
check and tags are silently dropped (never persisted, no error returned).

## Examples

Correct (array):

```json
{ "tags": ["health-finding", "warning"] }
```

Wrong (string — silently dropped):

```json
{ "tags": "[\"health-finding\", \"warning\"]" }
```

Wrong (comma-separated — silently dropped):

```json
{ "tags": "health-finding,warning" }
```

## Notes

- Tag length max 64 chars per item — see `_shared/mcp-clamp-limits.md`.
- Empty array `[]` is valid and clears tags on update.
- Verify after write with `mx_detail` and inspect `tags` — silent drop is
  the only failure mode, so verify-after-write is the only reliable check.
