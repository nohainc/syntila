# Architecture decisions

Each ADR records one decision that is in force. Superseded decisions are deleted, not kept; the current system is described in [ARCHITECTURE.md](../../ARCHITECTURE.md).

| Decision | Status |
| --- | --- |
| [ADR-005: Better Auth for human authentication](ADR-005-authentication-architecture.md) | Accepted |
| [ADR-015: First-Party Worker v1 Contract](ADR-015-first-party-worker-v1-contract.md) | Accepted; current first-party logical Worker identity and ca |
| [ADR-019: Per-user Workflow execution configuration](ADR-019-per-user-workflow-execution-configuration.md) | Accepted; extended by shared Space overrides (see configurat |
| [ADR-022: Free and paid account plans](ADR-022-account-plans.md) | Accepted; billing through Paddle is not live |
| [ADR-023: One concurrent AI execution for Free accounts](ADR-023-free-execution-concurrency.md) | accepted. Extends [ADR-022](ADR-022-account-plans.md). |
| [ADR-024: Free Spaces hold up to four people](ADR-024-free-space-member-limit.md) | accepted. Extends [ADR-022](ADR-022-account-plans.md). |
| [ADR-025: Plan-based attachment storage and file limits](ADR-025-plan-attachment-limits.md) | accepted. Extends [ADR-022](ADR-022-account-plans.md). |
| [ADR-026: Research as independent parallel researchers plus synthesis](ADR-026-research-parallel-synthesis.md) | Accepted; implemented behind the preview gate |
| [ADR-027: Custom Worker plugins (Syntila Plus)](ADR-027-custom-worker-plugins.md) | Accepted; MCP Worker execution per [ADR-041](ADR-041-mcp-workers-on-worker-agents.md) |
| [ADR-028: MCP integration (custom Workers)](ADR-028-mcp-integration.md) | Accepted (scoped to MCP Workers; see ADR-041). |
| [ADR-029: Direct Spaces and Personal Connections](ADR-029-direct-spaces-and-personal-connections.md) | Accepted |
| [ADR-030: Phased 'Implement' workflow and catalog consolidation](ADR-030-implement-phased-workflow.md) | Accepted and implemented |
| [ADR-032: Worker Instance and Actor Identity](ADR-032-worker-instance-and-actor-identity.md) | Accepted and implemented |
| [ADR-033: Durable Events, Transactional Outbox and Worker Command Inbox](ADR-033-durable-events-outbox-and-command-inbox.md) | Accepted and implemented |
| [ADR-034: Syntila Connect, pairing and session fencing](ADR-034-connect-pairing-and-session-fencing.md) | Accepted and implemented |
| [ADR-035: Worker-targeted execution and eligibility](ADR-035-worker-targeted-execution.md) | Accepted and implemented |
| [ADR-036: Canonical Thread Timeline and Actor Attribution](ADR-036-canonical-thread-timeline-and-attribution.md) | Accepted and implemented |
| [ADR-037: Request files and artifact handoff between Workers](ADR-037-files-and-artifacts.md) | Accepted and implemented |
| [ADR-038: Unified Realtime Transport for Human and Worker Actors](ADR-038-unified-realtime-transport.md) | Accepted and implemented |
| [ADR-039: Horizontal Scaling Across Multiple Bun Nodes](ADR-039-horizontal-scaling.md) | Accepted; activation is gated on measured load (not active). |
| [ADR-040: Stateful Workflows on Worker Agents](ADR-040-stateful-workflows-on-worker-agents.md) | Accepted (option A) and implemented. |
| [ADR-041: MCP Workers on Worker Agents](ADR-041-mcp-workers-on-worker-agents.md) | Accepted (option A) and implemented. |
| [ADR-042: Per-Space Member Access for Worker Instances](ADR-042-worker-space-member-access.md) | Accepted and implemented |
| [ADR-043: Person Shares for Workers, and one account per computer](ADR-043-worker-person-shares-and-one-account-per-computer.md) | Accepted and implemented |
| [ADR-044: Device folders and the Space folder](ADR-044-device-folders-and-space-folders.md) | Accepted and implemented |
