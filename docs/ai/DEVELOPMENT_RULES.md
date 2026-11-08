# AI Development Rules

## Before implementation
An AI worker must:
1. read AGENTS.md;
2. read the relevant specification/ADR;
3. inspect existing code/tests before proposing architecture;
4. state the exact phase/task being implemented;
5. avoid broad changes beyond that task.

## Implementation
- Prefer small commits and cohesive units.
- Keep domain logic provider-independent.
- Use interfaces at infrastructure boundaries.
- Validate all AI/tool responses before accepting them.
- Make state transitions explicit and testable.
- Do not rely on hidden conversation state for persistent workflow facts.
- Preserve ordered event/audit history for orchestration actions.
- Never log credentials or sensitive tokens.

## Tests
Prefer functional tests that exercise meaningful user-visible behavior, including important failure paths. Add focused unit tests for consequential domain rules or state transitions when functional coverage would be impractical, and contract or integration tests for important protocol and infrastructure boundaries. Avoid redundant tests and assertions that only repeat implementation details or incidental names and constants. Update existing coverage when it already exercises the behavior.

## Documentation
Update documentation in the same task when changing:
- domain vocabulary;
- architecture;
- persistence;
- protocol/schema;
- security/permissions;
- public API;
- workflow semantics.

## Review handoff
Return:
1. summary;
2. files changed;
3. tests/checks and exact result;
4. documentation updated;
5. risks/assumptions;
6. recommended independent-review focus.
