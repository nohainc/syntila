# Cloudflare deployment

The public site and the authenticated app/auth edge deploy independently. The current topology and product responsibilities are described in [Architecture](../../ARCHITECTURE.md).

The app edge serves Flutter assets and handles human authentication. Its D1 database `syntila-auth` is for authentication only. Product data, Worker sessions, assignments and realtime streams live in the PostgreSQL backend. Files and artifacts use R2. Apply backend migrations using the [VPS backend procedure](VPS_BACKEND.md), independently of auth migrations.

The manual [cloud deployment workflow](../../.github/workflows/deploy-cloud.yml) requires passing CI on the same main commit. It builds the app, checks the bundle and production configuration, syncs authentication secrets, applies auth D1 migrations and deploys the edge. The [site workflow](../../.github/workflows/deploy-site.yml) deploys the public site separately. Review current workflow and configuration before deploying; local tests do not constitute deployment or device acceptance.

## GitHub sign-in

Configure GitHub OAuth for the production app callback `https://syntila.app/api/auth/callback/github`. Human sign-in uses identity scopes and does not grant repository access. Configure the client ID and secret as deployment secrets; never put credentials in the repository or browser bundle.

## Durable realtime stream alignment

Realtime streams and outbox rows belong to PostgreSQL. Apply forward-only backend migrations and verify the schema lock. See [Event Streams](../specifications/EVENT_STREAMS.md) for replay and recovery behavior and [Persistence](../specifications/PERSISTENCE.md) for retention.
