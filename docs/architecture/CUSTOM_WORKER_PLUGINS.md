# Custom Worker plugins: architecture, entitlement and trust

**Status:** Phase 0 proposal (docs and contracts only; nothing here is implemented)
**Decision record:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Companion contracts:** [Plugin protocol v1](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md), [Management IPC v1](../specifications/WORKER_PLUGIN_MANAGEMENT_IPC_V1.md)
**Plan, SDK and open decisions:** [Custom Worker plugins plan](../roadmaps/CUSTOM_WORKER_PLUGINS_PLAN.md)

Code references below were checked against the repository on 2026-11-03.
Where this document says a contract "changes", the file named is the one that
owns it today.

## 1. Architecture

```text
Cloud (account library metadata, enablement, entitlement, catalog row, scheduler)
  │  Workspace Runtime Protocol (additive fields; capability workspace.worker_plugins.v1)
  ▼
Workspace Service ── authenticated IPC ── syntila CLI (display only)
  │  Local Worker Protocol 4.2 (additive `executor`)
  ▼
CLI Worker Engine (generic; plugin host)
  │  Worker Plugin Protocol 1.x over stdio (NDJSON)
  ▼
plugin process (any language, user-imported, same OS user)
```

The Service never talks to a plugin. Cloud never sees a plugin binary, a
secret, or a local path. The CLI never executes anything.

### 1.1 Plugin identity

| Field | Meaning | Rules |
| --- | --- | --- |
| `pluginId` | Author-chosen stable name, e.g. `acme-reviewer` | `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`, ≤ 48 chars. Unique per account. Not globally unique. |
| `pluginRef` | Cloud-allocated opaque Worker Type ID, `plugin-` + 12 lowercase hex | Allocated once per `(owner, pluginId)`. Used as `worker_type_id` everywhere a Logical Worker ID is used. 19 chars, so it satisfies `WorkspaceProductWorkerTypeIdSchema` (≤ 128, kebab) and the Engine's `maxWorkerTypeIdLength = 64`. |
| `version` | Author semver `MAJOR.MINOR.PATCH` | Immutable once imported: re-importing the same version with a different digest is rejected (`plugin_version_conflict`). |
| `manifestDigest` | `sha256` of the canonical JSON manifest | **This is the pinned identity.** The manifest lists every platform artifact with its own `sha256` and size, so it transitively covers all executable bytes. Canonicalisation reuses the rule in `apps/cloud/src/canonical-json.ts`. |
| `artifactDigest` | `sha256` of the one artifact for this OS/arch | Must equal `manifest.artifacts[platform].sha256`. Reported in inventory so Cloud can freeze it. |
| `origin` | `{ kind, locator, importedAt, importedByUserId, signer? }` | `kind` ∈ `local_path`, `export_bundle` in v1. `locator` is a display string (basename or bundle name), never an absolute path. `url` and registry origins are deferred (open decision D8). |

Why an opaque `pluginRef` and not the author's `pluginId` as the catalog key:
`worker_catalog.worker_type_id` is a global primary key. Two accounts importing
`my-tool` would collide, and the ID would leak across accounts.

The official catalog's IDs (`chatgpt`, `gemini`, `copilot`, `grok`, and any
future catalog row) can never start with `plugin-`; Cloud rejects a Profile
publish or catalog insert for that prefix. Plugins cannot occupy an official ID.

### 1.2 Account-level private library

The library is a per-account list of plugin versions the account has imported
and registered. It is **metadata-only in Cloud** (recommended; see decision D1):

```text
account_worker_plugins            one row per (owner_user_id, plugin_id): plugin_ref, display name, created_at
account_worker_plugin_versions    one row per (plugin_ref, version): manifest_json, manifest_digest, size,
                                  origin_json, signature_json?, protocol_range, imported_at, status
```

Cloud stores no executable and no local path. It is private: reads and writes
are scoped to `owner_user_id`; no other account (including Space members or
Workspace borrowers) can list or fetch library rows. The library is where
`pluginRef` is allocated and where the paid-feature check for import runs.

D1 stays owned by Cloud route/service modules (a new `worker-plugins` route and
service module); Core stays provider-independent and imports nothing about
plugins beyond opaque IDs.

### 1.3 Per-Workspace enablement and readiness

Two separate facts, as with official Workers (ADR-021/Workspace architecture:
lifecycle is separate from activation):

