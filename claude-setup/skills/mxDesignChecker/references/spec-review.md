# Specification / PRD Review Rules

These rules are loaded when mxDesignChecker reviews a `SPEC-*.md` file.

## 1. Requirement Clarity

- **Check**: Is every requirement understandable in 1-2 sentences? Are there ambiguities?
- **Typical failures**:
  - Vague wording: "The system should be user-friendly" (not measurable)
  - Implicit assumptions: "Process as usual" (usual for whom? how exactly?)
  - Multiple meanings: "Fast" can mean load time, throughput, or reaction time
  - Abbreviations without explanation that are not in the project glossary
- **Review method**: Read each requirement individually. Can a developer who only has the spec (no chat context) understand what is meant?
- **Severity**: CRITICAL if ambiguity can lead to wrong implementation, WARNING if unclear but context-recoverable

## 2. Testability of Acceptance Criteria

- **Check**: Can a concrete test be formulated for every acceptance criterion?
- **Typical failures**:
  - Not measurable: "Should be performant" -> better: "Response time under X ms"
  - Too general: "Data is saved correctly" -> better: "Mandatory fields Name, Email are persisted in table X and displayed after reload"
  - Missing boundary values: "Handle large datasets" -> how large exactly?
  - Missing negative tests: only happy path described, no error cases
- **Review method**: For every criterion ask: "How would I test this? What input, what expected result?"
- **Severity**: WARNING for untestable criteria, INFO for missing negative tests

## 3. Completeness

- **Check**: Are all discussed requirements covered in the spec?
- **Typical failures**:
  - Brainstorming output partially forgotten
  - Edge cases only discussed verbally but not documented in the spec
  - Error handling not specified (what happens on error X?)
  - Permissions / roles not defined (who may do what?)
- **Review method**: Reconcile the chat history (if available) or the Overview / Goals with the Requirements. Every goal must be covered by at least one requirement.
- **IMPORTANT**: Only check what is actually discussed in the chat or documented in the spec. Do NOT speculate about which requirements "are probably still missing". The Golden Rule applies: no finding without proof.
- **Severity**: WARNING for missing coverage of a goal, INFO for missing error-handling details

## 4. Consistency

- **Check**: Are there contradictions within the spec or with existing documents?
- **Typical failures**:
  - Requirement 3 contradicts requirement 7
  - Spec says "admins only", existing ADR says "all users"
  - Non-goals list contains something that also appears in requirements
  - Acceptance criteria do not cover a requirement (AC tests something different than the requirement defines)
- **Review method**: Read requirements numbered, check for overlaps and contradictions. If Related links exist, read the target document and reconcile.
- **Severity**: CRITICAL for contradictions, WARNING for missing AC coverage

## 5. Scope / Boundaries

- **Check**: Are non-goals defined? Is the scope clearly bounded?
- **Typical failures**:
  - Non-goals section missing or empty
  - Scope creeping too large ("and also X and Y")
  - Dependencies to other features not documented
  - Migration need not mentioned (existing data, existing APIs)
- **Review method**: Read the Non-goals section. Ask: "Could someone reasonably assume X is in scope even though it should not be?" If yes, X must be listed in Non-goals.
- **Severity**: WARNING for missing boundaries, INFO for missing dependencies

## 6. Edge Cases

- **Check**: Are obvious edge cases documented?
- **Typical failures**:
  - Empty inputs not considered (empty string, empty list, no selection)
  - Permission boundaries: what happens when an unauthorized user accesses?
  - Concurrent editing: what if two users edit the same thing?
  - Data volume: does the system behave the same at 1 entry as at 10,000?
- **Review method**: Only report edge cases that arise directly from the requirements. Do NOT invent theoretical edge cases that do not fit the requirement context.
- **Severity**: WARNING for missing obvious edge cases, INFO for theoretical ones

## 7. Feasibility

- **Check**: Are the requirements technically feasible in the project context?
- **Typical failures**:
  - Feature requires a technology that per CLAUDE.md is not used (e.g. WebSocket in a PHP-only project)
  - Performance requirement unrealistic for the tech stack
  - Dependency on an external service that is not available
  - Complexity of a requirement massively exceeds the planned effort
- **Review method**: Check requirements against the CLAUDE.md tech stack. Only report obvious conflicts; NO speculative feasibility concerns.
- **Severity**: CRITICAL for technical infeasibility, WARNING for high complexity
