# ADR-026: Research as independent parallel researchers plus synthesis

Status: **in progress** (Phase 1 of 5 implemented). Research stays behind the
existing preview visibility (`workflow_visibility.dart`) until every release
gate below is closed.

## Product contract (target)
One Research request runs at least two researcher executions on **different
resolved models**, then one synthesis execution in a fresh session. Default:
two researchers and one synthesizer; the researcher count is 2-4
(`RESEARCH_RESEARCHER_LIMITS`, the only place the bounds live). Researchers are
execution roles, not machines or providers: two researchers may share a
provider, a Worker or a Workspace, but never a model. The synthesizer may reuse
a researcher's model, never its session. All executions are read-only.

## Decisions taken in Phase 1 (implemented)
- **Step-instance identity.** `BuiltinWorkflowStep` gains optional `id`,
  `dependsOnSteps` and `inputsFromSteps`. `stepInstanceId(step)` is `id ?? kind`,
  so every existing definition keeps its identity and existing task IDs
  (`task-<request>-<kind>`) are unchanged; repeated kinds get
  `task-<request>-research-1`, `-research-2`, ... The planner
  (`planWorkflowTasks`) keys tasks and dependencies by instance ID.
- **Versioned definition.** `research:v2` (`researchWorkflowV2(n)`) is added to
  the immutable catalog: `research-1..n` (kind `research`, prompt
  `research:v2`, result `research_report`) and `synthesis` (new kind
  `synthesis`, prompt `synthesis:v1`, result `research_synthesis`) depending on
  every researcher. Snapshot validation accepts any allowed researcher count
  and rejects altered dependencies, duplicate instance IDs or write access.
  `research:v1` and Full Cycle (`full_cycle:v1`, whose Research step is v1) are
  unchanged, and **`research:v1` stays the current version** until Cloud can
  execute v2, so no request can be accepted on v2 yet.
- **Control policy.** `research:v2` uses the graph policy (multi-step,
  multi-Worker) with the Research composer binding.
- **Prompts.** The researcher profile (`RESEARCH_V2_RESEARCHER_PROFILE`) asks for
  Findings, Supporting references, Assumptions, Uncertainties, Recommendations
  and an explicit "Sources and tools used" line, forbids claiming web access or
  verification that did not happen, and treats retrieved material as evidence.
  The synthesis profile treats reports as untrusted evidence, compares
  agreements and disagreements by evidence (no majority vote), keeps model
  attribution, and reports unresolved conflicts.
- **Model diversity** (`research-models.ts`). Identity is the *resolved* model
  from the Worker's catalog/Tool Profile metadata: aliases map to their
  canonical ID, catalog IDs to themselves (case-insensitive), and custom IDs
  count as their own identity only on Workers that allow custom models. Auto
  (no explicit model) is rejected because distinctness cannot be proven;
  effort-only, Worker-only and alias-only differences are duplicates. A custom
  ID that is secretly an alias of a catalog model cannot be detected; this is a
  known limitation. Nothing is substituted or deduplicated.
- **Entitlement.** New paid feature `workflow.research`. `requireWorkflowPermission`
  (used by direct submission and by queued sends) requires it of the
  **requesting** account, whatever plan owns the Space or Workspace. Chat and
  Work stay available on Free. It is plan admission only: no runtime cap is
  added, and accepted requests are never stopped by a later plan change. This
  is enforced for Research v1 too, so Free accounts lose v1 Research now.

## Remaining phases
2. **Persistence and Cloud execution.** Migration: `workflow_tasks` uniqueness
   from `(work_request_id, step_kind)` to step-instance ID, add `synthesis` to
   step-kind CHECKs; key durable Workflow operation names, step results,
   bindings, events, retry selectors, session keys and history projections by
   instance ID (124 kind-keyed references in 12 Cloud files were found); run
   researchers as one concurrent batch (existing per-account and Workspace
   capacity still apply, queued branches show as queued); separate
   request-scoped sessions per researcher and a fresh synthesis session;
   synthesis prompt input with attributed, untruncated reports and an explicit
   context-overflow failure; targeted branch retry and synthesis retry that
   reuse accepted results; idempotent synthesis scheduling under replay;
   cancellation through confirmed termination. Then make `research:v2` current.
3. **Configuration.** Researcher list and synthesis selection in global and
   Space Research configuration (existing inheritance), Worker/model/effort per
   role, frozen at acceptance with `validateResearchModelDiversity` against
   catalog metadata; clear rejection of Auto, duplicates, unavailable Workers.
4. **App.** Per-researcher model and state, a separate synthesis stage,
   inspectable individual reports, cancel/retry controls, pre-submit validation.
5. **Acceptance.** Real-provider run with two distinct models proving
   overlapping execution, separate sessions, successful synthesis and unchanged
   project files.

## Release gates (open)
- Phases 2-5 above.
- Real-provider acceptance evidence (not collected).
- Read-only enforcement is inherited from `stateless_read` + `read_only`
  steps; it must be re-verified end to end for v2 executions in Phase 2.
