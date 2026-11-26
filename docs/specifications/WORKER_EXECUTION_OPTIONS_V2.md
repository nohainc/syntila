# Worker execution options v2

Status: implemented additive contract, 2026-10-11. Extends the existing Worker
execution options and discovered catalog; it does not introduce a parallel
model catalog or a provider runtime. Architecture v8 and the Connect service
ownership contract remain authoritative.

## Existing boundary, new version

```text
Provider discovery → generic Engine → local catalog/cache → Connect service
→ sanitized worker inventory → Cloud execution options → AX selectors
```

The existing `modelCatalog` object accepts schema versions 1 and 2. New Engine
discovery writes version 2; matching old version 1 caches remain readable.
Cloud emits public `WorkerExecutionOptions.schemaVersion: 2` for all Workers,
including discovery-backed Codex/Gemini and static Profile catalogs. Core and AX
explicitly decode version 1 and version 2. The encompassing runtime/local
protocol identities are unchanged; the nested catalog is independently versioned.

Public model entries retain `id`, `name`, optional `badge`/`description` and replace
the v1 per-model `effort` object with `efforts`, `defaultEffort`, `selectionMode`
and `status`. Worker-wide `effort` remains the existing fixed/default-model
capability; it is not a second catalog. AX adapts both versions into its existing
internal effort representation so existing controls continue to work.

## Field ownership

| Field | Local Engine/cache and Service registry | Cloud inventory | Public Cloud/AX options |
| --- | --- | --- | --- |
| model.id | Logical selection ID | Yes | Yes |
| model.name | Display name | Yes | Yes |
| model.nativeId | Native CLI identity; defaults to id when absent | **Forbidden** | **Forbidden** |
| model.efforts | Per-model supported IDs | Yes | Yes |
| model.defaultEffort | Explicit reported default or null | Yes | Yes |
| model.selectionMode | separate or combined, declared by signed Profile | Yes | Yes; projected from Profile |
| model.status | listed, verified or unavailable | Yes | Yes |
| catalogRevision | Opaque SHA-256 catalog identity | Yes | Yes |
| profileDigest | Exact admitted signed Profile binding | Yes, internal runtime admission | **Forbidden** |
| providerToolVersion | Discovery CLI version | Yes, internal runtime admission | **Forbidden** |
| discoveredAt | Refresh timestamp | Yes | Not needed |
| CLI arguments, credentials, paths, native session data | Existing signed Profile/execution ownership | Not catalog fields | **Forbidden** |

Local Worker Protocol remains a trusted machine-side execution boundary, not an
AX API. Connect inventory explicitly removes native IDs; its strict schema
rejects a nativeId or any other undeclared implementation field. Cloud builds a
public allowlisted projection instead of forwarding raw catalog objects.

## Public example

```json
{
  "schemaVersion": 2,
  "catalogRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "models": {
    "supported": true,
    "discovery": "provider_catalog",
    "allowsCustomModel": false,
    "allowedModelIds": ["model-a"],
    "defaultModelId": null,
    "options": [{
      "id": "model-a", "name": "Model A",
      "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultEffort": "low", "selectionMode": "separate", "status": "listed"
    }]
  },
  "modelSwitch": { "supported": true },
  "effort": { "supported": false, "values": [], "defaultValue": null }
}
```

The identifiers in this example are illustrative. Supported values come from
matching discovery or a signed static Profile; there is no four-level effort cap.
Existing bounds remain: 128 models, 16 unique efforts per model, bounded ID/name
strings. Actual mappings are audited in [Phase 1](../architecture/MODEL_EFFORT_SELECTION_PHASE_1.md).

## Provider mechanisms

Optional signed `model.selectionMode` defaults to `separate`. The unsigned Gemini
runtime-catalog candidate declares `combined`; existing signed releases are not
modified. This field describes how the Profile represents selection, and does
not itself synthesize native model names or introduce a new invocation strategy.

Codex discovery uses catalog `id` as logical selection and `model` as native CLI
identity, falling back to id only when native metadata is absent. Its Engine
passes the stored native identity to `--model` and preserves the signed separate
reasoning-effort argument mapping. The same existing Engine argument expansion
is used for execution, with the logical selection retained in Syntila requests.

