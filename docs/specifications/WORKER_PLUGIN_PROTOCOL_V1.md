# Worker Plugin Protocol v1 (draft)

**Contract ID:** `workerPluginProtocol: 1.0`
**Status:** Phase 0 draft. Normative for plugin authors once ADR-027 is accepted.
**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Successor for new Workers (proposed):** the [Syntila MCP Worker profile](MCP_WORKER_PROFILE_V1.md) ([ADR-028](../decisions/ADR-028-mcp-integration.md))
**Architecture and trust:** [Custom Worker plugins](../architecture/CUSTOM_WORKER_PLUGINS.md)
**Host:** the generic CLI Worker Engine's plugin host (never the `syntila` CLI, never Cloud)

This is the contract between the Engine's plugin host and one plugin process.
It is separate from the Local Worker Protocol (Workspace ↔ Engine) and from
provider CLI protocols. It is not a Tool Profile and exposes no Profile schema.

Keywords MUST, SHOULD and MAY follow RFC 2119.

> **Freeze note (proposed, non-binding).** If ADR-028 is accepted, this protocol stays at
> 1.2 (no further MINOR versions are planned) and new custom Workers are steered to the MCP
> Worker profile. This note starts no deprecation clock: no MAJOR is deprecated, the 12-month
> notice in section 11 has not begun, and nothing about NDJSON plugins changes in the product.
> `syntila plugins migrate-check <id>` tells an author whether a plugin could move to MCP.


## 1. Transport and framing

- The host starts the plugin as a child process: executable and fixed argument
  vector from the verified manifest, **no shell**, working directory = the
  Space directory the Service resolved for the assignment (or the plugin data
  directory for `probe`/`hello`), environment built by the Engine (§8).
- **stdin** carries host → plugin frames. **stdout** carries plugin → host
  frames and nothing else. **stderr** is free-form logging; it is captured,
  redacted and size-bounded, never parsed as protocol.
- **Framing is NDJSON:** one UTF-8 JSON object per line terminated by `\n`.
  The host accepts `\r\n`. No BOM. No pretty-printing across lines. In protocol 1.0 and 1.1 a frame
  MUST be ≤ **1 MiB (1,048,576 bytes)** including the newline. Protocol 1.2
  removes this size limit for host-to-plugin `execute` frames; other frames
  retain it. This equals
  `WorkerProtocolLimits.maxFrameBytes`; an oversize or non-JSON line on stdout is
  a protocol violation and the host terminates the plugin
  (`plugin_protocol_violation`).
- Every frame is an object with a string `type`. Unknown **fields** MUST be
  ignored. An unknown **type** from the host MUST be answered with an `error`
  frame, code `unsupported_frame`, and the plugin continues. An unknown type from
  the plugin is a violation before the handshake completes and ignored (counted)
  after it.
- One `execute` at a time per process. Parallelism is multiple processes; the
  host owns that (`limits.maxConcurrent`). The `id` field still correlates
  every frame to its request so a later minor version can multiplex.
- IDs are strings of `[A-Za-z0-9._:-]`, ≤ 128 chars. The host chooses them.
- Timestamps are RFC 3339 UTC. Durations are integer milliseconds.

## 2. Lifecycle

```text
host                                   plugin
 │── hello ───────────────────────────▶│   (≤ 10 s)
 │◀────────────────────── hello.result ─│
 │── probe(passive|live) ─────────────▶│   readiness; optional repeat
 │◀───────────────────── probe.result ──│
 │── execute ─────────────────────────▶│
 │◀── progress / activity (0..n) ───────│
 │── ping (every 15 s) ───────────────▶│
 │◀─────────────────────────── pong ────│
 │── cancel (optional) ───────────────▶│
 │◀──────────── result | error ─────────│   exactly one terminal frame per execute
 │── shutdown ────────────────────────▶│
 │◀──────────────── process exits 0 ────│   (≤ 3 s, else killed)
```

