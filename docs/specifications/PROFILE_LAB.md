# Profile Lab Specification

**Status:** Current V9 operational specification; the V8 material below is retained as a historical migration reference.
**Architecture:** [Worker Profile V9](WORKER_PROFILE_V9.md)
**Decision:** [ADR-019](../decisions/ADR-019-syntila-profile-lab.md)  
**Implementation:** `apps/profile_lab`

## V9 operating contract

Profile Lab is an authenticated operator tool for one current JSON Profile per
logical Worker. The operator edits a local candidate, validates it, runs the
required digest-bound tests, and publishes it through one atomic Cloud
publication transaction. Cloud revalidates the payload, evidence, candidate
digest, and expected revision before storing the new current snapshot and
history record.

V9 Profiles are not cryptographically signed. Workspace verifies the canonical
payload digest, schema, Worker identity, and Engine compatibility before
activation. Workspace application releases retain their separate native
release-signing mechanism. There are no Profile testing, beta, or stable
channels; previous snapshots are inspected or restored as a new current
revision. Provider credentials remain local to the provider CLI, and local
candidate testing remains isolated from production execution.

The remainder of this document is the superseded V8 lifecycle reference. It is
not an active API, storage, or runtime contract.

## Historical V8 reference (superseded)

## 1. Executive Summary

Syntila Profile Lab is an internal macOS desktop application (`apps/profile_lab`) dedicated to authoring, validating, sandbox testing, publishing, promoting, rolling back, and revoking Syntila Tool Profiles and Logical Workers.

Under Architecture v8, provider-specific Worker executables are replaced by one generic CLI Worker Engine (`engines/cli_worker`) configured by signed, immutable Tool Profiles. Vendor CLI tools evolve rapidly. Profile Lab is the operational control surface that enables engineers and maintainers to keep provider CLI integrations up to date without releasing new Workspace application binaries.

### Current release controls

Profile Lab stores complete sandbox evidence locally in the exact Cloud contract shape. Before publication, it submits that contract as local qualification for the exact draft digest; Cloud stores it immutably and requires its ID to sign and publish. After publication, an operator can submit a separate acceptance record for Stable promotion. Promotion references only the returned Cloud evidence ID; Profile Lab never includes evidence JSON in a promotion request.

The Profile Draft Assistant uses a Cloud-trusted Stable Worker Profile and the local generic CLI Worker Engine to request model-backed Draft proposals. Before each request, the operator confirms that the Draft and bounded test diagnostics may be sent through that provider CLI. Profile Lab does not collect or store provider credentials. The separate Repair Loop remains an experimental local heuristic. Both flows can propose Draft edits only; their output is never test evidence or acceptance evidence.

---

## 2. Product Boundaries & Architecture Surfaces

Syntila enforces a strict separation across four distinct product surfaces:

```text
+-----------------------+      +-----------------------+      +-----------------------+
|      Syntila      |      |   Syntila Workspace  |      |  Syntila Profile Lab |
+-----------------------+      +-----------------------+      +-----------------------+
| Human orchestration   |      | Local Work Root &     |      | Profile engineering   |
| Spaces & Threads|      | reliable execution    |      | Draft authoring       |
| Step bindings         |      | Admitted signed       |      | Sandbox testing       |
| Worker selection      |      | releases ONLY         |      | Evidence & promotion  |
+-----------------------+      +-----------------------+      +-----------------------+
           \                               |                             /
            \                              |                            /
             +---------------------------------------------------------+
             |                     Syntila Cloud                      |
             | Authoritative state, Worker catalog, signing boundary   |
             +---------------------------------------------------------+
```

### Boundary Rules:
1. **Syntila:** Web application for human space orchestration. Displays catalog workers and local readiness. Exposes zero profile editing or administration.
2. **Syntila Cloud:** Multi-tenant authoritative backend. Manages `worker_catalog`, `tool_profile_definitions`, `tool_profile_releases`, release channels, and Ed25519 cryptographic signatures. Executes zero provider tools.
3. **Syntila Workspace:** Background-first native desktop machine runtime. Manages local Work Roots, process tree execution, and local worker readiness. Consumes **only** cryptographically signed, admitted Tool Profile Releases.
4. **Syntila Profile Lab:** Administrative desktop engineering application. Authors and tests unsigned local Draft Profile candidates against installed provider CLIs in an isolated sandbox. Exposes full release lifecycle management. **Never registers as an execution Workspace, never accepts Work assignments, and never owns Space Work Roots.**