AGY TSV supplies exact native IDs and no independent effort defaults. Phase 3
intersects those identifiers with the candidate's signed exact mapping: four
logical families and eleven explicit efforts for installed AGY 1.3.3. No default
is inferred. Each selected pair resolves to one native `--model` slug, with no
separate effort flag. Unknown versions or native identifiers retain distinct
entries. See [normalization](MODEL_DISCOVERY_NORMALIZATION.md) for version gates,
availability, execution tests and rollout limitations.

## Deterministic failure and default rules

- Missing efforts means `[]`; missing defaultEffort means null. Missing metadata
  never inherits a guessed global value for a discovered model.
- Duplicate logical model IDs or duplicate effort values reject the catalog;
  neither first-wins nor last-wins merging is allowed. Codex discovery also
  rejects duplicate reported reasoning effort metadata.
- A non-null default must be a supported value. Invalid discovered defaults
  reject the catalog. Static Profile validators reject invalid defaults;
  Cloud's catalog projection also fails closed on malformed entries.
- Null effort remains provider Auto for separate selections. Combined families
  use an explicit signed default, or require an effort when no default exists.
  Displaying defaultEffort does not write an explicit selection. Null model
  remains provider Auto. For discovery-backed Profiles, explicit effort with
  null model has no qualified per-model metadata and stays unsupported.
- Unavailable entries remain public metadata for saved intent and diagnostics,
  but are absent from allowedModelIds. Core and AX reject unavailable models,
  including when custom-model support exists. No replacement is selected.
- Listed means provider metadata only. Separate model verification records an
  existing successful execution. Combined family verification requires success
  evidence for every available variant; private per-variant statuses preserve
  failed siblings without disabling the whole family.
- IDs are opaque. Changes across provider versions invalidate catalog reuse and
  execution evidence through exact CLI-version and Profile-digest binding.
  Removed IDs are not renamed or aliased automatically. Workflow history and
  saved selections remain unchanged and must be revalidated.
- During refresh, changed native identity or effort/default metadata loses the
  old verified/unavailable status. A Profile/CLI change cannot reuse prior cache.
  Existing failed-refresh last-successful-cache behavior is unchanged.

## Catalog identity

Local version 2 catalogRevision is lowercase 64-character SHA-256 over canonical
JSON containing Profile digest, CLI version and model entries sorted by logical
ID. Entry identity includes nativeId, display metadata, effort ordering/default,
selection mode and status. Refresh time is excluded, so unchanged refreshes retain
identity; availability, mapping, Profile or CLI changes change it. It is an opaque
identity, not a signature or authorization token. Local caches with explicit
native fields verify this revision on load.

Connect strips native fields while preserving the original opaque revision.
Cloud forwards it only for a schema-valid catalog matching the admitted Profile
digest and installed CLI version. Version 1 catalogs and static Profiles receive
a deterministic Cloud-derived SHA-256 revision over normalized catalog metadata,
Profile binding and CLI version, excluding discoveredAt. Upgrading from v1 to v2
may change revision once; schema version identifies the encoding.

## Additive migration and rollout

Deploy readers first: shared protocol/Core readers and AX v1/v2 decoder, then
Cloud v2 projection and inventory decoder, then Connect/Engine v2 writers.
Do not enable v2 writers against an older Cloud inventory validator or deploy
Cloud v2 projection before its AX decoder. No negotiation fallback or compatibility
API is added to the unreleased architecture. A downgrade to old readers requires
rolling back writers and clearing/recreating only the unsupported **catalog
cache** after preserving it; never reset an installation or Work Root.

No D1 migration is required: the existing model_catalog_json stores the versioned
object. Registry layout, installation/Connect/runtime IDs, secure credentials,
Work Root, Profiles and sessions are preserved. Existing Profile payloads remain
immutable. Importing/signing/promoting the updated authoring candidate is a
separate release operation. Generated Engine artifacts must be rebuilt when
shipping the new writer; no native app packaging or release signing was performed.

## Phase 2 verification record

