# VPS backend

The product backend is a Bun server backed by PostgreSQL. It owns Spaces, Threads, Workers, Work, authorization and durable events. The Cloudflare edge handles human authentication and app assets; Connect runs Workers on their owners' computers. See [Architecture](../../ARCHITECTURE.md) and [Event Streams](../specifications/EVENT_STREAMS.md).

## Deployment

The staged release consists of the bundled backend and ordered migrations. `infra/vps/deploy-backend.sh` checks prerequisites and lists pending migrations. It stages a timestamped release, starts the service, waits for readiness, and attempts to restore the previous code release if readiness fails. The service runs the migration runner before starting the server and the deploy script checks the resulting schema against `schema.lock`.

Review the script and pending migrations before a production deployment. Switching the code back does **not** reverse a migration; fix forward or reset the database. The migration policy and schema verification are documented in [backend migrations](../../apps/backend/migrations/README.md). The backend smoke checks human REST and realtime paths only; it does not establish Worker execution or reconnect acceptance.

## Operations and scaling

Use the [operations guide](VPS_OPERATIONS.md) for monitoring. The current Worker resilience script is disabled until its obsolete client is replaced; its absence must be accounted for in release acceptance. The local two-node test exercises shared-database and outbox recovery and reports its cross-node realtime gap. Scaling beyond one node remains gated by [ADR-039](../decisions/ADR-039-horizontal-scaling.md).

## Local validation

Run `pnpm validate:backend` with a local PostgreSQL test database. Use `scripts/test-two-node.sh` when changing durability, outbox, sessions or realtime. These tests do not replace a real Connect and provider acceptance.
