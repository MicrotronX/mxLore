# Mirror Sync — Canonical 3-Mirror Protocol (Shared)

Single source-of-truth for propagating skill edits across the three required
mirror locations. Edit canonical first, then cp to mirrors, then md5-verify.

## Mirror Layout

| Role       | Path                                                       |
|------------|------------------------------------------------------------|
| canonical  | `~/.claude/skills/<skill>/`                                |
| mirror1    | `<project-root>/claude-setup/skills/<skill>/`              |
| mirror2    | `<mxLore-skills-root>/<skill>/`                            |

`<project-root>` is the mxLore project checkout. `<mxLore-skills-root>` is
the public skills repo checkout (`MicrotronX/mxLore-skills`).

## Protocol

1. Edit the file under canonical only.
2. Bash `cp <canonical>/<file> <mirror1>/<file>` and `cp <canonical>/<file>
   <mirror2>/<file>` for every changed file.
3. Verify each pair with `md5sum`:
   - Raw md5: `md5sum canonical mirror1 mirror2`
   - LF-normalized md5 (handles CRLF drift): pipe each file through
     `tr -d '\r' | md5sum -` and compare.
4. Report per file `PASS` (all three md5s match in raw OR LF-normalized
   form) or `FAIL` (mismatch — show all three hashes for triage).

## Rules

- Never edit a mirror directly — re-cp from canonical instead.
- A mirror that has drifted under VCS history is repaired by canonical cp,
  not by hand-editing.
- Do NOT include the canonical hash twice in the report (one row per file).