| Scope | Result |
| --- | --- |
| Focused public contract/projection tests | 18 passed, including retained installed AGY/Codex evidence; same public shape, 11 Gemini IDs and 40 Codex pairs |
| Engine analysis and complete source test suite | Clean analysis; 42 passed, including actual fixture invocation of distinct logical/native Codex IDs, explicit ultra and omitted effort |
| Local catalog protocol tests | 2 passed; v1/v2 roundtrip, native privacy, duplicate/default validation and revision behavior |
| Shared Dart Profile options tests | 10 passed; additive selection mode and effort validation |
| Connect focused registry/inventory/discovery tests | 13 passed; persistence, eligible release/version filtering, stripped native fields |
| AX focused selector/workflow tests | 8 passed; v1/v2 decoding, six effort values, invalid metadata, Auto and unavailable selections |
| Changed AX files / Connect / Profile Lab / Engine analysis | Clean |
| Cloud and changed shared TypeScript packages | Type checks passed |
| Connect service check | Compiled, started headlessly and stopped cleanly |
| Generic Engine artifact build | Passed; refreshed Connect and Profile Lab copies (no native app build) |
| Documentation links and diff whitespace | Passed |

Component validation was attempted for each changed component and direct shared
package consumer. Broader suites are **not clean**:

- Engine component script stopped at formatting differences in the unchanged
  shared runtime supervisor; direct Engine analysis and all 42 Engine tests pass.
- AX component script stopped at formatting differences in existing app-state
  and cache files. Full AX analysis also reports an unchanged cache-file lint;
  changed-file analysis is clean. Running the remaining test stage independently
  yielded 656 passed and one Home-page “AI updates See all” dialog failure.
- Cloud/shared component test scope yielded 675 passed and one unchanged inventory
  fixture containing a forbidden legacy capabilities field. The additional
  installed-evidence test passed separately after that run.
- Connect analysis passed; full tests yielded 371 passed, 10 skipped and 20
  failures, including legacy Profile/initialize capabilities fixtures, runtime
  lifecycle/filesystem expectations and subprocess checks. Focused changed-boundary
  tests and the separately invoked Service check pass.
- Profile Lab component validation (prepared Engine) had clean format/analysis,
  150 passing tests and two unchanged first-run Profile-equality fixture failures.
- Protocol binding check reports an unchanged generated Dart binding as stale;
  this phase changes no central protocol schema metadata or generated bindings.

The pnpm launcher stalled in Phase 1; validation used the installed runners and
the component scripts directly. Full-repository validation and unrelated Public
Site/native app builds were not run. This dependency-aware scope checks actual
changed behavior and every direct consumer without expanding this phase into
unrelated fixture or formatting repairs. Existing unrelated working-tree edits
were preserved. No live provider requests or production deployment were made.

Remaining risks are the reader-first deployment order, outstanding broader-suite
failures, signed qualification/promotion, and later explicit Gemini pair mapping
and pair-level verification. No database migration, installation reset or
credential/session compatibility change is required.

## Phase 3 combined selection resolution

[Provider discovery and normalization](MODEL_DISCOVERY_NORMALIZATION.md) defines
optional signed `model.selectionMapping` v1, Engine 1.2.0 reverse resolution,
versioned native renames and private local variant availability. Combined families
with nonempty efforts and null default require an explicit effort. Native IDs and
`variantStatuses` never enter inventory or AX. The public v2 shape is unchanged.

## Phase 4 freshness and Service ownership

The Service readiness monitor refreshes configured Workers at startup and on a
one-minute background interval, including while no GUI client is attached. Setup,
Profile synchronization/revocation, enable and explicit refresh continue through
existing Service commands. This monitor serializes probe work, coalesces matching
requests, and queues requests for scopes not covered by an active check. A Profile
change can request one follow-up pass rather than reuse an older in-flight result.
Service shutdown cancels the interval and drains active/queued work.

Catalog v2 adds optional boolean `stale`; absence is false. Public execution
options v2 add optional boolean `catalogStale`; absence is false. AX decodes this
metadata. Temporary discovery/probe failure retains the validated last-known-good
catalog with stale=true. Explicit Profile digest or provider-version mismatch,
unsupported version, invalid signature or unavailable Profile clears the local
catalog; publication also independently checks the current eligible binding.
Invalidation removes selectable current capabilities and does not rewrite saved
workflow history or assignment snapshots. Engine selection validation still gates
new provider invocation against its own current Profile/version-bound catalog.

