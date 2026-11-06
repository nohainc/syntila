# Syntila Architecture v8 — Generic Worker Engine and Tool Profiles

**Status:** Accepted architecture and implementation target  
**Release declaration:** Withheld; acceptance gates remain open

**Date:** 2026-10-01  
**Product contracts:** Work v1, Workspace lifecycle, logical Worker catalog
**Primary decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)

## 1. Executive decision

Architecture v8 uses one generic isolated CLI Worker Engine and signed
Cloud-managed Tool Profiles:

~~~text
Syntila
    |
    v
Syntila Cloud
    |
    v
Syntila Workspace
    |
    | Local Worker Protocol 4.1
    v
Syntila CLI Worker Engine
    |
    | signed Tool Profile
    v
provider CLI
~~~

## Architecture contract

The sole v8 execution path is:

~~~text
AX → Cloud → Workspace → CLI Worker Engine → signed Tool Profile → provider CLI
~~~

The following are explicit architecture exclusions, not deferred extension
points or compatibility targets:

~~~yaml
prohibitions:
  provider_specific_worker_executable: true # Syntila-authored only; user plugins: ADR-027
  browser_or_web_ai_worker: true
  interactive_connector: true
  syntila_managed_provider_credentials: true
  agent_runtime: true
  configured_worker_product_entity: true
  pre_v8_goal_phase_task_orchestration: true
  compatibility_api_for_unreleased_architecture: true
~~~

In v8, a provider CLI is invoked only by the generic CLI Worker Engine under a
signed Tool Profile. Provider authentication remains in the provider CLI's
local installation. Workspace is the machine-side runtime; there is no separate agent-managed
runtime product. Work v1 owns its bounded Workflow and Step orchestration.
Unreleased architecture versions receive no API aliases or compatibility
surface.

