# Operator Runbook: Updating a Worker Profile

**Surface:** Syntila Profile Lab (`apps/profile_lab`)  
**Scope:** Edit and test a Worker candidate, publish one current Profile, and
recover safely through Cloud history.

## Prerequisites

Sign in with the Profile Lab operator account and the required Profile
administration permission. Provider credentials remain in the locally
installed provider CLI. Cloud must be reachable for publication; local editing
and testing do not change the current production Profile.

## Edit and test

Open **Workers**, select a logical Worker, and edit its JSON candidate. Save
locally with **Save** or `⌘S`, then run **Validate** and **Run tests**. The
candidate digest changes whenever the payload changes, so validation and test
evidence from an older digest cannot qualify a later publication.

The test ladder covers schema and Engine compatibility, executable discovery,
CLI version, authentication, deterministic execution, stdin transport, model
discovery, session behavior, error interpretation, and the authorized local
access check. Keep testing isolated from the current published Profile.

## Publish

Choose **Publish** for a saved candidate that has current, passing evidence.
Cloud authenticates the operator, revalidates the JSON and evidence, checks the
candidate digest and expected current revision, then atomically writes the new
current snapshot and history record. A concurrent edit produces a revision
conflict; refresh and compare before retrying.

V9 Profiles are not cryptographically signed and have no testing, beta, or
stable channels. The Profile payload is protected by canonical digest
validation, schema validation, Engine compatibility checks, authenticated
publication, and Workspace-side verification before activation. macOS app
signing and Workspace application-release signing are separate mechanisms.

## Restore a previous snapshot

Open **History**, compare the prior revision with the current Profile, and
choose **Restore**. Restoration creates a new current revision with the
specified reason; it does not expose the old snapshot as another active
channel. Workspace executions already in progress keep their selected Profile
digest until completion.

## Workspace behavior

Workspace periodically refreshes the current Profile and retains the current
verified snapshot plus one last-known-good snapshot. It can continue using an
authorized cached Profile during a temporary Cloud outage where policy permits.
Explicit revocation still blocks activation and cannot be bypassed by the
fallback snapshot. A new execution uses the newly activated revision; an
existing execution remains pinned to its original digest.

## Diagnostics and security

If publication fails, inspect the exact candidate digest, validation result,
test evidence freshness, expected revision, and Cloud authorization. Never
edit cached Profile files by hand and never place provider credentials in
Profile JSON, evidence, logs, or source control. The Profile Lab must not
automatically publish local edits.

See [WORKER_PROFILE_V9.md](../specifications/WORKER_PROFILE_V9.md) for the
canonical contract and RELEASE_TRUST_AND_ROTATION.md
for the separate Workspace application-release trust model.