Freshness and discovery timestamps are excluded from catalogRevision. A failed
refresh and subsequent identical recovery retain the same revision; changed
capabilities, availability or binding produce a new identity. An unchanged fresh
catalog reuses its existing local record rather than publishing a new discovery
timestamp as a capability change. Readiness timestamps remain independent runtime
health metadata. Legacy local catalogs retained after a transient failure are
wrapped as catalog v2 to represent freshness without discarding their entries.

Post-execution metadata is accepted only if the selected Profile still resolves
to the same digest and the current Worker version has not changed. This path does
not overwrite a newer version or clear stale discovery state merely because one
execution finished. Native mappings, variant bookkeeping, arguments, paths and
credentials remain outside the inventory/public contract.

Management sign-out (or an expired human session) only revokes the human session; it does not stop the
authorized Service or revoke its runtime credential. Client attachment and human
session state are absent from capability refresh scheduling. Explicit Disconnect
Cloud continues to stop publication while leaving local background discovery
running. `service stop` cancels discovery scheduling.

### Phase 4 verification and compatibility

The headless publication test signs fixture Codex and Gemini Profiles, resolves
and admits them through the existing Service catalog coordinator, runs the
compiled generic Engine against fixture provider CLIs, and captures sanitized
inventory via the registry publication callback. Codex preserves its actual
fixture effort/default; Gemini publishes four families and eleven pairs. No
management window or human UI session participates. Separate background tests
verify periodic refresh, shutdown, overlapping-scope deduplication, queued passes,
stale recovery, stable revisions and binding invalidation. Engine process coverage
also exercises transient discovery failure and recovery using its real local cache.

Engine component validation passed: protocol 28, signed Profile 25, CLI runtime
18, Engine 46 tests. The standalone Service compile/start/stop smoke check passed.
Connect focused tests 18, AX model/workflow tests 15 and focused TS contract tests
21 passed. Cloud, Core and runtime protocol type checks, changed-file analysis,
document links and diff checks passed. This scope follows the changed shared
protocol/runtime packages into their direct consumers and exercises the headless
publication boundary rather than relying on GUI state.

Broader checks retain prior unrelated failures: Connect format/analysis clean,
376 passed, 10 skipped, 20 legacy fixture/lifecycle failures; Cloud/shared selected
component scope 206 passed and one forbidden-`capabilities` inventory fixture
failure; AX component stops on pre-existing app-state/cache formatting; Profile
Lab format/analysis clean, 150 passed and two first-run equality fixture failures.
No production release, launchd/signing/TCC claim, or paid provider inference is
made by these tests.

The public/runtime stale indicators are optional additive fields in the existing
v2 contract. Deploy readers before emitters when updating components separately.
Engine supervisor admission now declares 1.2.0 consistently with its compiled
artifact, correcting the previous 1.1.0 declaration. No registry schema reset,
replacement Connect, database migration, credential change, Work Root change,
Profile promotion or historical-record rewrite is needed. Provider file/version
changes are detected on the next background pass (normally within one minute),
or immediately through an explicit refresh. Disconnect Cloud retains local
capability work but cannot publish until transport authorization/connectivity is
restored.


## Phase 5: Cloud catalog synchronization and selection validation

Cloud inventory ingestion binds a sanitized catalog to the exact published,
non-revoked profile release for the reported Worker type, its payload digest,
and the reported provider version. Invalid or mismatched metadata clears the
current catalog; historical Work snapshots are retained. Duplicate Worker IDs
reject a snapshot before any writes or omission pruning. Local inventory
revisions remain monotonic and ownership remains bound to the authenticated
Connect.

For v2 discovery catalogs, Cloud preserves the published selection mode,
effort values, defaults, availability and catalog revision. Provider-specific
support is not inferred from effort names. Signed mapping constraints still
limit admission. Legacy v1 catalogs and static profile catalogs retain their
existing adapter. A v1 downgrade within a successfully published v2 binding
retains the v2 catalog as stale, requiring service refresh before execution.

