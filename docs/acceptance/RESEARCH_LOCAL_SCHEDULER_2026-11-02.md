# Research local scheduling investigation — 2026-11-02

Scope: local Cloud development database, Syntila Space, Research Thread.
This is scheduler evidence, not real-provider release acceptance.

## Observed request

- Request: `work-request-02003da8-8f20-4e82-ae50-c29569fe0083`.
- Research v2 accepted at `2026-11-02T11:56:14.248Z` and failed at
  `2026-11-02T11:57:59.453Z`.
- Both researchers failed before dispatch with the generic no-eligible-Worker
  scheduling error. Synthesis did not start. Zero Worker assignments or reports
  were created for this request.
- The Workspace was online; both configured Workers were enabled and ready,
  with their accepted Profile revisions present and an active Space grant.

## Cause and correction

The request froze execution configurations by step instance (`research-1`,
`research-2`, `synthesis`). The scheduler indexed them by semantic role
(`research`), so neither researcher could pass configuration validation.
Scheduling now uses the accepted instance binding. The `direct` binding still
looks up Work's `implement` configuration. Missing instances remain rejected.
Cloud dispatch/session binding types now allow instance IDs without pretending
they belong to the legacy kind-only binding union.

## Evidence

A read-only SQLite connection to the actual local D1 database was supplied to
the corrected `selectSpaceExecutionTarget`. Each accepted step selected:

| Step | Worker | Accepted model | Read-only |
| --- | --- | --- | --- |
| Researcher 1 | ChatGPT | `gpt-5.6-terra` | Yes |
| Researcher 2 | Gemini | `gemini-3.8-flash` | Yes |
| Synthesis | ChatGPT | `gpt-6.1-terra` | Yes |

The check called only scheduler selection, with durable queuing allowed as in
normal dispatch. It did not dispatch an assignment, start a provider, prove
simultaneous capacity, or retry the request. Afterwards its status remained
`failed` and assignment count remained zero.

Focused scheduler, execution-engine and session-key suites passed (51 tests),
including regression cases for distinct instances, missing-instance rejection,
and Work binding compatibility. Real-provider Research acceptance stays open.
