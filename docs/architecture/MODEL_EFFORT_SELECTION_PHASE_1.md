# Unified model and effort selection — Phase 1 audit and contract design

Date: 2026-10-11. Status: design proposal; runtime contracts remain unchanged.

## Scope and evidence

Inspected the six requested modules, the generic Engine's execution validation and
argument construction, the Tool Profile v1 specification and Dart validator,
v8/Connect architecture, ROADMAP, ADR-018 and the workflow configuration ADR-019.
The attached review describes the starter migration accurately, but the current
runtime-catalog authoring candidate differs from that migration.

Queried installed AGY 1.3.3 (`agy models`, `agy --help`, `agy help models`) and
Codex 0.160.0 (`initialize`, then `model/list` over app-server stdio, visible
models, 128-row limit). Codex returned one page with `nextCursor: null`.
AGY discovery needed local-server/log access outside the sandbox; Codex discovery
also required an unsandboxed process. No model prompts, signing, promotion,
Cloud updates, configuration writes or application builds were performed.

Retained sanitized evidence and the exhaustive current-selection mapping:

- AGY exact catalog
- Codex metadata
- Mapping table, CSV

The CSV includes every explicit Codex pair and every explicit model with omitted
effort. Invocation columns are structured selection argument fragments appended
to the Profile's execution arguments, not standalone commands. All-null Auto
omits both model and effort arguments. Metadata verification is not a live
execution or account-entitlement test.

## Current behavior by boundary

| Module | Observed behavior |
| --- | --- |
| `engines/cli_worker/lib/src/model_discovery.dart` | Generic TSV: exact ID/name, optional effort list/default; signed prefix filtering. Codex app-server: ID, displayName, per-model efforts/default, hidden filtering, bounded pagination. No grouping or native/logical mapping. Cache keyed by Profile digest and CLI version. |
| `apps/connect/lib/local_worker_registry.dart` | Serializes/restores optional `DiscoveredModelCatalog` on LocalWorker. Does not interpret model suffixes. `copyWith` uses null coalescing, so null alone does not clear an existing catalog. |
| `apps/connect/lib/worker_inventory_projection.dart` | Publishes catalog only with eligible matching Worker/Profile, available Engine, exact digest and CLI-version match. Readiness/activation remain separate. |
| `apps/cloud/src/worker-execution-options.ts` | Requires matching discovered catalog, reapplies signed prefix, excludes unavailable entries; exposes Listed/Verified badges and per-model effort. Public schema is v1, discovery source is provider_catalog; no private invocation data. |
| `apps/app/lib/src/ax/worker_execution_options.dart` | Parses public v1; looks up selected/default model effort, otherwise global effort. Reconciliation clears invalid overrides to null. No provider mapping. |
| `apps/app/lib/src/ax/workflow_configuration_options.dart` | Selected-Worker model/effort lists and validation; unchanged unavailable intent may be retained; Cloud is authoritative. No default inference or effort-count limit. |

Engine execution independently rechecks exact catalog membership/status and
per-model effort. Discovery overrides pass-through: an unknown ID still fails.
Explicit effort with Auto model is rejected for dynamic catalogs because no
concrete discovered model is selected. Null effort emits no effort argument.
Successful explicit execution marks the model verified; explicit unsupported
model error marks it unavailable. Evidence currently belongs to the model ID,
not each model/effort pair. Refresh retains same-identity statuses and a matching
last-successful cache on failure; successful empty discovery removes choices.

The starter SQL `0030` declares `effortSupported: false` and has no effort
argument. The current Gemini authoring candidate has `--effort {{reasoningEffort}}`
and no executionOptions declaration. Neither establishes actual effort choices:
today AGY emits only two-column rows. A further gap: Cloud and Engine's dynamic
catalog paths can accept discovered effort metadata regardless of declared
`effortSupported: false`; a starter without an effort argument could then accept
and silently omit it. This is a future contract/validation fix, not changed here.

## Verified installed catalog and mappings

