# Syntila External Worker SDK

Repository-local Dart author tooling for Worker Plugin Protocol 1.0. This
package is not published yet. Add a path dependency to this directory and
import `package:syntila_external_worker_sdk/syntila_external_worker_sdk.dart`.

Create a project with an absolute local dependency on this SDK:

```sh
dart run syntila_external_worker_sdk:init /path/to/new-plugin new-plugin
```

The target must be empty; follow its README to compile and pack.

Subclass `ExternalWorker`, implement `id`, `version` and `execute`, then call
`runMcpWorker`. See [the echo example](../../examples/mcp/echo_worker/README.md)
and [author guide](../../docs/specifications/WORKER_PLUGIN_AUTHOR_GUIDE.md).

`WorkRequest.prompt` provides the assembled prompt for agent CLIs. A Worker
that uses chat messages can instead use the optional `WorkRequest.conversation`:
map its `instructions` to provider instructions, its ordered `messages` to
previous user and assistant turns, and its `request` to the latest user turn.
When `conversation` is absent, fall back to `prompt`.

The runner handles handshake, probes, ping responses, cooperative cancellation,
progress throttling, terminal response validation and stdout framing. Work must
yield to the event loop to keep cancellation and heartbeats responsive. Run
CPU-intensive computation in another isolate. `SessionStore` persists non-secret
session state under the host-provided data directory.

After compiling the executable and creating `plugin.json`, run:

```sh
dart run syntila_external_worker_sdk:pack <package-directory>
```

Packing updates artifact sizes and SHA-256 hashes and prints the canonical
manifest digest. It does not build executables, create an archive or sign them.
Missing platform files retain their existing metadata, which must validate.
Conformance proves protocol behavior only; plugins execute as the local user.

### Execution metadata and sessions

`WorkRequest.execution` is optional. When present it identifies the workflow
and step where available, the advisory access mode, logical session policy, and
the kind of context supplied (`bootstrap`, `delta`, `none`, or `rebuild`).
Chat adapters can map `conversation` to messages; CLI adapters can use
`prompt`. Native-session adapters use `sessionKey`, `resumeSession`, and
`rebuildSession` to manage provider state, applying deltas on resume.
History-replay adapters use the available context each time. Context can be
bounded or summarized. The host owns the canonical conversation and decides
when a session requires rebuilding. Honor read-only instructions even when
the provider has no enforced read-only mode.