---

## 3. The Core Authority Chain

Logical Worker product identity is strictly decoupled from versioned implementation profiles:

```text
Worker Catalog (`worker_catalog`)
       ↓
Tool Profile Definition (`tool_profile_definitions`)
       ↓
Tool Profile Release (`tool_profile_releases`)
       ↓
Generic CLI Worker Engine (`engines/cli_worker`)
       ↓
Provider CLI (local executable binary)
```

No Worker identity (such as `chatgpt` or `gemini`) is hardcoded in Profile Lab, Workspace, or AX. Syntila Cloud is the sole authority for catalog descriptors and profile bindings. Adding a new Worker in Profile Lab makes it discoverable by Workspaces and selectable in AX without application redeployment or code modifications.

The Create Worker form starts new catalog entries in the `testing` release stage and offers only `testing`, `beta`, or `stable`. Worker and Profile capability arrays are not authored here; workflow eligibility and access policy are Cloud-owned. The v8 development cutover removed releases that contained the retired top-level `capabilities` field. New drafts and releases are rejected if they contain that field.

Profile Lab executable discovery follows the same rule: it gathers executable names from the loaded Worker catalog's `providerToolName` and from Tool Profile `providerTool.name` and `providerTool.executableCandidates`. Profile-declared `standardLocations` are used for those candidates. Diagnostics list only the names found in loaded Worker/Profile data; the application does not maintain a built-in provider inventory. Session formats and resume arguments remain Profile data, and a failed session diagnostic does not let repair logic infer them from a provider name.

Profile Lab builds default to `https://syntila.app`. Development builds can set `SYNTILA_CLOUD_URL=http://localhost:8787` with a Dart define or choose an origin in the Cloud connection settings. The settings override persists locally and can be reset to the build default. Cloud origins must be HTTPS except for loopback HTTP in development builds; URLs with credentials, paths, queries, or fragments are rejected. Saved Keychain sessions are bound to their Cloud origin and are cleared when the origin changes. Legacy sessions without origin binding are discarded.

### Profile Lab application boundaries

The `ProfileLabController` remains the UI-facing façade, with draft editing and sync, Engine testing, session handling, and Cloud administration implemented in separate controller components. `ProfileAdminApiClient` decodes Cloud reads into typed read models for Workers, definitions, releases, evidence, audit events, channel pointers, Workspace assignments, and signing preflight. The Tool Profile payload remains an open JSON object because its schema evolves independently. The controller converts Cloud read models to JSON-shaped presentation state for the Worker lifecycle views; no legacy navigation or compatibility pages are retained. New application logic should use typed read model fields directly.

---

## 4. Draft Authoring & Sandbox Testing

### Draft & Test workbench

The local candidate is always loaded from
`apps/profile_lab/assets/profiles/<workerTypeId>.json` in the repository checkout Profile
Lab runs from (the nearest ancestor containing `.git` of the working directory or
the app binary). Profile Lab does not load profiles from bundled app assets,
starter templates or the Cloud Profile. Selecting a Worker reads the file;
**More → Reload Profile from file…** forces a reload after confirmation. The file
must be for the selected Worker and its profile definition. If the candidate has
local edits and the file changed, the edits are kept and the menu flags the file
as changed. The current Cloud Profile stays available only as comparison and
publication revision state.

The selected Worker defines the workbench context; there is no separate local
Draft selector. A single header shows Draft version, local save status and Cloud
sync status. **Save** persists unsaved edits locally, then **Sync to Cloud** is
the primary action. Sync is reported only when the saved payload digest and
version match the Cloud draft. Conflicts retain explicit compare/resolution controls.

Wide workbenches default to a draggable Editor/Test split; narrower workbenches
stack the panes with a draggable horizontal divider. Compact toolbar buttons
collapse either pane (always leaving one visible) and toggle the **Inspector**,
which contains the structured Profile summary. Collapsing panes preserves editor
state. Tests require saved valid JSON and remain accessible in a scrolling pane.

Format JSON, Compare, Duplicate as Next Release, Revert, AI Proposal and
Experimental Repair are in the overflow menu. A failed test exposes a contextual
Repair Profile action; it retains the existing consent and review workflow.
A passing test exposes the separate authorized qualification/publication action.
These layout controls do not change evidence, signing or release authority.