Workflow selections optionally carry `catalogRevision` (64 lowercase hex
characters). Old clients may omit it and are validated against the current
catalog; new clients can pin their reviewed catalog. A mismatched revision or
stale catalog rejects new selections with an explicit refresh error. Resolved
bindings carry the revision into Work snapshots. Both admission and scheduling
validate the exact model/effort pair against the current Worker/profile binding;
scheduling rechecks capability validity before dispatch. Existing Connect,
Worker ownership, grant, profile-release and live-connection checks still apply.
No default effort or alternate model is substituted. Unchanged unavailable
workflow preferences can be saved as historical intent, but cannot execute.

AX read-cache persistence now retains the same public execution options,
including revisions and freshness, so reopening a client does not drop its
catalog. No native arguments, mappings or credentials enter this cache.

Deploy Cloud/runtime v2 readers first, then services that publish v2, and only
then AX revision-dependent writes. Do not bulk delete v1 records before every
supported service has refreshed successfully. Each successful v2 snapshot
replaces its legacy record in place; rollback requires capability refresh,
not rewriting historical Work or resetting Connect identity. This phase
adds optional JSON fields and ingestion validation; it requires no D1 schema
migration and performs no production deployment.


Phase 5 verification: the Cloud component regression suite passed 683 tests,
with one pre-existing legacy runtime-protocol inventory fixture failure
(`capabilities` is forbidden). Focused catalog ingestion, normalization,
selection, scheduling, and workflow tests passed. All six Cloud/shared TypeScript
checks and Wrangler binding verification passed. AX capability/workflow/cache
focused tests passed 29 tests. AX component validation remains blocked by
pre-existing formatting in `ax_app_state.dart`; changed-file analysis reports
one pre-existing cache-codec style warning and no errors. These scopes cover
the changed Cloud boundary, direct shared-contract consumers and AX cache;
no Connect/Engine behavior or native packaging changed in this phase.

## Phase 6: shared Flutter Model/Effort selection

`syntila_protocol/worker_execution_options.dart` contains the provider-neutral
public capability projection and pure selection rules. It adapts the existing
v1/v2 public contract; it does not introduce another wire catalog. Native IDs,
argument templates and signed payloads are absent from these presentation types.
`syntila_design/ModelEffortSelector` supplies the shared Flutter controls.

AX workflow defaults and step overrides, AX transient request settings, Connect
Service-catalog inspection, and Profile Lab's trusted proposal dialog use this
component. Connect uses read-only mode and continues to fetch capabilities
only through authenticated Service IPC. AX uses a compact dialog for request
settings. Profile Lab groups choices by trusted profile release, projects actual
discovered efforts and availability, and passes the selected pair through the
existing generic Engine sandbox; it does not choose the first model on load.

The selector optionally shows Worker/Model/Effort controls, supports inherited
Auto and Provider default where the selected Worker advertises those values, and
exposes loading, stale, unavailable and unsupported states. Combined Gemini
families advertise neither model Auto nor effort Auto, so the selector renders
an explicit-selection placeholder and blocks submission until both values are
chosen. Material dropdowns provide keyboard selection, focus traversal and
accessibility labels; validation and reset notices use semantic live regions.
Read-only mode displays the complete model/effort matrix. Widgets contain no
provider-specific conditions.

Catalog refreshes never mutate saved choices. Missing saved IDs remain visible
as unavailable, including restored AX request settings. An explicit model change
retains an explicit effort only when the effective new model supports it;
otherwise it resets to Auto/inheritance and explains the reset. If the inherited
effort is incompatible, the normal validation message remains until the user
chooses a supported effort. Worker changes clear dependent overrides. No guessed
model, effort, or default is substituted.

V2 AX edits carry the reviewed `catalogRevision` into workflow or transient
selection writes. A revision inherited from one Worker cannot pin another
Worker's catalog. Cloud's transient-selection reader now accepts the same optional
revision as workflow preferences; deploy this Cloud reader before the updated AX
client. Legacy selections without pins remain readable. Existing unavailable
preferences remain historical intent; Cloud still authorizes each execution.
No persistence schema migration, Worker/Connect identity reset, credential
change, or native packaging change is required.

### Phase 6 verification and limits

