# Ollama MCP Worker (reference)

A Syntila MCP Worker ([MCP_WORKER_PROFILE_V1](../../../docs/specifications/MCP_WORKER_PROFILE_V1.md))
that runs assignments on a local [Ollama](https://ollama.com) daemon through its
**HTTP API**. One dependency-free Dart file, so it compiles to a single binary.

| Tool | What it does |
| --- | --- |
| `syntila.execute` | Streams `/api/chat`, reports progress, honours the deadline and cancellation (the HTTP connection is aborted) |
| `syntila.probe` | `passive`: Ollama reachable (`/api/version`). `live`: also at least one installed model |
| `syntila.models` | Installed models (`/api/tags`); `:cloud` entries and `syntila-session-*` snapshots are skipped |

Continuity is `history_replay`: Syntila sends the earlier turns with every request
(`conversation`), and the Worker maps them to Ollama `system` / `user` /
`assistant` messages and keeps no session. It asks Ollama for an 8,192-token
context (`OLLAMA_NUM_CTX` overrides it) and drops the oldest turns that do not
fit, because Ollama truncates an oversized prompt without an error. Ollama errors map to stable codes (`context_limit_exceeded`,
`model_unavailable`, `not_ready`, `timeout`, `cancelled`, `output_too_large`).

## Safety notes

- `OLLAMA_BASE_URL` (default `http://127.0.0.1:11434`) must be a **loopback**
  address; anything else is refused so a prompt cannot leave the machine by accident.
- A listed model is not proof that inference will work (memory, task fit, or an
  alias that forwards to a cloud model). Keep Ollama's cloud features disabled
  when local-only execution matters.
- The server runs as you. Consent shows the full tool definitions.

## Run it as an External Worker

Package it and attach it to the Workspace as a Worker. Once enabled it is an
ordinary local Worker: it is listed, checked and scheduled like any other.

```sh
./scripts/package-ollama-worker.sh             # → dist/workers/ollama-mcp/
syntila workers import "$PWD/dist/workers/ollama-mcp"
syntila workers inspect ollama-mcp             # checks and pins the MCP tools
syntila workers register ollama-mcp            # shows the consent document
syntila workers register ollama-mcp --accept HASH
syntila workers enable ollama-mcp              # shows the consent document
syntila workers enable ollama-mcp --accept HASH
syntila workers check ollama-mcp
```

The Worker list displays the package ID (`ollama-mcp`). Use that ID with
`check`, `test`, `enable`, `disable`, and `remove`.

The build requires Dart; pass an optional output directory to the script to
choose another location. Registering and enabling talk to Cloud. The server
defaults to `http://127.0.0.1:11434`. Start Ollama and install a model before
using it. A rebuilt binary has a new digest, so import, inspect, register and
enable the new package again.

`./scripts/build-ollama-macos.sh` builds only the bare executable. Adding that
with `syntila mcp add` registers an MCP *tool server* for other Workers, not a
Worker. The executable runs as the local user; process isolation is not a
filesystem sandbox.

Tests: `engines/cli_worker/test/mcp_ollama_worker_test.dart` (against a scripted
fake Ollama, including disconnect on cancel and deadline).
