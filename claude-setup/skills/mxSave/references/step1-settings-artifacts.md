<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
### 1) Clean settings.local.json (LOCAL)
Read+clean `.claude/settings.local.json`:
- Remove duplicates (e.g. `python:*`+`python3:*`→keep one)
- Remove stale/one-time Bash permissions
- Bash(grep/find/ls/dir:*)→remove (Glob/Grep/Read exist)
- Keep useful entries (WebSearch, WebFetch domains, python)
- Sort logically: WebSearch→WebFetch→Bash
- ⚡ Fail-soft: auto-mode permission classifier may DENY settings.local.json edits (even pure removals get classified as self-modification) → skip + report `Step 1 skipped — settings edit denied by classifier`, do NOT retry or escalate (observed live 2026-06-10)

### 1b) Local Artifact Sweep (LOCAL, report-only)
Scan workspace for stale local artifacts — REPORT only; any delete/refresh strictly confirm-gated (AskUserQuestion). Generic patterns only (project-specific paths belong in project docs, not here):
- Superseded build/release artifacts: keep the newest ZIP + extracted-dir pair, list older ones (count+size)
- `logs/` entries older than 14d (aggregate count+size only, no per-file listing)
- `*.new` / `*.old-*` / `*.bak` leftovers from install/update scripts (repo root + bin dirs)
- Mirrored-file timestamp drift: files maintained as copies in 2+ repo locations where the designated SOURCE is older than its mirror → report (downgrade risk on next copy)
- Output: `Artifacts: <N> stale candidates (report-only)` — silent if 0. Missing dirs → skip silently. `--loop` mode: skip entire step.
