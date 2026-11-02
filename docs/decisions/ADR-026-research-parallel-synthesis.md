# ADR-026: Research as independent parallel researchers plus synthesis

Status: **in progress** (Phases 1-4 implemented; Phase 5, real-provider acceptance, open). Research v2 is the current Research version and stays behind the preview gate. Research stays behind the
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
  unchanged. Phase 3 subsequently made `research:v2` current.
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
- **Entitlement** (`workflow.research`, a Syntila Plus feature). See the
  Entitlement section below.

## Entitlement
- Held by the **requesting** account only. A Space owner's, Workspace
  owner's or another member's plan never grants it, and it never grants access
  to otherwise unauthorized Spaces, Workspaces or Workers (all existing
  permission, grant and readiness checks still run).
- Uses the effective plan (`past_due` grace, expiry) from ADR-022.
- Gates the standalone `research` workflow, every version. Workflows that only
  contain a research step (Full Cycle) are not gated. Chat and Work stay Free.
- Server enforcement (`requireWorkflowEntitlement`): checked in
  `requireWorkflowPermission`, before any request, run, task, capacity
  reservation or dispatch exists, for direct submission, validation, adding to
  and sending from the Thread request queue, and in `handleRetryWorkRequest`
  for user-triggered request and step retries. Workflow IDs are resolved only
  from the built-in catalog; client-supplied definitions and step invocation
  are not accepted, so there is no alternate path. Errors use the existing
  `402 paid_plan_required` format with `feature: "workflow.research"`.
- An idempotent replay of an accepted submission returns the original result
  without re-checking the plan and creates no execution.
- Automatic recovery and continuation of an accepted run (researcher
  branches, synthesis, reconciliation) never re-check the plan, so a run
  accepted under Plus finishes after the plan lapses. Reports, history and
  cancellation stay available after a downgrade.
- No numeric concurrency cap is added; plan admission is separate from runtime
  capacity.
- App: `workflowAccess` shows a workflow as hidden (unreleased, no preview),
  locked (Plus required) or available. `releasedPlusWorkflowIds` is empty
  until Research passes release acceptance, so a Plus plan never exposes it
  early, and the preview account sees it locked unless it holds Plus. The
  composer offers only available workflows; the locked text is "Research
  compares independent investigations from different models and combines them
  into one outcome. Available with Syntila Plus." Saved configuration is kept
  on downgrade. The plan cache refreshes on sign-in and whenever the plan is
  reloaded (Profile, sharing); there is no upgrade action to link yet.

## Phase 2 (implemented): persistence and Cloud execution
- **Migration `0099_workflow_step_instances.sql`** rebuilds `workflow_tasks`:
  `step_instance_id` (written only for repeated kinds) and a stored generated
  `step_id = COALESCE(step_instance_id, step_kind)`, which replaces
  `step_kind` in the per-request uniqueness; `synthesis` joins the allowed
  kinds. Existing rows get `step_id = step_kind`, so task IDs, history and Step
  Runs are unchanged; dependencies and Step Runs are restored from copies and
  the migration asserts counts and foreign keys before finishing. Step Runs
  record the instance ID as `step_id` and the kind as `role`; history events
  carry `stepId`.
- **Engine** (`workflow.ts`): durable operation names, preloaded results,
  retry selection and binding lookup use the step-instance ID (equal to the
  kind for every older definition, so in-flight v1 Workflows replay
  unchanged). Independent researchers form one batch and dispatch concurrently;
  per-account and Workspace capacity still apply, and a branch waiting for
  capacity reports its own queued reason. Every branch outcome is persisted
  before a failure ends the run, so a successful researcher's report survives
  a sibling failing; synthesis is then blocked, never run on a partial set.