The host starts a plugin process per assignment (or reuses a ready process
between assignments of the same pinned digest while idle; the host may restart
at any time). A plugin MUST NOT assume it will receive a second `execute`.

## 3. Version handshake

Host first frame:

```json
{"type":"hello","id":"h1","protocol":{"supported":["1.0"],"preferred":"1.0"},
 "host":{"name":"syntila-engine","version":"1.4.0"},
 "dataDir":"/abs/path/to/plugin-data",
 "limits":{"maxFrameBytes":1048576,"maxPromptBytes":524288,"maxOutputBytes":786432}}
```

Plugin reply:

```json
{"type":"hello.result","id":"h1","protocol":"1.0",
 "plugin":{"id":"acme-reviewer","version":"1.4.2","name":"Acme Reviewer"},
 "capabilities":{
   "progress":true,"activity":false,
   "sessionResume":false,
   "models":[{"id":"fast","name":"Fast"}],
   "readOnly":"honors",
   "cancel":"cooperative"}}
```

Rules:

1. `protocol` in the reply MUST be one of `hello.protocol.supported`. If the
   plugin supports none, it sends `error` with code `unsupported_protocol`
   listing `supports: [...]` and exits. The host then reports
   `plugin_protocol_unsupported`.
2. **Identity check.** `plugin.id` and `plugin.version` MUST equal the manifest.
   The plugin cannot attest its own digest; the host has already hashed the
   artifact it launched (architecture §1.4). A mismatch is
   `plugin_identity_mismatch`.
3. `capabilities` MUST be a subset of what the manifest declares. A capability
   the manifest does not declare is ignored and reported by `validate`.
4. `models` is a static list, ≤ 32 entries. A plugin with no list is "Auto" only.
   There is no model discovery in v1.
5. `readOnly`: `"honors"` (the plugin promises not to write when asked) or
   `"never"`. Syntila additionally requires an enforced isolation tier before it
   schedules read-only Steps to the plugin (architecture §4.4).

## 4. Readiness

```json
{"type":"probe","id":"p1","mode":"passive"}
{"type":"probe.result","id":"p1","state":"ready",
 "checks":[{"code":"config","ok":true,"message":"endpoint reachable"}]}
```

- `mode`: `passive` (no cost, no side effects, ≤ 30 s, same bound as
  `maxProbeTimeoutMs`) or `live` (may consume the plugin's own quota; used by
  `plugins test` and `workers test`).
- `state` maps one-to-one onto the existing inventory enum:

  | `state` | Inventory `readinessState` |
  | --- | --- |
  | `ready` | `ready` |
  | `setup_required` | `setup_required` |
  | `sign_in_required` | `sign_in_required` |
  | `unavailable` | `worker_runtime_unavailable` |
  | `failed` (live only) | `test_failed` |

- `issueCode` (optional, `^[a-z][a-z0-9_]{0,63}$`, prefixed `plugin_` by the host)
  and ≤ 32 `checks` with `message` ≤ 1,024 chars (`maxCheckMessageLength`).
  Check messages are redacted and shown in `workers` output.
- A plugin that cannot answer `probe` within the timeout is
  `worker_runtime_unavailable` with `plugin_handshake_failed`/`plugin_unresponsive`.

## 5. Work request, progress, result, error

```json
{"type":"execute","id":"e1","deadlineMs":1800000,
 "prompt":"…canonical context + the request…",
 "workingDirectory":"/abs/Space/dir",
 "access":"read_write",
 "model":"fast","effort":null,
 "session":{"key":"worker-session-9c1…","mode":"new"},
 "attachments":[]}
```

- In protocol 1.0 and 1.1, `prompt` ≤ 512 KiB; protocol 1.2 has no plugin-protocol prompt limit. It is the same assembled prompt the Engine would send a
  provider CLI (bootstrap, delta, or stateless as the Conversation Router
  decided). Plugins SHOULD treat it as opaque text.
