# Feature flags

Flags gate the Worker-first migration (ADR-032 to ADR-039). They exist so each phase of `WORKER_FIRST_IMPLEMENTATION_PHASES.md` can be deployed dark, enabled for the owner first, and switched off again during the rollback window.

## How they are set

One environment variable on the backend:

```text
SYNTILA_FEATURE_FLAGS=worker_identity,worker_agent_connect
```

- Comma-separated names, whitespace ignored. Every flag is **off** unless listed.
- Implementation: `apps/backend/src/feature-flags.ts`; tests: `apps/backend/test/feature-flags.test.ts`.
- `loadConfig()` validates the value at boot. An **unknown name** or a flag **without its prerequisite** stops the backend with a clear error, so a typo cannot leave a flag silently off.
- Code asks `isFeatureEnabled("worker_identity")`. Never read the variable directly.
- The value is configuration, not state. Every node must receive the same value (ADR-033 multi-server rules). Changing it needs a restart.

In production set it in the backend environment file (`infra/vps/backend.env.example` shows the line) and restart `syntila-backend`.

## The flags

| Flag | Requires | Phase | ADR | Turns on |
| --- | --- | --- | --- | --- |
| `worker_identity` | none | P1 | ADR-032 | Worker Instances and Actors: `/api/workers` CRUD, read-only Worker list in the app. |
| `worker_agent_connect` | `worker_identity` | P3, P4 | ADR-034 | Pairing, per-Worker sessions with epoch fencing, standalone Agent connections. |
| `worker_target_dispatch` | `worker_agent_connect` | P5 | ADR-035 | Assignments routed to a Worker Instance instead of a Workspace. |
| `workers_ux` | `worker_target_dispatch` | P6 | ADR-035 | Workers navigation and Workspace-free Worker selection in the app. |
| `canonical_timeline` | `worker_target_dispatch` | P7 | ADR-036 | Canonical Thread timeline and attribution. |
| `artifact_handoff` | `worker_agent_connect` | P8 | ADR-037 | Local files and cross-Worker artifacts. |
| `unified_gateway` | `worker_agent_connect` | P9 | ADR-038 | One realtime transport for browsers and Agents. |
| `cluster_mode` | `unified_gateway` | P12 | ADR-039 | More than one backend node in production. Only after the P11 load-test gate. |

The prerequisite column is enforced in code and follows the dependency graph of the phases document. If a phase graph changes, change `FEATURE_FLAG_REQUIRES` in the same commit.

## Rules for using a flag

1. A flag guards a **new** path. The old path keeps working with the flag off and is removed in P10, together with the flag.
2. A flag never makes two execution paths run the same assignment (ordering principle 3). Choose the path once, when the assignment is created.
3. Schema changes are additive and not flag-dependent: migrations run regardless of flags, and the columns stay nullable until the cleanup phase.
4. The app learns the flags through `GET /api/features` (added in P1); the Worker list loads only when `worker_identity` is listed.
5. Remove a flag, its tests and its line here when its phase is final.

## Milestone M1: Worker-first GA (one server)

Turn on `worker_agent_connect`, `worker_target_dispatch`, `workers_ux`, `canonical_timeline` and `artifact_handoff` by cohort. The flag value is process-wide (see above), so a cohort means a separate environment or an allow-listed deployment, not a per-user switch; no per-user flag exists yet.

| Step | Cohort | Move on when |
| --- | --- | --- |
| 1 | Internal accounts only | Two Agents on two hosts complete a Thread round trip; no duplicate answers; the P7 timeline matches the old rendering on fixtures. |
| 2 | Owners | No `worker_offline` surprises, no stuck assignments, artifact handoff verified between a macOS and a Linux Agent. |
| 3 | Test cohort | A week without a rollback trigger (duplicate answers, lost Work cards, unauthorized folder reach). |
| 4 | Default | Steps 1-3 clean. Legacy removal is P10. |

Rollback is removing the flag and restarting; schema changes stay. `unified_gateway` (P9) is enabled separately, after M1, because Agents opt in by sending `syntila.messaging/1` frames.
