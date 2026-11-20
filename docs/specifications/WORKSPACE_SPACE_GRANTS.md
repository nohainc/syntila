# Workspace Space Grants

> **Superseded in part (P10).** Workspaces are replaced by Worker Agents ([ADR-034](../decisions/ADR-034-standalone-worker-agent-and-session-fencing.md), [ADR-035](../decisions/ADR-035-worker-targeted-execution-and-workspace-removal.md)). This document describes the legacy Workspace path, which is closed in stages and then removed ([LEGACY_CUTOVER.md](../operations/LEGACY_CUTOVER.md)). Do not build new features on it.

Cloud owns Workspace grant authorization and persistent state. AX never uses a
cached grant as an authorization decision.

## Workflow-managed authorization

The standalone Space access collection and mutation routes on the Workspaces
page have been removed. A Space owner selects the effective Workspace in the
Space Workflows tab. That selection creates or repairs the internal
`workspace_space_grants` row used by Cloud admission and assignment dispatch.
AX filters Workers from the selected Workflow Workspace, so Workflows is the
single user-facing place for execution configuration.

The grant table remains Syntila-owned security state. It is not a second user
configuration surface: status, capability, permission, expiry, and revocation
checks continue to protect new and historical execution assignments.

The Workspace list exposes machine status, Worker inventory, and active work;
it no longer computes or displays derived Space-grant counts.

## Space and member boundaries

Workspace selection and workflow enablement live on the Space Workflows tab.
Selecting the owner's Workspace authorizes the internal execution grant; global
selection covers inherited and new owned Spaces. Existing grant policies,
suspension, expiration, and member rights remain authoritative. Only Workers
from the selected Workspace may be resolved for new execution.

Workspace attachment is not a Space member permission. See [Workflow Workspace
selection](USER_WORKFLOW_CONFIGURATION_V1.md#workspace-selection) and [Space
member rights](AUTHORIZATION_MODEL.md#space-member-rights-v1).

## Verification

Focused tests cover Workflow Workspace selection, missing-grant repair, Worker
resolution, Workspace read models, and the Workspaces page without a Space
access collection.
