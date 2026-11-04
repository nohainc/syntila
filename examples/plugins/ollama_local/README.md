# Ollama Local custom Worker

A text-generation plugin using the installed Ollama **CLI**, pinned at build
time, connected to `127.0.0.1:11434`. The default model is `llama3.2:3b`.
The plugin checks `ollama list` before inference; missing models produce
`setup_required` rather than an automatic download. Install the desired local
model yourself, then build with its exact tag:

```sh
ollama list
# Only if you want to download this model:
ollama pull llama3.2:3b
bash examples/plugins/ollama_local/build.sh llama3.2:3b
```

Run build.sh from the repository checkout. It compiles an executable and writes
`dist/plugins/ollama-local/plugin.json` with its actual hash and size. The package
is specific to this OS/architecture and the absolute Ollama executable path on
this machine. A different model/path requires rebuilding and renewed consent.
It does not bundle Ollama or model weights. Keep the local Ollama daemon running.

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

The plugin returns generated text. It does not edit files, execute model-proposed
tools, or retain conversation sessions. Syntila currently schedules custom
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
