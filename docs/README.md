# Documentation index

Start with [ARCHITECTURE.md](../ARCHITECTURE.md) (how the system is built),
[ROADMAP.md](../ROADMAP.md) (what is still open) and [AGENTS.md](../AGENTS.md)
(working and validation rules). Each document describes the system as it is now;
replaced decisions are deleted, not archived. `pnpm docs:check` verifies links,
anchors and repository paths named in code spans.

## How the system works

| Topic | Read |
| --- | --- |
| Protocol boundaries and versions | [Protocol boundaries](architecture/PROTOCOL_BOUNDARIES.md), [Unified messaging protocol](specifications/UNIFIED_MESSAGING_PROTOCOL_V1.md) |
| Technology stack | [Tech stack](architecture/TECH_STACK.md) |
| Authorization | [Authorization model](specifications/AUTHORIZATION_MODEL.md) |
| Persistence, events and delivery | [Persistence](specifications/PERSISTENCE.md), [Event streams](specifications/EVENT_STREAMS.md), [Realtime synchronization](specifications/REALTIME_SYNCHRONIZATION.md), [Database write paths](backend/WRITE_PATHS.md), [Backend migrations](../apps/backend/migrations/README.md) |
| Execution lifecycle | [Lifecycle](specifications/EXECUTION_LIFECYCLE_V9.md), [Command delivery and revocation](specifications/COMMAND_DELIVERY_AND_REVOCATION_V9.md), [Parallel execution](specifications/PARALLEL_EXECUTION_V9.md), [Worker activity](specifications/WORKER_ACTIVITY_V1.md), [Execution activity](specifications/EXECUTION_ACTIVITY_V9.md), [Workflow terminal events](specifications/WORKFLOW_TERMINAL_EVENTS_V9.md), [Input delivery](specifications/INPUT_DELIVERY_V1.md) |
| Conversations and context | [Conversation continuity](specifications/CONVERSATION_CONTINUITY_V1.md) |
| Work, Workflows and Workers | [Work v1](specifications/WORK_V1_CONTRACT.md), [User workflow configuration](specifications/USER_WORKFLOW_CONFIGURATION_V1.md), [First-party Worker catalog](specifications/FIRST_PARTY_WORKER_CATALOG_V1.md), [Worker execution options](specifications/WORKER_EXECUTION_OPTIONS_V2.md) |
| Connect and pairing | [Connect CLI and services](specifications/CONNECT_CLI_AND_SERVICES.md), [Worker pairing and sessions](specifications/WORKER_PAIRING_AND_SESSIONS.md) |
| Profiles | [Tool Profile v1](specifications/TOOL_PROFILE_V1.md), [Worker Profile V9](specifications/WORKER_PROFILE_V9.md), [Evidence contract](specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md), [Provider discovery](specifications/MODEL_DISCOVERY_NORMALIZATION.md), [Gemini/AGY Profile](architecture/GEMINI_AGY_PROFILE.md), [First-party Worker testing](architecture/FIRST_PARTY_WORKER_TESTING.md), [Profile Lab](specifications/PROFILE_LAB.md) |
| MCP and custom Workers | [MCP host](specifications/MCP_HOST_V1.md), [MCP management IPC](specifications/MCP_MANAGEMENT_IPC_V1.md), [MCP Worker Profile](specifications/MCP_WORKER_PROFILE_V1.md), [MCP golden vectors](specifications/mcp-vectors/README.md), [Plugin golden vectors](specifications/worker-plugin-vectors/README.md), [Plugin protocol](specifications/WORKER_PLUGIN_PROTOCOL_V1.md), [Plugin author guide](specifications/WORKER_PLUGIN_AUTHOR_GUIDE.md), [Plugin architecture and trust](architecture/CUSTOM_WORKER_PLUGINS.md) |
| Product areas | [Home](specifications/HOME_V1_CONTRACT.md), [People](specifications/PEOPLE_V1.md), [Reply](specifications/REPLY_V1.md), [Issue reporting](specifications/ISSUE_REPORTING_V1.md), [Account security UI](specifications/ACCOUNT_SECURITY_UI.md), [Discussion paging](specifications/DISCUSSION_PAGING.md), [Product vision](specifications/PRODUCT_VISION.md) |
| Web app internals | [AX server state](architecture/AX_SERVER_STATE.md), [Conditional reads](specifications/AX_CONDITIONAL_READS.md), [Mutation idempotency](specifications/MUTATION_IDEMPOTENCY.md), [Thread lifecycle](architecture/AX_THREAD_LIFECYCLE_V1.md), [Thread presentation](architecture/AX_THREAD_PRESENTATION_V1.md), [Timeline rendering](architecture/AX_TIMELINE_RENDERING_V1.md), [Work rendering](architecture/AX_WORK_RENDERING_V1.md), [Render diagnostics](architecture/AX_RENDER_DIAGNOSTICS_V1.md), [Web Work realtime](specifications/WEB_WORK_REALTIME_V9.md), [Work tab states](specifications/WORK_TAB_EXECUTION_STATES_V9.md) |
| Diagnostics and latency | [Diagnostic events](specifications/DIAGNOSTIC_EVENTS_V1.md), [Latency trace](specifications/LATENCY_TRACE_V1.md) |
| Email | [Email templates](architecture/EMAIL_TEMPLATES.md) |

