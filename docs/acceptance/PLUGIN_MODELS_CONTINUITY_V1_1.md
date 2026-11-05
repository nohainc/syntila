# Plugin model discovery and continuity 1.1

Date: 2026-11-05

## Implemented scope

- Protocol 1.1 adds correlated, bounded metadata-only `models.list`; 1.0 remains
  negotiated for existing packages. The SDK provides `PluginModel` and
  `discoverModels()`; discovery is included in conformance when declared.
- Shared model catalogs flow from Engine probes through Workspace readiness and
  inventory to Cloud. Cloud validates owner/enabled-pin/digest/version binding,
  projects model choices and validates scheduler selection. Empty successful
  catalogs replace old entries; failed refreshes retain explicitly stale data.
- Continuity strategies distinguish none, canonical history replay, native
  handles and adapter checkpoints. Commands remain in the adapter. Existing
  Engine session records/locks replace timestamp-only plugin markers, preserving
  ownership, model/policy compatibility and context-revision watermarks. Missing
  native state permits one bounded reconstruction with canonical bootstrap.
- SDK checkpoint transactions lock per key, write atomically, check monotonic
  generation/revision and deduplicate the last committed request. They do not
  promise exactly-once remote effects before a local commit.
- Ollama package 1.1.0 removes the compiled model pin, resolves requested public
  IDs to current CLI entries and reports removed models without substitution or
  downloads. Its one-shot execution uses canonical history replay. Interactive
  `/save` and `/load` automation is not part of this release.

## Evidence

`pnpm validate:engine` passed (Engine: 164 passed, 7 skipped, plus its dependency suites).
Focused executable checks cover protocol correlation/validation, SDK discovery,
transaction rollback/locking/retry deduplication, dynamic Ollama selection and
model removal, Engine discovery freshness/removal, checkpoint restart/resume,
missing-state reconstruction, model changes, Workspace inventory projection and
Cloud pin-bound ingestion/admission. Dart SDK tests (22), Dart plugin protocol
tests (36), TypeScript runtime protocol tests (39), Cloud typechecking and the
architecture guard pass. The final focused plugin Engine suite passed 10 tests.

The built `dist/plugins/ollama-local` package negotiated 1.1 and discovered
`syntila-llama:8b` and `llama3.1:8b` from the actual local daemon. This was a
metadata-only check, not a real model generation or native save/load acceptance.
The Workspace Service compiled, started headlessly and stopped cleanly.

The broader Cloud run passed 178 of 181 files; its remaining failures were test
timeouts. Broader Cloud and Workspace test runs encountered timeouts under concurrent load;
the failing cases passed when isolated (Cloud start-permit tests used a 30-second
CLI test timeout). The Workspace component command stops on existing formatting
in `lib/release_trust_roots.dart`, `test/plugin_cli_ipc_test.dart`, and
`test/plugin_service_test.dart`; these unrelated files were not reformatted.
Workspace analysis reports an existing style information message in
`test/workspace_cli_output_parity_test.dart`. Consult run output for complete
component-suite results; this record does not claim release qualification.

## Upgrade and limits

No database migration or installation identity change. Existing immutable 1.0
packages stay installed. Build/import/test/register/enable the 1.1.0 package using
the existing digest-bound consent flow; no running installation was activated by
this source change. Old timestamp session markers are not trusted; canonical
context rebuilds execution state. Package digest changes also reconstruct.

Listed Ollama entries are not execution verification, memory admission or proof
that a custom alias executes locally. Explicit `:cloud` entries and reserved
adapter session names are excluded; local-only deployments must disable daemon
cloud features. CLI preflight checks are not atomic with inference: concurrently
removing a model after discovery can trigger the native CLI's automatic pull.
There is no explicit pull operation in the adapter. Existing filesystem isolation and Chat eligibility restrictions
remain unchanged. Adapter state cleanup, provider format compatibility and
cancellation before checkpoint commit remain adapter responsibilities.