### Draft testing and release evidence

There is no separate Tests page or local/Cloud evidence scope selector. The
active Draft’s Test pane starts with **Provider CLI**, **Version**, and
**Authentication** preflight statuses followed by **Run Full Test**. CLI discovery
uses Profile-declared executable candidates. Version and authentication show
**Not checked** until the full test observes them. Persisted matching evidence
is labeled as previously tested rather than a fresh check; authentication readiness
reflects the Profile’s passive probe checks, not a Cloud identity or credential.
No model-consuming preflight runs automatically.

During a run, completed stages stream into the pane. Completion summarizes
actual passed stages out of eleven, skipped stages separately, provider/version,
elapsed duration, and readiness for Cloud qualification. Qualification readiness
requires saved local acceptance evidence matching the exact Draft identity,
version and digest. Changing the saved payload or Worker clears the displayed
run; unsaved edits block testing and qualification. Late events from a previous
Draft do not populate another Draft’s Test pane.

Failed stages expose **Retry** (reruns the complete test), **Apply version range**
when the version probe supplies a bounded recommendation, and **Repair Profile**
using the existing experimental proposal/review workflow. Applying a range saves
the changed Draft and requires a new full test. Raw streamed logs live in collapsed
**Execution details**; digest-bound **Local acceptance evidence** stays with the
result. Cloud acceptance records are inspected under the matching published
release in **Releases**, with definition/version/digest filtering. Cloud still
validates qualification and promotion independently.

### Profile creation

When the repository has no file for the selected Worker, Draft & Test shows the
expected path and **Reload from folder**. No Profile is created or seeded
automatically. Loading a file never replaces an existing Cloud version.

Cloud owns `tool_profile_starter_templates`, keyed by `profile_definition_id`,
with schema version, v1 Profile JSON and update timestamp. The fresh v8 baseline
and development seed include the tested `chatgpt-codex` and `gemini-antigravity`
v1 fixture payloads. Templates are mutable authoring data, carry no qualification
or signature, and are absent from Workspace APIs and storage. Normal local tests,
Cloud sync, qualification, signing and rollout remain required. The definition
response’s nullable `starterTemplate` contains `{schemaVersion: 1, profile: ...}`.
The v8 baseline is updated in place; existing development databases must be
rebuilt/reseeded or explicitly provisioned with the table and seed data.

After the development release reset, use the clean candidate payloads in
`packages/tool-profile/test/fixtures/chatgpt-codex.v2.json` and the current
Gemini starter returned by Cloud (or
`docs/profile-templates/gemini-antigravity-runtime-catalog.v1.json`) to create
and test the next ChatGPT and Gemini releases. The Gemini candidate must carry
`model.selectionMode: "combined"` and `model.discovery.effortVariants` before it
can publish grouped model/effort choices (models and efforts are derived from
the CLI output, not listed in the Profile). These files are unsigned authoring
inputs; publication still happens through the normal qualification and Cloud
signing flow.


Profile Lab allows engineers to author and iteratively refine Draft Profiles before requesting a signed release:

- **Local Draft Store (`DraftProfileStore`):** Persists draft configurations locally under Profile Lab's dedicated application support directory (`~/Library/Application Support/syntila_profile_lab/drafts/`).
- **Unsigned Draft Candidate (`LocalDraftProfileCandidate`):** Implements `ToolProfileCandidate` with `isSigned => false`. Unsigned drafts are strictly barred from entering Workspace's trusted profile store (`ToolProfileReleaseStore`).
- **Sandbox Test Supervisor:** Uses `PlatformProcessSupervisor` from `syntila_cli_worker_runtime` to run tests out of process with hard execution deadlines, process tree cleanup, and secret redaction (`SafeProviderDiagnostics`).
- **Progressive Test Ladder:** Keeps schema, Engine compatibility, executable discovery, version, passive probe, and live probe as preflight stages. It then submits actual assignments through the generic CLI Worker Engine, including a file write verified inside the isolated sandbox. Session create/resume and model selection each submit real Engine assignments when the Profile contract supports them; unsupported or untestable scenarios are shown as skipped, never passed.
- **Representative Write Verification:** The write stage requires the expected UTF-8 sentinel and accepts either the exact bytes or one conventional terminal LF/CRLF. This accommodates provider CLIs that serialize a text-file edit with a final line ending while still rejecting missing, redirected, or altered content.
  Each restricted/full-access write assignment has a bounded three-minute
  deadline to accommodate provider tool execution. When full access is defined,
  both checks must succeed for the representative-write acceptance status to
  pass. This budget does not change production assignment or live-probe limits.
