# Writing a Worker plugin

A custom Worker is a local MCP server that implements the
[Syntila MCP Worker profile](MCP_WORKER_PROFILE_V1.md) and ships in a package with a
manifest ([package and manifest](WORKER_PLUGIN_PROTOCOL_V1.md)). It runs as the user
who installs it, with that user's files and logins; read the security notes before
shipping one. Users should review the
[installation security guide](../security/CUSTOM_WORKER_PLUGINS.md).

## The Dart SDK

`packages/syntila_external_worker_sdk` is repository-local (not published to a package
registry). Subclass `ExternalWorker`, implement `execute`, and call `runMcpWorker`,
which serves `syntila.execute`, `syntila.probe` and, when you declare
`modelDiscovery: true`, `syntila.models`: exactly one answer per request, progress
notifications with strictly increasing values, cancellation that completes
`context.cancelled`, `print` redirected to stderr, and a thrown `PluginFailure` mapped
to the stable issue codes. Tool names and descriptions are fixed by the SDK, so a
consented tool pin only changes when the SDK does.

```dart
class MyWorker extends ExternalWorker {
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

Future<void> main() => runMcpWorker(MyWorker());
```

Create a project from a checkout and pack it:

```sh
cd packages/syntila_external_worker_sdk
dart run syntila_external_worker_sdk:init /path/to/my-plugin my-plugin   # destination must be empty
# build the executable (dart compile exe), then fill hashes and print the manifest digest:
dart run syntila_external_worker_sdk:pack /path/to/my-plugin
```

Notes:

- Dart is single-threaded per isolate: a long synchronous loop stops cancel handling, so
  `await` between steps (or compute in an isolate) and check `context.isCancelled`.
- `request.prompt` is the assembled prompt for agent CLIs; `request.conversation`
  carries chat messages for Workers that use them. `context.dataDirectory` is
  `SYNTILA_PLUGIN_DATA_DIR`, set only by the Engine.
- **Sessions and continuity.** Declare `continuity: {strategy: "history_replay"}` for
  one-shot CLIs that receive canonical context, or a native-handle or checkpoint
  strategy with a lowercase kebab `formatId` and implement new, resume and rebuild
  inside `execute` (`resumeSession`, `rebuildSession`). Persist provider state before
  reporting a created or resumed result. The optional `SessionStore.transact` helper
  gives locking, atomic commits, monotonic revision checks and retry deduplication for
  the last committed turn; it is not exactly-once remote inference.
- **Model discovery.** Override `discoverModels()` to return bounded `PluginModel`
  metadata and declare `modelDiscovery: true`; resolve `request.model` against current
  entries and never silently substitute an unavailable selection.
- Reference servers: `examples/mcp/echo_worker` (sessions and cancel) and
  `examples/mcp/ollama_worker` (wraps the installed Ollama CLI with runtime model
  discovery; needs an already-downloaded model and does not execute model-proposed
  tools).

Any language works if the server implements the profile; the SDK is only the Dart
path. A plugin that reads or writes the Space needs `access.workRoot` other than
`none`, which only warns users: filesystem isolation is not enforced.

## Check it

```sh
dart run syntila_external_worker_conformance -- ./my-plugin   # author tool, no account needed
```

This starts your server directly and runs the MCP conformance runner
(`packages/syntila_external_worker_conformance`). It checks sampled protocol behavior,
including tool definition shapes, not the full behavior of your Worker, and a pass says
nothing about safety or the truthfulness of your access list.

On a Connect that has Custom Workers available:

```sh
syntila-connect mcp-worker import ./my-plugin   # copies into the Connect store and records approval
syntila-connect mcp-worker test my-plugin       # starts it in the Engine, checks the profile and tools, records tool pins
syntila-connect mcp-worker list
syntila-connect mcp-worker approve ID VERSION MANIFEST_DIGEST
syntila-connect mcp-worker remove ID MANIFEST_DIGEST
```

Approval is tied to the exact ID, version and manifest digest, so a changed package
needs approval again. Cloud separately checks the owner's entitlement and the Worker's
pin before scheduling; see [MCP Worker operations](../operations/CUSTOM_WORKER_PLUGINS_OPERATIONS.md).

## What Syntila enforces

The Engine enforces the SHA-256 pin (re-checked before every start), a built environment
(an allow-list plus the names the user accepted, never `SYNTILA_*`), no shell, handshake
and cancellation deadlines, frame and progress limits, redaction of paths and tokens in
diagnostics, process-tree cleanup, tool-definition pins, and artifact paths that stay in
the working directory. POSIX hard CPU and open-file limits and Windows job limits apply
before and during execution; observed memory, process-count and aggregate-CPU budgets are
sampled, so short-lived spikes can be missed and they are not kernel quotas.

Not enforced: filesystem and network isolation. A process boundary is not a sandbox.
Read-only Steps are never routed to plugins because nothing proves read-only; plugins run
Work Steps only.

## Security notes for authors

- Never write secrets to stdout, stderr or files under the working directory; redaction
  is best effort. Treat prompts and files as untrusted input.
- Do not ask users for credentials you do not need; Syntila never stores or forwards
  provider credentials, and your plugin must not either.
- Sign releases if you can. After `pack`, from the repository root:

```sh
umask 077
openssl genpkey -algorithm ED25519 -out /private/path/author.pem
node scripts/sign-plugin.mjs /path/to/packed-plugin /private/path/author.pem author-1
```

The signer reads a PKCS#8 PEM Ed25519 key, writes `plugin.sig` in the Service's format,
never prints the key and refuses to overwrite an existing signature (remove a stale one
after repacking). Keep the author key outside the package and different from any Cloud
lease key. Users still consent to the digest and signer fingerprint; a recognized signer
does not verify the claimed author name.

## Author kit

`node scripts/build-plugin-author-kit.mjs` writes
`dist/plugin-author-kit/syntila-plugin-author-kit.tar.gz` and its SHA-256 sidecar: the
SDK, conformance runner, protocol packages, the echo example, the signing tool and this
guide's references, with a `MANIFEST.sha256`. It uses an explicit source allow-list,
rejects source symlinks, and excludes build caches, tests, local trust state and
credentials. It is a local or CI artifact, not a published package or a signed Syntila
release.
