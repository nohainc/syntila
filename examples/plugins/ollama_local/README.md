# Ollama Local custom Worker

A text-generation plugin using the installed Ollama **CLI**, connected to
`127.0.0.1:11434`. Protocol 1.1 discovers installed model entries using
`ollama list`; the selected public model ID is resolved back to its native tag
at execution. No model is compiled into the package. Namespaced tags receive
stable hashed IDs; their original names remain visible as model labels.
Explicit `:cloud` entries and reserved `syntila-session-` snapshots are excluded.
A listed entry is not proof of successful inference, sufficient memory, task
compatibility, or local-only execution of an alias; keep cloud features disabled
in the daemon when local execution is required.

Build once, then choose an installed model in the normal Worker model selector:

```sh
ollama list
bash examples/plugins/ollama_local/build.sh
```

With multiple installed entries an explicit selection is required. With exactly
one entry, Auto uses that entry. A missing selected model fails without replacing
it or explicitly requesting a download. The preflight check and native CLI run
are not atomic; concurrent model removal can trigger Ollama's own automatic pull.
`ollama ps` lists loaded models; loading is not a
prerequisite for selection, so unloaded installed entries remain selectable.

The build creates version 1.3.0 at `dist/plugins/ollama-local`, specific to this
OS/architecture and absolute Ollama executable path. Re-import, test, register,
and enable the new package through the existing consent flow. It bundles neither
Ollama nor model weights and requires a running local daemon.

From a configured Plus Workspace:

```sh
syntila plugins import /absolute/path/to/Syntila/dist/plugins/ollama-local
syntila plugins validate ollama-local
syntila plugins test ollama-local
syntila plugins register ollama-local
# Repeat register with the displayed --accept hash.
syntila plugins enable ollama-local
# Repeat enable with its displayed --accept hash.
```

The plugin does not impose a prompt-size limit. The current Workspace-to-Engine
protocol still limits prompts to 512 KiB and canonical bootstrap context to
256 KiB; larger conversations require changes to that separate protocol. Conversations are also limited by the selected model’s context window; older
material may be truncated by Ollama, and processing a long prompt can be slow. The plugin returns generated text. It does not edit files, execute model-proposed
tools, or claim native session resume. Its continuity strategy is `history_replay`:
the Engine supplies canonical context on each invocation, including after a
restart. The plugin never sends interactive `/save` or `/load` through the
one-shot prompt pipe. Native checkpoints can be implemented later through the
same plugin contract without changing Cloud's conversation identity. Syntila currently schedules custom
plugins for Work only. The manifest declares loopback network and subprocess
access; these declarations do not create a sandbox.

Prompts go over stdin, not shell interpolation or command-line arguments. The
child environment fixes the endpoint and excludes inherited proxies and API
credentials. Output is bounded; deadline/cancel kills the CLI process. Ollama's
already-running daemon and its model runner are outside the Engine child tree:
Engine resource limits do not bound the daemon's memory or CPU, and terminating
the CLI is not proof that server inference has stopped. Use Ollama's own process
controls when needed. Keep cloud-backed models disabled in the local Ollama
installation; a loopback endpoint alone cannot establish how its daemon runs a
model. Do not put provider credentials into the package.

Validation: `dart analyze` and `dart test` in this directory. Tests use a fake
CLI to check missing setup, literal stdin, local endpoint, cancellation, deadline
and safe diagnostics. A real inference/conformance pass additionally requires
an installed model; readiness failure is not a successful generation test.

## Suggested configuration for a 64 GB Apple Silicon Mac

The supplied Modelfile uses Llama 3.1 8B with an 8,192-token context and at most
2,048 generated tokens. The smaller context leaves more memory for other apps.
Create a local alias (it reuses the downloaded weights), then select `syntila-llama:8b` in Syntila:

```sh
ollama pull llama3.1:8b
ollama create syntila-llama:8b -f examples/plugins/ollama_local/Modelfile
bash examples/plugins/ollama_local/build.sh
```

The source model remains installed. `ollama ps` shows actual runtime memory and
GPU usage. This is a practical starting configuration, not a quality benchmark.
