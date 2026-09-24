<!-- mxSave reference, moved verbatim from SKILL.md 2026-09-24 -->
### 5) Session Summary as MCP Note (MCP, Main-context synchronous)
Step 5 runs in Main; subagent may build body but Main issues `mx_create_doc` (skill runtime cannot await a background subagent — running Step 5 in background regresses the deferred-write fix).

⚡ **Body-Validation Gate + Subagent dispatch hardening + Archive-Fidelity Rule:** see `references/body-validation.md`.
Enforce in Step 5 BEFORE `mx_create_doc`: validate length≥500 / ≥3 template sections / required-appendices preserved → fail any → Main builds local fallback (verbatim appendices). Body passed to `mx_create_doc` is NEVER empty, NEVER shorter than fallback, NEVER drops detected decision artefacts.

⚡ **Status must be `active`:** Session-notes are finalised at save-time. Pass `status='active'` explicitly — leaving it at the server's `draft` default breaks resume-enrichment pairing in the next session.
```
mx_create_doc(project, doc_type='session_note', title='Session Notes YYYY-MM-DD[-N]', content, status='active')
```
**Template (all sections required — omit only if truly ∅, do NOT paraphrase absence). ⚡ Resume-Quality is the DEFAULT, not a mode: EVERY save (incl. `--loop`, incl. doc-only sessions) MUST produce a note from which a fresh `/clear` context is fully reconstructable in ONE read. The two ⚡ALWAYS sections below are never omitted — empty → literal `keine`, never dropped:**
- `## Quickstart after /clear` — ⚡ALWAYS (∅→`keine`, never omit). FIRST section. 1-sentence situation ("where we are") + `mx_briefing(project=<slug>)` hint + the single most-actionable NEXT action (file/function/task). A save you cannot resume from in one read is worthless.
- `## Blocked on me` — directly below Quickstart. Open items that wait on the user's decision/action (1 line each, id + what is needed); none -> `none`.
- `## What was done` — numbered per work stream
- `## Changed files` — git-status / file-touch list verbatim
- `## Commits` — `<hash> — <subject>` + explicit push status (`pushed` / `NOT pushed`)
- `## Docs created this session` — enumerate ALL doc_ids created this session (notes, lessons, references, ADRs, plans, specs, bugreports, feature_requests). Format: `<type>#<id> — <title>`. Source: `mx_create_doc` tool-call returns from THIS session, NOT prose-guessed. Purpose: a fresh `/clear` session reads this block + `mx_detail` each ID to fully reconstruct the work.
- `## Next step` — if the active Plan has pending next-phase tasks (M2/M3/next milestone), enumerate them **verbatim** from the Plan body (copy `- [ ]` lines 1:1, do NOT paraphrase). Pointer-only (`see Plan#NNNN M2`) is insufficient because resume-enrichment may not fetch the Plan body.
- `## Tooling gotchas + verify` — ⚡ALWAYS (∅→`keine`, never omit). Verify commands to re-confirm state after resume (build/test/run one-liners) + non-obvious pitfalls this session hit (local-binary-vs-npx, build prerequisites, encoding traps, env quirks). Purpose: the next session re-verifies instead of re-discovering.
- `## Open bugs / TODOs` — inline code-TODOs, pending MCP findings, version-bumps pending, push-pending
- `## User notes` — explicit user corrections, feedback, near-misses
**Numbering:** mx_search(project=<slug>, doc_type='session_note', query='YYYY-MM-DD')→exists→append number
**if !mcp_available →** Fallback local `docs/plans/session-notes-YYYY-MM-DD.md`+warning