**Plugin clarification ([ADR-027](../decisions/ADR-027-custom-worker-plugins.md)).**
`provider_specific_worker_executable` excludes Syntila-authored provider
executables. A Syntila Plus user may import a Worker plugin that the generic CLI
Worker Engine's plugin host supervises: `AX → Cloud → Workspace → CLI Worker
Engine → pinned plugin digest → plugin process`. Official Workers keep the path
above unchanged, and no Syntila code names a plugin or provider.

The v8 architecture guard checks that this contract remains present alongside
the assignment path and schema invariants.

Failure reporting follows the same trusted execution path. The Cloud issue
reporting contract and D1/R2 storage model are defined in
[`ISSUE_REPORTING_V1.md`](../specifications/ISSUE_REPORTING_V1.md); clients
submit only a failed Work request reference and Cloud derives the report from
authoritative execution records.

### 1.1 Canonical v8 terminology

Use these terms for v8 architecture, implementation, tests, and operations:

- **Logical Worker** — stable product identity selected by Threads and Work;
- **CLI Worker Engine** — generic isolated executable supervised by Workspace;
- **Tool Profile Definition** — stable official provider integration identity;
- **Tool Profile Release** — immutable signed payload for a definition;
- **Profile lifecycle/channel** — Cloud-managed release state and promotion;
- **Provider CLI** — locally installed tool such as `codex` or `agy`;
- **Local Worker Protocol 4.1** — Workspace-to-Engine contract.

The `@syntila/core` package organizes current domain contracts by concept
(`space`, `workspace-grants`, `thread`, `integration`, and
`observability`). Current source uses domain names rather than architecture
version labels.

Workspace, Worker, Worker Type, Thread, Work Request, and Work v1 Workflow
remain canonical product/domain terms. The generic Engine is the sole
production CLI Worker runtime. Live provider and release acceptance are
tracked as release gates in the current implementation roadmap.

Examples:

~~~text
ChatGPT
-> CLI Worker Engine
-> chatgpt-codex profile
-> codex

Gemini
-> CLI Worker Engine
-> gemini-antigravity profile
-> agy
~~~

The logical Worker identity remains stable. Workflows, user execution preferences,
scheduling, collaboration history, and AX UX continue to target ChatGPT,
Gemini, and future approved logical Workers rather than implementation details.

## 2. Product mental model

Users should understand only:

> **Space** = collaboration boundary (Group Space for team/project collaboration; Direct Space for 1:1 personal connection).\
> **Thread** = persistent unit of work and conversation.\
> **Workspace** = machine where AI can execute.  
> **Worker** = AI/tool choice available on that Workspace.  
> **Workflow** = Syntila-defined way to perform work.

Users do not need to understand:
- Worker Engine;
- Tool Profiles;
- profile releases/channels;
- engine/profile compatibility;
- Local Worker Protocol.

Normal Workspace UI remains Worker-centric.

## 3. Product topology

~~~text
                         SYNTILA
                             |
                             v
                       SYNTILA CLOUD
                             |
                   Workspace Runtime Protocol
                             |
                             v
                    SYNTILA WORKSPACE
                             |
                   Local Worker Protocol 4.1
                             |
                             v
                    CLI WORKER ENGINE
                             |
               +-------------+--------------+
               |                            |
      chatgpt-codex profile       gemini-antigravity profile
               |                            |
               v                            v
             codex                         agy
~~~

At runtime, each assignment/probe starts its own engine child process by
default. Multiple assignments may run concurrently according to Worker and
Workspace concurrency limits.

## 4. Application boundaries

### Cloud API surface

Cloud's HTTP handlers are grouped by current product domain under
`apps/cloud/src/routes/`: authentication, Spaces, Workspaces, Threads,
Work, Tool Profiles, and Workspace/application releases. The Workspace Gateway
is the authenticated runtime surface. Thread Discuss provides
collaboration; Work v1 Work Requests provide execution.

### 4.1 Syntila

AX remains the human web application.

It owns:
- Spaces (`group` and `direct`) and Threads;
- Personal direct conversations (under a dedicated Personal navigation hierarchy);
- Discuss;
- Work;
- built-in Workflow selection;
- user Workflow execution preferences;
- model selection where supported;
- Work history/results;
- read-only Workspace/Worker operational visibility.

AX never sees provider credentials, local tool paths, provider session IDs, or
raw Tool Profile configuration.

### 4.2 Syntila Cloud

Cloud remains the collaboration/orchestration control plane.

It owns:
- human accounts and Space membership;
- Threads and Work Requests;
- built-in Work v1 definitions;
- safe Workspace/Worker inventory;
- scheduling and assignment snapshots;
- Workspace Gateway;
- logical Worker catalog;
- official Tool Profile definitions/releases/channels;
- profile release audit/revocation;
- release trust metadata.

Cloud does not execute provider CLIs.

#### Authorization boundaries

Cloud request identity contains the authenticated human, session, and current
Space membership roles. Spaces are categorized into `group` and `direct` kinds
(ADR-029). Space reads, writes, and Work execution are checked against the Space
membership on each request. In Direct Spaces, technical ownership is retained for
schema compatibility, while both participants hold symmetric conversation and
Thread rights. Direct Spaces reuse the existing Thread, Discuss, Work Request,
and AI History infrastructure. Workspace membership roles and organization
aliases are not authorization principals.

Execution Workspaces have one owner. Workspace operations recheck that owner
against the Workspace row. A Space can use an Execution Workspace only
through an active Space → Workspace Grant; Space membership alone does not
grant machine access. Thread access is checked separately by the Thread
policy.

Desktop installation ownership is stored independently in the Cloud
`workspace_installations` table, keyed by the persistent installation ID and
pointing to one owner and canonical Execution Workspace. Runtime credentials
remain in `workspace_runtime_identities` and can be rotated or revoked without
changing ownership. Explicit release changes the installation record to
`released`; re-registration by another account can then create a new Workspace
binding. The legacy runtime `installation_id` column is retained for deployed
schema compatibility, but it is not an ownership authority. D1 primary and
unique partial indexes enforce one ownership row per installation, one active
installation per Workspace, and one unrevoked runtime identity per Workspace.

Tool Profile administration and release operations use separate Cloud
allowlists: `SYNTILA_PROFILE_ADMIN_USER_IDS` grants catalog and draft
administration, while `SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS` grants
publication and rollout management. Workspace ownership and Space roles do
not grant either permission. Stable promotion and channel rollback require
fresh session-bound passkey step-up authentication. Release revocation uses
release-manager authorization, a mandatory reason, and explicit Profile Lab
confirmation.
Profile Lab stores its desktop session in the macOS Keychain and removes legacy
plaintext session files during migration. Sandbox runs use unique private
scratch directories, cancel active Engine work during teardown, and fail if
cleanup cannot be verified.

### 4.3 Syntila Workspace

Workspace remains the persistent machine-side trust and execution supervisor.

It owns:
- human/runtime identity;
- local Work Root;
- Thread directory resolution;
- logical Worker local state;
- local permissions;
- engine installation/version selection;
- signed Tool Profile synchronization/cache;
- profile signature/digest/schema validation;
- profile eligibility/resolution;
- engine child-process supervision;
- outer deadlines/cancellation;
- logs/diagnostics aggregation;
- safe Worker readiness synchronization to Cloud.

Signed Profile releases are materialized under Workspace-managed
`Profiles/<profileDefinitionId>/<releaseVersion>/profile.json` directories,
with signed release metadata beside each immutable payload and active/LKG
pointers in `release-state.json`. Workspace refreshes Cloud revocations before
release sync and validates the shared Profile v1 schema and trust envelope
before writing. Cache updates are independent of Engine and Workspace
application versions.

Every normal assignment resolves its enabled, ready Logical Worker from local
Workspace state, selects a signed Tool Profile using the same channel and
provider-version rules as readiness, and runs it through
`CliWorkerEngineSupervisor.execute()`. The execute frame carries only the
bounded Workspace
execution policies `restricted` and `provider_default`; provider Profile
arguments map those policies to CLI-specific sandbox flags.

Workspace does **not** know provider-specific commands or event formats.

### 4.4 CLI Worker Engine

The CLI Worker Engine is one generic standalone Dart console executable.

It owns:
- bounded Tool Profile runtime parsing and identity/digest checks;
- provider CLI discovery from Profile candidates and approved locations;
- verified cached executable paths, generic OS search locations, bounded PATH
  search, and executable validation;
- provider environment construction within engine policy;
- passive/live probe execution;
- command/argument construction;
- prompt transport;
- provider event parsing;
- provider session integrity/storage;
- progress/result/error normalization;
- process cleanup for the provider child;
- engine-side logs/diagnostics.

It has no Cloud credentials and never connects directly to Cloud.

Workspace verifies official release signatures and performs canonical Tool
Profile v1 schema admission before launching the Engine. The Engine rechecks
the loaded payload digest, identity, compatibility, and execution bounds before
accepting Protocol 4.1 requests (and legacy 4.0 frames without catalog pins).

### 4.5 Tool Profile

A Tool Profile is an immutable signed declarative provider integration release.

It describes provider behavior only through the finite v8 profile schema.

A profile may not contain arbitrary code or shell commands.

Official profile release lifecycle:

~~~text
draft -> testing -> beta -> stable -> retired
                              |
                              +-> revoked
~~~

The actual lifecycle may skip beta for urgent fixes, but stable promotion is
always explicit and audited.

Cloud selects the Profile channel for each Workspace. A Workspace without an
explicit internal override receives `stable`; platform-admin development
operations may opt a Workspace into `testing` or `beta`. The Workspace runtime
authenticates its catalog request with its runtime credential, and Cloud derives
the allowed channel from that identity. The catalog API rejects caller-supplied
channel selection. Normal users do not choose Profile channels in AX or
Workspace settings. Each selected release is still signature-checked and
passively validated locally before activation; real provider acceptance is an
explicit test action.

## 5. Protocol boundaries

Architecture v8 keeps three wire/trust boundaries:

~~~text
AX <-> Cloud
Human Product Protocol

Cloud <-> Workspace
Workspace Runtime Protocol

Workspace <-> CLI Worker Engine
Local Worker Protocol 4.1
~~~

Provider CLI communication exists below the Local Worker Protocol and is private
to Engine + Tool Profile.

The boundaries share canonical IDs only. They do not share credentials.

## 6. Local Worker Protocol 4.1

Protocol 4.0 carries the provider-neutral operations required by Workspace and
the Engine:

~~~text
initialize
probe(passive|live)
execute
progress
result
error
~~~

Identity now contains:

~~~text
workerTypeId
engineVersion
profileDefinitionId
profileReleaseVersion
profileSchemaVersion
providerToolName
providerToolVersion
~~~

Workspace supplies the admitted profile payload/reference and expected logical
Worker identity. Engine initialization must prove the resolved identity matches
the Workspace-selected release.

The protocol never carries:
- provider credentials;
- provider session IDs;
- arbitrary executable paths from Cloud;
- arbitrary shell command text.

## 7. Process architecture

Default execution:

~~~text
Workspace
└── CLI Worker Engine
    └── provider CLI
~~~

Concurrent example:

~~~text
Workspace
├── CLI Worker Engine [ChatGPT]
│   └── codex
├── CLI Worker Engine [ChatGPT]
│   └── codex
└── CLI Worker Engine [Gemini]
    └── agy
~~~

Workspace is the ultimate kill authority over the Engine process tree.

The Engine is separate from the Workspace service process to preserve crash,
memory, parser, and provider isolation.

## 8. Engine deployment/versioning

There is one CLI Worker Engine release per supported platform/architecture.

Example:

~~~text
syntila-cli-worker 1.3.0

macos-arm64
macos-x64
linux-arm64
linux-x64
windows-x64
...
~~~

Initially, the signed/notarized Workspace application release is the Engine
trust boundary. Each Workspace build bundles one known-good Engine executable
for its platform. The executable is not fetched from Cloud and has no mutable
database lifecycle. Its version is compiled into the Workspace supervisor and
is independently reported by Engine initialization and diagnostics.

At startup, Workspace bounds and hashes the bundled asset, then materializes it
into the managed application-support directory:

~~~text
<WorkspaceData>/
  Engines/
    cli_worker/
      1.0.0-<sha256>/
        syntila-agent[.exe]
~~~

The version and digest make each materialized artifact immutable and
content-specific. Workspace restricts directory/executable permissions and
rechecks an existing artifact against the bundled bytes on startup; altered or
incomplete cached bytes are replaced from that trusted bundle. A missing,
oversized, or unmaterializable Engine fails closed and leaves the Worker
runtime unavailable.

The active Engine is exactly the one bundled by the installed Workspace
release. There is no independent Engine active/LKG pointer and no Engine
selection from Profile lifecycle metadata. Engine changes therefore ship with
a Workspace release. Until the Workspace application update transaction has
verified drain, staging, restart, health check, and rollback, recovery from a
bad Engine release means reinstalling the previous verified signed/notarized
Workspace release as a whole. The Engine is not silently replaced by an older
cached executable. Independent signed Engine delivery may later add its own
immutable platform artifacts, trust/revocation checks, candidate admission,
health check, and atomic active/LKG rollback; that mechanism is not required
for v8 acceptance.

## 9. Tool Profile domain model

### 9.1 Profile definition

Stable integration identity:

~~~text
profileDefinitionId = chatgpt-codex
logicalWorkerTypeId = chatgpt
engineFamily = cli
~~~

### 9.2 Profile release

Immutable configuration:

~~~text
definition = chatgpt-codex
releaseVersion = 9
schemaVersion = 1
channel/status = stable
engineCompatibility = >=1.2 <2.0
providerToolCompatibility = >=0.176 <0.190
signedPayload = ...
~~~

### 9.3 Channel pointer

Cloud records which eligible release is currently:
- testing;
- beta;
- stable.

Promotion changes pointers/state, never release payload contents.

## 10. Tool Profile schema

The normative schema is defined in
[Tool Profile v1](../specifications/TOOL_PROFILE_V1.md).

At a high level it contains:

~~~text
identity
engineCompatibility
providerTool
discovery
versionProbe
compatibility
authProbe
environment
execution
stdin
output
events
session
model
progress
errors
sandboxPolicy
limits
~~~

The schema uses typed enums and bounded placeholders rather than executable
expressions.

## 11. Profile resolution

Workspace/Engine resolution inputs:

~~~text
logical Worker
Engine version
platform
provider tool name
provider tool version
profile channel/policy
revocation state
~~~

Resolution returns one signed eligible profile release.

Workspace resolves locally cached, signature-verified releases in this order:

1. locally active verified release if still eligible;
2. current compatible stable release;
3. last-known-good compatible stable release where permitted;
4. otherwise Worker becomes Setup required / Needs attention.

Compatibility uses semantic-version ranges with an inclusive minimum and
exclusive maximum. The current stable candidate is the version selected by
the latest successful stable catalog sync; it is tracked separately from the
active pointer so a local rollback cannot make an older release appear current.
Every candidate must match the requested logical Worker, definition, channel,
Engine range, provider CLI range, and current revocation policy. An unsupported
provider CLI version returns unavailable and never selects an incompatible
profile.

## 12. Profile update/rollback

Profile updates are lightweight and independent from Workspace/Engine binaries.

Workspace rollback selects a locally cached, signature-verified, compatible
last-known-good release. It initializes the Engine and runs a passive probe
against that candidate before atomically switching the active Profile pointer.
The previous active release becomes last-known-good. A failed validation leaves
the current pointers unchanged; rollback never sends a model request.

Revocation makes a release ineligible as soon as the refreshed revocation state
is applied. If it was active, Workspace clears that active pointer first, then
resolves and passively probes another eligible release before activation. A
cached release is never promoted solely because it remains trusted. If no
eligible release passes, the Worker is marked Needs attention. Provider
authentication, quota, and service outages do not trigger Profile rollback;
they remain readiness failures for the current release.

~~~text
Cloud stable pointer -> new release
        |
        v
Workspace fetches signed release
        |
        v
verify signature/digest/schema
        |
        v
verify Engine/provider compatibility
        |
        v
candidate initialize + passive probe
        |
        v
activate
~~~

No live model request is required for every automatic stable update.

Workspace first caches a validated release as an inactive candidate. The
candidate Engine performs initialize and a passive provider probe before one
atomic release-state update changes the active/stable pointers and records the
previous active release as last-known-good. If the Engine or a matching local
Worker is unavailable, or the candidate probe fails, the candidate remains
cached and the previous active/LKG pointers stay unchanged.

Testing/beta promotion should run fixture and real provider acceptance.

Workspace retains active and last-known-good profile releases locally.

## 13. Trust model

Profile configuration is treated as executable behavior policy.

Trust chain:

~~~text
Cloud metadata
-> signed immutable profile payload
-> Workspace signature/digest verification
-> schema validation
-> engine compatibility validation
-> provider compatibility validation
-> candidate probe
-> activation
~~~

The Engine rejects schema constructs that would weaken runtime invariants.

Workspace continues to own publisher trust/revocation.

## 14. Profile security invariants

A Profile cannot:
- invoke a shell;
- construct one free-form shell command;
- disable output/deadline limits;
- inherit unrestricted environment;
- select arbitrary helper programs;
- escape Thread/state boundaries;
- turn off session consistency validation;
- override Workspace local permissions;
- redefine Local Worker Protocol behavior.

Executable discovery is bounded to profile-declared provider tool candidates and
engine-approved discovery mechanisms.

Arguments are arrays, not shell strings.

## 15. Profile version compatibility

Profile releases explicitly support provider CLI versions.

Prefer new releases for material behavior changes.

Example:

~~~text
chatgpt-codex@9
codex >=0.160 <0.176

chatgpt-codex@10
codex >=0.176 <0.190
~~~

Small compatible variations may use bounded overrides inside one profile if the
schema can express them clearly and test fixtures cover them.

Do not accumulate large behavior branches in one profile.

## 16. Official Worker catalog

The logical Worker catalog is Cloud/product data, not compiled provider code.

Syntila v1 initially provisions ChatGPT and Gemini as official Workers. The
official Worker Catalog is Cloud-managed and dynamically delivered. Additional
approved Worker Types can become available without a Workspace application
release when an existing Engine family and supported Tool Profile schema can
express them.

Initial Workers:

~~~text
ChatGPT -> chatgpt-codex
Gemini  -> gemini-antigravity
~~~

A future approved Worker may be added without changing the Workspace
application when it fits an existing Engine family, has a valid signed Profile
using the supported schema, and Cloud catalog policy enables it.

The user cannot add arbitrary catalog/profile entries in v8.

## 17. Workspace UI

> **Note (2026-10):** the Flutter Workspace UI described in this section was removed. Workspace is a headless Dart service plus the `syntila` CLI; Worker-centric presentation now lives in AX and the CLI `workers` output. See [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

Keep current UX.

Normal row:

~~~text
ChatGPT                  Ready
Codex 0.177
[Test] [Enabled]
~~~

Advanced diagnostics:

~~~text
Worker              ChatGPT
Engine              1.3.0
Integration Profile chatgpt-codex@10
Profile channel     Stable
Provider tool       Codex 0.177
Last passive probe  Passed
Last live test      Passed
~~~

Do not expose:
- profile JSON;
- profile editing;
- arbitrary executable selection;
- profile release channel selection to normal users.

## 18. Worker readiness

Readiness remains logical-Worker based.

A Worker is effectively ready when:

~~~text
Engine available
AND official Profile resolved/verified
AND provider CLI discovered
AND supported provider CLI version
AND passive auth/config checks pass
AND local permissions permit required behavior
AND optional setup live test has passed when product policy requires it
~~~

Disabled remains independent from readiness.

Testing a disabled Worker does not enable it.

## 19. Sessions

Syntila session keys remain provider-neutral.

~~~text
Work/Workflow
-> logical sessionKey
-> Engine/Profile
-> provider session ID
~~~

Provider session IDs remain local.

Profile describes extraction/resume mapping; Engine enforces identity continuity.
Workspace session state is partitioned by logical Worker, Profile definition,
provider tool identity, and logical `sessionKey`. A Profile Release may resume
an older provider session format only when its signed compatibility list names
that format; otherwise Engine starts a fresh provider session.

Separate sessions remain mandatory for independent verification steps.

## 20. Work v1

Architecture v8 uses the [Work v1 Contract](../specifications/WORK_V1_CONTRACT.md)
for Workflow and Step semantics. Work v1 binds logical Workers and remains
independent of Engine versions, Profile releases, and provider CLI formats.

Canonical Steps:

~~~text
Chat
Research
Plan
Implement
Test
Verify
~~~

Built-in Workflows:

~~~text
Chat
Work
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Work is `direct:v2`, the current user-facing version of stable ID `direct`;
`direct:v1` retains its immutable historical name Direct. Chat (`chat:v1`) is a
read-only conversational Workflow: its Work Request is stateless and acquires
no mutation lease, but its provider session is durable within the Thread.
Work is writable, has its own durable provider session, and participates in
Thread mutation coordination. Research, Plan, Test and Verify keep their
existing semantics and request/Step session scopes. Full Cycle excludes Chat.

User Workflow configuration supplies sparse execution defaults and step overrides.
Cloud resolves the owned logical Worker and signed Profile release at acceptance,
freezing nullable model/effort and identity/version per step. Workspace executes
that admitted Worker under the signed Profile through the generic Engine.

```text
Workflow Definition → User Workflow Configuration (Space owner)
                     → Space Workflow Configuration
                     → Scope default Workflow selection
                     → Execution Resolution
                     → WorkflowRun → StepRun
