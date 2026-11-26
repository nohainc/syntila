# Syntila Technology Stack

**Status:** Current Worker-first architecture.

## Stack summary

| Layer | Technology |
| --- | --- |
| Syntila Web App | Flutter + Dart, Web |
| Cloud Backend | TypeScript + Bun/Node + PostgreSQL (`apps/backend`) |
| Auth Edge | TypeScript + Cloudflare Workers (`apps/cloud`) |
| Syntila Connect | Pure Dart headless service + CLI (`apps/connect`) + Flutter desktop GUI (`apps/connect_gui`) |
| Local Worker Protocol | Protocol 4.0, versioned NDJSON |
| Local CLI execution | Generic Dart CLI Worker Engine + signed Worker Profiles |
| Database | PostgreSQL (backend) |
| Artifact and release storage | Cloudflare R2 |
| Live Worker connection | WebSocket (`syntila.worker-agent-protocol`) |
| App-to-Cloud boundary | Human Product Protocol over HTTPS and `syntila.messaging/1` realtime |
| Connect-to-Cloud boundary | Worker Agent Protocol (`syntila.worker-agent-protocol`) |
| Connect-to-Engine boundary | Local Worker Protocol 4.0 over stdin/stdout |
| TypeScript tests | Vitest / Bun test |
| Dart/Flutter tests | `dart test` (Connect, Engine, packages) / `flutter test` (Web App, Profile Lab) |
| CI and deployment | GitHub Actions |

## Applications and runtime

Syntila is the human web application. Syntila Cloud owns identity,
authorization, Spaces, Threads, scheduling, Profile releases, and
persistence. Syntila Connect runs on the user's computer and owns per-Worker
credentials, sessions, journals, locks, Profile verification/cache, Engine
supervision, cancellation, and diagnostics.

Each assignment or probe runs through the generic CLI Worker Engine as a
separate process. The Engine starts a locally installed provider CLI using
structured arguments. Connect owns the process tree and applies deadlines,
output limits, cancellation, and cleanup. Provider authentication remains with
the provider CLI; Syntila Cloud never receives provider credentials.

The Engine plus Profile boundary is defined by ADR-018 and the
[Tool Profile v1 specification](../specifications/TOOL_PROFILE_V1.md).

## Contract boundaries

Human Product, Worker Agent, and Local Worker Protocol contracts have
separate owners, endpoints, authentication, versions, and wire schemas. Keep
one canonical schema source per boundary and generate language bindings from
it. Shared domain IDs do not justify sharing transport envelopes.

See [Protocol Boundaries](PROTOCOL_BOUNDARIES.md).

## Implementation principles

- Keep PostgreSQL persistence owned by backend route and domain modules; keep
  Connect state under `<application data>/Syntila/Workers/<worker-id>/` and keep
  user project folders separate from that internal state.
- Prefer explicit domain types, state machines, immutable assignment snapshots,
  and idempotent commands.
- Keep scheduling authorization in Cloud and process/filesystem enforcement in
  Connect and Engine.
- Keep logs, output, artifacts, and diagnostics bounded and redact secrets.
- Use platform-specific code only for actual OS behavior.
- Do not add infrastructure or providers without a concrete product requirement.

## Storage and secrets

PostgreSQL stores structured metadata and state. R2 stores large immutable
artifacts, request files, and releases. Local provider credentials remain in the
provider's secure configuration, and Connect Worker credentials use the platform
credential store. Never write plaintext credentials to database tables,
assignment payloads, logs, or artifacts.
