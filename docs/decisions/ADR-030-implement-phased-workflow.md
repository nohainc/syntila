# ADR-030: Phased Implement workflow and catalog consolidation

Status: **Accepted.** The built-in plan step, plan approval route and phased queue
batches are implemented (`apps/backend/src/domain/routes/implement-plan.ts`,
`thread-request-queue.ts`); the Implement workflow requires the requester's Syntila Plus
(`workflow.implement`, [ADR-022](ADR-022-account-plans.md)).

## Context

Real AI coding tasks need an upfront plan with phased milestones, human review and
adaptive verification. Rigid multi-step waterfall workflows inside one Workflow
execution risk context exhaustion, step-count limits and timeouts, and give users no
visibility into upcoming steps.

## Decision

1. **Four active workflows**, each orthogonal:
   - **Chat** (`chat`): read-only conversation and file inspection (`chat:v2`, "Chat with
     tool", adds one consented MCP tool call first).
   - **Work** (`direct:v2`): quick single-turn implementation for small and medium edits.
   - **Implement** (`plan_implement:v2`): phased, approved and verified implementation for
     complex tasks.
   - **Research** (`research:v2`): parallel multi-model investigation and synthesis
     ([ADR-026](ADR-026-research-parallel-synthesis.md)).

   Earlier versions that existing snapshots reference stay in the built-in catalog
   (`BUILTIN_WORKFLOW_CATALOG`), so saved requests remain valid.
2. **Implement lifecycle.**
   - *Plan.* A read-only planning step (`plan:v2`) produces a structured plan split into
     explicit phases with completion criteria.
   - *Human gate.* The plan is shown with controls to approve or reject it and to choose
     a verification policy: `none`, `per_phase` (after each phase) or `final` (once after
     all phases) (`POST /api/work-requests/:id/approve-plan`).
   - *Phased queue execution.* On approval the phases are enqueued in
     `thread_request_queue` as locked batch items: they cannot be edited or reordered, but
     remaining phases can be removed or cancelled.
   - *Completion evaluation and auto-pause.* Each phase reports a standard status
     (`STATUS: COMPLETED` or `STATUS: BLOCKED / NEEDS_INPUT`). An incomplete phase, or one
     that needs input, pauses the queue until the user answers in the Thread; the response
     offers an inline reply that submits a normal Work request with the responding Worker
     while the rest of the queue stays paused, and the user resumes the queue explicitly.
     This does not reopen the original phase: session continuity follows the normal Thread
     Work session rules and depends on the Worker and Profile remaining available. The main
     composer keeps its existing queue behavior.