- **Enablement** (user intent, per Workspace, Cloud-recorded): which library
  version is pinned on this Workspace and whether the user turned it on.
  `workspace_worker_plugin_enablements(workspace_id, plugin_ref, pinned_version,
  pinned_manifest_digest, consent_json, intent ∈ enabled|disabled, updated_at)`.
  `consent_json` records what was shown and accepted (§4.1).
- **Readiness** (machine fact, per Workspace, Service-reported): reuses the
  existing `workspace_worker_inventory` row and its `activation_state` /
  `readiness_state` enums. No new enum values are needed; plugin-specific causes
  use `readinessIssueCode`: `plugin_not_installed`, `plugin_digest_mismatch`,
  `plugin_protocol_unsupported`, `plugin_handshake_failed`,
  `plugin_not_ready` (plugin said so), `plugin_entitlement_lapsed`,
  `plugin_platform_unsupported`, `plugin_conformance_required`.

Local storage (Service-owned, under Application State, never Work Root):

```text
<state>/Plugins/<pluginRef>/<version>/<manifestDigest>/   immutable, read-only
    plugin.json                  verified manifest
    artifact/…                   the platform artifact, mode 0500 (Unix)
<state>/Plugins/<pluginRef>/data/    plugin-writable data dir (quota-bound)
<state>/Plugins/quarantine/…         imported but not yet validated
```

The directory name includes the digest so an update never overwrites a pinned
version, and rollback is "re-pin the previous directory".

Plugin Workers show up in the existing Workers list and `workers.list`
projection because enablement creates the normal inventory row. The Workers
list distinguishes them with the descriptor field `origin: "plugin"`; AX needs
no provider branches.

### 1.4 Execution snapshot bound to the digest

At admission Cloud freezes, in `worker_assignments.permission_snapshot_json`
under `executionSelection.executor`:

```json
{
  "schemaVersion": 1,
  "kind": "plugin",
  "pluginRef": "plugin-3fa91c04b2d7",
  "pluginId": "acme-reviewer",
  "version": "1.4.2",
  "manifestDigest": "<64 hex>",
  "artifactDigest": "<64 hex>",
  "pluginProtocol": "1.0",
  "isolation": { "tier": "best_effort", "readOnlyEnforced": false },
  "consentId": "…"
}
```

Rules:

1. Cloud copies `manifestDigest` and `artifactDigest` from the inventory row the
   Service reported **and** requires `manifestDigest` to equal the Workspace
   enablement pin. A mismatch is a scheduler rejection `plugin_digest_not_pinned`;
   nothing is dispatched.
2. The snapshot is immutable, like the existing `executionSelection` snapshot.
   Retries (scheduler retry consumes the snapshot) reuse the same digests; a
   plugin update after admission cannot change a queued or retrying assignment.
3. The Service passes `manifestDigest`/`artifactDigest` to the Engine in the 4.2
   `executor` object. The Engine re-hashes the artifact immediately before
   `spawn` and fails with `plugin_digest_mismatch` before any plugin code runs.
   The artifact is executed from the immutable, read-only store path, never from
   the imported location. Residual time-of-check/time-of-use risk exists for a
   same-user attacker who can replace files inside Application State; this is
   within the "same user" trust boundary (§4.5) and is documented, not solved.
4. History displays the frozen `pluginId`, `version` and display name. It never
   relabels from current library state (same rule as
   `execution-selection-snapshot.ts`).
5. Native-session-style continuity: the opaque session key Syntila already sends
   (`conversationWorkerSessionReference`) is passed to a plugin that declares
   resume support. The reference hashes `profileDefinitionId` today; for plugins
   the dispatcher substitutes `pluginRef` so an update does not orphan sessions.
   A plugin that cannot resume replies `session_not_found` and the existing
   reconstruction path (frozen canonical context) applies.

## 2. Cloud contracts: changed and preserved

Verified against `apps/cloud/src`, `apps/cloud/migrations-v8` and
`packages/workspace-runtime-protocol/src` on 2026-11-03.

### 2.1 Must change

