# First-Party Worker Catalog Contract v1

**Contract ID:** `firstPartyWorkerCatalogVersion: 1`  
**Status:** Product identity frozen by ADR-015; runtime implementation updated by Architecture v8 / ADR-018

> V9 superseding note: this historical catalog specification predates the
> single-current-Profile model. Current catalog/profile behavior is defined by
> [WORKER_PROFILE_V9.md](WORKER_PROFILE_V9.md); its release channels, signed
> Profile envelopes, and channel-based resolution are not active contracts.

Syntila v1 initially provisions ChatGPT and Gemini as official Workers. The
official Worker Catalog is Cloud-managed and dynamically delivered. Additional
approved Worker Types can become available without a Workspace application
release when they can be expressed through an existing Engine family and
supported Tool Profile schema.

**Historical implementation rule:** a normal local CLI integration was a
Logical Worker implemented by the generic CLI Worker Engine and an official
signed Tool Profile Release. V9 uses a current Worker Profile instead.

## Cloud-owned Worker Catalog

Cloud `worker_catalog` is the only authority for logical Worker identity and
presentation metadata.

The catalog identity is deliberately separate from its implementation:

- `worker_catalog` stores stable logical product identities.
- `tool_profile_definitions` stores implementation bindings for those identities.
- `tool_profile_releases` stores immutable, signed, versioned implementation behavior.

Cloud permits at most one active Profile Definition per Worker. Replacing an
implementation does not change the Worker Type ID used by Threads,
permissions, inventory, scheduling, and history. Catalog identity and Profile
Definition must remain separate even when a Worker has exactly one active
implementation.

The initial official Workers are:

| Product type ID | User-facing name | v8 implementation | Cardinality per Workspace |
| --- | --- | --- | --- |
| `chatgpt` | ChatGPT | CLI Worker Engine + `chatgpt-codex` Profile -> Codex CLI | one stable catalog slot |
| `gemini` | Gemini | CLI Worker Engine + `gemini-antigravity` Profile -> `agy` | one stable catalog slot |
| `copilot` | Copilot | CLI Worker Engine + `copilot-cli` Profile -> GitHub Copilot CLI (`copilot`) | one stable catalog slot (testing stage) |
| `grok` | Grok | CLI Worker Engine + `grok-cli` Profile -> xAI Grok Build CLI (`grok`) | one stable catalog slot (testing stage) |

These are the initial entries, not an exhaustive list of Worker Types. New
approved entries can use an existing Engine family and the supported Profile
contract without an application-side ID-to-name mapping.

Workflows, Thread bindings, scheduling, history, and AX UI use logical
Worker IDs. They do not use Profile IDs, Engine versions, or provider
executable names as identity.

## WorkerDescriptor

Cloud resolves the catalog row with its active Tool Profile Definition and
returns this descriptor to consumers:

~~~text
workerTypeId
displayName
description
engineFamily
profileDefinitionId
providerToolName
releaseStage
visibilityState
sortOrder
~~~

The descriptor represents the Cloud-defined Worker. It never contains a local
Worker ID, local readiness, provider CLI version, locally downloaded Profile
release, local activation, or Workspace ID. Those are Workspace inventory and
readiness facts. A descriptor can be parsed without knowing or branching on
its Worker Type ID.

The authenticated human product catalog API is `GET /api/workers/catalog`. It
returns active, visible stable Workers with their active Profile Definitions.
It contains no local readiness or Profile release payload.

Workspace has a separate runtime catalog API at
`GET /api/workspace-runtime/workers/catalog`. It reads the Workspace's
selected Profile channel and returns every active, visible Worker with an
active Profile Definition eligible for that channel:

| Workspace channel | Eligible Worker release stages |
| --- | --- |
| `stable` | `stable` |
| `beta` | `beta`, `stable` |
| `testing` | `testing`, `beta`, `stable` |