The shared design package passed all 15 tests, including keyboard selection,
semantic labels, dependent effort retention/reset, unavailable saved choices,
inheritance, freshness and read-only presentation. The pure Dart protocol package
passed 10 tests. Direct client scopes passed AX 34, Connect 9 and Profile Lab
17 tests. Profile Lab coverage invokes the compiled generic Engine with a fixture
provider and checks exact model/effort arguments. AX integration covers restored
unavailable selections and local revision persistence.

Changed-file analysis is clean. The three component checks were attempted:
Connect formatting/analysis passed and tests reported 377 passed, 10 skipped,
20 existing legacy fixture/lifecycle failures; Profile Lab formatting/analysis
passed and tests reported 151 passed with two existing first-run fixture failures;
AX still stops on existing `ax_app_state.dart` formatting. Cloud regression for
the additive transient revision reader and Worker-specific revision inheritance
passed 686 tests with the existing forbidden-`capabilities` protocol fixture
failure. Cloud TypeScript checks passed. These scopes cover the shared packages
and their three direct Flutter consumers plus the changed Cloud write boundary;
no unrelated applications or native .app packaging builds were needed.

Fixture and widget evidence establishes deterministic behavior, not macOS
VoiceOver, signing, launchd, paid provider inference, or production rollout.
Those remain device/release checks. Readers must be published before revision-
dependent AX writes; this implementation does not deploy or promote a Profile.


## Phase 7 — application surfaces

Connect uses the shared read-only catalog presentation, including each model's
supported efforts, known provider default, availability, loading and stale state.
Refresh is available even when the catalog is missing and uses the existing
management action lifecycle; the GUI remains a Service client. No worker
execution preference is stored in, or mutates, the discovered catalog.

Work always exposes the shared Worker/Model/Effort summary for the composer's
execution binding. Workflow policy independently controls which fields may be
edited; fixed bindings remain inspectable in read-only mode. The catalog matrix
is omitted from this request summary. Workers that cannot switch model in place
explain that a model change starts a new provider session with conversation
context. The existing authoritative conversation router retains its
`NEW_SESSION_FOR_MODEL` reconstruction path; the UI does not switch an active
provider session itself.

Workflow defaults and step overrides use the same selector and option order as
Work. Inherited values, explicit choices and the resulting effective selection
are visible together. Saved unavailable selections remain visible until replaced.
Historical immutable resolution is Phase 8 and is not reconstructed from the
current catalog by this change.


Phase 7 verification: shared selector widget tests (8), AX Workflow/Work
integration tests (15), Connect catalog/worker-view tests (10), and Core
conversation-router tests (19) pass. Targeted Dart analysis of the selector,
AX surfaces and Connect management UI is clean. This scope checks field
permissions, inheritance, defaults, missing/stale/loading catalogs, saved
invalid selections and the existing model-switch routing policy. Connect
component validation reports 377 passing, 10 skipped and the same 20 existing
fixture/lifecycle failures; its management UI tests pass. AX component validation
still stops at the pre-existing `ax_app_state.dart` formatting difference.
No persistence schema, catalog wire contract, migration or deployment changes
are introduced in Phase 7. Native device accessibility and real-provider
acceptance remain later verification work.


## Phase 8 — immutable execution resolution and history

Before dispatch, Cloud validates the effective workflow/default/override pair,
then materializes only declared model and effort defaults. Unknown provider
choices remain null with `provider_default` provenance; Cloud never guesses an
identifier or effort. Combined families without a declared default still require
an explicit effort. The same concrete values are passed to the assignment and
its immutable public `permissionSnapshot.executionSelection` (schema version 1):

```json
{
  "schemaVersion": 1,
  "workerTypeId": "gemini",
  "workerDisplayName": "Gemini",
  "modelId": "gemini-3.1-pro",
  "modelName": "Gemini 3.1 Pro",
  "effort": "high",
  "profileReleaseVersion": 2,
  "catalogSource": "provider_catalog",
  "catalogRevision": "<SHA-256 revision>",
  "modelSource": "explicit",
  "effortSource": "explicit"
}
```

