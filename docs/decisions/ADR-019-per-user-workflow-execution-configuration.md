# ADR-019: Workflow execution configuration

- **Status:** Accepted; Worker-targeted execution is specified by [ADR-035](ADR-035-worker-targeted-execution.md)
- **Date:** 2026-10-08
- **Details:** [User Workflow Configuration](../specifications/USER_WORKFLOW_CONFIGURATION_V1.md)

## Context

Syntila owns the Workflow definitions, their Steps and prompts. People need to save execution preferences without changing those definitions or exposing provider credentials.

## Decision

A person's Workflow settings store enabled state and sparse Worker, model, effort and fixed-Step preferences. Space settings can override the owner's global configuration for an individual Workflow. The server validates settings and authorizes Space changes. A Thread stores its authored instructions and default Workflow; accepted requests snapshot their execution configuration.

Selections name Workers. At acceptance and dispatch Cloud checks current authorization, readiness, capabilities and the Worker's model and effort options. An unavailable Worker fails clearly; Cloud does not silently select another. Connect enforces local permissions and resolves the signed Profile to the generic Engine. See ADR-035 for authoritative eligibility and selection rules.

## Consequences

Saved settings do not copy Workflow definitions, provider secrets or local paths. Editing a preference does not rewrite accepted execution snapshots. Cloud and Connect independently enforce their respective authorization and local safety boundaries.