- `access`: `read_only` or `read_write`. Syntila **sends** the policy; whether it
  is **enforced** depends on the isolation tier (architecture §4.4).
  `workingDirectory` is the only directory the plugin is *authorised* to use
  besides `dataDir`. Additional folders are not passed in v1.
- `attachments`: reserved, always empty in 1.0. Files are read from the working
  directory.
- `session.mode`: `new` or `resume`. Present only when `capabilities.sessionResume`
  is tested (§9). Otherwise omitted.

Non-terminal frames (plugin → host):

```json
{"type":"progress","id":"e1","message":"Reviewing 12 files","percent":40}
{"type":"activity","id":"e1","seq":3,"activity":"tool.started","title":"git diff",
 "details":{"files":12}}
```

- `progress.message` ≤ 2,048 chars; `percent` optional integer 0-100.
- `activity` uses the existing activity vocabulary (`execution.started`,
  `message.updated`, `tool.started`, `tool.completed`, `tool.failed`,
  `model.status`, `execution.completed|failed|cancelled`), ≤ 16 KiB of details,
  depth ≤ 4, 32 entries (same bounds as `WorkerProtocolLimits`). Optional;
  progress alone is sufficient.
- Rate limit: ≤ 20 non-terminal frames/s sustained, burst 100. Excess frames are
  dropped and counted; they never terminate the plugin by themselves.

Terminal frames, **exactly one per `execute`**:

```json
{"type":"result","id":"e1","output":"…final text…","artifacts":[
   {"path":"reports/review.md","mediaType":"text/markdown"}],
 "session":{"state":"created"},
 "usage":{"inputTokens":1200,"outputTokens":340}}
{"type":"error","id":"e1","code":"sign_in_required",
 "message":"Run the vendor login first","retryable":false}
```

- `output` ≤ 768 KiB. Larger output is an error `output_too_large`, never
  silently truncated.
- `artifacts[].path` is relative to `workingDirectory`, ≤ 64 entries, and MUST
  resolve inside it. The host rejects absolute paths, `..` segments and symlinks
  that escape (`plugin_artifact_path_invalid`).
- `usage` is informational and optional.
- `code` values: `invalid_request`, `cancelled`, `timeout`, `not_ready`,
  `sign_in_required`, `unsupported_policy`, `session_not_found`,
  `rate_limited`, `output_too_large`, `unsupported_frame`,
  `unsupported_protocol`, `internal`. Codes outside this set are mapped to
  `internal` with the original string kept in diagnostics.
- `retryable` is advice; the scheduler's retry rules decide.
- `session_not_found` triggers the existing reconstruction path; it is not a
  failure.

## 6. Cancel, shutdown, heartbeats

- `{"type":"cancel","id":"e1","reason":"user"}` — the plugin MUST stop work and
  send a terminal `error` with `code:"cancelled"` (or a `result` if it finished
  first) within **5 s**. After the grace the host kills the process tree.
  Cancel is idempotent. Cancel arriving after the terminal frame is ignored.
- `{"type":"shutdown"}` — finish cleanup and exit with status 0 within **3 s**.
  `service stop` and `disable` use the same path before the Engine's kill-on-close.
- **Heartbeats:** while an `execute` is outstanding the host sends
  `{"type":"ping","nonce":"…"}` every **15 s**; the plugin replies
  `{"type":"pong","nonce":"…"}`. *Any* plugin frame counts as liveness. Three
  consecutive 15 s windows (45 s) with no frame ends the plugin
  (`plugin_unresponsive`). Plugins doing long blocking work MUST emit `progress`
  or answer pings from a separate thread. A plugin MAY send `ping`; the host
  answers `pong`.
- Plugin exit without a terminal frame is `plugin_crashed` with exit code and a
  redacted stderr tail; the assignment fails normally (retry per scheduler).
- stdin EOF means the host is gone: finish immediately and exit.

## 7. Redaction

The host applies redaction before anything leaves the Engine (to the Service
logs, diagnostics, `progress`/`activity` forwarded to Cloud, and error text):

