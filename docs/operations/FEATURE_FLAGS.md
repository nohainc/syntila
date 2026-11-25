# Feature flags

Only one flag is left: `cluster_mode`. The Worker-first rollout flags (`worker_identity`, `worker_agent_connect`, `worker_target_dispatch`, `workers_ux`, `canonical_timeline`, `artifact_handoff`, `unified_gateway`, `worker_stateful_work`) were removed when the Worker path became the only path. A backend still started with one of them stops at boot with `Unknown feature flag`; remove it from the environment file.

## How it is set

One environment variable on the backend:

```text
SYNTILA_FEATURE_FLAGS=cluster_mode
```

- Comma-separated names, whitespace ignored. Every flag is **off** unless listed.
- Implementation: `apps/backend/src/feature-flags.ts`; tests: `apps/backend/test/feature-flags.test.ts`.
- `loadConfig()` validates the value at boot. An **unknown name** or a flag **without its prerequisite** stops the backend with a clear error, so a typo cannot leave a flag silently off.
- Code asks `isFeatureEnabled("cluster_mode")`. Never read the variable directly.
- The value is configuration, not state. Every node must receive the same value (ADR-033, ADR-039). Changing it needs a restart.

In production set it in the backend environment file (`infra/vps/backend.env.example` shows the line) and restart `syntila-backend`.

## The flags

| Flag | Requires | ADR | Turns on |
| --- | --- | --- | --- |
| `cluster_mode` | none | ADR-039 | More than one backend node in production. Only after the load-test gate. |

## Rules for using a flag

1. A flag guards a **new** path. The old path keeps working with the flag off.
2. A flag never makes two execution paths run the same assignment.
3. Schema changes are additive and not flag-dependent: migrations run regardless of flags.
4. Remove a flag, its tests and its line here when its feature is final.
