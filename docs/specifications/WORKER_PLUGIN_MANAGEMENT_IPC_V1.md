# Worker plugin management: CLI and IPC contract v1 (draft)

**Status:** Phase 0 draft
**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Architecture:** [Custom Worker plugins](../architecture/CUSTOM_WORKER_PLUGINS.md)
**Plugin protocol:** [Worker Plugin Protocol v1](WORKER_PLUGIN_PROTOCOL_V1.md)

The `syntila plugins` commands are a display client of the existing
authenticated Workspace Manager IPC (`workspaceManagerProtocolName`,
`workspaceManagerProtocolVersion = 1`, one request/response envelope per
command, ≤ 1 MiB frames). They add a command group; they add no second channel.

## 1. Rules the CLI must satisfy

- The CLI **never executes a plugin, the Engine, or a provider CLI**, never reads
  a plugin's bytes, never talks to Cloud directly, and never computes a digest it
  then trusts. It sends a request, prints the Service's answer, and collects
  typed confirmation from the user.
- The Service performs every operation, including the conformance test
  (Service → Engine → plugin). The CLI shows structured results only.
- Architecture tests (the existing "CLI does not spawn or construct Cloud/Engine
  objects" tests) extend to cover `plugins.*` commands.
- IPC frames are ≤ 1 MiB, so package bytes never cross IPC. `import` sends a
  **path**; the Service (same OS user) opens it. `export` sends a destination
  path the Service writes. Both are canonicalised, symlinks resolved, and
  rejected if they overlap Application State, Work Root internals or provider
  credential directories (`plugin_path_not_allowed`).

## 2. IPC versioning

| Aspect | Rule |
| --- | --- |
| Envelope | Unchanged: `{type:"request", id, version:1, command, payload}` / `{type:"response", id, ok, result|error}`. |
| Version integer | **Stays `1`.** The server rejects any other value with `version_mismatch`, so bumping it would lock out every older CLI. A bump is reserved for envelope-breaking changes. |
| Feature discovery | The Service `hello` gains additive `capabilities: ["plugins.v1"]`. The CLI shows `service_outdated` (and the existing "replace the running service and restart after active work finishes" guidance) when absent. |
| Command payload versions | Every `plugins.*` result includes `schemaVersion: 1`. A new optional field is additive; removing or re-meaning a field increments `schemaVersion` and the old shape is served for one release. |
| Unknown command | `unsupported_command` (the existing dispatcher code for an unregistered command in `workspace_manager_service.dart`; `workspace_manager_worker_catalog.dart` already treats it as "older service"). |
| Events | Additive event types over `events.subscribe`: `plugin.testProgress`, `plugin.changed`. Old CLIs ignore unknown events. |

## 3. Commands

Lifecycle order a user follows: `import → validate → test → register → enable`.
All state transitions are Service-owned.

| CLI | IPC command | Entitlement (Cloud-checked) | Long-running | Summary |
| --- | --- | --- | --- | --- |
| `syntila plugins list` | `plugins.list` | free | no | Library, local installs, per-Workspace enablement, readiness, entitlement hint. |
| `syntila plugins show ID[@VER]` | `plugins.show` | free | no | Manifest, digests, origin, consent, last conformance, isolation tier. |
| `syntila plugins import PATH` | `plugins.import` | **Plus** | yes | Service copies the package into `quarantine/`, hashes it, parses the manifest. No code runs. |
| `syntila plugins validate ID[@VER]` | `plugins.validate` | free | no | Static: manifest schema, platform artifact present and hash matches, protocol range, path rules, access vs. capability consistency, signature if present. Never spawns. |
| `syntila plugins test ID[@VER] [--live]` | `plugins.test` | **Plus** | yes | Conformance suite in the Service → Engine host. Streams `plugin.testProgress`; the CLI only renders. |
| `syntila plugins register ID[@VER]` | `plugins.registerPrepare` + `plugins.registerCommit` | **Plus** | no | Consent, then publish metadata to the account library. Requires `validate` and `test` passed for this digest. |
| `syntila plugins enable ID[@VER]` | `plugins.enablePrepare` + `plugins.enableCommit` | **Plus** | no | Per-Workspace: consent diff if the pin moves, pin the digest, create the inventory row. |
| `syntila plugins disable ID` | `plugins.disable` | free | no | Per-Workspace: stop scheduling; running work drains. Intent recorded; files kept. |
| `syntila plugins export ID[@VER] --out PATH` | `plugins.export` | free | no | Write a credential-free bundle (architecture §4.5). Works offline and after downgrade. |
| `syntila plugins remove ID` | `plugins.remove` | free | no | Remove from the account library and local store. Refuses while enabled anywhere or in use. |
| `syntila plugins trust-signer ID FINGERPRINT` | `plugins.trustSigner` | **Plus** | no | Optional signer pin. |
| `syntila plugins entitlement` | `plugins.entitlement` | free | no | Shows lease state: entitled, expiry, offline remaining. A **hint**; Cloud decides. |

`--workspace` is not needed: the Service is the one installation's Workspace,
so `enable`/`disable` are per-Workspace by construction. A multi-Workspace
account repeats `enable` on each machine (P4 adds the shared distribution
path).

### 3.1 Two-step consent commands

`registerPrepare`/`enablePrepare` return a **consent document** (architecture
§4.1) and a one-time `consentToken` valid for 10 minutes and bound to the
document hash and `manifestDigest`. The CLI prints the document and asks for the
user to type the plugin ID. `…Commit` requires `{consentToken,
acceptedDocumentHash}`. Scripts pass `--accept <documentHash>`; there is no
`--yes`. A changed digest between prepare and commit invalidates the token
(`plugin_consent_stale`).

### 3.2 Result shapes (abridged)

```json
// plugins.list → result
{"schemaVersion":1,
 "entitlement":{"entitled":true,"source":"lease","expiresAt":"2026-11-04T10:00:00Z"},
 "plugins":[{
   "pluginRef":"plugin-3fa91c04b2d7","pluginId":"acme-reviewer",
   "versions":[{"version":"1.4.2","manifestDigest":"…","installed":true,
                "conformance":{"suiteVersion":"1.0.0","passed":true,"at":"…"}}],
   "workspace":{"pinnedVersion":"1.4.2","intent":"enabled",
                "effective":"enabled","readiness":"ready","issueCode":null,
                "isolation":{"tier":"best_effort","readOnlyEnforced":false}}}]}

// plugins.test → final result (progress arrives as events)
{"schemaVersion":1,"suiteVersion":"1.0.0","protocol":"1.0","passed":false,
 "cases":[{"id":"handshake.identity","status":"passed","ms":41},
          {"id":"cancel.within_grace","status":"failed",
           "detail":"No terminal frame 5,300 ms after cancel"}],
 "disclaimer":"Conformance shows protocol behavior only; it is not a safety assessment."}
```

`detail` strings are redacted by the Service before they reach the CLI. The
CLI prints `disclaimer` verbatim on every `test` result.

## 4. Error codes

All errors use the existing envelope `{ok:false, error:{code, message}}` where
`message` is safe to show. Stable codes:

| Code | Meaning | Typical command |
| --- | --- | --- |
| `service_outdated` | Service lacks `plugins.v1` | any |
| `unsupported_command` | Command not registered (existing code) | any |
| `version_mismatch` | IPC integer differs (existing) | any |
| `unauthorized` | Capability key rejected (existing) | any |
| `invalid_request` | Malformed payload (existing) | any |
| `paid_plan_required` | Cloud returned 402 for `workers.custom_plugins` (mirrors Cloud code) | import, test, register, enable, trust-signer |
| `entitlement_unverifiable` | Cloud unreachable and no valid lease | same |
| `entitlement_clock_invalid` | Clock earlier than the stored Cloud time mark | same |
| `cloud_unavailable` | Library/enablement call needs Cloud | register, enable, remove |
| `login_required` | No human session for an account action (`syntila login`) | register, enable, remove, library reads |
| `plugin_not_found` | Unknown ID/version | most |
| `plugin_path_not_allowed` | Path rejected by §1 | import, export |
| `plugin_package_invalid` | Unreadable/oversized/zip-slip/unsupported archive | import |
| `plugin_manifest_invalid` | Schema violation (details in `issues[]`) | import, validate |
| `plugin_platform_unsupported` | No artifact for this OS/arch | import, validate, enable |
| `plugin_digest_mismatch` | Bytes ≠ manifest, or ≠ pin | validate, test, enable, execution |
| `plugin_version_conflict` | Same version, different digest | import, register |
| `plugin_protocol_unsupported` | No common protocol version | test, enable |
| `plugin_conformance_required` | `register`/`enable` before a passing test for this digest | register, enable |
| `plugin_conformance_failed` | Suite failed (summary in result) | test |
| `plugin_signature_invalid` | Signature present and does not verify | validate, import |
| `plugin_consent_required` | Commit without a valid token | register, enable |
| `plugin_consent_stale` | Digest/document changed | register, enable |
| `plugin_already_enabled` / `plugin_not_enabled` | State errors | enable, disable |
| `plugin_in_use` | Active assignments reference it; removal is queued (reply `state:"removing"`, like Worker removal) | disable, remove |
| `plugin_removing` | Plugin is being removed; actions rejected | most |
| `plugin_quota_exceeded` | Library/install/data size limits | import |
| `plugin_use_plugins_enable` | `workers add` was given a `pluginRef` | `workers.configureWorker` |
| `command_failed` | Unexpected (existing; no details leaked) | any |

Errors never include absolute paths, plugin stderr, or any secret.

## 5. Cloud calls the Service makes on the CLI's behalf

The Service, not the CLI, calls Cloud; account-scoped calls use the stored
human session (`DesktopHumanSession`), runtime calls use the Workspace runtime
credential. A lost human session yields `login_required` and does not affect
running plugin Workers (same principle as `syntila logout` today).

| IPC command | Cloud call |
| --- | --- |
| `plugins.import` (entitlement pre-check) | `GET /api/me/plan` (hint) **and** the lease; authoritative check is at `register` |
| `plugins.registerCommit` | `POST /api/me/worker-plugins` (library create/version) |
| `plugins.enableCommit` / `disable` | `PUT/DELETE /api/workspaces/:id/worker-plugins/:pluginRef` |
| `plugins.remove` | `DELETE /api/me/worker-plugins/:pluginRef[/versions/:v]` |
| lease refresh | `POST /api/workspace-runtime/worker-plugins/entitlement` |

Payloads contain manifest metadata, digests, origin display strings and consent
hashes. They never contain executable bytes, local paths, environment values,
or credentials.