## API

[Contract](api/CONTRACT.md) (errors, versioning, rate limits, pagination,
idempotency) and [Routes](api/ROUTES.md) (generated from
`apps/backend/src/domain/routes/table.ts`; do not edit by hand).

## Decisions

[Architecture decisions](decisions/README.md): one document per decision in force.

## Operations and deployment

[Environments](operations/ENVIRONMENTS.md), [Test and deploy scripts](operations/TEST_AND_DEPLOY_SCRIPTS.md),
[Production provisioning](operations/PRODUCTION_PROVISIONING.md),
[GitHub Actions](operations/GITHUB_ACTIONS.md), [Feature flags](operations/FEATURE_FLAGS.md),
[Connect onboarding](operations/CONNECT_ONBOARDING.md),
[Thread execution](operations/THREAD_EXECUTION.md),
[MCP Worker operations](operations/CUSTOM_WORKER_PLUGINS_OPERATIONS.md),
[Performance tests](operations/PERFORMANCE_TESTS.md), [Scaling decision](operations/SCALING_DECISION.md),
[Paddle sandbox](operations/PADDLE_SANDBOX.md),
[Cloudflare Access](operations/cloudflare-access.md),
[Codex CLI reproduction](operations/CODEX_CLI_REPRODUCTION.md),
[Markdown selection validation](operations/AX_MARKDOWN_SELECTION_VALIDATION.md).
Deployment: [Cloudflare](deployment/CLOUDFLARE.md), [VPS backend](deployment/VPS_BACKEND.md),
[VPS operations](deployment/VPS_OPERATIONS.md), [VPS realtime protocol](deployment/VPS_REALTIME_PROTOCOL.md),
[Email delivery verification](deployment/EMAIL_DELIVERY_VERIFICATION.md).
Runbooks: [Create a Worker and its Profile](runbooks/OPERATOR_RUNBOOK_CREATE_NEW_WORKER.md),
[Update a Profile](runbooks/OPERATOR_RUNBOOK_UPDATE_PROFILE.md).

## Security

[Authorization model](specifications/AUTHORIZATION_MODEL.md),
[Installing custom Worker plugins](security/CUSTOM_WORKER_PLUGINS.md),
[MCP threat model](security/MCP_THREAT_MODEL.md),
[Worker-first security review checklist](security/WORKER_FIRST_SECURITY_REVIEW.md).

## Design, brand and site

[Branding](BRANDING.md), [Brand and design system](design/SYNTILA_BRAND_SYSTEM.md),
[Public site specification](site/PUBLIC_SITE_SPECIFICATION.md),
[Public site release gate](site/PUBLIC_SITE_RELEASE_GATE.md),
[Demo](demo/README.md) and its [scene script](demo/scenes.md).

## Per-application READMEs

[Web app](../apps/app/README.md), [Connect](../apps/connect/README.md),
[Connect desktop app](../apps/connect_gui/README.md), [Profile Lab](../apps/profile_lab/README.md),
[Account manager](../apps/account_manager/README.md), [CLI Worker Engine](../engines/cli_worker/README.md),
[Profile files](profile-templates/README.md).

## Keeping documents current

- Change a document in the same change as the behavior it describes.
- Describe what is true now: no phase numbers, dates, "removed" or "obsolete"
  notes. Delete a replaced decision or history instead of keeping it.
- Prefer one canonical place per fact and link to it.
- Name code in backticks with its real path; `pnpm docs:check` fails when the
  path or an anchor no longer exists.
