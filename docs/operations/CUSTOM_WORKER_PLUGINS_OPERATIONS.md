# Custom Worker plugins: operations runbook

**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Design:** [Architecture](../architecture/CUSTOM_WORKER_PLUGINS.md)

Plugins are a Syntila Plus feature. Cloud decides what runs; the Workspace
checks again before it starts a process. This runbook covers what an operator
must provision, the rollout order, downgrade handling and diagnosis.

## 1. Provisioning (once per environment)

Plugins need a Cloud signing key for **entitlement leases**. Without it the
lease route answers `503 Entitlement signing is not configured`, and no plugin
can be imported, tested, registered or enabled. Official Workers are unaffected.

1. Generate a key pair on a trusted machine:

   ```sh
   node scripts/generate-entitlement-key.mjs ent-2026-11
   ```

   The private key is printed once. Do not commit it or paste it into a ticket.

2. Store the Cloud secrets (they are deliberately **not** in
   `secrets.required`, so deployments without plugins keep working):

   ```sh
   wrangler secret put SYNTILA_ENTITLEMENT_KEY_ID
   wrangler secret put SYNTILA_ENTITLEMENT_SIGNING_KEY
   ```

3. Give the public half to Workspace builds. It is a build define, separate from
   the release-signing keys, and fails closed (`{}` trusts nothing):

   ```sh
   export SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON='{"entitlement":{"ent-2026-11":"<base64 public key>"}}'
   ```

   `scripts/internal/build-workspace-service.sh`,
   `scripts/build-workspace-macos.sh` and
   `scripts/internal/run-workspace-development.sh` pass it to `dart compile`.
   Release CI should set it as a repository variable next to
   `SYNTILA_RELEASE_TRUST_KEYS_JSON`.

**Rotation.** Generate a new key id. Ship a Workspace build that trusts **both**
ids. Switch the two Cloud secrets. Drop the old id one release later. Leases
live at most 24 hours, so a rotation never strands a Workspace for longer than
that.

## 2. Rollout order

The protocol is capability-gated so Cloud and Workspaces can deploy
independently, but this order avoids a window where plugin Workers are rejected.

1. Apply migration `0101_worker_plugins.sql` (additive; no data change).
2. Deploy Cloud. It announces `workspace.worker_plugins.v1` in `hello.ack`.
3. Set the two Cloud secrets (§1).
4. Release a Workspace with Engine **1.4.0** and the trust define. An older
   Workspace never reports a plugin Worker, and Cloud refuses a plugin Worker on
   an Engine older than 1.4.0 (`worker_engine_update_required`).
5. Grant Plus (`account_plans`; billing is still manual per ADR-022).

Rollback: undeploy nothing in Workspace; remove Plus grants or the Cloud signing
key to pause every plugin at once. Existing plugins are paused, never deleted.

## 3. What a downgrade or expiry does

Evaluated live from the Workspace **owner's** plan; no event is needed.

| Thing | Behaviour |
| --- | --- |
| New assignments | Not scheduled (`plugin_entitlement_required`); the assignment INSERT re-checks atomically. |
| New plugin processes, probes, tests | Stop at once once the 24-hour lease is gone; offline grace is exactly the remaining lease time. |
| Work already running | Finishes, capped at **30 minutes** after the lapse is noticed (`PluginLapseEnforcer`), then cancelled. |
| The plugin, its files, library entry, pin, consent | Kept. Intent stays `enabled`; the plugin shows as paused. Renewal restores it without re-consent. |
| Free operations | `list`, `show`, `validate`, `export`, `disable`, `remove`. |
| Paid operations | `import`, `test`, `register`, `enable`. |

## 4. Diagnosing

| Symptom | Likely cause |
| --- | --- |
| `syntila plugins import` → `paid_plan_required` | Owner has no active Plus row (or `current_period_end` passed). |
| `entitlement_unverifiable` | Offline with no valid lease; connect to Cloud. |
| `entitlement_clock_invalid` | The local clock is earlier than the newest Cloud time seen; fix the clock. |
| Lease route `503` | Cloud signing secrets missing (§1). |
| Plugin Worker never scheduled, rejection `plugin_digest_not_pinned` | The Workspace reports a different digest than the pin, usually after an update; run `plugins enable <id> --version <v>` again. |
| `plugin_read_only_unenforceable` | The step is read-only (Chat, Research, Plan, Test, Verify). No isolation tier proves read-only yet, so plugins run Work only. |
| `plugin_digest_mismatch` at launch | Files in the store changed after consent. Re-import; the store is read-only for a reason. |
| Worker listed but `worker_runtime_unavailable` / `plugin_entitlement_lapsed` | Paused by a lapse; see §3. |

Local state lives under `<Application Support>/Plugins/`: `store/` (immutable,
digest-addressed), `data/<pluginId>/` (plugin-writable), `registry.json`,
`entitlement.json`, `engine-state/`. Never copy `entitlement.json` between
machines; it is bound to one Workspace and installation.

## 5. Not yet covered (known gaps)

- **OS isolation and resource limits.** Memory, CPU, file-handle and process
  limits are not enforced and every plugin reports isolation tier `none`.
  Time, frame-size and progress-rate limits are enforced. Tiers need device
  evidence per platform (ADR-027 §4) before any claim is made.
- **Windows and Linux device evidence.** Unit and integration tests ran on
  macOS. Process-tree cleanup and the per-user logon task need target-device
  acceptance before a Windows or Linux release.
- **`plugins trust-signer`** (signer pinning) and URL/registry import are not
  implemented; signatures are verified and shown at consent.
