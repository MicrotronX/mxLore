# mxOrchestrate — Model Tiering (full text, moved verbatim from SKILL.md)

> Loaded when spawning a subagent whose tier is not obvious from the SKILL.md summary. SKILL.md keeps the binding defaults.

Main loop on premium model (Fable/Opus) → every subagent spawn (Agent-Tool, team agents, checker runs) sets the `model` param to the cheapest tier that satisfies the task. Match model to task floor, !ceiling:

| Tier | `model` | Task profile |
|------|---------|--------------|
| haiku | `haiku` | mechanical: state-file rewrites, file copy/sync, log tails, doc-body assembly from given content, simple greps |
| sonnet | `sonnet` | **DEFAULT** for subagents: mxOrchestrate HEAVY modes (init/resume/status/suggest), MCP CRUD flows, mxBugChecker/mxDesignChecker standard scope, Explore/codebase-search, standard implementation steps. MINI modes spawn nothing (see SKILL.md → Weight routing) — the cheapest spawn is no spawn |
| inherit | omit param | top-tier reasoning genuinely required: architecture decisions, security-critical analysis, cross-cutting refactors, ambiguous specs |

- ⚡ Orchestration *intelligence* (skill routing, escalation judgment, interpreting results) lives in the MAIN loop (premium model) — the /mxOrchestrate subagent executes a fully specified procedure (state CRUD, fixed decision trees), so `sonnet` suffices. Ambiguity safety net: diverged state / code-vs-doc conflict → STOP + ?user regardless of model.
- Main model ∈ {fable, opus*} → subagent default = `sonnet`. Omitting `model` (inherit=premium) requires 1-line justification in the spawn rationale (written into the Agent-tool prompt or the caller's status text).
- Main model already sonnet/haiku → omit `model` (inherit, no tiering gain).
- !premium subagents for mechanical work — token+cost efficiency over convenience.
- ⚡ **Loop rule (measured 2026-09-11):** the main-loop cost is `turns × context`, and cache reads are 99.9 % of the input — every turn re-pays the whole context (~75k baseline, 150-210k mid-session). A batch of **>5 same-shaped MCP calls** (`mx_ai_batch_log`, `mx_add_tags`, `mx_skill_feedback` verdict rounds, tag sweeps, findings triage, AI-batch runs) therefore NEVER runs in Main: one session ran 53 such turns on the premium model (27 batch_log + 26 add_tags) at ~150k context each. Dispatch the whole loop as ONE `sonnet` (or `haiku` when purely mechanical) subagent with the complete item list in the prompt; Main receives a ≤20-line tally. Tiering fixes the price per token — only fewer premium turns fix the token count.
