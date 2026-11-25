# ADR-036: Canonical Thread Timeline and Actor Attribution

- **Status:** Accepted and implemented
- **Date:** 2026-11-19
- **Related:** `CONVERSATION_CONTINUITY_V1.md`, `WORK_V1_CONTRACT.md`

## Context

`discussion_messages` stores the canonical Thread timeline (`kind IN ('message','ai_request','ai_answer')`, `work_request_id`, `worker_display_name`). Extending it in place with actor attribution (`author_actor_id`, `worker_instance_id`, `author_display_snapshot`) gives the web app one authoritative server timeline without maintaining a separate `thread_messages` table or client-side merge logic.

## Decision

1. **Extend `discussion_messages` in place. Don't create a new table.** Add `author_actor_id` (backfilled from `author_user_id` through the human Actor), `worker_instance_id` (nullable) and `author_display_snapshot`.
2. **Uniqueness:** partial unique indexes guarantee one `ai_request` and one `ai_answer` per `work_request_id`. Human sends are deduplicated through `(author_actor_id, client_mutation_id)`.
3. **Ask AI** creates the Work Request and its single `ai_request` timeline item in one transaction.
4. **Final answer:** a single transaction commits the terminal assignment result, the `ai_answer` row and the durable event (ADR-033). Retries or replays can't create a duplicate.
5. **Who authors a multi-Worker answer.** The Workflow declares a **terminal step**. The answer is authored by that step's Worker Actor. If no terminal step is declared, a System Actor labeled with the Workflow name authors it. Intermediate step output goes to execution details, not the timeline, unless the Workflow explicitly exposes it.
6. Execution evidence and the `ai_request`/`ai_answer` items can't be edited like ordinary chat messages.
7. **Context continuity:** the server's canonical turns plus artifact references are the context shared across Workers. A provider's native session is reused only by the same Worker Instance.
8. Display: show the current name, falling back to the snapshot for removed or tombstoned Workers.

## Consequences

- One ordered timeline, read over cursor-paginated HTTP, with notification events that carry only IDs.
- The client's Work-card merge logic is removed after old and new rendering match on seeded historical fixtures.
- Until that cutover, a live Work card replaces canonical AI rows for the same request in the displayed timeline. Terminal Work events refresh the observed discussion, including retry outcomes. Worker-first requests without a Workspace publish Work and step events on their Space stream.
- Migration is additive plus a backfill. Nothing is copied to a new table.
