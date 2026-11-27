# ADR-026: Research as independent parallel researchers plus synthesis

Status: **Accepted; implemented, behind the preview gate.** Research stays behind
the preview visibility (`workflow_visibility.dart`) until real-provider
acceptance is recorded (see Release gates).

## Decision

One Research request runs two to four researcher executions on **different
resolved models**, then one synthesis execution in a fresh session. The default
is two researchers and one synthesizer; the bounds live only in
`RESEARCH_RESEARCHER_LIMITS`. Researchers are execution roles, not machines or
providers: two researchers may share a provider or a Worker, but never a model.
The synthesizer may reuse a researcher's model, never its session. Every
execution is read-only.

## Workflow definition

- **Step-instance identity.** A step has an optional `id`, `dependsOnSteps` and
  `inputsFromSteps`; its identity is `id ?? kind`. Single-kind workflows keep
  `task-<request>-<kind>`; repeated kinds become `task-<request>-research-1`,
  `-research-2`, and so on. Planning, durable operation names, retry, bindings
  and session keys all use the instance ID.
- **`research:v2`** (`researchWorkflowV2(n)`) is the current Research version:
  `research-1..n` (prompt `research:v2`, result `research_report`) and
  `synthesis` (prompt `synthesis:v1`, result `research_synthesis`) depending on
  every researcher. Snapshot validation rejects altered dependencies, duplicate
  instance IDs and write access. `research:v1` is unchanged.
- **Read-only** is enforced by the assignment's `stateless_read` + `read_only`
  mode and the scheduler's effective permissions, not by prompt text.
- **Prompts.** Researchers receive the identical request and accepted context
  and no sibling output. They report Findings, Supporting references,
  Assumptions, Uncertainties, Recommendations and a "Sources and tools used"
  line, and must not claim access or verification that did not happen.
  Synthesis receives every report, delimited and attributed (step, model,
  effort) as untrusted evidence, compares agreement and disagreement by evidence
  (no majority vote) and reports unresolved conflicts. Reports are never
  truncated: a synthesis prompt over `MAX_RESEARCH_SYNTHESIS_PROMPT_CHARS` fails
  with `context_limit_exceeded` and the reports stay on their tasks.
- **Tools.** Prefer native file and search tools. Where repository reads are
  only available through a terminal tool, read-only inspection commands are
  allowed inside authorized folders and the sandbox; mutation, project scripts,
  dependency installation, Git changes and escalation are not. A report must
  disclose sources it could not inspect.

## Model diversity

Identity is the *resolved* model from the Worker's catalog: catalog IDs map to
themselves (case-insensitive), and custom IDs count as their own identity only
on Workers that allow custom models. Auto is rejected because distinctness
cannot be proven; effort-only and Worker-only differences are duplicates.
Acceptance fails with `422 research_configuration_invalid` and substitutes or
deduplicates nothing (`research-models.ts`, `validateResearchModelDiversity`).
Known limit: a custom ID that is secretly an alias of a catalog model cannot be
detected.

## Configuration and admission

- Research configuration schema version 2 has `researcherCount` (2-4) and
  overrides keyed by step instance (`research-1..n`, `synthesis`). Other
  workflows use version 1, keyed by kind. A version 1 Research configuration
  yields two researchers on one inherited model and is rejected until roles are
  configured.
- The definition is built from the Space configuration and frozen in the
  snapshot. Worker, model and effort are resolved and frozen per role
  (`resolvedBindings`, `stepExecutionConfigs`). A missing instance
  configuration fails closed and never inherits a sibling's.
- **Entitlement** `workflow.research` (Syntila Plus) is held by the requesting
  account only, using the effective plan of ADR-022. It never widens access to
  Spaces or Workers. `requireWorkflowEntitlement` runs before any request, run,
  task or dispatch exists (submission, validation, queueing and user-triggered
  retries) and answers `402 paid_plan_required` with
  `feature: "workflow.research"`. An accepted run finishes after a plan lapses;
  reports, history and cancellation stay available. Chat and Work
  are not gated.

## Execution

- The Workflow owns the dependency graph. Independent researchers dispatch
  together; each persists and publishes its result immediately. Synthesis is
  ready only after every configured researcher has completed, or after the user
  chooses to continue with the successful reports (at least one is required; the
  answer then names the missing perspectives and is marked as completed with
  gaps).
- Research has no pool or concurrency cap of its own. Account concurrency
  ([ADR-023](ADR-023-free-execution-concurrency.md)) and Worker readiness apply
  to each branch, and a waiting branch reports its own queued reason.
- `POST /work-requests/:id/retry` accepts `stepId` and re-queues only that
  instance. Completed siblings are preloaded, and a synthesis retry reuses the
  accepted reports. Retries and dispatch revalidate an accepted explicit model
  and effort against the refreshed catalog (same Worker and Profile revision,
  model and effort still available) without rewriting accepted bindings; Auto
  selections stay pinned to their accepted catalog.
- Each new Research message starts a fresh graph with fresh sessions for all
  roles; earlier native provider sessions are not resumed.

## Conversation context

An accepted Research request joins the Thread's canonical Conversation. Later
requests see the user's request and the synthesis; individual researcher reports
stay on their steps and are excluded from bootstrap. Prompts treat earlier
assistant conclusions as unverified history. Bootstrap documents carry
`historyCoverage` version 1 (eligible, included and omitted counts, first
included sequence, whether earlier history was cleared). No generated summary
replaces omitted evidence.

## App

The Work read model returns `stepId` per step. The run view labels "Researcher N"
(model and state) and a separate "Synthesis" stage; the final answer is the
synthesis. The composer offers no single Worker or model override for Research;
a **Research executions** control shows each role's effective Worker, model and
effort. The Workflows editor has the researcher-count control and blocks saving
a configuration that breaks the diversity rule. `workflowAccess` shows a
workflow as hidden, locked (Plus required) or available.

## Release gates (open)

- Real-provider run with two distinct models proving overlapping execution,
  separate sessions, successful synthesis and unchanged project files.
- Runtime evidence for replay, targeted retry, cancellation and result
  persistence of parallel branches.
- Alias identity verifiable from authoritative catalog metadata.