- **Cancellation and Deadline Tests:** The Engine emits an internal start marker after the provider process is spawned; the host supervisor consumes it and wakes the ladder. Cancellation is requested as soon as that marker arrives, with no fixed sleep. The timeout case gives the provider a 100 ms Engine execution deadline after spawn while retaining a separate outer supervisor deadline. A stage passes only when the Engine reports the expected outcome and terminates the process tree. The operator can also cancel the currently active Engine assignment from the Test Bench.
- **Evidence Result:** The sandbox emits all eight Cloud scenario keys. It records `passed` only after observing an applicable scenario succeed and records `not_applicable` when the signed Profile contract does not support that scenario. Cloud independently derives the same expected statuses from the release Profile. Failed or incomplete run diagnostics remain in the local Test Workbench and do not become acceptance evidence.
- **macOS CI Acceptance:** The Profile Lab macOS verification script builds the actual CLI Worker Engine executable from `engines/cli_worker`, saves and reloads an unsigned Profile Lab Draft through `DraftProfileStore`, and runs the full 11-stage ladder against a local fixture provider. The check requires the real Engine and every applicable scenario to pass, validates the resulting Cloud evidence contract against the Draft digest, and verifies sandbox cleanup. It uses no live provider account or credential.

---

## 5. Cryptographic Evidence & Release Publication

Profile Lab stores local sandbox contracts against the canonical payload SHA-256 digest. Before publication, it submits the matching contract to Cloud as local qualification. Cloud validates and stores the submitted contract, then returns an ID that the publish request must include. This is a digest-bound authenticated assertion, not remote attestation of the local process; only the supported Profile Lab client emits a contract after applicable Engine scenarios pass. The request carries no signature or signing-key ID. Before this flow, Profile Lab checks the admin-only Cloud signing preflight. Cloud verifies that its configured private key matches the public trust root for the configured publisher/key ID and that the key is not revoked. Publication repeats signer and qualification checks and fails closed if either is invalid or unavailable:

1. **Local Qualification:** The sandbox emits the `ToolProfileAcceptanceEvidence` contract only when all required Engine scenarios pass. Cloud validates current draft identity/digest, reported Engine and provider compatibility, freshness, and required statuses, then stores an immutable qualification record before publication. Failed or incomplete ladder diagnostics remain in the Test Workbench and cannot qualify a draft through the supported client.
2. **Digest Invalidation:** Any mutation to a Draft Profile payload changes its SHA-256 `payloadDigest` and invalidates all previously gathered test evidence.
3. **Cloud Signing Boundary:** Cloud requires the stored qualification ID, reloads and validates it against the current draft, verifies release-manager scope (`profiles:release:manage`) and signer readiness, and signs the release using Cloud's Ed25519 private key. Stable promotion, Stable channel assignment, and rollback require a recent session-bound passkey step-up. Release revocation requires release-manager authorization, a mandatory reason, and explicit confirmation in Profile Lab.
4. **Cloud Acceptance Evidence API:** After publication, Profile Lab can separately submit an acceptance contract for the signed release. Cloud validates it and returns an immutable acceptance evidence ID.
5. **Stable Promotion:** Profile Lab sends only the stored Cloud evidence ID. Cloud reloads and revalidates that record against the signed Profile and digest before promotion.
6. **Signed Admission (`ToolProfileReleaseAdmission`):** Returned to clients with `isSigned => true`. Production Workspaces load and verify these signed releases using public keys (`ReleaseTrustRoots`).

---

## 6. Release Lifecycle & Channel Promotion

Profile releases move through a controlled lifecycle managed via Profile Lab:

```text
Local Draft → Cloud Qualification → Published Release → Testing Channel → Beta Channel → Stable Channel
                                        |                |
                                     Rollback         Revocation
```

- **Channel Pointers:** Cloud maintains channel pointers (`workspace_tool_profile_channels`) pointing to release versions (`testing`, `beta`, `stable`).
- **Channel Promotion:** Promoting a release moves a pointer forward. The underlying profile payload and signature remain 100% immutable.
- **Rollback:** Pointing a channel backward to an earlier immutable release version instantly restores a known-good configuration.
- **Revocation:** Marking a release as revoked (`revoked_at` timestamp) causes Cloud and Workspaces to immediately refuse execution for that release version across all channels.