| # | Contract (owner) | Change | Why it cannot be avoided |
| --- | --- | --- | --- |
| C1 | `worker_catalog` (`migrations-v8/0001`) | Add `origin TEXT NOT NULL DEFAULT 'official' CHECK (origin IN ('official','plugin'))` and `owner_user_id TEXT NULL REFERENCES users(id)`, with `CHECK ((origin='plugin') = (owner_user_id IS NOT NULL))`. One plugin row per `pluginRef`: `engine_family='cli'` (kept; the Engine family is unchanged), `release_stage='stable'`, `visibility_state='visible'`. | `worker_assignments.worker_type_id` has `REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT` and the scheduler `JOIN`s the catalog. A plugin needs a catalog row or the assignment INSERT fails. Alternative (drop the FK) needs a table rebuild of the hot assignment table and loses an integrity guarantee. |
| C2 | Every `worker_catalog` reader | Add `origin='official' OR owner_user_id = :caller`. Concretely: `router.ts` `GET /api/workers/catalog` (line ~469) and `GET /api/workspace-runtime/workers/catalog` (~496); `worker-profile-registry.ts` list query (~144, `LIMIT 256`) and `requireWorkerCatalogRow` (~224); `scheduler.ts` (~319 `JOIN worker_catalog`); `routes/profiles.ts` (~44); `routes/thread-policy.ts` (~545); `routes/reply-references.ts` (~119); `routes/work-lifecycle.ts` (~760, label only, snapshot-first so low risk). | Without the filter, one account's plugin name appears in every account's catalog and in Profile Lab's admin list. The runtime catalog for a Workspace returns official rows plus **that Workspace owner's** enabled plugin rows only. |
| C3 | `worker_profiles` publishing | `requireWorkerCatalogRow` must reject `origin='plugin'` rows. | Plugins have no Profile; Profile Lab must not be able to attach one. |
| C4 | `workspace_worker_inventory` | Add nullable `executor_kind` (`profile`\|`plugin`, default `profile`), `plugin_ref`, `plugin_version`, `plugin_manifest_digest`, `plugin_artifact_digest`, `plugin_isolation_json`. Existing `profile_definition_id`/`profile_release_version` stay `NULL` for plugins. | Inventory is the single source of readiness the scheduler reads. |
| C5 | `WorkspaceWorkerInventoryEntrySchema` (`workspace-runtime.ts` ~322, `.strict()`) | Add optional `executor` object (`kind`, `pluginId`, `version`, `manifestDigest`, `artifactDigest`, `pluginProtocol`, `isolation`). Service sends it **only after** Cloud announces `workspace.worker_plugins.v1` in `hello.ack` `cloudCapabilities` (same gating the Allowed Folders contract uses; `cloud_connection.dart` ~1711). | Strict schema rejects unknown keys; an older Cloud must never see the field. |
| C6 | Scheduler admission (`scheduler.ts` ~495-560) | The `engine_profile_unavailable` check requires a Profile definition and release. Add an `executor_kind='plugin'` branch: require `plugin_manifest_digest`, `engine_version` ≥ 1.4.0 (same pattern as `supportsExecutionCatalogPin`), a pin match, and the entitlement (§3). New rejection codes: `plugin_entitlement_required`, `plugin_digest_not_pinned`, `plugin_not_enabled`, `plugin_read_only_unenforceable`, `plugin_additional_folders_unsupported`. | Today a Worker without a Profile is rejected. |
| C7 | Dispatcher snapshot + target (`assignment-dispatcher.ts`, ~420-480; `execution-selection-snapshot.ts`) | Write `executionSelection.executor` (§1.4); `profileDefinitionId`/`profileReleaseVersion` target fields become optional and `engineVersion` stays required. Add the plugin entitlement predicate to the assignment `INSERT … SELECT … WHERE`, beside `executionSlotAdmissionSql`, so admission and the entitlement check are one atomic write. | Race: a plan could expire between the scheduler read and the INSERT. |
| C8 | Execution selection snapshot schema (`workspace-runtime.ts` ~457-506, strict) | Additive optional `executor`. | Same strict-schema reason as C5. |
| C9 | `account-plan.ts` | Add `"workers.custom_plugins"` to `PAID_FEATURES` and a label; add `paidPluginOwnerSql()` thin wrapper over `paidOwnerSql`. `GET /api/me/plan` then lists the feature automatically (`features: tier==='paid' ? PAID_FEATURES : []`). | The existing mechanism; see §3. |
| C10 | New routes | `GET/POST /api/me/worker-plugins[/…]` (library), `GET/PUT/DELETE /api/workspaces/:id/worker-plugins/:pluginRef` (enablement), `POST /api/workspace-runtime/worker-plugins/entitlement` (lease). Human-session routes use the Desktop human session (`syntila login`); runtime routes use the Workspace runtime credential. All in a new route module that owns its D1 access. | New surface. No compatibility aliases. |
| C11 | Local Worker Protocol (`packages/syntila_worker_protocol`) | 4.2: optional `executor` on `initialize.request`/`execute.request` and the identity block; `supportedLocalWorkerProtocolVersions` gains `'4.2'`; limits for plugin frames. 4.0 and 4.1 frames decode unchanged. | Version negotiation already picks the newest common version. |
| C12 | Hello/ack capabilities | Announce `workspace.worker_plugins.v1`. | Capability-gated additive rollout (Service and Cloud deploy independently). |