Catalog discovery returns descriptors only. Signed Profile Release payloads
are delivered separately by `GET /api/tool-profiles?workerTypeId=…`; the
Workspace never receives Profile payloads as part of catalog discovery. A new
approved `worker_catalog` row and its active Profile Definition therefore
become discoverable without deploying Workspace or AX code.

Both catalog APIs use Cloud `worker_catalog` and the active Tool Profile
Definition relationship as their source, but keep human-session and Workspace
runtime authentication and response contracts separate.

## Workspace Workers page

The Workspace Workers page renders every local Worker from its Cloud catalog
descriptor. The displayed Worker name and ordering come from that descriptor;
the page does not maintain a provider-specific list:

~~~text
{descriptor.displayName}
provider CLI version
readiness
[Test]
[Enabled/Disabled]
~~~

Normal users do not:
- register new Cloud Worker catalog types;
- choose Tool Profile releases;
- edit Profile JSON;
- select arbitrary executables.

Platform-approved catalog additions appear through catalog sync without an app
deployment.

`WorkerCatalogCoordinator` owns the synchronization pipeline for startup,
periodic refresh, readiness, assignments, and the Workers page. It refreshes
when Workspace starts, after each Cloud runtime session finishes sync and
becomes ready (including reconnect or recovery from offline), when the Workers
surface opens, and before a user configures or tests a Worker. The Workers
surface also offers a manual refresh action. Cloud's selected Profile channel
is applied during the same Profile sync, so a channel change is observed on
the next refresh trigger. A 10-minute periodic refresh remains as a fallback;
these event-driven refreshes do not add background polling.

1. Load and publish the cached catalog immediately.
2. Fetch the current Cloud catalog and reconcile removed/changed descriptors.
3. Synchronize signed Profile releases for each currently eligible Worker.
4. Resolve the selected or best compatible local Profile.
5. Refresh local readiness and publish the completed view.

The Workers page observes coordinator state and requests refresh/setup through
the coordinator. It does not decide when or how catalog/Profile synchronization
runs.

The coordinator snapshot exposes one `WorkerCatalogWorkerState` in `workers`
for every catalog descriptor, including its local Worker, Profile availability,
provider tool state, and readiness. Registry mutations refresh the projection.
Missing or incompatible local Profiles do not hide a catalog Worker; the page reports states such as
`Resolving`, `Downloading`, `Available`, `Not downloaded`, `Incompatible`, and
`Unavailable` alongside local readiness.

The displayed Worker state is derived from those facts; it is not persisted in
`LocalWorker.status`. In precedence order, retired catalog entries, disabled
Workers, Profile sync/incompatibility/availability, local runtime availability,
authentication, provider CLI detection, readiness, and successful readiness
determine the display. This produces explicit states such as `Setup required`,
`Preparing integration…`, `Provider tool not installed`, `Authentication
required`, `Ready`, `Disabled`, `Incompatible`, `Catalog retired`, and
`Runtime unavailable`. A catalog descriptor remains visible when no local
Worker or Profile is installed.

After Cloud confirms a catalog refresh, locally configured Workers absent from
that catalog remain visible with `Catalog retired`; cached catalog contents do
not retire local Workers while refresh is still pending.

Cloud unavailability or an invalid Cloud response is never treated as an empty
catalog. Workspace retains its last locally validated catalog and continues
using locally verified signed Profile releases. Retirement is applied only
after a successful, validated authoritative catalog synchronization. Existing
configured Workers can therefore continue offline when their cached catalog
entry, signed Profile, local configuration, and provider CLI are still usable;
a failed catalog or Profile refresh alone does not retire or disable them.

After a successful synchronization, Workspace reconciles the previous and new
authoritative catalogs:

- A newly added descriptor appears immediately and its Profile is synchronized.
  Workspace does not create a local Worker slot; the user configures it.
- Changed metadata is reflected from the descriptor. Catalog metadata is not
  copied into persistent local Worker state.
- A descriptor removed or hidden by Cloud is unavailable for setup and
  assignment. Its local Worker record and diagnostics remain stored, but it is
  omitted from ready inventory, provider readiness probes, and assignment
  execution while absent.
