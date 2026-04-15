# Workflow Templates

Declarative workflow definitions for `/mxOrchestrate`.
Projects can override or extend these templates in `docs/workflows.md` (project-specific takes precedence over global).

---

## Template: new-feature

**Trigger words:** feature, new feature, new functionality, implement, new area
**Description:** Full workflow for a new feature — from idea to implementation.

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Clarify requirements | superpowers:brainstorming | no | - |
| 2 | Write specification | /mxSpec (with PRD phase) | yes | If feature is complex enough to need its own spec |
| 2a | Spec review | /mxDesignChecker | if-spec | Only if step 2 ran; loads spec-review.md rules |
| 2b | Fix spec + re-review | /mxSpec + /mxDesignChecker | if-findings | Max 2 iterations for CRITICAL/WARNING |
| 3 | Review design | /mxDesignChecker | no | Review the design document from step 1 |
| 4 | Document decision | /mxDecision | yes | If an architectural decision emerged during brainstorming |
| 5 | Create plan | /mxPlan | no | - |
| 6 | Implement | superpowers:executing-plans OR superpowers:subagent-driven-development | no | - |
| 7 | Review code | /mxDesignChecker | no | Check modified files against design |
| 8 | Bug check | /mxBugChecker | yes | For critical or complex code |
| 9 | Save state | /mxSave | no | - |

---

## Template: bugfix

**Trigger words:** bug, fix, error, problem, broken, crash, exception
**Description:** Structured bugfix workflow with analysis and verification.

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Analyze bug | /mxBugChecker OR superpowers:systematic-debugging | no | - |
| 2 | Plan fix | /mxPlan | yes | If the fix touches multiple files or non-trivial changes |
| 3 | Implement fix | manual | no | - |
| 4 | Review code | /mxDesignChecker | no | Check modified files |
| 5 | Document decision | /mxDecision | yes | If an architectural change was required |
| 6 | Save state | /mxSave | no | - |

---

## Template: decision

**Trigger words:** decision, architecture, adr, design decision, trade-off
**Description:** Structured architectural decision with analysis and documentation.

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Discuss options | superpowers:brainstorming | no | - |
| 2 | Document decision | /mxDecision | no | - |
| 3 | Update affected specs | /mxSpec | yes | If existing specs are impacted by the decision |
| 4 | Update affected plans | /mxPlan | yes | If existing plans need to be adjusted |
| 5 | Save state | /mxSave | no | - |

---

## Template: specification

**Trigger words:** spec, specification, requirements
**Description:** Create a feature specification with review iteration followed by planning.

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Clarify requirements | superpowers:brainstorming | no | - |
| 2 | Write specification | /mxSpec (with PRD phase) | no | - |
| 3 | Spec review | /mxDesignChecker | no | Spec file as argument; loads spec-review.md rules |
| 3a | Fix spec | /mxSpec (update) | if-findings | Only if review produced CRITICAL/WARNING findings |
| 3b | Re-review | /mxDesignChecker | if-fix | Max 2 iterations, then continue (open findings become open questions) |
| 4 | Document decision | /mxDecision | yes | If an architectural decision emerged |
| 5 | Create plan | /mxPlan | yes | If moving directly into planning |
| 6 | Save state | /mxSave | no | - |

---

## Template: ad-hoc

**Trigger words:** (no manual trigger — automatically created by auto-tracking)
**Description:** Lightweight tracking WF for ad-hoc work without an explicit workflow start. Auto-cleanup at 0 artifacts.

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Do the work | — | no | - |
| 2 | Review code | /mxDesignChecker + /mxBugChecker | yes | Only for code changes |
| 3 | Save state | /mxSave | no | - |

---

## Project-specific overrides

Projects can define their own workflow templates in `docs/workflows.md`.
Format is identical to the templates above. On name collision the project template wins.

Example of a project-specific `docs/workflows.md`:

```markdown
# Project Workflows

## Template: tariff-extension

**Trigger words:** tariff, rate, zone, price matrix
**Description:** Extend the tariff system (zones, rates, matrix).

| # | Step | Skill | Optional | Condition |
|---|------|-------|----------|-----------|
| 1 | Clarify requirements | superpowers:brainstorming | no | - |
| 2 | Write tariff spec | /mxSpec | no | Tariff changes require a spec |
| 3 | Review design | /mxDesignChecker | no | - |
| 4 | Plan DB migration | /mxPlan | no | install.sql changes |
| 5 | Document decision | /mxDecision | yes | For fundamental changes |
| 6 | Implement | superpowers:executing-plans | no | - |
| 7 | Review code + grid | /mxDesignChecker | no | Spreadsheet changes are critical |
| 8 | Save state | /mxSave | no | - |
```