### 2.2 Preserved unchanged

| Contract | Why it holds |
| --- | --- |
| `worker_assignments` columns and the idempotent `INSERT … RETURNING` admission pattern, the active-status set, assignment state machine and terminal-outcome journal/ack reconciliation | Plugin assignments use the same table; only the snapshot JSON and one predicate are added. |
| `workspace_space_grants.allowed_worker_ids_json` and `thread_execution_policies.allowed_worker_type_ids_json` | Both are opaque ID allow-lists, so `workerId`/`pluginRef` work. A plugin Worker is subject to the same grant and Thread policy as any Worker. |
| `worker_scheduling` (Cloud scheduling toggle) and Workspace slot accounting | Plugin Workers consume the same Workspace-wide `parallel_slots`. |
| `workspace_worker_inventory` readiness and activation enums and their `CHECK`s | Plugin causes are issue codes, not new enum values (avoids a table rebuild). |
| Free-tier admission SQL (`executionSlotAdmissionSql`, personal Workspace allowance, Space member limit, attachment limits) | A plugin run is an ordinary execution for the requester's concurrency rule. |
| Thread mutation leases, fencing tokens, Space-wide lock, Space directory resolution, Allowed Folders | Unchanged. Plugin receives the resolved Space directory and nothing broader. |
| Context Engine, Conversation Router, canonical history, frozen context snapshot | Plugins receive the same canonical envelope the Engine builds for a provider CLI, or a bootstrap prompt when they cannot resume. |
| `workflow-workspace.ts` auto-enabling Cloud scheduling for ready, enabled Workers on the selected Workflow Workspace | Plugin Workers are enabled the same way. **Note:** this makes a ready plugin schedulable as soon as the Workspace is the Workflow Workspace, so the entitlement and pin checks in C6/C7 are mandatory, not an optimisation. |
| Per-installation lock, `service stop`, Disconnect Cloud, `workspace.nano` restart-applied config | Not touched (§5). |
| Profile schema, Profile publication, Profile Lab, official catalog sync (`WorkerCatalogCoordinator`) | Plugins neither read nor write them. |
| Realtime events, AX server-state caching | Inventory change events already carry plugin rows. AX renders by descriptor. |

### 2.3 Needs product confirmation, not assumed

- AX catalog UI reads `GET /api/workers/catalog` for "Add Worker" style
  surfaces. Plugin Workers should not appear there for adding (they are added
  by `plugins enable`); confirm with product. The CLI `workers add` for a
  `pluginRef` is rejected with `plugin_use_plugins_enable`.
- `AGENTS.md` and `ARCHITECTURE.md` describe Profiles as "signed". The V9
  contract (`RELEASE_TRUST_AND_ROTATION.md`) states V9 Profiles are *not*
  cryptographically signed. This proposal relies on the V9 statement and flags
  the doc drift rather than reconciling it here.

## 3. Entitlement design

### 3.1 Use the existing mechanism

ADR-022 already provides everything needed except offline persistence:

- one tier column (`account_plans`), `effectiveTier()` and its SQL twin
  `paidOwnerSql()` (kept in step by a test),
- named features in `PAID_FEATURES`, gated with `requirePaidFeature()` →
  HTTP 402 `{ code: "paid_plan_required" }`,
- precedent for downgrade: *pause, never delete, renewing restores, admitted
  work finishes* (`workspace.sharing`).

Add one feature: `workers.custom_plugins`. No new tier, no new table for plans.
The owner of the library and of the Workspace is the entitled principal; the
requester's plan is irrelevant for plugin gating (a borrower can only reach an
owner's Workspace while the owner is Plus anyway, because sharing is itself a
paid feature).