- If the descriptor returns, the existing local Worker record is reused; no
  second slot is created.

Cloud inventory snapshots include only configured local Workers whose type is
present in the current catalog. For each included record, Workspace resolves a
verified Profile compatible with the Worker Type and Engine. If that Profile
or the Engine is unavailable, Workspace may retain the record for diagnostics,
but reports non-ready state and no Profile release version.
Cloud eligibility already rejects non-ready Workers and records without a
Profile release identity, so stale local readiness cannot make an orphan or
unrunnable Worker schedulable.

The authenticated human Worker inventory API composes catalog `displayName`
and `description`, plus the Workspace name, into each local inventory record.
AX reads these fields directly alongside readiness, capability, Engine,
Profile, and provider-tool details; Thread Worker choices render
`displayName · workspaceName` and retain the local Worker ID as the selection
value. AX does not join a separate catalog response or infer a display name
from the Worker Type ID.

Cloud also checks the authoritative catalog independently during scheduling
and Thread binding validation. The inventory Worker Type must still have
an active, visible catalog entry allowed by that Workspace's stable, beta, or
testing channel, and its Profile Definition must still be the matching active
definition. A retired or otherwise ineligible Worker is rejected even if a
Workspace continues to report it as ready.

Advanced Diagnostics may show:
- Engine version;
- Profile definition/release;
- Profile lifecycle channel;
- provider CLI version;
- last probe/test evidence.

Disabled and readiness remain independent states.

A disabled Worker can still be tested.

## Readiness ownership

Workspace owns local logical Worker state.

Engine + admitted Profile own provider-specific readiness behavior:
- provider executable discovery;
- version detection;
- passive authentication/config checks;
- live test;
- result/error normalization.

Workspace never runs provider commands directly.

Cloud receives only safe readiness/runtime projection.

## v8 implementation mapping

~~~text
chatgpt
  engineFamily: cli
  profileDefinitionId: chatgpt-codex

gemini
  engineFamily: cli
  profileDefinitionId: gemini-antigravity

copilot
  engineFamily: cli
  profileDefinitionId: copilot-cli

grok
  engineFamily: cli
  profileDefinitionId: grok-cli
~~~

The Profile release itself is selected by Workspace from trusted compatible
official releases.

Changing Profile release does not change the logical Worker ID.

## Provider authentication

Provider authentication remains owned by the installed provider CLI.

Syntila does not store/share provider subscription tokens in Cloud.

Examples:
- ChatGPT/Codex uses its locally configured Codex authentication.
- Gemini uses its locally configured Antigravity/Google authentication.
- Copilot uses its locally configured GitHub Copilot CLI login.
- Grok uses its locally configured Grok CLI login (`grok login`) or the
  user's own `XAI_API_KEY` environment.

Workspace may show safe readiness guidance returned by Engine/Profile but does
not reimplement provider login flows.

## Model selection

Models are not Worker Types.

AX/Thread assignment may select an optional model.

The Engine/Profile maps that model to the provider CLI only when supported.

No Profile may silently substitute a different model.

## Execution options

The logical Worker exposes the safe intersection of:
- signed Profile execution options;
- provider tool/version behavior;
- Workspace local permissions.

Cloud scheduling must never assume a capability solely because the Worker Type
normally supports it.

## Version evidence

v8 distinguishes:

~~~text
logical Worker type
Engine version
Profile definition/release
provider CLI version
provider model
~~~

Only the first item is the product Worker identity.

## Dynamic catalog expansion & Profile Lab administration

Architecture v8 permits a new approved logical Worker (such as `claude` or arbitrary CLI integrations) to be created and rolled out dynamically without modifying or redeploying Syntila Workspace or Syntila application source code.

