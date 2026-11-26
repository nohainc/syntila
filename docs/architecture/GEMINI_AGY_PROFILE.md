# Gemini / AGY Tool Profile

The Gemini Worker uses the same signed Tool Profile resolver, generic CLI Worker
Engine, Service-owned readiness/inventory, assignment routing, and durable session
store as ChatGPT. There is no Gemini executable or provider branch in Cloud.

## Audit and comparison

| Boundary | ChatGPT / Codex | Gemini / AGY |
| --- | --- | --- |
| Definition | `chatgpt-codex` | `gemini-antigravity` (existing definition reused) |
| Executable | `codex` | `agy` |
| Discovery | Signed standard locations and PATH | `~/.local/bin`, `~/.gemini/antigravity-cli/bin`, PATH |
| Version | `--version` | `--version` |
| Passive authentication | `login status` | No reliable passive authentication assertion; explicit live test required |
| Live readiness | Exact `OK`, bounded, user initiated | Same Engine-owned check |
| Models | Connect CLI discovery, published through Cloud inventory | CLI `models`, all sanitized IDs, with exact Gemini family mappings where declared |
| Effort | Connect CLI discovery, per-model metadata | CLI-reported effort values are passed through; missing metadata means no effort picker |
| Input / output | Codex JSONL events | NDJSON `user` input; `init`, `step_update`, `result` events |
| Sessions | Codex thread ID | AGY `conversation_id`, resumed with `--conversation` |
| Cancellation / timeout | Shared process supervision | Same; Profile additionally maps `--print-timeout` |
| Chat execution | Cloud workflow policy | AGY uses `--mode plan` for the read-only Chat profile |
| Authentication | Provider-owned local account | Provider-owned local account; no Syntila-managed credentials |

Cloud's Worker inventory joins the matching published, non-revoked Profile
release. It never uses an authoring template to widen execution options. Cloud
resolves frozen workflow selections to an assignment; the Service admits the
signed Profile, resolves the Space directory and authorized environment, and
asks the Engine to execute it. The Engine parses provider events into generic
progress/result/error frames. Native session identifiers remain local.

## Discovery contract

`model.discovery` is an optional version 1 generic declaration:

```json
{"schemaVersion":1,"arguments":["models"],"timeoutMs":10000,"format":"tsv","idPrefix":""}
```

The Engine runs this command on the resolved provider executable without a shell
or model request. It accepts bounded tab-separated ID/name rows with optional
comma-separated effort IDs and a default effort, preserves IDs, rejects
malformed/duplicate IDs and includes every returned model when the Profile's
prefix is empty. The Profile's exact Gemini family mapping still groups native
effort variants into one logical family; other provider models remain separate
native selections. Both the catalog and execution request use the 128-character
ID limit, with at most 128 models and 64 KiB CLI output. The Engine never
invents model or effort values.

The last successful catalog is stored in `model-catalog.json` under the Worker's
internal Engine state directory. It is bound to the exact Profile payload digest
and CLI version. Execution checks the CLI version and uses only a matching
cache, rediscovering after version changes. Passive readiness/model refresh
refreshes the list. A failed refresh retains a matching last-successful cache and
reports a warning; a successful empty result retires all models. A different
Profile or CLI cannot reuse the old cache. No background model probes or polling
are introduced. Registry and IPC display caches survive UI/service restarts.

Model states are `listed`, `verified`, and `unavailable`. A successful explicit
model execution verifies only that ID; an explicit unsupported-model error marks
it unavailable. Auto-model success does not verify every catalog entry. Other
failures (network/auth/quota) do not mark a model unavailable. A Profile/CLI change
invalidates this evidence. Removed IDs disappear from selectable options while
stored workflow selections remain intact and fail validation; no fallback model
is selected. A known unavailable ID remains excluded until cache/profile/CLI
replacement; refresh alone does not assert that its account access recovered.

The Service republishes Engine metadata after an assignment without another CLI
probe. Connect shows Models with status, a per-Worker refresh icon and its
existing Test/activation actions. Test and refresh work for disabled Workers
without enabling them. The existing section refresh also refreshes model
metadata. Model selection stays in AX workflow/request controls, avoiding a
competing Worker-level default setting.

Connect Runtime Protocol 5.1 inventory and Local Worker Protocol 4.0 probe
results carry an optional versioned `modelCatalog` object. Older Profiles remain
valid. The new Profile requires Engine 1.2.0 so it cannot accidentally run under
an older implementation. Cloud stores bounded public discovery metadata in
`worker_inventory.model_catalog_json`; public options identify the
source as `provider_catalog`. Cloud requires the same published release digest
and CLI version and applies the Profile's discovery prefix again. Private CLI arguments,
credential settings, local paths, and profile digests are not exposed in model
picker options.