The one genuinely new piece is the **entitlement lease** (§3.4), needed because
the Service must make decisions while Cloud is unreachable.

### 3.2 Where Cloud checks (source of truth)

| Moment | Check | On failure |
| --- | --- | --- |
| **Library import / register** (`POST /api/me/worker-plugins`) | `requirePaidFeature(env, userId, "workers.custom_plugins")` | 402 `paid_plan_required` |
| **Enablement** (`PUT /api/workspaces/:id/worker-plugins/:ref`, intent `enabled`) | Same, for the Workspace owner; also checks the version exists in the owner's library | 402; disabling is always allowed |
| **Assignment eligibility** (scheduler) | Plugin branch rejects with `plugin_entitlement_required` unless `paidOwnerSql(ew.owner_user_id)` | Candidate skipped; other Workers still considered |
| **Assignment INSERT** | Same predicate inside the `WHERE`, atomic with the write | Nothing written; scheduler re-evaluates |
| **Workspace start-up / reconnect** | On `hello` Cloud evaluates the owner's entitlement, announces it in `hello.ack`, and issues a lease. If not entitled, Cloud marks plugin inventory rows `plugin_entitlement_lapsed` and the Service does not probe or spawn plugins | Official Workers unaffected |
| **Lease renewal** | Every connect and every ≤ 12 h while connected | See §3.4 |

Read paths stay free so a downgraded user can see, export and remove their
plugins: list library, list enablements, `export`, `disable`, `remove`, `validate`.

### 3.3 Local checks are a UX hint only

The Service and CLI may read the cached lease and `GET /api/me/plan` result to
say "Custom plugins require Syntila Plus" before a round-trip. They never
authorise anything on their own: a command that changes Cloud state is
re-checked by Cloud, and a Worker only receives work when Cloud assigns it.

### 3.4 Offline grace and the lease

A Cloud-signed, short-lived lease lets the Service keep a consistent local
answer without trusting editable files.

```json
{
  "v": 1,
  "kid": "ent-2026-01",
  "feature": "workers.custom_plugins",
  "ownerUserId": "…",
  "workspaceId": "…",
  "installationId": "…",
  "leaseId": "…",
  "issuedAt": "2026-11-03T10:00:00Z",
  "expiresAt": "2026-11-04T10:00:00Z",
  "planStatus": "active",
  "planPeriodEnd": null
}
```

- **Signing:** Ed25519 over canonical JSON. A new Cloud secret holds the private
  key; the public key set is compiled into the Service like the existing release
  trust roots (`release_trust_roots.dart`), with a `purpose: "entitlement"` and
  `kid` for rotation. Production fails closed when no entitlement key is
  configured; dev fixture keys are separate (same rule as release trust).
  This is the only new trust root.
- **TTL and grace:** `expiresAt = min(issuedAt + 24 h, planPeriodEnd)`. Offline
  grace is exactly the remaining lease time: no extra grace period, no
  "last known good forever". After expiry the Service treats plugins as
  `plugin_entitlement_lapsed` until it reaches Cloud again.
- **What an unreachable Cloud affects:** an offline Workspace receives no Cloud
  assignments, so the lease governs only *local* actions: probing/readiness,
  `test`, starting a new plugin process for an admitted assignment that arrived
  before the disconnect, and in-flight work (§3.5).
- **Tamper resistance:** the lease is signed and bound to
  `workspaceId`+`installationId`+`ownerUserId`; editing it invalidates the
  signature; copying it to another machine fails the binding. The Service stores
  a high-water mark of the latest Cloud time seen (from `issuedAt` and
  `hello.ack`). A wall clock earlier than that mark minus 5 min makes the lease
  invalid (`entitlement_clock_invalid`), which defeats rolling the clock back to
  extend a lease.
- **Local registry edits:** flipping `enabled: true` in the local plugin
  registry, or deleting the lease, changes nothing Cloud-visible. The inventory
  Cloud receives is rejected or filtered by the Cloud entitlement predicate, and
  Cloud never assigns work to a plugin Worker it considers unentitled.
- **What this does not stop, stated plainly:** a user who patches their own
  Service binary or runs their own executable by hand can run local code. That is
  not a Syntila feature path (no Workers list entry, no Cloud assignments, no
  Space integration), and no client-side control could prevent it. The gate that
  matters is Cloud scheduling.

