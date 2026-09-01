---
name: mxKnowledge
description: Use when working on a reusable component, a tool, or a third-party library — reading its sources, changing its wrapper, choosing between its features, or judging what it can do. Retrieves the knowledge dossier for that artefact from the mxLore knowledge DB (doc_type='skill' in project _knowledge), and creates one when a repeatedly-consulted artefact has none. Triggers on "component", "library", "third-party", "wrapper", "what can X do", "Komponente", "Fremdbibliothek", "Werkzeug", "/mxKnowledge". Also fires mechanically via the recall-gate --knowledge hook when a covered file path is touched.
---

# mxKnowledge — cross-project knowledge about components, tools and libraries

> Knowledge about a reusable artefact belongs to the ARTEFACT, not to the project that
> happened to need it first. Dossiers live in the project `_knowledge` as `doc_type='skill'`
> and are reachable from every project.

## The one rule that decides whether this works at all

⚡ **Search WITHOUT the `project` parameter.**

```
mx_search(doc_type='skill', query='<artefact name>', limit=5)     ← correct
mx_search(project='mxLore', doc_type='skill', query='...')        ← finds NOTHING
```

`project` is a hard filter and `scope='all'` does NOT lift it — measured 2026-08-31,
and recorded as a defect. Every habit in the mx-rules, in CLAUDE.md and in the briefing writes
`mx_search(project=...)`. Here that habit returns an empty result, and an empty result reads
exactly like "no knowledge exists". Passing `project` is the single most likely way to make
this skill silently useless.

## Retrieve

1. `mx_search(doc_type='skill', query='<artefact>', limit=5)` — no `project`.
2. Hit → `mx_detail(doc_id)`. Use it before deriving the same facts from the sources again.
3. ⚡ **The code always wins over the dossier.** A dossier carries a date, not a guarantee.
   Where they disagree, say so in your answer AND fix the dossier (see *Update*) — otherwise
   the next session re-derives the same correction.
4. **Zero hits is a fork, not an answer.** Distinguish the three cases and say which one it is:
   - `mx_ping` fails → MCP is unreachable. Report it, continue working without the dossier.
     ⚡ Only a real ping error counts: tools deferred → load first per
     `~/.claude/skills/_shared/mcp-tools-load.md` (tool-missing ≠ server-down).
     Never block on this (dossier spec R14).
   - `mx_ping` succeeds but `_knowledge` is absent from `mx_search(project=None)` results
     entirely → likely **no access** rather than no content: `_knowledge` is invisible to a
     developer without a `developer_project_access` row. Report "no access to _knowledge",
     not "no knowledge exists".
   - MCP fine, project reachable, nothing matched → genuinely no dossier. Offer to create one
     (see *Create*) if the artefact is worth it.

## Create

A dossier is worth creating when the artefact is **reusable and outlives one project**: a
component, a tool, a third-party library. Not for project-specific behaviour — bugs, specs and
usage stay in the owning project.

Mandatory sections (dossier spec R8). A dossier missing any of them is incomplete:

| Section | Content |
|---|---|
| Origin / vendor | who makes it, where the real documentation lives |
| **File location** | ⚡ the paths. This field feeds the hook watch list — a dossier without it is never triggered mechanically |
| Proven capabilities | what it can do, each claim carrying `file:line` |
| Known landmines | what looks fine and is not |
| Active users | who calls it, verified by grep, with the reach that implies |
| Date of record | when this was last checked against the code |

⚡ **Evidence rule (R9): no claim without `file:line`.** "It probably supports X" is not
dossier material. If you could not verify it, either verify it or leave it out — a dossier
that carries guesses is worse than none, because the next reader trusts it.

Then:

```
mx_create_doc(project='_knowledge', doc_type='skill', title='DOSSIER: <artefact>', ...)
```

⚡ **And immediately update the watch list**, or the hook will never fire for it:

```
node ~/.claude/skills/mxKnowledge/scripts/knowledge-cache.js set \
  --doc-id <id> --title "<short name>" --prefix "<path>" [--prefix "<path>" ...]
```

Pass the paths exactly as they appear in the *File location* section. The script normalises
case and slashes, appends the trailing separator for directories, replaces any previous entry
for that doc id, and writes atomically. Verify with `... list`.

## Update

`mx_update_doc(doc_id, append_content=...)` for growth; `replace_old`/`replace_new` for a
surgical correction. Full `content` replaces the body — only for a real rewrite.

⚡ **Concurrency (R20a):** two machines may hold the same dossier open. Pass
`expected_updated_at` from your `mx_detail` read. A rejected update means someone else wrote
first — re-read, merge, retry. Never force.

If the *File location* section changed, re-run `knowledge-cache.js set`. If the dossier was
deleted or archived, run `knowledge-cache.js remove --doc-id <id>`.

## Migrate an existing file-based skill

`/mxKnowledge migrate <skill-name>` converts a local `SKILL.md` into a dossier plus a stub.

⚡ **Hard block (R19f): a delivered process-skill must NEVER be migrated.** The delivered DB is
empty (R4), so a skill needed to operate mxLore cannot come from it — migrating `mxSave` would
mean you need `mxSave` to retrieve `mxSave`. That is a bootstrap deadlock, and it is not
recoverable from inside the tool.

Ownership is decided by the bundle manifest, never by the name:

```
~/.claude/skills/_shared/bundle-manifest.json      ← written by install-skills.sh
```

- name listed in the manifest → **refuse**, name the deadlock, stop.
- ⚡ **manifest missing → also refuse.** No manifest means ownership cannot be established, and
  a name glob is not proof of ownership — that assumption has already caused real data loss
  here. Fail safe, not open: tell the user to
  re-run the installer. Never guess from the `mx` prefix.
- name absent from an existing manifest → private skill, migration allowed.

Migration is only ever explicit. Nothing here migrates anything on its own.

## What this skill does NOT do

- It does not maintain a second copy of anything. One fact, one source (R3). To use a dossier
  from another project, FIND it or link it with `mx_add_project_relation` — never copy it in.
- It does not gate work. No dossier, no access, no MCP — say so and carry on.
- ⚡ No process-skill may DEPEND on a dossier (R5). Dynamic lookup is fine — that is what this
  skill does; a static reference to a particular dossier is not. Test: remove all dossiers; if
  the process still works (with less knowledge), the dependency is dynamic and allowed.
