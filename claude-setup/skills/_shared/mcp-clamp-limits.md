# MCP Clamp Limits — Canonical Field Reference (Shared)

Single source-of-truth for VARCHAR field limits enforced by the mxLore MCP
server. Applies to `mx_create_doc`, `mx_update_doc`, and `mx_add_relation`.
Clamp before write rather than relying on server truncation.

## Limits

| Field           | Max chars | Tool(s)                                |
|-----------------|-----------|----------------------------------------|
| title           | 255       | mx_create_doc, mx_update_doc           |
| slug            | 100       | server-derived from title              |
| change_reason   | 500       | mx_update_doc                          |
| summary_l1      | 255       | mx_create_doc, mx_update_doc           |
| summary_l2      | 500       | mx_create_doc, mx_update_doc           |
| tag             | 64        | mx_add_tags, mx_remove_tags            |

Values past the limit are silently truncated server-side — no error is
raised. Callers MUST clamp + verify locally.

## Notes

- `slug` is auto-generated server-side from the title. The `slug=` param does
  not exist on `mx_create_doc` and is silently ignored.
- `mx_add_relation` param names are literally `source_doc_id` /
  `target_doc_id` — not `source` / `target`.
- For `mx_update_doc`, pass `max_content_tokens=0` on the preceding
  `mx_detail` to avoid silent body truncation.
