# First-Party Worker Catalog Contract v1

**Contract ID:** `firstPartyWorkerCatalogVersion: 1`
**Decision:** [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md) (product
identity). Profile publication and delivery are in [Worker Profile V9](WORKER_PROFILE_V9.md).

The official Worker Catalog is Cloud-managed. Additional approved Worker Types become
available without a Connect or app release when they can be expressed through the
generic CLI Worker Engine and a Tool Profile ([Tool Profile v1](TOOL_PROFILE_V1.md)).

## Catalog and Profile

Cloud's `worker_catalog` is the only authority for logical Worker identity and
presentation: `worker_type_id`, `display_name`, `description`, `lifecycle_state`
(`active`, `retired`), `visibility_state` (`hidden`, `visible`), `release_stage`
(`testing`, `beta`, `stable`), `sort_order`, `engine_family` (`cli`),
`profile_definition_id`, `provider_tool_name`, and `origin` (`official`, or `plugin`
with an `owner_user_id` for a user's MCP Worker Type). Identity is deliberately
separate from implementation: the Worker Type ID used by Threads, permissions,
inventory, scheduling and history never changes when its Profile changes, and Workflows,
bindings and the app use Worker Type IDs, never Profile IDs, Engine versions or provider
executable names. Each Worker Type has at most one current published Profile (plus
bounded history) in `worker_profiles`.

The official Worker Types:

| Type ID | Name | Implementation |
| --- | --- | --- |
| `chatgpt` | ChatGPT | Engine + `chatgpt-codex` Profile → Codex CLI |
| `gemini` | Gemini | Engine + `gemini-antigravity` Profile → `agy` |
| `claude` | Claude | Engine + Claude Code Profile |
| `copilot` | Copilot | Engine + `copilot-cli` Profile → GitHub Copilot CLI |
| `grok` | Grok | Engine + `grok-cli` Profile → xAI Grok Build CLI |

This is the current official set, not an exhaustive list; the Profile files are in
`apps/profile_lab/assets/profiles/`. Release stage controls rollout visibility, not
Profile channels (there are none).

## Descriptor and API

`GET /api/workers/catalog` (authenticated human session) returns active, visible Worker
Types with their current Profile summary: `workerTypeId`, `displayName`, `description`,
`engineFamily`, `profileDefinitionId`, `providerToolName`, `lifecycleState`,
`visibilityState`, `sortOrder` and the current Profile revision, digest and update time.
It never contains a local Worker ID, local readiness, provider CLI version, Connect ID
or the Profile payload. A consumer can parse a descriptor without branching on its Type
ID, and no application code hard-codes Worker Type identities. The authenticated Worker
inventory composes the catalog `displayName` and `description` with the Worker's own
name and readiness, so the app reads them directly and never joins a separate catalog
response or derives a name from the Type ID. Admin reads and publication are the
`/api/admin/workers…` routes in [the route table](../api/ROUTES.md).

Connect receives a Worker's Type when the owner creates and pairs that Worker; it
fetches the Profile pinned for it (`GET /api/worker-agent/profile`), verifies it and
activates it ([Connect CLI and services](CONNECT_CLI_AND_SERVICES.md)). Cloud also
checks the catalog independently at scheduling and binding time: a Worker Type that is
retired, hidden or no longer matching its Profile is rejected even if a Connect still
reports it ready, and a Worker with no current Profile identity is never schedulable.
Retiring a Type removes it from setup and new assignments; existing local records and
history are kept and become usable again if the entry returns.

## Readiness ownership

Connect owns local Worker state. The Engine with the admitted Profile owns
provider-specific readiness: executable discovery, version detection, passive
authentication and configuration checks, the live test and result and error
normalization. Connect never runs provider commands directly, and Cloud receives only a
safe readiness projection ([Execution lifecycle](EXECUTION_LIFECYCLE_V9.md)). Disabled
and readiness are independent states, and a disabled Worker can still be tested.
Advanced diagnostics may show the Engine version, Profile definition and revision,
provider CLI version and last probe or test evidence.

## Authentication, models and options

Provider authentication belongs to the installed provider CLI (Codex, Antigravity,
Claude Code, the Copilot CLI login, or `grok login` / the user's own `XAI_API_KEY`);
Syntila stores no provider tokens in Cloud and does not reimplement provider logins,
only showing safe guidance the Engine and Profile return.

Models are not Worker Types. A request may select an optional model, which the
Engine and Profile map to the provider CLI only when supported; no Profile silently
substitutes another model. A Worker exposes the safe intersection of its Profile's
execution options, the provider tool and version behavior, and Connect's local
permissions, and Cloud scheduling never assumes a capability just because the Type
normally has it ([Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md)).

Product identity is only the logical Worker Type; the Engine version, Profile
definition and revision, provider CLI version and provider model are evidence, kept
distinct.

## Adding a Worker Type

An authorized maintainer creates the catalog entry and its first candidate in Profile
Lab, tests it locally against the real provider CLI, and publishes it through Cloud
([runbook](../runbooks/OPERATOR_RUNBOOK_CREATE_NEW_WORKER.md),
[Profile Lab](PROFILE_LAB.md)). Cloud validates, stores the next current revision and
makes the Type discoverable; owners can then create Workers of that Type and Connect
fetches the Profile on demand, with no change to `apps/connect` or `apps/app` source.

Tests use fixture Worker Types that exist only in test fixtures
(`packages/tool-profile/test/fixtures/`, `worker-profile-v9-registry.test.ts`,
`apps/app/test/ax_worker_descriptor_test.dart`) and are not official user-facing Workers.
For demo setup see the [demo guide](../demo/README.md#demo-connect-and-worker).
