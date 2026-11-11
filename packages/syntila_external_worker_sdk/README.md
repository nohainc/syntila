# Syntila plugin SDK

Repository-local Dart author tooling for Worker Plugin Protocol 1.0. This
package is not published yet. Add a path dependency to this directory and
import `package:syntila_external_worker_sdk/syntila_external_worker_sdk.dart`.

Create a project with an absolute local dependency on this SDK:

```sh
dart run syntila_external_worker_sdk:init /path/to/new-plugin new-plugin
```

The target must be empty; follow its README to compile and pack.

Subclass `PluginWorker`, implement `id`, `version` and `execute`, then call
`runMcpWorker`. See [the echo example](../../examples/mcp/echo_worker/README.md)
and [author guide](../../docs/specifications/WORKER_PLUGIN_AUTHOR_GUIDE.md).

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