---

## 7. Model-backed Draft Proposals & Experimental Repair Loop

The AI Draft Assistant resolves available model runners from the Cloud Worker catalog's current Stable channel pointers. It verifies each Profile signature against build-injected public trust roots and applies Cloud's current signing-key and Profile revocations before offering a model. A selected signed Profile executes locally through the generic CLI Worker Engine; the unsigned Profile being edited is never used as the model runner. Model selection uses a Profile-declared allowlist where available and otherwise delegates to the provider CLI's configured default.

Before sending a request, the operator explicitly consents to sending the current Draft and bounded test diagnostics to the selected provider. Credential-like fields and secret-like values in the Draft are rejected. Provider authentication remains in the installed CLI. The response must be a complete schema-valid Profile and must preserve the Draft's Worker, Profile, release version, and provider identity. Profile Lab displays a domain diff and requires an explicit human review-and-apply action. Apply updates only the local Draft editor. Provenance is stored in local Draft metadata and never inserted into the signed Profile payload. Saving, local qualification, Cloud publication, and Stable promotion remain separate human-controlled workflows.

The separate Repair Loop remains an experimental local heuristic and is not model-backed:

1. **Iteration Workflow:** Generate candidate → Validate JSON schema → Run local probe suite → Normalize failure log → Apply local heuristic repair rules → Display diff → Retest.
2. **Iteration Ceilings:** Automatically caps iterations (default: 3) and requires explicit human confirmation before applying material changes.
3. **Proposal Provenance:** Draft metadata records:
   - Creator/Modifier origin (`human`, model-backed Draft Assistant, or experimental heuristic repair loop);
   - the selected Worker Profile and model identifier when model-backed;
   - Parent release version and digest;
   - Prompt/task reference;
   - Resulting diff digest.

Audit records provide clear operational history (e.g. *"Draft v20 created by AI-assisted change, reviewed by Vitalii, tested on Codex 0.188.0, published by controlled signer, promoted to Testing by Vitalii"*).

Profile Lab's `SYNTILA_RELEASE_TRUST_KEYS_JSON` build define contains public Ed25519 trust roots only. If no valid root is configured, no model runner is offered. Production and development builds must receive the same managed public trust configuration used to validate Workspace Tool Profile releases.

---

## 8. Security Ceilings & Architecture Guards

Profile Lab enforces strict security boundaries verified by automated repository guards (`verify-v8-architecture.mjs`):

1. **Zero Direct D1 Access:** Profile Lab communicates exclusively via HTTPS REST endpoints (`ProfileAdminApiClient`). Direct database bindings (`D1Database`, raw SQL) are strictly prohibited.
2. **Zero Signing Seeds:** Signing private key seeds (`SYNTILA_WORKSPACE_ED25519_SEED`, `Ed25519PrivateKey`) are forbidden in Profile Lab code. Signature generation belongs solely to Cloud.
3. **Secret Redaction:** Test output logs and diagnostic summaries undergo strict secret redaction preventing provider keys or desktop tokens from being stored in logs or evidence artifacts.
4. **Process Isolation:** Provider CLI processes run under bounded deadlines with full process tree termination upon completion or cancellation.

---

## 9. Manual Profile Lifecycle Completion & Autonomous AI Maintenance Governance

### Acceptance Criteria and Current Status

**Manual Profile lifecycle: COMPLETE** for the implemented control path. Profile Lab supports human Worker/Profile creation, Draft editing, local Engine qualification, Cloud-signed publication, channel management, and lifecycle administration. Fixture acceptance covers dynamic Workspace discovery, AX projection, and Work execution without Worker-specific source changes. Publication and Stable promotion reference separately stored Cloud qualification and acceptance records.

This status does not claim that all real-provider workflows pass or that a deployed Testing Workspace rollout has completed. The [real-provider acceptance record](../acceptance/real-provider/2026-10-03/README.md) documents provider-specific results and remaining rollout gates. Cloud validates the submitted evidence contract and binds it to the release digest, but does not remotely observe or attest to the local provider process; see the [evidence contract](TOOL_PROFILE_EVIDENCE_CONTRACT.md).

