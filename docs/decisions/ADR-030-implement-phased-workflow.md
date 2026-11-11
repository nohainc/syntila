# ADR-030: Phased 'Implement' workflow and catalog consolidation

Status: **in progress** (Phase 1: Catalog consolidation & prompt specifications)

## Context

Syntila originally specified 6 built-in workflows:
1. `chat` ("Chat")
2. `direct` ("Work")
3. `research` ("Research")
4. `plan_implement` ("Plan & Implement")
5. `implement_verify` ("Implement & Verify")
6. `full_cycle` ("Full Cycle")

Of these, `chat`, `direct`, and `research` were implemented and active. The remaining three (`plan_implement`, `implement_verify`, `full_cycle`) were rigid waterfall specifications that remained unimplemented. In practice:
- Real-world AI coding tasks require an upfront plan with phased milestones, human review/approval, and adaptive verification.
- Having three separate rigid workflows was redundant, confusing, and inflexible.
- Running a lengthy multi-phase plan inside a single monolithic Cloudflare Workflow execution risks context window exhaustion, step count limits, and step timeouts, while giving users zero visibility into upcoming steps.

## Decision

1. **Consolidate the Catalog**:
   - Retire `implement_verify` and `full_cycle` from active selection in `BUILTIN_WORKFLOWS` and the UI.
   - Retain `implement_verify:v1` and `full_cycle:v1` in `BUILTIN_WORKFLOW_CATALOG` so existing historical snapshots remain valid and executable per `WORK_V1_CONTRACT.md`.
   - Update `plan_implement` to **v2** with the canonical name **`Implement`** ("Plan in phases, review the approach, and execute step-by-step with verification.").
   - Resulting active catalog contains exactly 4 focused, orthogonal workflows:
     - **Chat**: Read-only conversation and file inspection.
     - **Work** (`direct:v2`): Quick, single-turn implementation for small/medium edits.
     - **Implement** (`plan_implement:v2`): Phased, approved, and verified implementation for complex tasks.
     - **Research** (`research:v2`): Multi-model parallel investigation and synthesis.

2. **The Implement Workflow Lifecycle**:
   - **Step 1 (Plan)**: A dedicated planning step produces a structured plan partitioned into explicit phases with completion criteria.
   - **Step 2 (Human Alignment Gate)**: The plan is presented to the user with interactive controls:
     - Approve / Reject the plan.
     - Select verification policy: `none` (no verification), `per_phase` (verify after each phase), or `final` (verify once after all phases).
   - **Step 3 (Phased Queue Execution)**: Upon approval, the phases are enqueued into the `thread_request_queue` as special locked batch items. They cannot be edited or forced out of order, but remaining phases can be removed/cancelled.
   - **Step 4 (Completion Evaluation & Auto-Pause)**: Each phase reports a standardized completion status (`STATUS: COMPLETED` vs `STATUS: BLOCKED / NEEDS_INPUT`). If incomplete or if user input is needed, the queue pauses automatically and waits for user guidance in the Thread. When a completed phase requests input, the response offers an inline reply. It submits a normal Work request directly using the responding Worker selection, while the remaining queue stays paused. The user reviews the reply and resumes the queue explicitly. This does not formally reopen the original phase; session continuity follows the normal Thread Work session rules and depends on the Worker and Profile remaining available. The main composer retains its existing queue behavior.

3. **Phase-by-Phase Rollout Plan**:
   - **Phase 1**: Core domain types, catalog consolidation, prompt profiles (`plan:v2`, `implement:v2`, `verify:v2`), and test updates.
   - **Phase 2**: Plan parsing and thread request queue support for locked phased batch items.
   - **Phase 3**: Phase completion evaluation and automated queue pause.
   - **Phase 4**: AX UI presentation (interactive plan approval card, verification selector, queue locked badges).
