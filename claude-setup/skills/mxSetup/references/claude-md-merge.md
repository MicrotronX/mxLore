# CLAUDE.md mx-rules Merge Logic

Used by Phase 5c and `--update-rules` mode. Source file: `/tmp/mxLore-skills-CLAUDE.md` (staged in Phase 2 via `install-skills.sh`).

Three branches based on state of `~/.claude/CLAUDE.md`:

## Branch 1 — File does not exist
Copy `/tmp/mxLore-skills-CLAUDE.md` verbatim to `~/.claude/CLAUDE.md`. New file contains the full mx-rules block inside markers.

## Branch 2 — File exists, mx-rules marker present
File already has both markers:
```
<!-- mx-rules-start -->
...old content...
<!-- mx-rules-end -->
```
Replace everything between `<!-- mx-rules-start -->` and `<!-- mx-rules-end -->` (exclusive of markers themselves) with the new block content from the template. User text above and below the markers is preserved byte-for-byte.

⚡ Only touch content strictly between the two markers. Never edit user additions outside the markers.

## Branch 3 — File exists, no markers
User has a CLAUDE.md without our marker block. Append the full mx-rules block (including both markers) at the end of the file, separated from existing content by a single blank line. Do not modify existing content.

## Cleanup
After merge (any branch): `rm /tmp/mxLore-skills-CLAUDE.md`.

## Edge cases
- Only one marker present (unbalanced) → treat as Branch 3 (append), warn user the old marker was not removed.
- Marker order reversed (`end` before `start`) → treat as Branch 3, warn.
- File is a symlink → follow the link, merge into the target.