### Human Control and AI Proposal Boundary

Model-backed assistance is limited to proposing Draft edits within this human-controlled lifecycle:
- AI models propose state changes by generating draft candidate JSON payloads.
- Syntila owns persistent state, validates JSON schemas against `TOOL_PROFILE_LIMITS`, and enforces signature verification.
- The operator consents before Draft context and bounded diagnostics are sent, reviews the proposal diff, and explicitly applies it to the local Draft.
- Qualification, publication, signing, Stable promotion, rollback, and revocation remain separate human-controlled Cloud workflows.
- Proposal output is not qualification or acceptance evidence. Cloud's evidence contract is an authenticated assertion validated and bound to a release; it is not device attestation or independent proof of local execution.

### Provider compatibility

Provider compatibility starts incomplete for a new Draft. A successful
version probe can offer a narrow range beginning at the discovered version and
ending at the next minor boundary. Applying the suggestion saves the local
Draft; qualification must then be rerun. Cloud publication rejects missing or
obvious near-universal placeholder ranges.

## Tab activation and operation state

Navigation changes the selected tab synchronously and remains available during
Cloud refreshes, provider discovery, local tests, AI proposals, and release
operations. The controller schedules lazy loading after navigation; tab views
must not fetch data or notify the shared controller during construction.
The application activates the initial tab after its first frame and activates
the current tab after successful sign-in.

Concurrent refreshes coalesce by domain and resource identity (catalog,
Workspace channels, definition, definition releases, release evidence, and
scoped audit). Catalog and Workspace data load lazily, including successful
empty results; explicit Refresh retries or reloads them. Releases are keyed by
Definition. Evidence and audit refresh on activation. Loading and errors are
owned by their individual domains. Publication, Cloud save, promotion,
rollback, revocation, and Workspace channel updates disable only their
initiating actions. Operations continue when the operator changes primary areas.
Responses for a previous Cloud origin/session or a superseded Definition or
release selection must not replace the current read model.

Workers distinguish sign-in required, not yet loaded, loading, successful
empty catalog, populated catalog, unauthorized access (HTTP 401/403), and
failed refresh. Failures display the actual error and Retry, including when
an older catalog remains visible. A malformed response is a failure, not an
empty catalog. Search with no matches has its own message. No built-in Worker
fallback exists: Cloud's `worker_catalog` and `tool_profile_definitions` remain
the shared source for Profile Lab and Workspace. The fresh v8 bootstrap seeds
ChatGPT and Gemini identities and Definitions, but no signed releases.

Regression coverage includes authenticated tab switching while catalog and
Workspace requests remain delayed, duplicate request coalescing, catalog
failure and unauthorized rendering, and the real admin catalog endpoint over
the fresh v8 database. These fixture checks do not establish deployed-service
or packaged desktop acceptance.

## Development access and unsigned execution

The checked-in Cloud configurations set
`SYNTILA_PROFILE_LAB_OWNER_EMAIL=vitalii@nohainc.com`. When this setting is
present, only that active account can approve, claim,
or use a Profile Lab desktop session or administer Profiles. The email is
resolved from Cloud's authenticated user record, never a client request field.
This exclusive policy replaces the user-ID admin and release-manager allowlists;
older allowlists cannot grant another account access. Browser authentication,
audience separation, credential rotation, and revocation remain in effect.
A blank configured owner denies everyone. Deployments without an owner setting
continue to require explicitly configured ID allowlists.

`GET /api/admin/profile-lab/access` requires authentication and returns the v1
access read model (`schemaVersion: 1`): authenticated identity/audience,
`permissions.profilesAdmin`, `permissions.releaseManager`, and
`signer.ready`/`signer.issues`. The Lab locks its content until Cloud verifies
administrative access. Its header shows Signed in until permission is verified,
then Profile Admin; the account/access control exposes release permission and signer state. There is no permanent access/status strip.
Check access retries the access read. Authentication alone never grants access.

All environments expose the complete Draft → Test → Sync → Testing → Beta →
Stable lifecycle. There is no Profile release mode switch. Publication requires
release permission, a ready signer, and stored qualification for the exact saved
and synced Draft. Missing signer/access is explained beside **Publish to Testing**;
the action remains visible after qualification. After publication the workbench
offers **View Releases** rather than publishing the same immutable version again.
No release rows are bootstrapped, and macOS app signing does not control these actions.