### End-to-end creation flow:
1. **Creation in Profile Lab:** An authorized maintainer launches Syntila Profile Lab (`apps/profile_lab`) and creates a new `worker_catalog` entry and `tool_profile_definitions` binding via Cloud admin REST endpoints (`POST /api/admin/workers/catalog` and `POST /api/admin/workers/definitions`).
2. **Draft Authoring & Local Testing:** The maintainer authors an initial Draft Profile payload (`LocalDraftProfileCandidate`) and executes local passive probes, live probes, and diagnostic session tests directly against the provider CLI in Profile Lab's isolated test sandbox.
3. **Evidence Capture & Signed Publication:** Profile Lab collects a verified `ToolProfileEvidenceContract` artifact and submits it to Cloud (`POST /api/admin/workers/definitions/:id/releases`). Cloud verifies evidence, signs the profile payload using Ed25519, and creates an immutable `tool_profile_releases` row.
4. **Channel Promotion:** The maintainer promotes the release to the `testing` channel (`POST /api/admin/workers/definitions/:id/channels/testing`).
5. **Dynamic Workspace & AX Discovery:**
   - **Workspace:** On next periodic catalog sync (`GET /api/workspace-runtime/workers/catalog`), Workspace dynamically discovers the new `WorkerDescriptor`, downloads the signed Tool Profile (`ToolProfileReleaseAdmission`), configures the local Worker slot, verifies local provider CLI readiness, and syncs safe readiness to Cloud.
   - **Syntila:** On next catalog fetch (`GET /api/workers/catalog`), AX automatically renders the new Worker in Workspaces inventory, and Threads can bind task roles to it immediately.
   - **Execution:** When AX dispatches a Thread step to the new Worker, Cloud schedules the task to the ready Workspace, and Workspace executes it using the generic CLI Worker Engine (`engines/cli_worker`) configured by the signed Tool Profile.

Zero lines of application source code in `apps/workspace` or `apps/app` contain hardcoded Worker Type identities.

## Development/testing scalability proof

The optional v8 development seed includes `fixture-worker`, a testing-channel
Logical Worker mapped to the `fixture-cli` Tool Profile Definition. Its v1
release payload and offline version, readiness, success, and error fixtures
live under `packages/tool-profile/test/fixtures/`. The generic Profile fixture
harness and CLI Worker Engine acceptance test exercise it without a new
Workspace or Engine implementation or a provider-specific Worker executable.
The entry is excluded from the stable catalog and is not an official user-facing
Worker.

The dynamic catalog acceptance fixture separately introduces
`dynamic-test-worker` / `Dynamic Test Worker` with Profile Definition
`dynamic-test-cli`. These identifiers exist only in tests. Cloud schema and
catalog tests prove database discovery; Workspace tests prove catalog display,
signed Profile download, explicit local configuration, readiness, inventory,
and generic Engine execution; AX tests prove metadata display and Thread
selection; Cloud scheduler tests prove it can be assigned. The Workspace
fixture then retires the still-ready local Worker and verifies it is omitted
from inventory and rejected for new execution, before restoring the catalog
entry and confirming the same local Worker is eligible again. A Cloud scheduler
test independently rejects a stale Ready inventory row after retirement. AX
keeps a bound retired Worker visible as unavailable and preserves its binding
until the user selects a replacement. None of Workspace or AX production
source needs to know this Worker Type.

The same fixture restarts Workspace after persisting the catalog, signed
Profile, and configured local Worker, then makes Cloud unavailable. Workspace
loads the cached descriptor and verifies the installed Profile; local Engine
work still completes. A Cloud-side Worker addition and newer Profile remain
unseen until a successful sync. A retirement made while offline also leaves
the last-known-good Worker runnable; after Cloud reconnects and confirms the
retirement, inventory omits it and new assignments are rejected. Reactivation
reuses the existing local Worker record.

## Demo setup

The [Northstar demo guide](../demo/README.md#separate-demo-workspace-and-worker-setup) records the current V9 Profile and readiness prerequisites, provider-owned sign-ins, model selection and fallback. Catalog presence alone does not establish readiness or read-only Chat eligibility.