`explicit` denotes a concrete effective binding, including a workflow default or
step override already resolved by Syntila. `catalog_default` denotes a declared
default materialized at dispatch. These sources do not claim that a human chose
each field explicitly. Assignment payload validation requires the public snapshot
to agree with the invoked Worker/model/effort and forbids native mapping fields.

Local Worker Protocol 4.1 adds an optional bounded `catalogRevision` execute pin;
4.0 frames remain readable without it. A pin cannot be carried in a 4.0 frame.
Provider catalogs require Engine 1.3.0 or newer at scheduling, and the Engine
checks the pin against its freshly resolved signed-profile/provider catalog
before starting the CLI. Stale or changed catalogs fail rather than silently
unpinning or substituting another selection. Static Profile catalog identity is
validated by Cloud and the admitted immutable signed Profile; it is not confused
with an Engine-discovered provider catalog pin.

The Engine writes private schema-version-1 evidence under its Service-owned
`execution-selections` state directory before invocation. Files are keyed by the
SHA-256 of the invocation ID, bounded, written atomically under a process lock,
and cannot be rewritten with different data. Evidence includes assignment and
invocation IDs, Worker Type, logical model/effort, resolved native model and native
effort argument, Profile release/digest, provider version, and the local provider
catalog revision. Static executions without a discovered catalog retain null for
that local revision and are bound by the signed Profile digest; their public
catalog identity remains in the Cloud assignment snapshot. No native identifier,
CLI argument, credential or native session handle is published to AX.

Separate effort remains a per-turn option. When a combined effort variant changes
the native model, the Engine also enforces the Profile's model-switch contract.
An incompatible override requires context-backed reconstruction or fails before
provider execution. Existing Profile/session format and context checks remain.

Completion evidence records observed exit status. Current signed Codex and Gemini
output contracts do not attest the accepted model/effort, so `acceptedModelId`
and `acceptedEffort` remain null with `selectionObservation: unavailable`.
Successful output is not treated as proof of an unreported selection. This phase
records the exact validated invocation and explicitly separates it from provider
attestation.

Work history reads frozen Worker/model labels and the actual assigned effort and
catalog revision. Both turn and legacy step read models retain these fields in
the authenticated cache. Rendering never consults a later catalog for a historic
model name. Older records retain their original IDs/default markers when no label
was captured; no retrospective defaults or labels are inferred.

### Rollout and persistence

Migration `0037_immutable_execution_selection.sql` adds a guard to the fresh v8
baseline that prevents assignment selection/attribution rewrites while permitting
status/result and unrelated context updates. It preserves existing records and
performs no label/default backfill. Apply the migration and deploy public readers
before relying on the new writer fields, then update Connect service together
with its supervised Engine 1.3.0 artifact. Dynamic-catalog Workers still running
older Engines receive a clear update-required scheduling rejection. Static
Profile selections remain compatible through their signed-release binding.
No installation ID, Connect identity, credential, Work Root or session reset is
required. No production migration or deployment was performed here.


### Phase 8 verification

- Full Engine component validation passes: Worker Protocol 30, Tool Profile 25,
  shared CLI runtime 18 and Engine 48 tests, with clean analysis and formatting.
  Native fixture invocations cover all 11 Gemini pairs plus Codex's separate
  native model/effort arguments, catalog-pin rejection and immutable local audit.
- Focused Cloud/Runtime tests pass (48): declared versus unknown defaults,
  explicit overrides, dispatch preserving a resolved null effort, actual stored
  snapshot/outgoing payload agreement, native-field rejection, Engine-version
  admission, immutable historical labels and selection rewrite prevention.
- AX history/cache tests pass (40) and both historical Work/Chat label widget
  cases pass (2). Cache rehydration retains frozen labels, effort and revision.
- Connect execution/lifecycle/headless publication tests pass (13); Service
  compilation and headless start/stop pass. Direct Profile Lab runtime consumers
  pass (10). Cloud binding types and all six relevant TypeScript checks pass.
- Broader Connect validation reports 378 passing, 10 skipped and the same 20
  existing fixture/lifecycle failures. AX component validation still stops at the
  pre-existing `ax_app_state.dart` formatting difference; targeted cache analysis
  has one existing style info outside the changed serialization fields.
