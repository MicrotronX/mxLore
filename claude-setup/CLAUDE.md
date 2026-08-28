# Global Rules
# IMPORTANT: Content between mx-rules markers is managed by /mxSetup --update.
# Place your own additions ABOVE or BELOW the marker block. Do NOT edit inside markers.

<!-- mx-rules-start v2026-08-28 -->
# mx* Rules (AI-Steno: !=forbidden →=use/instead ⚡=critical ?=ask)

## Persist ⚡
chat!=storage →docs/. decisions→/mxDecision plans→/mxPlan specs→/mxSpec session-end→/mxSave
session-words resume/continue/park/status/suggest (any-language phrasing maps to these)→/mxOrchestrate
proactive: persist when decision/plan/spec emerges in chat
PreCompact/PostCompact hooks DORMANT (prompt-type hooks blocked upstream in current Claude Code). Run /mxSave manually BEFORE /compact + mx_briefing manually after. Re-activate backup: ~/.claude/hooks/dormant-pre-post-compact.md. ~15-20 tool calls→proactive /mxSave
Cycle (manual): /mxSave→/compact→new session→mx_briefing manually→lean main context, MCP holds detail history
⚡ resume-quality = DEFAULT of EVERY /mxSave. save+clear/new-session (any phrasing)→/mxSave FIRST — save+clear = the OCCASION for /clear, !the condition for resume-quality. `--delta-check` flag = check only, !a save. Mechanics=mxSave skill (SSoT), !duplicate here
last_save_deltas≥15→mxSave aktive Compact-Frage. ≥10→Tipp-Zeile. ≥1→Marketing-Zeile. ==0→silent

## Context
3+files→Agent(Explore) !sequential reads. codebase-search→subagent !main-ctx
subagent return: max20, 1line each `file:line—finding` !raw-code
mxDesignChecker/mxBugChecker/mxHealth→Agent !main-ctx
grep-first→read(offset/limit) !>200lines !speculative
!repeat-user !explain-intent →just-do-it. results>explanations
⚡ !Bash for MCP-calls. !`claude --print`. !`claude -p`. ALWAYS MCP-tools direct (mx_search, mx_detail, mx_update_doc etc.)

## Tokens ⚡
mx_create_doc/mx_update_doc with long content→Background-Subagent !main-ctx (body stays out of history)
mx_detail max_content_tokens=600 default !full-text-read unless editing. mx_recall/mx_decision_trace return full content—use sparingly
mx_search include_content=false limit=3-5. mx_briefing token_budget=1000-1500
mx_skill_findings_list paginate(limit=10) !full-list
Edit surgical 1-5L. multi-line→Write or background-subagent
tail -15 default for logs. wider only on need
status.md max10L pointer-only(MCP IDs) !duplicate-content
N mirrored files→edit canonical 1x + cp, !N Edit calls

## Agent-Messages ⚡ (content, !transport — cross-project)
mx_agent_send payload = POINTER !document. line1 = the point(claim/ask/answer), 1 sentence. then evidence only: `file:line`, doc-id, msg-id, command-output. !restate the peer's message !re-derive !recap what both already know →reference by id
⚡ >1000 chars(soft limit) = the CONTENT is wrong, !the limit. detail→mx_create_doc, send `ref_doc_id`(param exists, comes back in the inbox) →the message stays a pointer
!split into [1/2][2/2] — delivery order is NOT guaranteed, a part can arrive before the part it depends on. needing to split = proof the payload belonged in a doc
correction→name the retracted msg-id verbatim. content-bearing msg→ask for a 1-line receipt if you need one (silence means done, !read — asking is the sender's job)

## Security ⚡
!secrets(keys/pw/tokens/logins) in code or external →envvar
!commit .env/.pem/.key →.claudeignore
⚡ .env-files(.env,*.env,.env.*)=NEVER read values: !Read/cat/grep/sed/python/source/any dump. !value/prefix/grep-line/excerpt→chat/MCP-doc/agent-msg/error-text. ONLY key-names|empty/filled|value-length|equal/unequal via `bash ~/.claude/hooks/env-keys.sh <file> [--cmp A B]`. !infer meaning from length. create/append=`echo 'KEY=' >> x.env` only (Write/Edit on .env blocked by the deny). enforced: permissions.deny Read(//**/.env…)+PreToolUse env-guard.js(mxSetup 5a-Deny/5b). scope=.env only !extend to pas/dfm
validate input(sqli,xss,cmdi). !full-files →relevant-excerpts-only

## Encoding
preserve original encoding. pas/dfm=ANSI(Win-1252) !→utf8
php/html: file-encoding must match charset
!powershell/bash for content-edit →Read/Edit/Write tools
details @~/.claude/reference/encoding-details.md

## Shell ⚡
!>nul(CMD)→broken-files. bash:>/dev/null 2>&1 ps:|Out-Null. verify shell-ctx before redirects

## Knowledge ⚡
!assert unverified code/files/state. !invent unit/module names. ∅finding without proof. ?uncertain→ASK. gap>speculation

## Honesty ⚡
!sugarcoat !hedge. fatal-flaw→say-directly. hard-truth>comfort. !confirm-bad-plans→challenge. risky-assumptions→flag-proactively

## Stack
delphi→~/.claude/reference/delphi.md | php/web→~/.claude/reference/php-web.md

## Docs
~/.claude/CLAUDE.md=global(all projects, via /mxSetup)
<project>/CLAUDE.md=project-only(slug,stack,arch) !duplicate-global
⚡ CLAUDE.md-Gewicht=BYTES !Zeilen: `wc -c`≤40KB UND längste-Zeile≤4KB(`awk '{print length}'|sort -rn|head -1`). Zeilenzahl ist blind für Chronik die in Zeilen-LÄNGE wächst (gemessen: 212 Zeilen=163KB, 53 Zeilen=32KB/80% in 1 Zeile). Datei lädt in JEDE Session + JEDEN Subagent-Fork
⚡ Status/Chronik in CLAUDE.md = GENAU 1 Eintrag (aktuell, voll) + Zeiger `History→mx_search(doc_type='session_note')`. Vorgänger wird ENTFERNT !eingedampft (trägt eigenen note#, SSoT ist die Note). !Top-N-Regel — N 1-Zeiler sind wieder Duplikat + Eindampfen pro Save = Drift
docs/reference/=on-demand. mx*-skills→auto-generate !manual-create

## Superpowers→mx* Bridge (mx* priority in docs/-projects)
superpowers=optional plugin(install:/mxSetup --with-superpowers). mx*-skills work fully without it; if installed it adds rigor + skills may use it. !hard-fail on missing superpowers skill
writing-plans→/mxPlan | brainstorming→/mxPlan+/mxSpec+/mxDecision→/mxDesignChecker
verification/finishing→/mxSave | executing→/mxDecision+/mxDesignChecker | session-end→/mxSave
<!-- mx-rules-end -->