The unsigned exception also supports an explicitly opted-in local-development
Workspace. It uses `SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY` in a non-release build
and requires a loopback Cloud origin. It reads `<definition>/draft.json` from the
selected local directory (normally the Lab draft directory), validates Tool
Profile schema and catalog identity, and applies Engine/provider compatibility.
Each execution pins canonical bytes by digest in Workspace's separate
`development_profiles` directory. Drafts never become `ToolProfileReleaseAdmission`
and never enter the signed release store, channel pointers, or last-known-good
state. Edits apply to later resolutions, not already selected runs. Release
builds and remote Cloud connections reject this exception. The Workspace marks
it Unsigned / Local development. This supersedes the blanket unsigned exclusion
only for this bounded development path; production execution still uses signed
Profiles through the generic CLI Worker Engine.

For local development, start Cloud/AX with the existing local startup workflow,
then run `bash scripts/run-profile-lab-development.sh` and
`bash scripts/internal/run-workspace-development.sh`. Both default to
`http://localhost:8787`; set `SYNTILA_DEVELOPMENT_CLOUD_URL` to the same loopback
origin as your local Cloud. Sign in through the browser as the owner,
save and test a draft in the Lab, sync it, and publish to Testing. Assign the
development Workspace to Testing in the Lab and run a real task. The Workspace launcher
uses a separate DevelopmentState directory so existing production registration
is not reused. It now defaults to signed Cloud releases. Explicitly set
`SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY` to opt into unsigned local Draft execution;
that exception remains loopback-only. `SYNTILA_WORKSPACE_DEVELOPMENT_DATA_DIR`
overrides development state.

`scripts/setup-development-profile-signing.mjs` generates and validates a local
Ed25519 signer in ignored `apps/cloud/.dev.vars` (0600), preserving existing keys
and unrelated settings. Public roots are written to ignored
`.development/profile-trust.json` and injected by both development launchers.
The local stack launcher prepares this configuration before starting Wrangler.
`--hosted` prepares a separate development signer and public roots for the current
hosted development deployment; upload its ignored secret JSON with Wrangler
`secret bulk` only to the intended Worker. Launch both apps with
`SYNTILA_DEVELOPMENT_CLOUD_URL=https://syntila.app` to use the corresponding
hosted public roots. Customer build scripts never automatically load development
roots or private material; provision independent production keys before customer rollout.

Profile Lab's macOS build script skips Developer ID signing and notarization by
default, including when signing environment variables are inherited. `--unsigned`
is explicit; signing requires `--sign IDENTITY`. The internal artifact workflow
currently builds unsigned development/testing artifacts and supplies managed
public trust roots when configured. Apple may still apply local ad-hoc signatures
needed to execute a development binary; this is not Developer ID signing,
notarization, or Tool Profile release signing.

The explicitly configured internal Lab owner uses the existing authenticated
browser sign-in without a separate email-verification gate. The active account
must exactly match the configured owner email. Other emails remain denied, and
audience/session checks are unchanged. This internal owner policy is independent
of signing configuration; no verification flags are rewritten.

### Release lifecycle presentation

The selected Worker’s Releases view starts with Testing, Beta, and Stable cards populated from Cloud’s channel pointers, followed by published release history (Cloud drafts are excluded). Selecting a release shows status, publication time, provider version compatibility, release-scoped Cloud evidence, and implementation differences against the nearest earlier published version. Canonical payload and signing metadata are collapsed under Technical details. Promotion is contextual; Stable promotion continues to require qualifying Cloud evidence and the existing authorization gate. Rollback and revocation remain reason/confirmation protected and are accessed through release overflow. Refreshing releases also refreshes channel assignments and preserves the selected published version when available.

With no published releases, the view offers Draft & Test. Overview always shows Configure, Test, Sync, Publish, and Rollout. Promotion depends on release-management authorization and evidence gates, rather than desktop signing or current signer availability; existing immutable signatures do not change on promotion. Starter templates and local testing remain independent of Workspace runtime state.

### Workspace rollout and Activity presentation

Workspaces shows a compact rollout heading, Testing/Beta/Stable counts, search, and a table with Workspace, Host, App version, Connection, and Channel. Connection reflects the latest `execution_workspaces.status` reported to Cloud; absent status is Unknown, not inferred from runtime registration. Rollout help is available through an info control. Selecting another channel opens a confirmation describing the old/new assignment and effect on subsequent Profile resolution. Cancel leaves the assignment unchanged; existing authorization and Stable passkey verification remain enforced. Running sessions retain their pinned release.

