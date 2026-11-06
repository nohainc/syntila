# Writing a Worker plugin

A plugin is any executable that speaks the
[Worker Plugin Protocol v1](WORKER_PLUGIN_PROTOCOL_V1.md) over stdin and stdout.
This guide is the shortest path from nothing to a plugin that passes the
conformance suite. A plugin runs as the user who installs it, with that user's
files and logins; read the **security notes** before shipping one. Users should
review the [installation security guide](../security/CUSTOM_WORKER_PLUGINS.md).

## Get the author kit

From a source checkout, `node scripts/build-plugin-author-kit.mjs` writes
`dist/plugin-author-kit/syntila-plugin-author-kit.tar.gz` and its SHA-256 sidecar.
Engine CI builds and retains the same bundle as the `plugin-author-kit` artifact.
The extracted README walks through creating, compiling, packing and conformance
checking a plugin without a Syntila checkout or account. It contains the protocol,
SDK, conformance runner, source examples, signing tool and transcript vectors;
internal package dependencies remain relative within the kit.

The builder uses an explicit source allow-list and rejects source symlinks. It
excludes build caches, tests, local trust state, entitlement keys and credentials.
`MANIFEST.sha256` records file contents. This is a local/CI distribution artifact;
no packages have been published to a package registry and it is not a signed
Syntila release. Install Dart and use the extracted README's commands.

## 1. The package

A package is a directory (or a `.zip`) containing `plugin.json` and the files it
lists:

```text
my-plugin/
  plugin.json
  bin/my-plugin          # the executable for this platform
  plugin.sig             # optional detached Ed25519 signature
```

`plugin.json` (schema in the protocol spec, §10) pins every executable by
SHA-256:

```json
{
  "schemaVersion": 1,
  "pluginId": "my-plugin",
  "version": "1.0.0",
  "displayName": "My Plugin",
  "description": "What it does.",
  "author": { "name": "You" },
  "protocol": { "min": "1.0", "max": "1.0" },
  "artifacts": {
    "linux-x64": {
      "command": "bin/my-plugin",
      "args": [],
      "sha256": "<hex>",
      "size": 123456
    }
  },
  "capabilities": { "progress": true },
  "access": {
    "workRoot": "write",
    "network": { "mode": "none" },
    "subprocess": false,
    "env": []
  }
}
```

Platform keys: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`,
`windows-x64`, or `any`. Compute `sha256` and `size` of each artifact with
`shasum -a 256` and `wc -c`. Unknown manifest keys are errors on purpose, so a
typo cannot hide an access declaration. The `access` block is shown to the user
at consent; it is a request, not a sandbox.

## 1a. Dart: use the SDK

The SDK is currently repository-local, not published. Create a local project
from a checkout:

```sh
cd packages/syntila_plugin_sdk
dart run syntila_plugin_sdk:init /path/to/my-plugin my-plugin
```

The destination must be empty. The generated README contains build and pack
commands; the SDK dependency points to this checkout.

`packages/syntila_plugin_sdk` implements the protocol for you. Subclass
`PluginWorker`, implement `execute`, and call `runPlugin`:

```dart
class MyPlugin extends PluginWorker {
  @override
  String get id => 'my-plugin';
  @override
  String get version => '1.0.0';
  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    context.progress('Working');
    return WorkResult('answer for: ${request.prompt}');
  }
}

