# Provider failure details: implementation phases

Status: **Phase 4 implementation in progress; end-to-end verification remains**. This plan changes the current error and
privacy contract in [Work v1](../specifications/WORK_V1_CONTRACT.md#run-details-and-observability).
The existing canonical-only behavior remains authoritative until the relevant
phase is implemented and deployed. Each phase must be independently reviewable;
do not claim the end-to-end feature is complete until phase 5 is verified.

## Target behavior

- Keep the Syntila execution error code, canonical fallback message and failed
  status authoritative for lifecycle, retry and automation. A CLI response on
  an error is not proof of success and must never become a successful result.
- When a provider supplies an error code, error message, or response together
  with a failure, preserve them as separately identified provider-supplied
  fields. Preserve both the error and response when both exist. A process exit
  code is process evidence, not a substitute for a provider error code. Do not
  fabricate a native code or expose an Engine classification as a native code.
- The client renders the supplied text as text without rewording, parsing, or
  inferring a new status. Clearly label a response as coming from a failed run.
  Keep the generic message when provider information is absent. Show fields on
  reload as well as during the live update.
- Provider text becomes part of the failed Work record and is visible to users
  authorized to view that Work, including in shared Workspaces. It may contain
  local paths, file contents or other sensitive information. Workspace owners
  decide whom to share with; the product must explain that visibility at the
  relevant sharing or display surface. Ordinary Work authorization remains in
  force; this change grants no new access.
- Never persist API keys or credentials in plaintext application tables.
  Encrypt the entire provider failure object before table persistence with an
  authenticated encryption key held outside application tables. Phase 3 must
  define key lifecycle, access control and fail-closed behavior before enabling
  persistence. Pattern matching alone cannot guarantee credential detection.
  If a credential is detected, do not persist it in plaintext; make
  any omission explicit rather than silently presenting altered text as the
  original. Secret detection is not a guarantee that all sensitive content is
  recognized. Preserve ordinary provider text without client-side changes.
- Bound payloads consistently across all hops. Preserve original text up to a
  documented limit, and explicitly mark truncation or omission. Limits must
  fit frame, WebSocket, database, API and UI constraints, including Unicode
  and multibyte content. Do not put raw provider payloads into logs, activity
  events, analytics or support reports as a side effect.

## Phase 1: contract and compatibility

Specify versioned, optional fields for native error code, provider error text,
failed-run response, source and truncation/omission metadata. Define field
types, per-field and total byte limits, encoding, terminal control handling,
credential handling, retention, authorization and explicit fallback behavior.
Specify how a Profile declares extraction of native error fields and response
on failure without provider-specific Engine logic. Separate provider-provided
data from stderr, Engine-generated diagnostics and process exit evidence.

Update both TypeScript and Dart Workspace protocol schemas and the Local Worker
Protocol together, including their strict validators and generated bindings.
Choose and document compatible capability negotiation or a coordinated version
cutover before emitting new fields; old peers must not reject terminal messages
or lose the canonical failure. Include plugin-host behavior and old Profile
releases. Do not add compatibility APIs for unreleased architectures.

**Evidence:** contract fixtures for old and new peers, invalid/oversized values,
absence of optional fields, exact Unicode text, credential handling and generated
binding checks. Document any rollout order and its mixed-version behavior.

## Phase 2: Engine and Workspace delivery

The generic Engine advertises `provider_failure_details_v1` during initialization;
Workspace selects Local Worker Protocol 4.4 only for an Engine that
advertises it, including MCP Worker executors. Failure details are encrypted with AES-256-GCM in the local
assignment journal using an installation-specific key in the platform credential
store. Missing keys and authentication failures must not create replacement keys
or expose plaintext. Cloud delivery is gated on its `assignment.provider_failure.v1`
capability; an older Cloud receives only the canonical failure. Cloud advertises
the capability only when its encryption key is configured. The AGY starter Profile
declares failure extraction; signed releases remain immutable. Additional
provider and plugin coverage and real-device secure-store verification remain
necessary before considering this phase complete.

Extract failure fields through signed Tool Profiles and the generic Engine,
including structured errors and a final response on failure. Inspect each
first-party CLI's documented output and existing Profiles; support plain-text
and stderr-only failures using explicitly identified sources. Preserve terminal
failure, existing session and retry semantics, and distinguish a provider code
from process exit status. Update Profiles and their conformance fixtures without
silently changing already signed releases. Plumb fields through Engine frames,
supervisor, Workspace normalization, local assignment journal and replay to
Cloud. Keep private diagnostics separate.

**Evidence:** focused Engine/Profile and Workspace tests for AGY's error plus
response, structured errors from other supported CLIs, stderr-only failure,
missing fields, nonzero and zero process exit, size limits, cancellation,
replay and mixed-version fallback. Run Workspace Service checks and component
validations required by repository policy where the environment permits.

## Phase 3: Cloud persistence and reads

Cloud encrypts bounded provider failures with AES-256-GCM and the assignment ID
as authenticated data. Only authorized Work detail and history reads decrypt
them. The envelope follows assignment and Work retention. The gateway publishes
a content-free phase update so clients re-read the authorized Work record. Key
provisioning, recovery, the online rotation limitation and fail-closed behavior
are specified in the [Work contract](../specifications/WORK_V1_CONTRACT.md#provider-failure-details-contract-phase-1).

Validate and persist the new fields with the matching assignment attempt;
retain stable error classification and terminal transition/idempotency rules.
Carry them through the Work history and Run details read models and live updates
without exposing one attempt's details on another. Apply existing Work/thread
authorization on all reads. Treat provider content as data, never as trusted
markup or instructions. Keep issue-report/support diagnostics and telemetry
separate unless explicitly authorized by their own contract. Establish retention
and account deletion behavior; identify any schema migration actually required.

**Evidence:** backend integration tests for receipt, persistence, reload,
authorization, retries and duplicate terminal delivery, limits, and fallback
for older records. Validate direct protocol consumers and the backend component.

## Phase 4: Work UI

The Work timeline renders provider details as plain selectable text, including
per-step research failures and unavailable-data notices. Provider failure text
is excluded from the persistent browser read cache and is restored by an
authenticated Cloud refresh. Phase 5 still verifies the complete cross-service
path and real-device constraints.

Display the canonical failure and separately labelled provider error/code and
failed-run response where Work failure details are shown. Render text safely,
preserve line breaks, show explicit truncation/omission, and make long responses
usable. Do not transform provider text or treat it as success. Explain the
sharing visibility to the owner in an appropriate existing product surface.
Keep existing retry and issue-report behavior intact.

**Evidence:** functional UI tests for both error and response, each field
alone, fallback, reload, shared access and long/untrusted text. Run the App
component validation. Check accessible labels and a narrow layout.

## Phase 5: independent end-to-end verification

Review the implementation independently when practical. Exercise a deterministic
fixture end to end through Engine, Workspace journal/replay, Cloud and UI with
AGY-shaped `ERROR` plus response, and at least one other CLI output shape.
Verify exact text and native code, failure status, retry behavior, permissions,
credential handling, truncation and reload; test old peers and old records as
specified in phase 1. Run direct downstream component validations and document
results, limitations and rollout. Use real-provider evidence separately where
available; do not treat a provider's claim that tests passed as verification.
Historical failed assignments cannot recover text already discarded by the
current implementation.

### Local verification in progress

- Focused Engine tests cover the AGY-shaped error and response, and retain the
  structured denial data after a read-only retry also fails. Dart protocol
  tests cover 4.4 executor frames and canonical-only older frames; Workspace
  tests cover encrypted journal replay and the Cloud capability gate.
- MCP Worker execution now negotiates 4.4 only when the Engine advertises the
  capability. Plugin-supplied codes and messages are bounded and protected by
  the same failure-details policy; detected launch secrets cause an explicit
  field omission. Focused MCP Engine and runner tests pass when process
  inspection is allowed; the sandbox denies `/bin/ps`, causing even existing
  MCP fixture servers to be terminated.
- The Workspace Service smoke check compiled and passed with access to its
  default Work Root; the sandbox denied that access. The prepared Workspace
  component validation stopped at pre-existing formatting differences in ten
  unrelated files. The `pnpm` wrapper stalled even for `pnpm --version`.
  The complete Engine-to-UI acceptance fixture, another CLI
  output shape, real-device secure-store evidence and component validations
  remain open; these results do not constitute Phase 5 acceptance.
