# syntila-worker (Standalone Worker Agent)

One Agent is one Worker Instance: one credential, one journal, one connection. It runs with no Workspace installed. Design: `docs/specifications/WORKER_AGENT_RUNTIME_V1.md`, `docs/specifications/WORKER_AGENT_CLI_AND_SERVICES.md`, ADR-034.

```shell
cd apps/worker_agent
dart pub get
dart format .
dart analyze
dart test
dart run bin/syntila_worker.dart help
```

The package depends only on `crypto`, `cryptography` and `path`. It does not import `apps/workspace`.