- **Sessions**: the session key uses the instance ID, so each researcher and
  the synthesis get separate request-scoped sessions (synthesis may reuse a
  researcher's model, never its session). v1 keys are unchanged.
- **Read-only**: every v2 step is `stateless_read` + `read_only`, which the
  dispatcher turns into a read-only assignment and the scheduler into
  read-only effective permissions (the existing mechanism, not prompt text).
- **Prompts** (`renderResearchV2Prompt`): researchers get the identical
  request and accepted context (instructions, attachment contents) and no
  sibling output. Synthesis gets the same plus every report, delimited and
  attributed (`step`, `model`, `effort`) as untrusted evidence. Reports are not
  truncated: a synthesis prompt over `MAX_RESEARCH_SYNTHESIS_PROMPT_CHARS`
  fails with `context_limit_exceeded`, and the reports stay on their tasks.
  Research also rejects oversized common prompt fields instead of applying the
  shared renderer's truncation. Synthesis receives the same inline attachment
  text and references as the researchers. Research results bypass the generic
  96,000-character result truncation; larger reports can therefore trigger
  explicit synthesis overflow while remaining available on their tasks.
- **Retry**: `POST /work-requests/:id/retry` accepts `stepId` (defaults to the
  kind for older clients) and re-queues only that instance; completed sibling
  results are preloaded and not rerun, and a synthesis retry reuses the
  accepted researcher reports.
- Research v2 runs end to end in the Workspace Gateway acceptance harness
  (two researchers dispatched together on different models, then synthesis).
- Phase 3 made `research:v2` the current Research version.

## Phase 3 (implemented): configuration and admission
- **Contract.** Research configuration schema version 2 (`researcherCount`
  2-4, overrides keyed by step instance: `research-1..n`, `synthesis`). Other
  workflows, and old Research configuration, stay version 1 (overrides keyed by
  kind). Defaults -> per-role override inheritance and global -> Space
  resolution are the existing rules. The storage envelope column stays 1; the
  JSON carries its own version.
- **Acceptance.** The Research definition is built from the Space
  configuration (`configuredWorkflowDefinition`) and frozen in the snapshot.
  Worker, model and effort are resolved and frozen per role
  (`resolvedBindings`/`stepExecutionConfigs` keyed by step instance).
  `validateResearchModelDiversity` then rejects Auto, duplicate, alias-only,
  effort-only or Worker-only differences and unavailable Workers/models with
  `422 research_configuration_invalid`; nothing is substituted. Model identity
  comes from each Worker's catalog (`workerModelCatalogs` from eligibility):
  catalogs carry no alias metadata today, so identity is the listed ID
  (case-insensitive) and pass-through Workers' custom IDs are their own
  identity.
- An old (version 1) Research configuration yields two researchers on one
  inherited model, so acceptance rejects it until roles are configured.

## Phase 4 (implemented): app
- The Work read model returns `stepId` per step (both detail and list) and
  binds Worker/model per instance; the final answer is the last step
  (synthesis); researcher reports remain inspectable on their steps.
- Workflow run presentation keys Step Runs by instance ID and labels
  "Researcher N" (with its model and queued/running/completed/failed state)
  and a separate "Synthesis" stage.
- Retry sends `stepId`, so a failed researcher or the synthesis is retried
  alone.
- The Workflows editor shows Researcher 1..n and Synthesis, a researcher-count
  control (2-4), and blocks saving with the same diversity rule before
  submission (Auto or a repeated model).

## Remaining phases
2. ~~Persistence and Cloud execution~~ (done, above). Follow-ups: verify
   end-to-end result persistence and AI History attribution for repeated steps.
3. ~~Configuration~~ (done, above).
4. ~~App~~ (done, above). The composer does not yet surface the acceptance
   error before Send beyond the editor's validation.
5. **Acceptance.** Real-provider run with two distinct models proving
   overlapping execution, separate sessions, successful synthesis and unchanged
   project files.

## Release gates (open)
- Runtime-level replay, targeted retry, cancellation and result-persistence
  evidence for parallel branches; end-to-end read-only enforcement.
- Real-provider acceptance evidence (not collected).
- Model alias identity must be verifiable from authoritative metadata; current
  Worker catalogs do not provide alias metadata for all models.
