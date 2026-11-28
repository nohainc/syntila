# Worker execution options v2

How a Worker's model and effort choices travel from the provider CLI to the
selectors in the app, and how an accepted choice is frozen and enforced. There is
one catalog; no second model list and no provider runtime outside the generic
Engine.

```text
Provider discovery → generic Engine → local catalog/cache → Connect
→ sanitized Worker inventory → Cloud execution options → app selectors
```

Related: [Provider discovery and normalization](MODEL_DISCOVERY_NORMALIZATION.md),
[Tool Profile v1](TOOL_PROFILE_V1.md),
[User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md),
[Conversation continuity](CONVERSATION_CONTINUITY_V1.md#execution-options).

## Contract

The local `modelCatalog` has schema version 2 (version 1 caches stay readable).
Cloud emits public `WorkerExecutionOptions.schemaVersion: 2` for every Worker,
whether its catalog is discovered or comes from a static Profile; Core and the app
decode versions 1 and 2. Each public model entry has `id`, `name`, optional
`badge` and `description`, `efforts`, `defaultEffort`, `selectionMode`
(`separate` or `combined`, declared by the signed Profile) and `status`
(`listed`, `verified`, `unavailable`). Worker-wide `effort` is the fixed capability
for a Worker without per-model efforts.

```json
{
  "schemaVersion": 2,
  "catalogRevision": "<64 lowercase hex>",
  "models": {
    "supported": true,
    "discovery": "provider_catalog",
    "allowsCustomModel": false,
    "allowedModelIds": ["model-a"],
    "defaultModelId": null,
    "options": [{
      "id": "model-a", "name": "Model A",
      "efforts": ["low", "medium", "high"], "defaultEffort": "low",
      "selectionMode": "separate", "status": "listed"
    }]
  },
  "modelSwitch": { "supported": true },
  "effort": { "supported": false, "values": [], "defaultValue": null }
}
```

IDs are opaque and values come from discovery or the signed Profile; there is no
fixed effort ladder. Bounds: 128 models, 16 unique efforts per model, bounded
ID and name strings. Optional `catalogStale` is true when the catalog is the
last-known-good copy after a failed refresh (absent means false).

### Field ownership

| Field | Engine / Connect | Cloud inventory | Public options |
| --- | --- | --- | --- |
| `id`, `name`, `efforts`, `defaultEffort`, `selectionMode`, `status` | Yes | Yes | Yes |
| `nativeId` (native CLI identity; defaults to `id`) | Yes | **Forbidden** | **Forbidden** |
| `catalogRevision` | Opaque SHA-256 | Yes | Yes |
| `profileDigest`, `providerToolVersion` | Yes | Internal admission only | **Forbidden** |
| CLI arguments, credentials, paths, native session data | Profile/execution ownership | Not catalog fields | **Forbidden** |

Connect strips native fields (its strict schema rejects any undeclared
implementation field), and Cloud builds an allowlisted public projection instead of
forwarding raw catalog objects.

## Discovery rules

- Codex reads models and efforts from its app-server: the catalog `id` is the
  logical selection and `model` the native identity passed to `--model`. Gemini
  (AGY) derives families and efforts from the CLI's own `models` output using
  the Profile's `model.discovery.effortVariants` rule, so new provider models need
  no Profile change. Claude keeps a Profile `catalog`. See
  [normalization](MODEL_DISCOVERY_NORMALIZATION.md) for version gates and the
  signed `selectionMapping` that remains available for providers whose native IDs
  cannot be derived.
- `selectionMode` only describes how the Profile represents selection; it does not
  synthesize native names or invent an invocation strategy.
- **Missing metadata** means no efforts (`[]`) and a null default; nothing is
  inherited from a guessed global value. Duplicate logical model IDs or effort
  values reject the catalog (no first-wins or last-wins merge), as do a
  non-supported default and malformed entries (Cloud's projection fails closed).
- **Auto.** A null model runs with the provider's default; clients no longer offer it
  while the catalog lists models, and Cloud still accepts it for saved selections.
  Null effort is provider Auto for separate
  selections; combined families use an explicit signed default or require an
  effort. Showing a default effort never writes an explicit selection. Explicit
  effort with null model is unsupported for discovery-backed Profiles.
- **Unavailable** entries stay in public metadata (saved intent, diagnostics) but
  not in `allowedModelIds`; Core and the app reject them even when custom models are
  allowed, and nothing replaces them.
- **Listed** means provider metadata only. **Verified** records a successful
  execution; a combined family is verified only when every available variant has
  succeeded, with private per-variant statuses so one failed sibling does not
  disable the family.
- Provider-version or Profile changes invalidate catalog reuse and verification
  through exact CLI-version and Profile-digest binding. Removed IDs are never
  renamed or aliased; saved selections and history stay as they were and must be
  revalidated.

## Catalog identity and freshness

`catalogRevision` is a lowercase SHA-256 over canonical JSON of the Profile digest,
CLI version and the model entries sorted by ID (native ID, display data, effort
order and default, selection mode, status). Refresh and discovery times are excluded,
so an unchanged refresh keeps its revision; availability, mapping, Profile or CLI
changes change it. It is an identity, not a signature or authorization token. Local
caches with native fields verify it on load. Connect forwards the original revision;
Cloud accepts it only for a schema-valid catalog matching the admitted Profile
digest and installed CLI version, and derives a deterministic revision for version 1
and static catalogs.

The Connect readiness monitor refreshes each configured Worker at startup and every
minute, with no UI attached. It serializes probes, coalesces matching requests and
queues scopes not covered by the active check; a Profile change requests one
follow-up pass. A transient discovery or probe failure keeps the validated
last-known-good catalog with `stale: true`. A digest or provider-version mismatch,
unsupported version, invalid signature or unavailable Profile clears the local
catalog, which removes selectable capabilities but never rewrites saved history or
assignment snapshots. Post-execution metadata is accepted only when the Profile
digest and Worker version still match. Signing out of the management UI neither
stops Connect nor revokes its credential.

## Cloud synchronization and validation

- Inventory ingestion binds the sanitized catalog to the exact published,
  non-revoked Profile release for the Worker Type, its payload digest and the
  reported provider version. Invalid or mismatched metadata clears the current
  catalog. Duplicate Worker IDs reject the whole snapshot before any write.
  Inventory revisions are monotonic and ownership stays bound to the authenticated
  Connect.
- Cloud preserves the published selection mode, efforts, defaults, availability and
  revision; it does not infer support from effort names, and signed mapping
  constraints still limit admission.
- Workflow selections may carry `catalogRevision` (64 lowercase hex). Without it the
  selection is validated against the current catalog; with it, a mismatched
  revision or a stale catalog rejects the new selection with an explicit refresh
  error. A revision inherited from one Worker cannot pin another Worker's catalog.
  Resolved bindings carry the revision into snapshots. Admission and scheduling both
  validate the exact model/effort pair against the current Worker and Profile
  binding, and scheduling re-checks before dispatch. No default effort or alternate
  model is substituted. An unchanged unavailable preference can be saved as intent
  but cannot execute.
- The app's read cache keeps the same public options (revision and freshness) and no
  native arguments, mappings or credentials.

## Selection UI

`syntila_protocol/worker_execution_options.dart` holds the provider-neutral
presentation types and pure selection rules over the public contract;
`syntila_design/ModelEffortSelector` supplies the shared Flutter controls. The app
(workflow defaults, step overrides and the transient request settings dialog),
Connect (read-only catalog inspection through authenticated Service IPC) and Profile
Lab (trusted proposal dialog, grouped by Profile release, never defaulting to the
first model) all use it, with no provider-specific conditions.

- Controls show Worker, Model and Effort, inherited values, and loading, stale,
  unavailable and unsupported states. The Model picker lists only models in the
  Worker's catalog; the client adds no Auto choice of its own. A provider's own
  "auto" model appears only when the provider reports it during catalog refresh.
  While the catalog lists any model, a model must be chosen and the selector
  blocks submission until it is; a Worker whose catalog lists none runs with the
  provider's default. Combined families also require an effort. Dropdowns are keyboard operable with accessibility labels and live-region
  notices; read-only mode shows the complete matrix.
- Catalog refreshes never change saved choices; a missing saved ID stays visible as
  unavailable. A model change keeps an explicit effort only if the new model
  supports it, otherwise resets to inherited Auto with an explanation; a Worker
  change clears dependent overrides. Nothing is guessed or substituted.
- The Work request summary always shows Worker, Model and Effort for the composer
  binding; workflow policy decides which fields are editable. A Worker that cannot
  switch models in place explains that a model change starts a new provider session
  with conversation context (the conversation router's reconstruction path; the UI
  never switches a live session).
- One presentation function, `executionEffortDisplayName`, labels efforts in the
  selector and Work history; unknown provider strings stay visible.

## Immutable execution resolution

Before dispatch Cloud validates the effective workflow default or override, then
materializes only declared model and effort defaults. Unknown provider choices stay
null with `provider_default` provenance, and combined families without a declared
default still require an explicit effort. The same concrete values go to the
assignment and to its immutable public `permissionSnapshot.executionSelection`:

```json
{
  "schemaVersion": 1,
  "workerTypeId": "gemini", "workerDisplayName": "Gemini",
  "modelId": "…", "modelName": "…", "effort": "high",
  "profileReleaseVersion": 2,
  "catalogSource": "provider_catalog", "catalogRevision": "<SHA-256>",
  "modelSource": "explicit", "effortSource": "explicit"
}
```

`explicit` is a concrete effective binding (including a resolved workflow default or
override); `catalog_default` is a declared default materialized at dispatch.
Assignment validation requires the snapshot to match the invoked Worker, model and
effort and forbids native mapping fields. A database guard blocks rewriting
selection and attribution while allowing status, result and unrelated context
updates.

- **Pin.** Local Worker Protocol 4.1 adds an optional bounded `catalogRevision` to
  execute frames (4.0 frames cannot carry it). Provider catalogs need Engine 1.3.0 or
  newer at scheduling (older Engines get an update-required rejection), and the Engine
  compares the pin with its freshly resolved Profile and provider catalog before
  starting the CLI; a stale or changed catalog fails instead of unpinning. Static
  Profile catalogs are bound by the signed Profile digest and the Cloud snapshot.
- **Local evidence.** Before invocation the Engine writes private schema-1 evidence
  under its `execution-selections` state directory, keyed by the SHA-256 of the
  invocation ID, bounded, atomic under a process lock and not rewritable with
  different data. It records the assignment and invocation IDs, Worker Type, logical
  model and effort, resolved native model and effort argument, Profile release and
  digest, provider version and local catalog revision (null for static catalogs).
  Nothing native is published to the app.
- **Effort and model switches.** Separate effort is a per-turn option. When a
  combined effort variant changes the native model, the Engine also enforces the
  Profile's model-switch contract: an incompatible override needs context-backed
  reconstruction or fails before provider execution.
- **No attestation.** Current signed output contracts do not report the accepted model
  or effort, so `acceptedModelId` and `acceptedEffort` stay null with
  `selectionObservation: unavailable`; a successful run is not proof of a selection
  the provider did not report.
- **History.** Work history reads the frozen Worker and model labels, the assigned
  effort and the catalog revision, from turns and legacy step read models, including
  after cache rehydration. It never consults a later catalog; older records keep
  their original IDs and default markers, with no retrospective labels.

## Verification

| Scenario | Coverage |
| --- | --- |
| Codex per-model effort metadata and native arguments | Engine `model_discovery_test.dart`, `native_model_execution_test.dart` |
| Gemini combined identifiers and reverse mapping | Engine `combined_model_execution_test.dart` |
| Local evidence and catalog pin | Engine `execution_selection_snapshot_test.dart` |
| Selector behavior, inheritance, unavailable saved choices, stale and read-only | `packages/syntila_design/test/model_effort_selector_test.dart`, app workflow and Work tests |
| Catalog ingestion, scheduling and immutable snapshots | Cloud tests in `apps/backend/test` |
| Capability lifecycle, rollback and revision changes | Connect capability and catalog tests |

Fixture providers establish deterministic behavior only; real-provider smoke runs
are opt-in and do not certify every model's allowance. Run the Engine suite with
`pnpm validate:engine` and Connect with `pnpm validate:connect`.