## Readiness and security

`probe.live.requiredForReadiness: true` means passive installation/model checks
alone cannot enable scheduling. A successful live test is tied to the Profile
payload digest and provider version in the local registry. Version/Profile
changes require a fresh explicit Test. Existing Profiles preserve their current
readiness policy.

AGY 1.2.16 and the subsequently installed 1.3.3 expose `--effort`, but
`agy models` reports the current Gemini effort as part of each native model ID
(for example, `gemini-3.8-flash-high`). The Engine groups those native
IDs into logical families and resolves a selected family/effort pair back
to exactly one native `--model` value. Since Engine 1.3.0 this is derived from
the CLI output (`model.discovery.effortVariants`, see
[Derived efforts](../specifications/MODEL_DISCOVERY_NORMALIZATION.md)); the
Profile no longer lists models. Gemini combined families have no provider
model or effort Auto value: the UI requires both selections, and the Engine
does not send a separate `--effort` argument. A missing or unresolved native
variant stays unavailable rather than being guessed.

AGY documentation explicitly says file writes can be auto-allowed in
headless mode. `--sandbox` restricts terminal activity and `--mode plan` is not
an independently verified filesystem boundary. Syntila therefore treats Chat
versus Work as a Cloud workflow decision, while the signed Profile selects the
provider mode: Chat/provider-default uses `--mode plan`, and Work/restricted
uses `--sandbox` with `--mode accept-edits`. No Worker or Profile capability
array is required for admission. No `--dangerously-skip-permissions` is used.
Provider settings still control which additional tools are permitted. Slash
command expansion is disabled.