Future<void> main() => runPlugin(MyPlugin());
```

`examples/plugins/echo_dart` is a complete plugin that also supports session
resume (`SessionStore`) and cancel; tests exercise all 21 conformance cases
standalone and through the Engine host. After
`dart compile exe`, fill the hashes with:

```sh
dart run syntila_plugin_sdk:pack ./my-plugin     # writes sha256/size, prints the manifest digest
```

Dart is single-threaded per isolate. A long synchronous loop stops heartbeats
and cancel handling, so `await` between steps (or compute in an isolate) and
check `context.isCancelled`. The SDK sends exactly one terminal frame per
request, turns thrown errors into a safe `internal` error (never a stack trace or
path), and redirects `print` to stderr.

## 1b. Dart: run the same Worker over MCP (ADR-028)

The SDK can serve your `PluginWorker` as a Syntila MCP Worker instead of the NDJSON
plugin protocol. Change only the entry point:

```dart
Future<void> main() => runMcpWorker(MyWorker()); // instead of runPlugin(MyWorker())
```

`runMcpWorker` answers `syntila.execute`, `syntila.probe` and (when you declare
`modelDiscovery: true`) `syntila.models` as described in
[MCP_WORKER_PROFILE_V1](MCP_WORKER_PROFILE_V1.md): exactly one answer per request,
progress notifications with strictly increasing values, a cancel that completes
`context.cancelled`, `print` redirected to stderr, and a `PluginFailure` mapped to
the same stable codes. `context.dataDirectory` is `SYNTILA_PLUGIN_DATA_DIR`, which
only the Engine sets.

Package it with `"kind": "mcp"` in `plugin.json` (the `protocol` range is then the
Syntila Worker profile range, `1.x`). `plugins test` starts the server in the Engine,
checks the profile and the two required tools, and pins every tool definition; the
consent screen shows them. Tool names and descriptions are fixed by the SDK so a pin
only changes when the SDK does. Differences to keep in mind:

- The Engine does not pass a working directory to MCP Workers yet; use
  `request.workingDirectory` only if the field is sent.
- There is no NDJSON conformance suite for MCP Workers; `plugins test` is a profile
  check, not a behavioural test.
- Reference servers: `examples/mcp/echo_worker` and `examples/mcp/ollama_worker`.

## 2. The protocol in ten lines

- Read one JSON object per line from stdin; write one per line to stdout. stdout
  carries protocol frames **only**; log to stderr.
- Answer `hello` with `hello.result` naming your `pluginId` and `version`
  exactly as in the manifest, choosing a protocol the host offered.
- Answer `probe` with `probe.result` (`ready`, `setup_required`,
  `sign_in_required`, `unavailable`, `failed`).
- For `execute`, send optional `progress` frames, then **exactly one** `result`
  or `error` carrying the same `id`.
- On `cancel`, stop and send `error` with code `cancelled` within 5 seconds.
- Answer `ping` with `pong` (any frame you send also counts as liveness).
- On `shutdown` or end of input, exit within 3 seconds.
- In plugin protocol 1.2, execute prompts are not size-limited by the plugin protocol. Legacy protocols limit prompts to 512 KiB and frames to 1 MiB. Output remains limited to 768 KiB; the separate Worker protocol still has its own limits.
- Artifacts in a result are paths relative to the working directory.
- To support sessions, store state under the `dataDir` from `hello`, keyed by the
  `session.key` you receive, and declare `"sessionResume": true`.

## 3. Check it

```sh
dart run syntila_plugin_conformance -- ./my-plugin       # author tool, any language
```

This starts your plugin directly and runs the same 21 cases the Workspace runs
(`packages/syntila_plugin_conformance`). It is free and needs no Syntila
account. A pass means **your plugin speaks the protocol**. It does not mean the
plugin is safe, truthful about its access list or free of malicious behaviour,
and users are never shown it as a security rating.

On a Plus Workspace:

```sh
syntila plugins import ./my-plugin       # copies it into the Workspace store
syntila plugins validate my-plugin       # static checks; runs nothing
syntila plugins test my-plugin           # conformance inside the Engine
syntila plugins register my-plugin       # shows consent, then re-run with --accept <hash>
syntila plugins enable my-plugin         # same, per Workspace
```

Consent is by content: `register` and `enable` print what the user is accepting
and a hash of it; only re-running with that exact `--accept <hash>` proceeds. A
new version or any change to the files changes the digest and needs consent
again. `syntila plugins export my-plugin ./my-plugin.syntila-plugin` writes a
bundle with no credentials, data or logs.

## 4. What Syntila enforces, and what it does not

Enforced by the Engine: the SHA-256 pin (re-checked before every start), a built
environment (only an allow-list plus names the user accepted, never `SYNTILA_*`),
no shell, handshake/heartbeat/cancel/shutdown deadlines, frame-size and
progress-rate limits, redaction of paths and tokens in diagnostics, process-tree
cleanup, and artifact paths that must stay inside the working directory.

The plugin-mode Engine now applies POSIX hard CPU/open-file limits before exec,
Windows job memory/process-count/CPU limits, and observed data-directory limits.
On POSIX, memory/process count and aggregate CPU are sampled in addition to
the hard per-process CPU limit. Windows samples aggregate job handles. These
sampled budgets can miss short-lived activity and are not hard kernel quotas. See [resource-limit evidence](../acceptance/PLUGIN_RESOURCE_LIMITS.md)
for defaults and platform verification gaps.

**Not enforced:** filesystem and network isolation. A process boundary is not a
sandbox. Read-only Steps are never routed to plugins because nothing proves
read-only; plugins run Work Steps only.

## 5. Security notes for authors

- Never write secrets to stdout, stderr or files under the working directory.
  Redaction is best effort.
- Treat prompts and files as untrusted input.
- Do not ask users for credentials the plugin does not need; Syntila never stores
  or forwards provider credentials, and your plugin must not either.
- Sign releases if you can. `plugin.sig` is JSON
  `{"alg":"ed25519","keyId":"...","publicKey":"<base64 raw 32 bytes>","signature":"<base64 64 bytes>"}`
  where the signature is over the UTF-8 bytes of the manifest digest (64 hex
  characters). A valid signature proves who built it, not that it is trustworthy.


## 6. Sign a packed release

Signing is optional. Keep the author key outside your package directory, and
use a different key from the Cloud entitlement lease key. For example:

```sh
umask 077
openssl genpkey -algorithm ED25519 -out /private/path/author.pem
node scripts/sign-plugin.mjs /path/to/packed-plugin /private/path/author.pem author-1
```

Run the signing command from the repository root after `pack`. It reads a
PKCS#8 PEM Ed25519 key and writes `plugin.sig` in the Service's signature format.
It never prints the private key, and refuses to overwrite an existing signature.
After changing or repacking a release, explicitly remove the stale `plugin.sig`
and sign again. The signer does not replace static manifest validation or
conformance testing. Users still consent to the digest and signer fingerprint;
`syntila plugins trust-signer <id>` recognizes a verified key locally after
consent by hash. `plugins signers` lists fingerprints and `plugins untrust-signer
<fingerprint>` forgets one. Recognized keys still need explicit consent for every
registration, update and enablement; they do not verify the claimed author name.

The [Python example](../../examples/plugins/echo_python/README.md) demonstrates
implementing the same protocol without the Dart SDK. Its interpreter comes from
the local environment; prefer standalone executables for distribution.

The [Ollama local plugin](../../examples/plugins/ollama_local/README.md) wraps
the installed Ollama CLI with runtime model discovery and selection, cancellation and bounded
output. It requires an already-downloaded model and does not edit files or
execute model-proposed tools.


### Discovery and continuity SDK (protocol 1.1)

Override `discoverModels()` to return bounded `PluginModel` metadata and declare
`modelDiscovery: true` in both the manifest and `capabilities`. The Engine handles
catalog caching and publication; resolve `request.model` against current native
entries before execution. Never silently substitute an unavailable selection.

Declare `continuity: {strategy: "history_replay"}` for one-shot CLIs receiving
canonical context. For native handles or checkpoint files, declare the matching
strategy and a lowercase kebab `formatId`; implement new/resume/rebuild inside
`execute`. SDK requests expose `resumeSession` and `rebuildSession`. Persist the
provider state before reporting a created/resumed result. The optional
`SessionStore.transact` helper provides locking, atomic commits, monotonic
revision/generation checks and retry deduplication for the last committed turn.
It does not provide exactly-once remote inference. See the protocol 1.1 section
of [Worker Plugin Protocol](WORKER_PLUGIN_PROTOCOL_V1.md) for complete semantics.