AGY exposes 18 exact native IDs: 11 Gemini, six Claude, one GPT-OSS. The Gemini
Profile's `gemini-` filter admits only the 11 Gemini IDs. Other IDs are retained
in the CSV as excluded, not added as Workers or capabilities.

The following grouped logical IDs are **proposed**, not current runtime IDs.
The table uses the CLI's explicit labels (High/Medium/Low) as provenance for
presentation grouping; it does not claim a separate `--effort` combination.
Each proposed pair invokes the exact listed native slug with effort argument
omitted. Activation requires an explicit reviewed, signed mapping declaration.

| Native model ID | Proposed logical model ID | Effort label | Default | Verification | Selection arguments |
| --- | --- | --- | --- | --- | --- |
| gemini-3.8-flash-high | gemini-3.8-flash | high | Unknown | Listed | `--model gemini-3.8-flash-high` |
| gemini-3.8-flash-medium | gemini-3.8-flash | medium | Unknown | Listed | `--model gemini-3.8-flash-medium` |
| gemini-3.8-flash-low | gemini-3.8-flash | low | Unknown | Listed; prior Engine execution evidence* | `--model gemini-3.8-flash-low` |
| gemini-3.7-flash-high | gemini-3.7-flash | high | Unknown | Listed | `--model gemini-3.7-flash-high` |
| gemini-3.7-flash-medium | gemini-3.7-flash | medium | Unknown | Listed | `--model gemini-3.7-flash-medium` |
| gemini-3.7-flash-low | gemini-3.7-flash | low | Unknown | Listed | `--model gemini-3.7-flash-low` |
| gemini-3.6-flash-high | gemini-3.6-flash | high | Unknown | Listed | `--model gemini-3.6-flash-high` |
| gemini-3.6-flash-medium | gemini-3.6-flash | medium | Unknown | Listed | `--model gemini-3.6-flash-medium` |
| gemini-3.6-flash-low | gemini-3.6-flash | low | Unknown | Listed | `--model gemini-3.6-flash-low` |
| gemini-3.1-pro-high | gemini-3.1-pro | high | Unknown | Listed | `--model gemini-3.1-pro-high` |
| gemini-3.1-pro-low | gemini-3.1-pro | low | Unknown | Listed | `--model gemini-3.1-pro-low` |

*Prior evidence is described in [Gemini/AGY architecture](GEMINI_AGY_PROFILE.md)
and its linked real-provider record. That JSON does not independently name the
selected ID; do not elevate today's discovery rows to verified from that alone.

