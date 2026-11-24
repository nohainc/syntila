# Dynamic Worker E2E — 2026-10-03

## Acceptance result

The fixture-backed Phase 13 journey passed without adding a Worker-specific
application branch or executable:

1. Profile Lab registers a unique Logical Worker and Profile Definition through
   its admin client, persists an unsigned Draft, and uploads the Draft payload.
2. The Profile Lab sandbox runs the 11-stage ladder through the bundled generic
   CLI Worker Engine and a temporary fixture CLI. Its full qualification
   evidence is bound to the Draft payload digest.
3. A local Cloud test boundary accepts that qualification and signs the Testing
   release with a test-only Ed25519 key. The signature is verified using the
   normal Workspace trust policy.
4. Workspace discovers the unique Worker through the runtime catalog HTTP
   endpoint, downloads the Cloud-selected Testing Profile through the normal
   Profile HTTP endpoint, activates it after a live Engine probe, and marks the
   local Worker ready.
5. The safe Workspace inventory is joined to Cloud catalog metadata in the AX
   Worker projection. AX's real `AxApiClient` creates a `direct` Work Request
   for a Thread; the Cloud test boundary applies the new Thread binding
   and dispatches an assignment to the Workspace handler. The bundled Engine
   and fixture CLI execute it and return `WORK_DONE`.
6. AX loads the completed Work Request through its real API client. The Work
   step preserves the new Worker identity, display name, Profile release,
   provider metadata, and result.

The Worker ID is generated during the run and is not present in the repository's
application source or catalog fixtures. The provider implementation is a
temporary executable created by the test. No application source changes are
needed to add or execute this Worker.

## Checks

From `apps/workspace`:

~~~sh
flutter test test/dynamic_worker_end_to_end_acceptance_test.dart --reporter=expanded
flutter analyze
~~~

From `apps/app`:

~~~sh
flutter test test/dynamic_worker_ax_acceptance_test.dart --reporter=expanded
flutter analyze
~~~

All four checks passed on 2026-10-03. The Workspace journey uses the actual
bundled Engine, Workspace-to-Cloud HTTP clients, and AX Work Request client.

## Scope and limits

Cloud is an in-process test boundary in this acceptance. It checks the Profile
Lab create, Draft, qualification, and publication calls and applies a
short-lived test signing key; it does not exercise deployed Cloud, D1
persistence, production signing, or a real Testing Workspace rollout. The
provider is a fixture CLI, not a real external provider. The acceptance proves
the dynamic Worker contract and Work execution path, while production Cloud
and real-provider release gates remain tracked separately in the
Architecture v8 roadmap.

No database migrations or compatibility changes were made.