### 3.5 Downgrade and expiry behaviour (decisions)

Trigger: effective tier becomes Free (status not entitled, or
`current_period_end` passes). No event is needed for date expiry: every Cloud
check evaluates it live, as ADR-022 does.

| Subject | Decision | Rationale |
| --- | --- | --- |
| **Running work** | **Finishes**, but capped. Cloud admits nothing new. The Service stops spawning any new plugin process (new assignments, resumes, probes, tests) as soon as it learns of the lapse or its lease expires. Already-spawned assignments run to completion or their own timeout, with a hard cap `PLUGIN_LAPSE_DRAIN_MAX_MS = 30 min` after the lapse, then the normal cancel path ends them with `plugin_entitlement_lapsed`. | Matches ADR-022 ("Work already admitted finishes") and avoids half-written Space files. The cap exists because, unlike a provider CLI, a plugin is user-supplied code that Syntila would otherwise let run for up to the 24 h protocol maximum without entitlement. |
| **Plugins** | Effective state = `intent AND entitled`. Intent (`enabled`) is **preserved**; the plugin shows `disabled (Plus required)`. Library rows, versions, Workspace enablements, local files and consent records are **never deleted**. Renewing restores them without re-consent, provided the pinned digest still matches. | Same pattern as paused Person Grants. |
| **Exports** | Remain possible, offline and lapsed, because export reads only local files and the user's own data. | Data portability; the user must never be locked out of their own artefacts. |
| **Remove / disable / validate / list** | Allowed. | Like cancelling invitations after a downgrade. |
| **Import / register / enable / test / update-pin** | 402 `paid_plan_required`. | These grow the paid footprint. |
| **Official Workers** | Unaffected. | Plugins are additive. |
| **Past-due** | Entitled, per `ENTITLED_STATUSES`. | Same grace as every other paid feature. |

### 3.6 Sequencing note

Billing-provider checkout is not implemented (ADR-022). Until it ships,
entitlement is the manual `account_plans` grant. The design needs no billing
integration; it inherits whatever makes `effectiveTier` return `paid`.

## 4. Trust and security model

### 4.1 Consent flow (CLI over IPC; no GUI)

`plugins register` and `plugins enable` are two-step in the Service:

1. `…prepare` returns a **consent document** (never an implicit yes). The CLI
   renders it and asks for typed confirmation. The Service issues a one-time
   `consentToken` bound to the digest and the document hash; `…commit` must
   present it. Non-interactive use requires the explicit
   `--accept <consent-hash>` flag, so scripts cannot silently consent.