Reference: [AGY headless documentation](https://www.agy.dev/docs/cli/headless/).

## Release and deployment

`docs/profile-templates/gemini-antigravity-runtime-catalog.v1.json` is the
replacement **unsigned authoring candidate**, not a stable published release.
It contains the version-bounded native-to-logical mapping but no guessed
provider defaults. Import it as a new release in Profile Lab, qualify it against
the installed AGY CLI, then sign
and promote it through the normal release flow. Existing static releases should
be retired after the replacement is qualified; no compatibility fallback is
required for this development-stage contract.

Use Profile Lab's existing import/qualification/sign/publish/promotion flow for
the candidate. Protected signing, full account qualification, signed macOS
LaunchAgent testing, and safe Chat isolation remain release gates. Existing
rollback/last-known-good handling is unchanged. Rebuild Connect/Engine before
using this candidate; changing Dart sources does not update an installed service.

## Validation evidence

The focused discovery tests cover filtering, exact execution, manual refresh,
removed IDs, explicit rejection, verified/unavailable states, corruption and
version/profile cache invalidation. Protocol tests cover bounds and round trips;
Connect tests cover persistence, activation independence, live authentication
identity and inventory filtering. Cloud tests cover source/digest/version
checks, generic effort validation, privacy and removed-model rejection.
Existing Codex/AGY session, timeout, cancellation, malformed output, release
verification and rollback tests provide regression coverage through the shared
Engine/Connect component suites.

Real AGY evidence
records CLI 1.3.3, 11 Gemini models, live readiness, an explicit
`gemini-3.8-flash-low` request, durable resume, and a verified temporary
Work-file write. Chat/Work admission is determined by the Cloud workflow
policy; the Profile only maps the provider mode for the selected execution.
The process ran through the actual generic Engine with restricted PATH and home
location discovery, outside Flutter. It was not a signed release, launchd,
reboot/login, Cloud-to-AX test, or an exhaustive
account entitlement test. Earlier 1.2.16 catalog/help inspection was superseded
by the CLI updating to 1.3.3 during validation. The candidate admits only those
patch versions, and future versions require qualification. Legacy `capabilities`
arrays in signed v1 payloads are accepted for migration parsing only and are
ignored by Cloud, Connect, and the Engine; new Profile releases omit the
field.

Connect component validation currently reports four remaining failures outside
this change: the scoped fixture lacks a directory lifecycle, the filesystem test
expects obsolete per-Thread mutation rules, the lock subprocess harness times out,
and a disconnected configuration test expects an endpoint the implementation
does not restore. The affected discovery/readiness tests and the unsigned
development Profile execution regression pass independently.

Executed validation: Engine component checks passed; Cloud/shared TypeScript
checks and 661 tests passed; 14 focused Connect tests, 13 AX selector/editor
tests, 3 Profile Lab diff tests and 2 starter-provisioning tests passed. Protocol
bindings and boundary checks passed. These cover the shared contracts and their
direct consumers without unrelated native application builds. The full Connect
run passed 387 tests, skipped 10 and initially failed 5; the development execution
failure was corrected and passed in the focused rerun. The four failures above
remain unresolved. During initial implementation, no remote database migration or stable release
promotion was performed.

## Profile Lab rollout clarification

The hosted catalog was inspected on 2026-10-11: both `chatgpt` and `gemini`
and their active definitions exist. Gemini has no release or channel pointer;
ChatGPT has a beta pointer. Catalog visibility is independent of release
availability. Refresh the Profile Lab Cloud catalog to receive both Workers.
The Gemini starter template was initially updated remotely using the authoring-only
0030 SQL; no Draft, signed release or channel pointer was changed. The later
hosted rollout applied both pending migrations through the migration ledger.

Profile Lab now discovers models through passive generic Engine probes after
admitting the current Worker Profile, rather than skipping dynamic Profiles with
no fixed allowlist. It filters unavailable IDs and checks the Profile digest
and Profile discovery prefix. Discovery consumes no model requests. The bundled generic
Engine was regenerated at 1.3.0. Rebuild Profile Lab to receive these changes.
The AI selector still requires an approved signed Stable Gemini release; merely
adding a Worker or installing AGY does not authorize an unsigned model runner.

Profile Lab follow-up validation: focused model/catalog UI regressions pass
(6 tests), and changed-file analysis is clean. Full Profile Lab validation passed
140 tests and failed 6 real-Engine fixture/first-run tests on probe/execution
timeouts; it is not a clean release gate. No native `.app` build was run.

Profile Lab's release app was rebuilt with the updated Dart Profile validator
after an older installed build rejected `probe.live.requiredForReadiness`.
The readiness-policy regression test and 8 execution-options tests pass. The
local macOS build is an unsigned development artifact, not a notarized release.
Quit the older app and launch the newly built bundle before importing the JSON.

## Hosted Draft-sync rollout

On 2026-10-11, the production API was updated after the old deployed validator
rejected the Gemini candidate with “Tool Profile v1 is invalid.” A Cloud
Draft-boundary regression parses the exact candidate JSON. Cloud type checking,
646 Cloud/shared-contract tests, and production security preflight passed.
Production migrations 0029 and 0030 were applied, preserving existing rows and
release/channel state. API version `5c8ea02d-ce60-4711-93ef-465527b65b93` includes
the new validator. An authenticated end-user sync was not performed by the
developer; retry Sync in Profile Lab. Stable promotion remains a separate action.

## Unified capabilities contract (Phase 2)

Cloud now publishes [Worker execution options v2](../specifications/WORKER_EXECUTION_OPTIONS_V2.md)
for both Codex and Gemini. Engine/Service catalog v2 adds a stable revision and
local native identity, which inventory strips before Cloud publication. AX
reads v1/v2, preserves all supported efforts, and excludes unavailable selections.
The unsigned Gemini runtime-catalog candidate declares combined selection mode;
AGY's current two-column output still reports no independent efforts/defaults.
Exact native variant IDs remain unchanged pending explicit signed pair mapping.
No authoring SQL, signed release or hosted deployment was changed by Phase 2.

## Provider normalization (Phase 3)

The unsigned runtime-catalog authoring candidate now contains an exact signed-data
mapping candidate for the eleven installed AGY 1.3.3 Gemini identifiers: four
logical families, separate low/medium/high choices where listed, and no inferred
default. It requires Engine 1.2.0 and emits only the resolved native `--model` for
combined selections. Mapping applies only to the evidenced 1.3.3 version interval.
See [discovery normalization](../specifications/MODEL_DISCOVERY_NORMALIZATION.md)
for reverse resolution, availability, verification and rollout limits. Existing
signed fixture releases and active installations were not modified.

## Denied actions

AGY ends a turn with `status: SUCCESS` even when it refused to run an action,
for example a file write under `permission_mode: request-review`. The final
`result` then carries `denied_actions`. The Profile reads that list with a
`set_provider_error` action, and the Engine treats a non-empty list as
`permission_denied` ("Permission denied for: WriteToFile") instead of a
successful answer. An empty or missing list is not an error. Running AGY with
`--dangerously-skip-permissions` (`permission_mode: always-proceed`) is what lets
the file tools run; the `restricted` and `provider_default` sandbox mappings use
`--mode`, which has no effect while slash commands are disabled, so those runs
can hit this failure.
