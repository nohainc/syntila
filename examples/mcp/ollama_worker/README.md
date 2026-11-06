# Ollama MCP Worker (reference)

A Syntila MCP Worker ([MCP_WORKER_PROFILE_V1](../../../docs/specifications/MCP_WORKER_PROFILE_V1.md))
that runs assignments on a local [Ollama](https://ollama.com) daemon through its
**HTTP API**. One dependency-free Dart file, so it compiles to a single binary.

| Tool | What it does |
| --- | --- |
| `syntila.execute` | Streams `/api/chat`, reports progress, honours the deadline and cancellation (the HTTP connection is aborted) |
| `syntila.probe` | `passive`: Ollama reachable (`/api/version`). `live`: also at least one installed model |
| `syntila.models` | Installed models (`/api/tags`); `:cloud` entries and `syntila-session-*` snapshots are skipped |

Continuity is `history_replay`: Syntila replays history inside the prompt, so the
Worker keeps no session. Ollama errors map to stable codes (`context_limit_exceeded`,
`model_unavailable`, `not_ready`, `timeout`, `cancelled`, `output_too_large`).

## Safety notes

- `OLLAMA_BASE_URL` (default `http://127.0.0.1:11434`) must be a **loopback**
  address; anything else is refused so a prompt cannot leave the machine by accident.
- A listed model is not proof that inference will work (memory, task fit, or an
  alias that forwards to a cloud model). Keep Ollama's cloud features disabled
  when local-only execution matters.
- Like every plugin, it runs as you. Consent shows the full tool definitions.

## Package and use it

```sh
cd examples/mcp/ollama_worker
dart compile exe ollama_worker.dart -o package/bin/run
# Fill plugin.json.template: __PLATFORM__ (for example darwin-arm64),
# __SHA256__ and __SIZE__ of package/bin/run, then save it as package/plugin.json.
syntila plugins import ./package
syntila plugins test ollama-mcp        # starts it in the Engine, pins its tools
syntila plugins register ollama-mcp    # repeat with --accept <hash>
syntila plugins enable ollama-mcp      # repeat with --accept <hash>
```

Then pick an installed model in the normal Worker model selector. With exactly
one installed model, Auto uses it; with several, an explicit choice is required.

Tests: `engines/cli_worker/test/mcp_ollama_worker_test.dart` (against a scripted
fake Ollama, including disconnect on cancel and deadline).