AGY help lists `low|medium|high|xhigh|max` for `--effort`. Its
[headless documentation](https://www.agy.dev/docs/cli/headless/#select-a-model-effort-or-agent)
shows native slug selection and separate effort usage but no per-model matrix,
defaults, or precedence when both are supplied. Therefore explicit separate AGY
efforts, xhigh/max variants, Pro medium, and grouped-model Auto effort remain
unsupported in this proposal. First-row ordering is not a default.

Codex's native `model` equals catalog `id` for all seven installed entries:

| Native / logical model ID | Supported explicit efforts | Default effort | Default model | Verification | Selection arguments |
| --- | --- | --- | --- | --- | --- |
| gpt-6.1-sol | low, medium, high, xhigh, max, ultra | low | Yes | Provider metadata | `--model gpt-6.1-sol -c model_reasoning_effort="<effort>"` |
| gpt-6-astra | low, medium, high, xhigh, max, ultra | low | No | Provider metadata | `--model gpt-6-astra -c model_reasoning_effort="<effort>"` |
| gpt-6-sol | low, medium, high, xhigh, max, ultra | medium | No | Provider metadata | `--model gpt-6-sol -c model_reasoning_effort="<effort>"` |
| gpt-6-luna | low, medium, high, xhigh, max | medium | No | Provider metadata | `--model gpt-6-luna -c model_reasoning_effort="<effort>"` |
| gpt-5.6-sol | low, medium, high, xhigh, max, ultra | low | No | Provider metadata | `--model gpt-5.6-sol -c model_reasoning_effort="<effort>"` |
| gpt-5.6-terra | low, medium, high, xhigh, max, ultra | medium | No | Provider metadata | `--model gpt-5.6-terra -c model_reasoning_effort="<effort>"` |
| gpt-5.6-luna | low, medium, high, xhigh, max | medium | No | Provider metadata | `--model gpt-5.6-luna -c model_reasoning_effort="<effort>"` |

The CSV expands all 40 explicit Codex combinations. Omitted effort is a separate
selection, emitting only `--model <id>`; it is never replaced by the displayed
default. Current discovery drops Codex `isDefault`, so the public defaultModelId
remains null for this dynamic Profile. `ultra` is unsupported on both Luna models;
`none` and `minimal` are unsupported across this installed catalog.

## Proposed versioned contract and fail-closed resolution

1. Keep Worker identity stable. Extend the existing catalog/public options with
   an explicitly versioned contract; do not change schemaVersion 1 meanings.
   Connect service remains inventory authority; generic Engine interprets
   signed Profiles. Cloud/AX receive selection metadata only.
2. A signed Profile declares a finite selection strategy: independent native
   model + effort argument, or explicit logical-pair-to-native-model table.
   No suffix stripping, regular-expression inference, concatenation or provider
   branches in Connect, Core, Cloud or UI. Dynamic catalogs intersect signed
   mappings; a mapping never makes an absent native ID available.
3. Independent selections preserve provider effort lists/defaults. Combined
   mappings explicitly enumerate each logical ID/effort/native ID. Duplicate or
   ambiguous keys, invalid defaults, unknown pairs and unsupported mappings fail
   validation. Declared effort support must have an effective argument mapping
   or a combined native resolution; otherwise reject explicit effort.
4. Null model/null effort means provider Auto and emits neither argument.
   Explicit model/null effort needs a demonstrable native default mapping for
   combined models; no Gemini grouped Auto until one exists. Null model/explicit
   effort remains unsupported without explicit provider default-model evidence.
   Never synthesize a default from order, name or maximum effort.
5. Separate support (mapping exists), verification (listed vs executed), and
   availability (available vs unavailable) per selection. Unverified listed
   selections may remain selectable under existing policy; unavailable selections
   cannot execute. Pair verification cannot be widened by a different effort's
   success. Keep these axes distinct in versioned local/public metadata.
6. Bind catalog/mapping evidence to Profile definition, immutable release/digest,
   provider CLI version and native selection. Freeze logical model/nullable effort
   and Profile identity at acceptance. Resolve using that admitted Profile and
   record effective native model/effort locally for reproducibility. Profile drift,
   removed IDs and changed CLI fail admission without substitution.
7. All UI selectors consume the same public per-model values/order/defaults and
   status semantics; inheritance/permissions remain workflow concerns. Cloud
   validates saved intent and execution separately; UI reconciliation must not
   silently rewrite persisted unsupported choices.

## Validation and completion boundary

Focused Engine discovery tests passed: 6 tests, including parsing, invalid effort
metadata, app-server handshake and cache invalidation. Cloud projection tests passed: 7 tests in
`apps/cloud/test/profile-model-options.test.ts` (direct installed Vitest runner;
the pnpm launcher stalled and was stopped). Documentation links and
`git diff --check` passed. Exact installed catalogs were queried
without model requests. Mapping CSV is checked for pair uniqueness, exact AGY
prefix counts and Codex effort/default consistency.

This phase changes documentation/evidence only. Focused checks are sufficient;
no runtime component changed, so component builds/full regression are unnecessary.
No database or compatibility migrations, signed releases or runtime schema changes
are applied. Existing unrelated working-tree modifications are preserved.

Remaining qualification: live execution of all listed selections, AGY per-model
`--effort` semantics/defaults, signed mapping admission and rollout, pair-scoped
status schema, shared selector behavior and frozen effective-invocation evidence.
Phase 1 establishes concrete argument mappings for current selections and the 11
explicit proposed Gemini pairs; all other combinations remain unsupported. It
makes no exhaustive live-provider or release-readiness claim.