- Broader Cloud/shared component validation reports 695 passing and retains the previously identified
  inventory fixture failure that supplies retired `capabilities` fields. The
  phase's new selection/history tests pass; this legacy fixture is not changed
  here. Markdown link validation and `git diff --check` pass.

This scope exercises the changed contracts and each direct runtime/UI consumer.
No native app packaging/build, production migration/deployment, or live provider
inference was performed. Provider attestation remains unavailable under current
signed output contracts; real-installation acceptance belongs to Phase 9.


## Phase 9 — Regression coverage, acceptance and cleanup

The shared selector and Work history now use one presentation-only effort label
function, `executionEffortDisplayName`. It does not invent supported values or
change identifiers. Unknown provider effort strings remain visible. The retired
Work and Workflow pickers are absent; v1 catalog readers remain at the existing
normalization boundary for the additive rollout.

Current-contract fixtures remove obsolete descriptor/Profile `capabilities`
fields. Runtime protocol tests explicitly reject that retired inventory field.
The dynamic signed Worker test covers offline restart, retirement, restoration
and current Space execution ownership. Profile Lab first-run tests now assert
legacy Codex starter migration and implement the app-server discovery handshake.
Selection cleanup also fixes the execution-options update dialog's narrow-width
overflow exposed by AX component validation.

| Scenario | Executable coverage |
| --- | --- |
| Codex per-model effort metadata | Engine `model_discovery_test.dart`, `native_model_execution_test.dart` |
| Gemini combined identifiers and exact reverse mapping | Engine `combined_model_execution_test.dart` exercises all 11 mapped pairs |
| Model change and no-effort provider | Dart domain and shared selector tests |
| Offline saved selections and execution gating | Connect capability lifecycle, catalog coordinator and dynamic Worker acceptance; Cloud scheduler tests |
| Profile changes, rollback and catalog revision | Connect capability lifecycle; Cloud catalog inventory binding and scheduler tests |
| Workflow default/step override precedence | Core workflow configuration, Cloud workflow execution configuration and AX workflow integration tests |
| Existing session compatibility | Engine Worker session/release compatibility tests |
| Immutable historical execution | Cloud assignment snapshot and conversation tests; AX Work history and persistent cache tests |
| Migration and retired fields | SQLite capability removal migration tests, immutable assignment trigger tests, strict runtime protocol tests |

Real installation evidence is retained in
the execution acceptance record.
Codex 0.160.0 and `agy` 1.3.3 each passed provider-default smoke execution and
explicit low/high execution on one discovered family. The generic Engine's
private snapshots matched each logical pair, native identifier and catalog
revision. All mapped Gemini pairs additionally pass deterministic invocation
coverage. These runs do not certify every provider model's allowance or quota.
Neither provider's signed output contract attests the accepted model/effort;
those observation fields remain unavailable. No signed production Profile was
published and no production database migration was applied.

Validation uses the full directly affected components and packages, rather than
native app packaging: Cloud/shared TypeScript tests, all shared Dart/presentation
checks, AX, Connect, Profile Lab, Engine and standalone headless Service checks.
`pnpm check` was explicitly attempted but stopped at existing architecture guards
for Connect configuration names, a diagnostic `configuredWorkers` key, the
nullable installation lock helper and the headless development build guard.
This repository-wide gate remains unresolved; successful component results do
not imply `pnpm check` passed. No retired database fields are dropped by this
phase; existing removal migrations are exercised, and v1 readers remain required
until the additive catalog rollout is complete.


Final Phase 9 executable results: Cloud/shared TypeScript 696 passed across 106
files; AX 659 passed; Connect 398 passed with 14 opt-in live tests skipped in
the routine component run; Profile Lab 154 passed. Shared Dart domain 10,
Local Worker Protocol 30, runtime 18, signed Profile package 25, Engine 48 and
shared presentation 17 tests passed, with formatting and analysis clean.
All six TypeScript package checks, generated Cloud binding checks, Markdown link
checks, `git diff --check`, and headless Service compilation/start/stop passed.
Six separately opted-in live provider executions passed (two provider-default
smokes and four explicit normalized selections). Native packaging and deployment
were not needed to validate the changed presentation, protocol and execution
boundaries. Repository-wide architecture guard failures remain the release gate.
