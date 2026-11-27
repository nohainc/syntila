# Profile Lab Specification

**Status:** Current operational specification.
**Architecture:** [Worker Profile V9](WORKER_PROFILE_V9.md)
**Decision:** ADR-019
**Implementation:** `apps/profile_lab` (setup, build, workflow and acceptance commands are in its README)

## Purpose and boundaries

Profile Lab is an internal macOS desktop tool for operators who maintain one
current JSON Tool Profile per Worker Type. It authors and tests; Cloud decides.

| Component | Owns | Never does |
| --- | --- | --- |
| Profile Lab | One local candidate per Worker Type, the local test ladder, requests for Cloud validation and publication | Touch the database, hold a signing key, collect provider credentials, accept Work assignments |
| CLI Worker Engine | Runs the candidate against the provider CLI installed on the operator's Mac | Contain provider-specific app branches |
| Cloud | Worker catalog, the one current Profile, bounded history, authorization, audit, atomic publication, signing of the digest on delivery | Trust test evidence as proof of local execution |
| Connect | Verifies and runs published Profile snapshots | Edit Profiles or select a candidate |

Profile Lab talks to Cloud only through its HTTPS admin API
(`ProfileAdminApiClient`, audience `syntila.profile-lab.management`).

## Lifecycle

`Edit → Save → Validate → Run tests → Publish`. There are no Profile testing,
beta or stable channels, no promotion, and no draft-release stage.

1. The candidate is read from `apps/profile_lab/assets/profiles/<workerTypeId>.json`
   in the checkout Profile Lab runs from (nearest ancestor with `.git`). Profile
   Lab does not load starter templates or the Cloud Profile as a candidate; the
   current Cloud Profile is kept for comparison and for the expected revision.
2. Schema validation, required fields, unknown-field rejection and size limits
   run on every edit. Any edit to the payload changes its canonical digest and
   invalidates earlier test and validation results.
3. The local test ladder (no stage calls a model) covers schema validation,
   Event Mapping Replay against sanitized Codex and agy fixtures, CLI discovery,
   version, passive probe and live probe. Evidence is stored against the exact
   candidate digest in the shape defined by the
   [evidence contract](TOOL_PROFILE_EVIDENCE_CONTRACT.md).
4. Publication sends `expectedRevision`, `candidateDigest`, the candidate and
   recent evidence. Cloud revalidates all of it and writes the next current
   revision and its history row in one transaction. Restoring a previous
   snapshot publishes it as a new revision.

Evidence is an authenticated assertion about what Profile Lab observed; it is
not device attestation.

## Security rules

- Provider credentials stay with the provider CLI; they never enter a Profile,
  evidence or logs, which are secret-redacted.
- Provider processes run only through the supervised Engine, with bounded
  deadlines and process-tree cleanup.
- Cloud enforces permissions, evidence checks, revision concurrency and
  publication. The UI only requests operations.
- Sessions live in the macOS Keychain. Cloud origins are HTTPS outside local
  development builds, and contain no credentials or path.
- No Cloud private key or signing seed exists in the app. Cloud signs the
  Profile digest when it serves a Profile; Connect verifies that proof against
  build-time trust roots ([Connect CLI and services](CONNECT_CLI_AND_SERVICES.md)).

## Access

Cloud authorizes the operator from its own authenticated user record, never from
a client field. `GET /api/admin/profile-lab/access` returns the access read
model (`schemaVersion: 1`, `permissions`, `signer`); the Lab stays locked until
Cloud confirms administrative access. Authentication alone never grants it.

## Development access and unsigned execution

A local build targets only the local Cloud and shows a "LOCAL DEVELOPMENT BUILD"
banner; a production build targets only production. An explicitly opted-in
local Connect may run an unsigned local candidate: it needs
`SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY` in a non-release build and a loopback
Cloud origin. Connect validates the candidate's schema, catalog identity and
Engine/provider compatibility, pins its canonical bytes by digest in its
separate `development_profiles` directory, and never mixes it with published
Profiles or the last-known-good cache.

## Where behavior is specified

The Profile schema is [Tool Profile v1](TOOL_PROFILE_V1.md), the publication
and delivery contract is [Worker Profile V9](WORKER_PROFILE_V9.md), and the
operator steps are in the
[create](../runbooks/OPERATOR_RUNBOOK_CREATE_NEW_WORKER.md) and
[update](../runbooks/OPERATOR_RUNBOOK_UPDATE_PROFILE.md) runbooks.