Activity defaults to all events and offers an optional current-Worker filter. Event summaries lead with Worker name, version, lifecycle action, and actor name. Raw IDs, reasons, provenance, and full details remain expandable. Global and definition audit responses add nullable `actorDisplayName` and `workerDisplayName`, resolved through existing user/catalog records; these are current display labels, not historical snapshots. Missing identities are shown as System or an operator while retaining raw IDs in details. No schema migration is required.

### Design system and desktop accessibility

Profile Lab shares `LabPageHeader`, `StatusBadge`, `LifecycleStepper`, `EmptyState`, `ErrorState`, `WorkerSidebarItem`, `PrimaryActionCard`, `TechnicalInspector`, `ReleaseChannelCard`, and `OperationProgress` in `lib/widgets/lab_components.dart`. Spacing follows an 8/16/24 point scale; table rows are 48–64 points, action buttons are at least 40 points high, and technical identities/JSON retain monospace typography. Routine headings use sentence case. Indigo denotes interaction; green/amber/red denote semantic success/warning/error. Status and lifecycle indicators include readable labels and symbols, and operation/error announcements expose live regions. Shared semantic status text is checked for contrast.

At compact desktop widths (below 1000 points), the Worker catalog stacks above the selected Worker; wide windows retain the sidebar. Lifecycle steps and headers wrap, tables scroll horizontally, and the workbench retains its responsive pane arrangement. Layout regression checks cover all primary views at 800×700 and 1440×1000.

`⌘S` saves a valid modified local Draft when Draft & Test is active, including with editor focus. It never publishes or syncs automatically. `⌘R` refreshes the current resource: catalog on Overview, Cloud/evidence state on Draft & Test without replacing editor text, releases/channel pointers on Releases, Workspace assignments on Workspaces, and events on Activity. Both shortcuts are blocked behind dialogs and during conflicting operations; Save requires authorized Profile administration. Save and refresh tooltips advertise the shortcuts; the obsolete global telemetry strip is removed. Automated tests cover labels, contrast, focus, modal boundaries, and layouts; native VoiceOver verification remains a separate manual check.

### First-run acceptance and UI migration

For a deployed v8 database that predates starter templates, run
`node scripts/provision-profile-starter-templates.mjs`, then apply its generated
SQL file with Wrangler D1 to the intended database. It extracts only the current
baseline table and `INSERT OR IGNORE` seeds; existing templates, Drafts, releases,
and user data are preserved. Do not replay/reset the baseline on an existing database.

Only Workers, Workspaces, and Activity are primary areas (`LabArea`). Workers owns Overview, Draft & Test, and Releases. The workbench is `DraftTestWorkbench`, with `ProfileDraftEditor` as its editor pane; obsolete Profiles/Tests/evidence pages, their navigation aliases, the duplicate Draft selector, and the global telemetry/status strip are removed without compatibility shims. Existing local Draft and evidence storage paths, identities, formats, and Cloud APIs remain unchanged by this UI cleanup. The starter-template table remains part of the fresh-start v8 Cloud baseline; existing development databases must provision/reseed the current baseline when adopting that earlier data-model change.

`worker_first_run_acceptance_test.dart` covers sign-in, catalog selection, absent Profile, one-click initial Draft, dynamic `codex`/`agy` discovery, the actual eleven-stage ladder through the bundled Engine, persisted matching local evidence, local save, and Cloud Draft sync for both Workers with ready and missing signers. Ready-signer cases continue through qualification submission, Testing publication, and release history. Browser approval and Cloud persistence are controlled boundary fixtures. Provider executables use the existing v1 payload contracts with isolated home/PATH/environment; they do not call vendor services. The no-template path verifies a blank Draft inherits catalog identity and remains unqualified. A cold-start check reopens the same persisted Draft and matching evidence without recreating or translating them. Catalog Stable is always explicitly labeled as catalog stage and cannot establish a Stable release pointer. Signing/production rollout and real vendor acceptance remain separate release gates.

Operational messages have a copy icon. Use **Copy all messages** in the title bar to share current resource errors and active Draft test logs, or **Copy execution details** for the full test log. Secret values are redacted from copied text.
