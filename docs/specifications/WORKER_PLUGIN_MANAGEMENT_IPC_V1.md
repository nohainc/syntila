# Worker plugin management: CLI and IPC contract v1

**Status:** Implemented; platform and deployment acceptance remain gated
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
All state transitions are Service-owned. Every command works on any plan; Syntila
Plus is enforced only by Cloud when it schedules plugin work.

| CLI | IPC command | Long-running | Summary |
| --- | --- | --- | --- |
| `syntila plugins list` | `plugins.list` | no | Library, local installs, per-Workspace enablement, readiness. |
| `syntila plugins show ID [--version V]` | `plugins.show` | no | Manifest, digests, origin, consent, last conformance, isolation tier. |
| `syntila plugins import PATH` | `plugins.import` | yes | Service copies the package into `quarantine/`, hashes it, parses the manifest. No code runs. |
| `syntila plugins validate ID [--version V]` | `plugins.validate` | no | Static: manifest schema, platform artifact present and hash matches, protocol range, path rules, access vs. capability consistency, signature if present. Never spawns. |
| `syntila plugins test ID [--version V]` | `plugins.test` | yes | Conformance suite in the Service → Engine host. Streams `plugin.testProgress`; the CLI only renders. |
| `syntila plugins register ID [--version V] [--accept HASH]` | `plugins.register` | no | Consent, then publish metadata to the account library. Requires `validate` and `test` passed for this digest. |
| `syntila plugins enable ID [--version V] [--accept HASH] [--shareable]` | `plugins.enable` | no | Per-Workspace: consent diff if the pin moves, pin the digest, create the inventory row. |
| `syntila plugins disable ID` | `plugins.disable` | no | Per-Workspace: stop scheduling; running work drains. Intent recorded; files kept. |
| `syntila plugins export ID FILE [--version V]` | `plugins.export` | no | Write a credential-free bundle (architecture §4.5). Works offline on any plan. |
| `syntila plugins remove ID` | `plugins.remove` | no | Remove from the account library and local store. Refuses while enabled anywhere or in use. |
| `syntila plugins signers` | `plugins.signers` | no | List installation-local recognized key fingerprints. |
| `syntila plugins trust-signer ID [--version V] [--accept HASH]` | `plugins.trustSigner` | no | Re-verify the installed signature, show a fingerprint consent document, then save local key recognition. |
| `syntila plugins untrust-signer FINGERPRINT` | `plugins.untrustSigner` | no | Forget local key recognition, including offline or after lapse. Does not disable existing plugins. |

`--workspace` is not needed: the Service is the one installation's Workspace,
so `enable`/`disable` are per-Workspace by construction. A multi-Workspace
account repeats `enable` on each machine (P4 adds the shared distribution
path).

### 3.1 Consent by hash (as built)

`plugins.register` and `plugins.enable` are one IPC command each. Called without
`acceptHash` (or with a hash that does not match), the result carries
`{consentRequired: true, document, documentHash}` and **nothing is changed**; the
CLI prints the document and exits **3**. Called with the matching
`acceptHash`, the action happens. `documentHash` is the SHA-256 of the canonical
consent document, which includes the manifest and artifact digests, the access
request, origin and signature status, so a changed package can never reuse an
earlier acceptance. There is no token, no expiry and no server-side consent
state. Scripts pass `--accept <hash>`; there is no `--yes`.

### 3.2 Signer recognition

`plugins.trustSigner` accepts `{pluginId, version?, acceptHash?}` and follows the
same consent-by-hash response convention. Its document binds the installed
manifest digest, plugin identity/version, verified public-key fingerprint and
installation-local scope. It re-verifies package bytes and `plugin.sig`; registry
claims alone cannot establish a signer. Unsigned packages return
`plugin_signature_required`.

`plugins.signers` returns `{schemaVersion:1, scope:"installation", signers:[
{fingerprint, acceptedAt}], statement}`. `plugins.untrustSigner` accepts
`{fingerprint}` (64 lowercase hex) and returns `{schemaVersion:1, fingerprint,
removed, scope:"installation"}`. Forgetting an absent fingerprint is idempotent.

Recognition is an informational pin, not execution authorization. It never skips
registration, conformance, entitlement, update/access consent or digest checks.
Pins are stored in `Plugins/trusted-signers.json`, serialized and atomically
written by the Service, and excluded from export bundles. They do not propagate
to other installations or become account-level trust policy in Cloud. Existing
Cloud library metadata still records the verified package's signer fingerprint.
Corrupt local trust state is preserved and returns `plugin_signer_trust_invalid`
rather than being overwritten. The local store is bounded to 1 MiB and 1024
fingerprints; adding beyond that count returns `plugin_quota_exceeded`.

`plugins.show.selected.signerTrustedLocally` and the consent document's
`signature.trustedLocally` expose recognition. The manifest's author name remains
unverified (`authorVerified:false`); `signatureVerified` separately reports a
valid signature. A change in recognition invalidates an outstanding signed
plugin consent hash, but forgetting recognition does not revoke an already
accepted execution pin. Use `plugins.disable` to stop scheduling.

The IPC envelope remains v1 with additive commands; older Services return
`unsupported_command` for signer management.

### 3.3 Result shapes (abridged)

```json
// plugins.list → result
{"schemaVersion":1,
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
| `plugin_signature_required` | No verified package signature available | trust-signer |
| `plugin_signer_trust_invalid` | Local signer store is unreadable/corrupt; preserve it for recovery | signer reads/mutations and signed consent |
| `plugin_signature_invalid` | Signature present and does not verify | validate, import |
| `plugin_not_enabled` | Disable of a plugin that is not enabled | disable |
| `plugin_quota_exceeded` | Cloud library limit (20 plugins, 50 versions each) | register |
| `plugin_in_use` | Still enabled, or running/queued work references it | remove |
| `plugin_quota_exceeded` | Library/install/data size limits | import |
| `plugin_use_plugins_enable` | `workers add` was given a `pluginRef` | `workers.configureWorker` |
| `plugin_use_plugins_remove` | `workers remove` targeted a plugin Worker | `workers.removeWorker` |
| `command_failed` | Unexpected (existing; no details leaked) | any |

Errors never include absolute paths, plugin stderr, or any secret.

## 5. Cloud calls the Service makes on the CLI's behalf

The Service, not the CLI, calls Cloud; account-scoped calls use the stored
human session (`DesktopHumanSession`). A lost human session yields `login_required` and does not affect
running plugin Workers (same principle as `syntila logout` today).

| IPC command | Cloud call |
| --- | --- |
| `plugins.registerCommit` | `POST /api/me/worker-plugins` (library create/version) |
| `plugins.enableCommit` / `disable` | `PUT/DELETE /api/workspaces/:id/worker-plugins/:pluginRef` |
| `plugins.remove` | `DELETE /api/me/worker-plugins/:pluginRef[/versions/:v]` |

Payloads contain manifest metadata, digests, origin display strings and consent
hashes. They never contain executable bytes, local paths, environment values,
or credentials.