1. **Local paths:** absolute filesystem paths are replaced with `<path>`
   (consistent with `DIAGNOSTIC_EVENTS_V1`).
2. **Known secrets:** every value of an environment variable the host passed to
   the plugin, and token patterns (bearer/basic headers, common API-key
   prefixes, PEM private-key blocks, cloud-provider key shapes) are replaced with
   `<redacted>`.
3. **Scope:** applied to stderr, `progress.message`, `activity` fields, `error.message`
   and `probe` check messages. It is **not** applied to `result.output` or
   artifact contents, because they are the user's work product; the host counts
   pattern matches and records the count as a diagnostic flag only.
4. Redaction is best-effort pattern matching, not a guarantee. Plugins MUST NOT
   log secrets, and the host never sends the plugin any Syntila credential, the
   Cloud runtime token, or the entitlement lease.

## 8. Environment and credentials

Built, not inherited: the Engine's existing provider-neutral allow-list
(`PATH` subset, `HOME`, locale, temp dir) plus names listed in the manifest
`env` that the user accepted at consent, minus every `SYNTILA_*` variable. The
plugin may use the user's own logins in the home directory, as provider CLIs do.
Syntila does not store, forward or manage them.

## 9. Session resume (optional, declared and tested)

1. The manifest declares `capabilities.sessionResume: true` and the plugin
   repeats it in `hello.result`.
2. The Service runs conformance case `resume.roundtrip` (create → new process →
   resume → unknown-key → `session_not_found`) in the service. The result is
   stored against the `manifestDigest`.
3. Inventory reports `sessionResume: "tested" | "declared_untested" | "none"`.
   Cloud offers `durable_session` to a plugin **only** when `tested`; otherwise
   the Conversation Router uses stateless/bootstrap prompts.
4. The plugin owns its state, stored under `dataDir`, keyed by `session.key`
   (an opaque Syntila reference, not a provider id). Syntila does not read it.
5. Deleting the data dir or a digest change does not invalidate Syntila's
   conversation; the plugin answers `session_not_found` and the host
   reconstructs from canonical history.

## 10. Manifest (`plugin.json`)

The manifest is public, small, and versioned independently of the protocol.

```json
{
  "schemaVersion": 1,
  "pluginId": "acme-reviewer",
  "version": "1.4.2",
  "displayName": "Acme Reviewer",
  "description": "Code review against Acme's internal rules.",
  "author": { "name": "Acme Platform Team", "contact": "plugins@acme.example" },
  "protocol": { "min": "1.0", "max": "1.0" },
  "artifacts": {
    "linux-x64":   { "command": "bin/reviewer", "args": ["--syntila"], "sha256": "<64 hex>", "size": 4821032 },
    "darwin-arm64":{ "command": "bin/reviewer", "args": ["--syntila"], "sha256": "<64 hex>", "size": 4790112 },
    "windows-x64": { "command": "bin\\reviewer.exe", "args": ["--syntila"], "sha256": "<64 hex>", "size": 5020416 }
  },
  "capabilities": { "progress": true, "sessionResume": false, "readOnly": "never" },
  "access": {
    "workRoot": "write",
    "network": { "mode": "declared", "hosts": ["api.acme.example"] },
    "subprocess": false,
    "env": ["ACME_ENDPOINT"]
  },
  "limits": { "maxConcurrent": 1, "memoryMiB": 1024 },
  "requires": [],
  "license": "Apache-2.0",
  "homepage": "https://example.com/acme-reviewer"
}
```

Constraints (checked by `validate`):

- `schemaVersion` is `1`. Unknown top-level keys are an error (strict) so
  typos cannot hide an access declaration. `pluginId` and `version` per
  architecture §1.1. Strings have length caps; `description` ≤ 512.