2. The consent document shows:
   - `pluginId`, `version`, display name, author as *claimed* by the manifest
     (marked "unverified" unless a signature verifies);
   - **origin** (`local_path` basename / `export_bundle` name, import time);
   - **`manifestDigest`** and this host's **`artifactDigest`** (full 64-hex;
     truncated forms are display aids only);
   - **requested access**, from the manifest and diffed against what Syntila can
     actually grant:
     `filesystem.workRoot: none|read|write`,
     `network: none|declared-hosts` (**declaration only; not enforced** unless the
     isolation tier says so),
     `subprocess: yes|no`, `env: [names it wants]`, `needsLogins: [..]`
     (informational: the plugin runs under the user's own logins),
     `sessionResume`, `limits` it asks for;
   - **isolation tier** for this host and whether it is enforced or best-effort;
   - signature status and signer fingerprint, if any;
   - the sentence: "This program runs as you and can do anything you can do. The
     access list above is what it says it needs, not a restriction."
3. Cloud records `consent_json` (document hash, accepted-by user, time, digest) with the
   enablement. The consent document contains no secrets and no local paths.

**Pinned digest and re-consent on update:** an enablement is pinned to one
`manifestDigest`. A new version, or any change that alters the digest, is a new
library version; the old pin keeps running. Moving the pin requires `plugins enable
--version` which shows a **diff** (version, digest, access added/removed,
signer change) and a fresh consent. Any increase in requested access, a signer
change, or an origin kind change always requires fresh consent even for the
same `pluginId`. A digest the Service finds on disk that differs from the pin is
`plugin_digest_mismatch`: refused, never auto-updated.

### 4.2 Optional signing

- A plugin may ship a detached Ed25519 signature over `manifestDigest`
  (`plugin.sig`: `{ alg, keyId, signature }`) and the author's public key
  fingerprint in the manifest.
- Verification only proves the bytes match what the key holder signed. It does
  not prove the key holder is trustworthy. The consent document therefore shows
  the **fingerprint**, and the user can pin a signer (`plugins trust-signer`,
  stored locally and recorded in Cloud as a fingerprint only). A pinned signer
  lets updates signed by the same key skip the *signer-change* consent, but never
  the *access-increase* consent.
- Default policy: **signing optional** (decision D2). A Cloud-level organisation
  policy "require signed plugins" is a future per-Workspace setting; the data
  model reserves `consent_json.signer`.
- No Syntila-operated CA or marketplace. No signing key ever passes through
  Cloud; Cloud stores fingerprints and the verification result.

### 4.3 Enforced limits (Engine plugin host)

Defaults below are the Phase 0 proposal; they are enforced by the Engine, not
requested of the plugin. Per-Workspace overrides are limited to lowering them.

| Limit | Default | Enforcement |
| --- | --- | --- |
| Handshake timeout | 10 s | Kill + `plugin_handshake_failed` |
| Heartbeat | plugin must send a frame or `ping` reply every 15 s while executing; 3 misses | Kill + `plugin_unresponsive` |
| Execute wall time | the assignment `timeoutMs` (protocol max 24 h) | `cancel`, grace 5 s, then process-tree kill |
| Cancel grace / shutdown grace | 5 s / 3 s | Then kill |
| Max frame size | 1 MiB (matches `WorkerProtocolLimits.maxFrameBytes`) | Oversize frame = protocol violation: kill |
| Max prompt / output | 512 KiB / 768 KiB (existing limits) | Truncate-with-error, never silent |
| Progress rate | 20 frames/s, 4 KiB each, burst 100 | Excess dropped, counted, reported |
| Stderr capture | 64 KiB ring, redacted | Diagnostics only |
| Concurrency | `manifest.limits.maxConcurrent` clipped by `min(Workspace parallel_slots, 4)`; default 1 per plugin | Scheduler uses inventory `localConcurrencyLimit`; Engine enforces |
| Processes | 1 plugin process per active assignment; at most 64 descendants | Job Object / cgroup / pgid accounting |
| Memory | default 1 GiB per plugin | See §4.4 for what each OS can actually enforce |
| CPU time | 1 h per assignment | `RLIMIT_CPU` / Job Object where available; otherwise service-observed |
| Open files | 256 | `RLIMIT_NOFILE` / Windows handle quota where available |
| Plugin data dir | 512 MiB | Service-observed (not a filesystem quota); breach cancels the assignment |

### 4.4 Isolation actually available (and what is not claimed)

A **process boundary is not a sandbox.** Starting the plugin as a child gives
crash isolation, cancellation and a place to apply limits. It does not stop the
plugin from reading `~/.ssh`, the provider CLI credentials directories, or
anything else the user can read, or from using the network. The plugin runs under
the user's own logins by design (ADR-021 §2.2).

The Service reports one of three tiers per plugin per host, evidence-based:

| Tier | Meaning |
| --- | --- |
| `none` | Process boundary and limits only. |
| `best_effort` | An OS facility is applied, but Syntila has not proven that it denies writes/network on this host. |
| `enforced` | A host self-test run by the Service proved the property for that plugin launch (e.g. a write to a canary path outside the Space directory was denied). |

Per-platform facilities (all require device evidence before any claim):

| Platform | Available | Notes and gaps |
| --- | --- | --- |
| **Linux** | `prlimit`/`setrlimit` (CPU, NOFILE, AS), cgroups v2 via `systemd-run --user --scope -p MemoryMax=… -p TasksMax=…` when a user systemd session exists, Landlock (kernel ≥ 5.13) for filesystem restriction, `bwrap` (bubblewrap) when installed and unprivileged user namespaces are permitted, seccomp. | Not available in every container or hardened kernel (userns disabled, no user systemd bus, Landlock off). Headless containers often have none of cgroup delegation. Tier is computed, never assumed. |
| **macOS** | `setrlimit` (CPU, NOFILE; `RLIMIT_AS` is not reliably enforced), process-group kill, `sandbox-exec` with a generated SBPL profile. | `sandbox-exec` is deprecated by Apple though still functional; it can break under notarised/hardened runtime contexts. No cgroups: memory is Service-observed (RSS polling) and enforced by kill, not by the kernel. App Sandbox/entitlements apply to signed apps, not to an arbitrary child binary. TCC prompts attribute to the host process. Needs device evidence. |
| **Windows** | Job Object (kill-on-close, active-process limit, per-process and job memory limits, CPU rate control) — the Engine already uses nested Job Objects (ADR-021 §2.7); restricted token / low integrity level (`CreateRestrictedToken`, mandatory integrity label). | AppContainer would give real filesystem and network capability isolation but requires a package SID, ACL provisioning of every path the plugin needs, and breaks tools that expect the user profile; it is **not** proposed for v1. Without AppContainer, filesystem and network are not enforced on Windows (tier `none` or `best_effort`). |

Consequences built into the design:

- **Read-only is only scheduled where enforced.** Chat/Research/Plan/Test/Verify
  steps carry a read-only policy. A plugin receives that policy but Syntila
  cannot make it true unless the tier is `enforced` with
  `readOnlyEnforced: true`. Otherwise the scheduler rejects the plugin for those
  Steps with `plugin_read_only_unenforceable`; the plugin remains eligible for
  Work (writable) Steps, for which the user consented to write access.
- `additionalFolderIds` are not passed to plugins in v1
  (`plugin_additional_folders_unsupported`).
- The network declaration is documentation until an `enforced` network tier
  exists. The consent text says so.
- A **protocol conformance test proves protocol behaviour only**. It shows the
  plugin handshakes, frames messages correctly, cancels, and exits. It does not
  show the plugin is safe, honest about its declared access, or free of
  malicious behaviour, and a passing result must never be presented as a safety
  rating.

### 4.5 Logins, secrets and export

- The plugin runs as the same OS user as the Service, so it can use whatever the
  user is logged into. Syntila neither injects nor stores provider credentials
  (v8, ADR-021). Inherited environment is *built*, not copied: only the Engine's
  existing allow-list plus the manifest `env` names the user consented to, with
  `SYNTILA_*` internals removed. Plugin-specific secrets are the user's
  business, held by the plugin or the OS, and never in Syntila tables.
- **Secrets never pass through Cloud.** Cloud receives only manifest metadata,
  digests, origin display strings, consent hashes and readiness codes. Prompts,
  outputs and files follow the existing Work data path and are not changed by
  this feature. Plugin stderr/log text sent to diagnostics passes through the
  redaction rules (protocol §7); local absolute paths are removed as in
  `DIAGNOSTIC_EVENTS_V1`.
- **Exports exclude credentials.** An export bundle contains the verified
  manifest, the artifact(s), the signature if any, and origin/consent *metadata*.
  It excludes the plugin data dir, session state, logs, environment, the
  entitlement lease, runtime credentials and anything under provider credential
  directories. The Service refuses to export if the plugin data directory is
  inside the artifact tree.
- **Same-user trust boundary.** Anything that can run as the user can replace a
  plugin in Application State; the digest re-check closes accidental corruption
  and casual swaps, not a determined same-user attacker.

## 5. Unchanged invariants

| Invariant | How this feature respects it |
| --- | --- |
| Only the headless Service tree spawns processes | Service → Engine → plugin. The CLI only calls IPC; architecture tests extend the existing "CLI does not spawn" test to the new commands. |
| No Workspace GUI | CLI only. AX shows plugin Workers like any Worker. |
| Official Workers keep the shared Engine and Profiles; no Profile editor; Profile schema not public | Untouched. The manifest is a separate, public, small schema and is not a Profile. |
| No plaintext credentials; no managed provider credentials; no compatibility APIs | None stored or added; new fields are additive behind a capability, not aliases. |
| Cloud route/service modules own D1; Core provider-independent | New module owns its tables; Core sees opaque IDs only. |
| v8 D1 schema is a fresh-start baseline | New tables/columns ship as numbered additive migrations like 0094-0100, with the baseline-schema check (`pnpm cloud:schema-check`) updated; no data migration chain. |
| Per-installation lock | Unchanged. Plugin registry writes use the same lock-protected state writes as the Worker registry. |
| `service stop` | Drains/cancels plugin assignments exactly like Engine work, then terminates the Engine and thereby the plugins (kill-on-close); registration stays. |
| Disconnect Cloud | Service keeps running; plugin Workers go offline in Cloud; lease keeps existing expiry; no plugin is deleted. |
