# Custom Worker plugins: operations runbook

**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Design:** [Architecture](../architecture/CUSTOM_WORKER_PLUGINS.md)

Running plugins is a Syntila Plus feature. **Only Cloud enforces it, and only
when a plugin Worker is used**: the scheduler, thread policy and assignment
dispatcher admit plugin work only for an entitled Workspace owner. Managing
plugins (import, test, register, enable, disable, remove) works on every plan
and the Workspace performs no local plan check. This runbook covers the rollout
order, downgrade handling and diagnosis.

## 1. Provisioning

Nothing plugin-specific. There is no entitlement signing key or Workspace trust
define; Plus grants in `account_plans` are all that is needed.

## 2. Rollout order

The protocol is capability-gated so Cloud and Workspaces can deploy
independently, but this order avoids a window where plugin Workers are rejected.

1. Apply migrations `0101_worker_plugins.sql` and
   `0102_worker_catalog_plugin_id_check.sql` (D1 rejects the 67-byte GLOB in
   0101's trigger; 0102 replaces it). Both are additive.
2. Deploy Cloud. It announces `workspace.worker_plugins.v1` in `hello.ack`.
3. Release a Workspace with Engine **1.4.0**. An older
   Workspace never reports a plugin Worker, and Cloud refuses a plugin Worker on
   an Engine older than 1.4.0 (`worker_engine_update_required`).
4. Grant Plus (`account_plans`; billing is still manual per ADR-022).

Rollback: undeploy nothing in Workspace; remove Plus grants to stop scheduling
every plugin at once. Existing plugins are kept, never deleted.

## 3. What a downgrade or expiry does

Evaluated live from the Workspace **owner's** plan; no event is needed.

| Thing | Behaviour |
| --- | --- |
| New assignments | Not scheduled (`plugin_entitlement_required`); the assignment INSERT re-checks atomically. |
| Work already running | Finishes normally; only new assignments are refused. |
| The plugin, its files, library entry, pin, consent | Kept and still `enabled` locally. Renewal resumes scheduling without re-consent. |
| Plugin management | Every `plugins` command keeps working on any plan. |

## 4. Diagnosing

| Symptom | Likely cause |
| --- | --- |
| Enabled plugin Worker never scheduled, rejection `plugin_entitlement_required` | Owner has no active Plus row (or `current_period_end` passed). |
| Plugin Worker never scheduled, rejection `plugin_digest_not_pinned` | The Workspace reports a different digest than the pin, usually after an update; run `plugins enable <id> --version <v>` again. |
| `plugin_read_only_unenforceable` | The step is read-only (Chat, Research, Plan, Test, Verify). No isolation tier proves read-only yet, so plugins run Work only. |
| `plugin_digest_mismatch` at launch | Files in the store changed after consent. Re-import; the store is read-only for a reason. |

Local state lives under `<Application Support>/Plugins/`: `store/` (immutable,
digest-addressed), `data/<pluginId>/` (plugin-writable), `registry.json`,
`engine-state/`. An `entitlement.json` left by an older build is unused and may
be deleted.

## 5. Not yet covered (known gaps)

- **Filesystem/network isolation.** Production isolation remains `none` and
  read-only Steps remain ineligible. Resource limits are implemented; see the
  [acceptance record](../acceptance/PLUGIN_RESOURCE_LIMITS.md) for native versus
  sampled limits and hosted Linux/Windows evidence.
- **Installed release acceptance.** Hosted tests do not establish signed release,
  per-user service lifecycle or deployed Cloud end-to-end behavior.
- **Distribution.** Local signer recognition and revocation are implemented;
  URL/registry import and package-registry publication remain unavailable.



## Resource-limit failures

The plugin Engine applies hard POSIX CPU/open-file limits and Windows job limits
before running plugin code. Memory/process counts on POSIX and plugin data size
are observed; inspection failure also stops work. `plugin_resource_limit` appears
in Engine diagnostics through the existing non-retryable provider-failure issue.
A hard native limit may instead appear as a process exit/provider failure.

Check plugin diagnostics and the [resource-limit acceptance record](../acceptance/PLUGIN_RESOURCE_LIMITS.md)
for exact defaults and platform gaps. Export and removal remain management
operations even when an oversized data directory prevents execution. Do not
raise limits or delete user work automatically. Manifest memory requests do not
raise the fixed host ceiling. These limits do not enforce filesystem/network
isolation or make a plugin safe.