- Platform keys: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`,
  `windows-x64`, or `any` (a package that is identical on every platform).
- `command` is a relative path inside the package, normalised, no `..`, and
  resolves to a file listed in `artifacts` hashing. `args` is a fixed array of
  strings; no shell expansion, no `{template}` substitution.
- `requires` names external tools the artifact needs (for example `node`,
  `python3`). The host resolves them with the Engine's bounded executable search
  and shows the resolved path and version at consent. **The interpreter is
  not covered by the digest** (documented risk, decision D7).
- `access` is a *request*, shown at consent. It is not a permission model.
- Canonical form for `manifestDigest`: the manifest with keys sorted, no
  insignificant whitespace, using the repository's canonical-JSON rule.
- `protocol.min`/`max` bound the versions the plugin accepts, within `1.x`.

## 11. Versioning and deprecation policy

- Protocol version is `MAJOR.MINOR`. A MINOR change is additive: new optional
  fields, new optional frame types, new codes. It never changes the meaning of
  an existing field. A MAJOR change may break.
- Negotiation is by `hello.protocol.supported` ∩ plugin support, newest common
  wins (the same algorithm as `negotiateProtocolVersion`).
- The host supports the **current MAJOR and the previous MAJOR**. A MAJOR is
  announced as deprecated at least **12 months** before removal, in this
  document, in `plugins validate` warnings, and in the SDK changelog. Within a
  MAJOR, no supported MINOR is removed before the MAJOR is.
- A deprecated plugin keeps working while supported; the Service surfaces
  `plugin_protocol_deprecated` as a readiness warning, not a failure, and
  refuses only after removal (`plugin_protocol_unsupported`).
- The conformance suite is versioned (`suiteVersion`) and pinned per protocol
  MINOR; a result records both. New MINOR cases never apply to a plugin whose
  `protocol.max` is lower.
- The management IPC and Local Worker Protocol have their own version numbers
  ([IPC spec](WORKER_PLUGIN_MANAGEMENT_IPC_V1.md)); a plugin never sees them.

## 12. Conformance (protocol behaviour only)

The conformance suite ([plan §2-3](../roadmaps/CUSTOM_WORKER_PLUGINS_PLAN.md)) checks, per case, the observable behaviour in
this document: handshake and identity, version negotiation, probe states, one
terminal frame per execute, frame size and rate limits, progress ordering,
cancel within grace, shutdown, ping/pong, malformed-input handling, artifact
path rules, optional resume. **A pass means the plugin speaks this protocol. It
says nothing about safety, honesty of the access declaration, absence of
malicious behaviour, or quality of results.** It MUST NOT be presented to users
as a security or trust rating.

## 13. Example transcript

```text
→ {"type":"hello","id":"h1","protocol":{"supported":["1.0"],"preferred":"1.0"},"host":{"name":"syntila-engine","version":"1.4.0"},"dataDir":"/…/data","limits":{"maxFrameBytes":1048576,"maxPromptBytes":524288,"maxOutputBytes":786432}}
← {"type":"hello.result","id":"h1","protocol":"1.0","plugin":{"id":"acme-reviewer","version":"1.4.2","name":"Acme Reviewer"},"capabilities":{"progress":true,"readOnly":"never"}}
→ {"type":"probe","id":"p1","mode":"passive"}
← {"type":"probe.result","id":"p1","state":"ready","checks":[]}
→ {"type":"execute","id":"e1","deadlineMs":600000,"prompt":"Review the diff","workingDirectory":"/…/Space","access":"read_write","attachments":[]}
← {"type":"progress","id":"e1","message":"Reading diff"}
← {"type":"result","id":"e1","output":"Looks good.","artifacts":[]}
→ {"type":"shutdown"}
```


## Protocol 1.1: model discovery and continuity strategies

The host offers 1.1 and 1.0 and negotiates the highest common version. Existing
1.0 plugins keep their handshake, execution, and `sessionResume` behavior.
Plugins requiring discovery or explicit continuity strategies should declare
`protocol: {min: "1.1", max: "1.1"}`. The Ollama example is now package 1.1.0;
immutable 1.0.0 packages are not overwritten or automatically activated.

A plugin may declare `modelDiscovery: true` in both manifest and handshake.
The host sends `{"type":"models.list","id":"models-1"}`. The plugin replies
with `models.list.result`, the matching ID, and `models`, an array of at most
128 unique `{id, name, status?}` objects. Status is `listed` (default), `verified`,
or `unavailable`. IDs use the public model token grammar; plugins map arbitrary
native names to stable safe IDs. Native invocation mappings stay in the plugin.
Discovery must not run inference, download weights, or modify provider state.
An empty successful list replaces old choices. Errors retain a stale last-known
catalog. Metadata is bounded by the host deadline and normal frame limits.

Engine probes refresh discovery on live checks, first use, and after one minute;
other passive checks reuse the catalog. Catalog identity is bound to the plugin
manifest digest and package version. Workspace publishes the standard catalog,
and Cloud accepts it only against the enabled, owner-scoped plugin pin. Selection
uses normal execution-option and scheduler validation. Effort and compaction
remain unsupported by this plugin contract.

Optional `continuity` capabilities describe behavior independently of execution
location:

- `strategy: "none"`: independent execution; durable requests are rejected.
- `strategy: "history_replay"`: Engine supplies canonical context each turn;
  no adapter session key or native-resume claim is made.
- `strategy: "native_handle"` or `"checkpoint"`: requires a `formatId`;
  plugin owns the native handle/state mapping under its local data directory.
  `modelSwitchSupported` defaults to false. Format IDs used by the Engine must
  follow its existing lowercase kebab identifier grammar (maximum 96 characters).

Without `continuity`, legacy `sessionResume: true` means native-handle behavior;
otherwise the strategy is none. Persistent adapters receive `session.key` and
`session.mode`: `new`, `resume`, or 1.1 `rebuild`. New/rebuild must establish fresh
state from the supplied canonical prompt; resume must fail with
`session_not_found` if unavailable, never silently start an empty conversation.
Return `session.state: created` for new/rebuild and `resumed` for resume, only
after required state is committed. Native handles and checkpoint paths never
leave the local adapter boundary.

Engine session ownership, model/policy compatibility, context revision/history
watermarks, and exclusive cross-process execution reuse the existing session
store. Package digest changes reconstruct state. Old timestamp markers are not
trusted as continuity evidence. Missing native state permits one bounded rebuild
within the same request when canonical bootstrap is available. Failed execution
invalidates the local mapping; successful consumption advances it. State writes
are atomic. A result/save failure is reported, never presented as a committed
continuation. `session_commit_failed` indicates adapter state could not commit;
`model_unavailable` means the selected model cannot be used.

The SDK exposes `discoverModels()` and `PluginModel`; `SessionStore.transact`
provides an exclusive checkpoint transaction with atomic replacement, generation
and context-revision checks, and replay of the last committed request's output.
It cannot undo provider side effects or deduplicate a remote call that succeeded
before its local commit. Cancellation checks before commit and provider-specific
checkpoint compatibility/cleanup remain the adapter's responsibility. Syntila's
canonical conversation remains the reconstruction authority.


## Protocol 1.2: execute prompt size and errors

A host-to-plugin `execute` prompt and its enclosing NDJSON frame have no
plugin-protocol size limit in 1.2. `maxPromptBytes` and `maxFrameBytes` in
the hello frame retain their legacy meanings for 1.0/1.1 and do not limit 1.2
execute prompts. Response and control-frame limits continue to apply. The host
rejects an oversized prompt before sending it to a 1.0/1.1 plugin with a
non-retryable context-limit error. Plugin authors remain responsible for their
model's token/context budget and may reject requests with
`context_limit_exceeded`; the Engine maps this to the provider-neutral
`context_limit_exceeded` failure.

This change only removes the plugin protocol ceiling. The separate local Worker
protocol currently limits a canonical bootstrap to 256 KiB, an execute prompt
to 512 KiB and a Worker frame to 1 MiB. Cloud and Workspace transports may
apply their own limits. End-to-end unbounded prompts require changes to those
separate contracts; protocol 1.2 must not be advertised as removing them.