```

The default Workflow selection is a user/Space preference, separate from the
sparse Worker/model/effort configuration. It starts at Chat, cannot point to a
disabled Workflow, and returns to Chat if the selected default is disabled.

Thread preference remains a future layer. A one-step Composer override is a
transient current-request input and is never persisted; Workflows remains the
sole editor for saved execution settings. Thread configuration keeps only
authored context and initial Workflow selection. See
[ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md) and
[User Workflow Configuration v1](../specifications/USER_WORKFLOW_CONFIGURATION_V1.md).

Research and Plan are stateless read-only Steps and may execute on any eligible
Workspace covered by the Space grant. A Work Request containing any stateful
Step acquires one Thread runtime lease and holds it until the request is
terminal. The lease serializes stateful Work Requests for that Thread,
selects the Primary Workspace, and carries a fencing token that Workspace
checks before filesystem mutation. Implement may write the ID-derived
Thread directory; Test and Verify run against that same filesystem with
read-only effective permissions. The request-scoped lease remains held while
stateless Research or Plan Steps in that same request run.

## 21. Database target

### 21.1 Logical Worker catalog

Cloud product catalog:

~~~text
worker_catalog
  worker_type_id
  display_name
  description
  engine_family
  visibility_state
  release_stage
  sort_order

worker_catalog = stable logical product identity and presentation metadata
tool_profile_definitions = replaceable implementation bindings for a Worker
tool_profile_releases = immutable, signed, versioned implementation behavior

WorkerDescriptor = worker_catalog row joined to its active
tool_profile_definitions row:
  workerTypeId, displayName, description, engineFamily,
  profileDefinitionId, providerToolName, releaseStage, visibilityState,
  sortOrder
~~~

These tables represent separate identities and lifecycles; do not collapse
`worker_catalog` into `tool_profile_definitions`. Product references use the
stable `worker_type_id`. A Profile Definition binds that identity to an
implementation, and signed releases version the behavior of that definition.
Replacing an implementation retires its old Definition and activates a new
one while preserving the catalog Worker ID. A partial unique index permits at
most one active Profile Definition per Worker.

Each active catalog entry is joined to its active Tool Profile definition.
Workspace receives visible entries eligible for its Cloud-selected channel;
it cannot request a different channel. Profile release resolution is separate,
so a Worker can still render while its Profile is unavailable and must remain
unrunnable until a trusted compatible release is selected. A catalog entry can
be created only by a platform administrator through the approved catalog
operation, which may create the initial logical Worker and Profile Definition
together. Workspace users cannot create catalog entries. Each release remains
signed, immutable, and independently validated before local activation.

AX reads descriptors through the authenticated human product API
`GET /api/workers/catalog`. It returns the stable catalog and never serves
Profile release payloads. Workspace reads its channel-scoped catalog through
`GET /api/workspace-runtime/workers/catalog`; signed Profile Release payloads
are fetched separately from `GET /api/tool-profiles` for one Worker Type. The
runtime catalog applies the selected-channel stage policy: stable includes
stable Workers, beta includes beta and stable, and testing includes testing,
beta, and stable. Both catalog routes use `resolveLogicalWorkerCatalog()` but
have distinct human and runtime authentication contracts. Adding an approved
catalog row requires no app deployment.

Workspace's `WorkerCatalogCoordinator` owns catalog/Profile synchronization.
It publishes cached catalog state first, refreshes and reconciles the Cloud
catalog, synchronizes Profiles for eligible Workers, resolves local Profile
selection, then refreshes readiness. Startup, periodic refresh, readiness
fallback, assignment fallback, and the Workers page use this coordinator rather
than maintaining separate synchronization policies.

The coordinator snapshot exposes `workers` as render-ready
`WorkerCatalogWorkerState` records. Each record contains its descriptor, local
Worker, Profile availability, provider tool state, and readiness. Registry
mutations refresh this projection. A missing or incompatible local Profile
never removes a catalog Worker from the page.

The displayed state is derived from these independent facts, not stored in
`LocalWorker.status`. Catalog retirement and activation are considered first;
then Profile state, local runtime availability, authentication, provider-tool
detection, and readiness determine the card state. Workspace can therefore
show `Setup required`, `Preparing integration…`, `Provider tool not installed`,
`Authentication required`, `Ready`, `Disabled`, `Incompatible`, `Catalog
retired`, and `Runtime unavailable` without treating Profile existence as
Worker existence.
Once a Cloud catalog refresh succeeds, a previously configured local Worker
missing from that catalog remains visible as `Catalog retired`; a cached
catalog alone does not trigger retirement.

An unavailable or invalid Cloud response is a failed synchronization, not an
empty authoritative catalog. Workspace keeps the last locally validated
catalog and continues resolving its locally verified signed Profile releases.
It applies catalog retirements only after a successful, validated Cloud
catalog response. A failed catalog or Profile refresh therefore does not
disable an existing Worker when its cached catalog entry, signed Profile,
local Worker configuration, and provider CLI remain usable.

After a successful catalog refresh, Workspace reconciles descriptors by Worker
Type ID. New descriptors appear and have their Profile synchronized without
creating local Worker slots. Changed metadata comes from the current descriptor
and is not duplicated in local Worker records. A removed or hidden descriptor
retains its local record for diagnostics, but Workspace excludes it from ready
inventory, readiness probes, and assignment execution. If the descriptor later
returns, the existing local slot is reused.

Worker and Profile capability arrays are not part of the v8 execution contract.
Cloud owns workflow enablement and access policy; signed Profiles provide the
provider execution options and sandbox mappings. A new catalog entry can use
the existing Workspace UI and generic Engine once its approved Profile release
is available.

Assignment permission IDs are canonical across Cloud and Workspace:
`repository:read`, `repository:write`, `shell:execute`, and `network:use`.
Cloud intersects Space-role permissions with the Workspace Space Grant.
Workspace separately checks the received IDs against the local Worker ceiling
before Engine execution; Cloud does not duplicate or simulate that local check.

### 21.2 Tool Profile definitions

~~~text
tool_profile_definitions
  id
  logical_worker_type_id
  engine_family
  display_name
  created_at
~~~

### 21.3 Tool Profile releases

~~~text
tool_profile_releases
  profile_definition_id
  release_version
  schema_version
  lifecycle_state
  engine_min
  engine_max
  provider_tool_name
  provider_version_min
  provider_version_max
  payload_digest
  signed_payload / storage_key
  signing_key_id
  signature
  created_at
  promoted_at
  revoked_at
~~~

### 21.4 Audit/channel state

Store:
- lifecycle transitions;
- promotion actor/time;
- revocation reason;
- stable/testing/beta pointers where pointers are used;
- rollout metadata if gradual rollout is introduced later.

The exact normalized schema may differ, but releases remain immutable.

## 22. Safe Worker inventory

Cloud inventory should expose logical state plus safe runtime evidence:

~~~text
worker_id
workspace_id
workspace_name
worker_type_id
display_name
description
activation_state
readiness_state
readiness_issue_code

engine_version
profile_definition_id
profile_release_version
provider_tool_name
provider_tool_version

concurrency
last_seen
~~~

Cloud does not receive:
- local provider executable path;
- provider session ID;
- local profile files;
- provider credentials.

Workspace inventory is based on configured local Workers present in the
current cached or authoritative catalog. Orphan local records are retained
for diagnostics but omitted from full inventory snapshots. Cloud composes the
human inventory read model by joining each local Worker row to its catalog
display name and description. AX receives those fields directly alongside
Workspace, activation, readiness, Engine, Profile, and provider
tool details; it does not derive product names from Worker Type IDs or combine
multiple API responses. For each reported Worker, Workspace resolves a
verified Profile compatible with the Worker Type and Engine before reporting
readiness. Missing or ineligible Profile material or a missing Engine produces
a non-ready record with no Profile release identity, so Cloud
scheduling cannot treat stale local readiness as executable.

Cloud independently enforces the same catalog boundary when selecting an
assignment target and validating resolved Workflow execution configuration. It joins inventory
to an active, visible catalog entry eligible for the Workspace's release
channel, and to the matching active Tool Profile Definition. A stale `ready`
inventory record cannot execute after its Worker is retired, hidden, moved
outside the Workspace's channel, or remapped to another active Profile
Definition.

Assignment snapshots and `worker_assignments` rows record Engine/Profile
identity. Each assignment stores that snapshot at dispatch, including the
provider tool version and explicit model, so later Profile promotions cannot
rewrite the evidence. Run history reads the stored snapshot instead of current
inventory. No local path or secret is included.

## 23. Observability

Every assignment/probe diagnostic correlates:

~~~text
Workspace version
Engine version
Profile definition/release
Provider tool/version
logical Worker
assignment/work request/task IDs
stable error code
duration
~~~

Workspace persists bounded local Engine/Profile probe records with the
resolution source, probe stage, stable error code, and failure layer
(`engine`, `profile`, or `provider_tool`). Engine records also include the
request/assignment identity where available. Advanced Diagnostics may show
Workspace and Engine versions, the official integration definition/release,
and provider CLI name/version. Diagnostics omit signed Profile payloads,
credential values, prompts, and free-form provider output.

This allows Syntila to distinguish:
- Engine regression;
- Profile regression;
- provider CLI incompatibility;
- auth/config issue;
- provider service failure;
- Work orchestration failure.

## 24. Profile fixture testing

Each official Profile release should ship or reference test fixtures covering:

~~~text
version output
auth success/failure
normal execution
tool-use progress
terminal success
terminal provider failure
invalid output
session start
session resume
version-specific variation
~~~

The generic Engine test harness runs profiles against fixtures without consuming
provider quota.

Real opt-in acceptance remains required before stable promotion for first-party
profiles.

## 25. Rollout channels

Recommended release process:

~~~text
Draft
-> static/schema validation
-> fixture tests
-> Testing
-> real provider acceptance
-> Beta (optional)
-> Stable
~~~

A critical stable regression may be handled by:
- immediate stable pointer rollback;
- revocation of the broken release if unsafe;
- new fixed release.

Existing active assignments keep their immutable resolved profile snapshot.

## 26. Assignment immutability

An assignment/run should record the effective local execution identity used:

~~~text
logical Worker ID
Engine version
Profile definition/release
provider tool version
model, if selected
~~~

The profile payload itself need not be copied into Cloud assignment data if the
release is immutable and addressable, but sufficient evidence must remain for
audit/reproducibility.

## 27. Release gates

The current schema, local Worker registry, assignment executor, and protocol
use the v8 model. Normal assignments resolve a logical Worker through its
signed Tool Profile and execute it with the generic Engine. There is no
parallel provider executable runtime or architecture-version route.

The v8 release declaration remains gated on retained evidence for:

~~~text
ChatGPT generic Engine/profile real acceptance
AND
Gemini generic Engine/profile real acceptance
AND
profile update/rollback acceptance
AND
Work v1 full-path acceptance
AND
failure/security acceptance
~~~

## 28. Future engine families

Architecture v8 deliberately names this component CLI Worker Engine.

If future integrations are not CLI based, introduce another constrained engine
family rather than expanding the CLI Profile schema unnaturally.

Possible future examples:

~~~text
API Worker Engine
MCP Worker Engine
Local Model Server Engine
~~~

All may still expose the same logical Worker/Work orchestration abstraction.

## 29. Final v8 topology

~~~text
                         SYNTILA
                             |
                       Work / Discuss
                             |
                             v
                       SYNTILA CLOUD
                   scheduling + profiles
                             |
                             v
                    SYNTILA WORKSPACE
                             |
                    logical Worker slot
                             |
                             v
                    CLI WORKER ENGINE
                     one generic binary
                             |
                    signed Tool Profile
                             |
                             v
                       provider CLI
~~~

Architecture v8 succeeds when adding or fixing a normal supported CLI
integration usually means publishing a tested signed Profile release rather
than rebuilding the generic CLI Worker Engine.

## 30. Manual Profile Lifecycle Completion & Autonomous AI Maintenance Governance

**Manual Profile lifecycle: COMPLETE**

The implemented human control path covers Worker and Profile creation, local
Draft editing and Engine-backed qualification, Cloud publication and signing,
channel promotion, rollback, revocation, and dynamic Worker discovery. The
fixture-backed Phase 13 acceptance verifies the generic Engine and Workspace
to AX Work path without Worker-specific source changes. Cloud stores
qualification and acceptance contracts separately and requires their returned
immutable IDs at publication and Stable promotion respectively.

This completion status describes the implemented lifecycle and its automated
fixture coverage. It does not claim that Cloud remotely observes or attests to
local provider execution, that every real provider workflow has passed, or
that a deployed Testing Workspace rollout has completed. The real-provider
acceptance record and rollout gates remain authoritative for those operational
claims. See the [evidence contract](../specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md)
for the exact trust boundary.

AI-assisted Profile maintenance is limited to model-backed Draft proposals.
The operator consents to sharing bounded Draft context, reviews the diff, and
applies it explicitly. Qualification, publication, signing, promotion,
rollback, and revocation remain separate human-controlled workflows.

## Local development exception (2026-10-04)

Production Workspaces continue to admit only signed Profiles. At the operator's
explicit request, a non-release Workspace can opt into unsigned local drafts
with `SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY`, provided its Cloud origin is
loopback. This bounded exception uses the same generic CLI Worker Engine,
validates schema/catalog identity and compatibility, and pins each selected
payload by digest in separate development storage. It does not manufacture
signed admissions, signing keys, release rows, or channel pointers. Release
builds and remote Cloud connections reject the development path. This exception
supersedes blanket draft exclusions only for local development; other
architecture exclusions and browser-based human authentication remain intact.
See [Profile Lab development access and execution](../specifications/PROFILE_LAB.md#development-access-and-unsigned-execution).

### Operational execution-mode alignment

The canonical task `execution_mode` values are `stateless_read` and
`stateful_thread`. Some previously renamed hosted databases retained the old
`stateful_workstream` CHECK constraint. This is deployed-schema drift, not a
supported execution mode or an API compatibility contract. It causes stateful
request acceptance to fail even when Worker and workflow preferences are valid.

Production schema preflight checks the complete `workflow_tasks` definition.
Space/Thread preflight also detects the obsolete enum after table/column names
have already been converted. The inspected, data-preserving cutover generator
normalizes this storage value and its constraint, preserving task IDs, dependency
and StepRun references, outputs, and historical request/StepRun snapshots. For an
affected database it emits `0021_workflow_execution_mode_alignment.sql`, so the
repair is not skipped when `0017_space_thread_cutover.sql` was already applied.
This is an operational alignment generated from that database's inspected schema,
not a compatibility migration added to the fresh-start v8 baseline.

Use the existing `pnpm db:migrate:production` workflow with a private verified
backup and its explicit production/cutover confirmations. Rehearse generated SQL
on the backup before applying it. Active Work Requests/assignments or schema drift
stop the conversion; do not bypass these assertions. No runtime code accepts or
writes the retired value, and schema generation does not itself modify remote D1.
