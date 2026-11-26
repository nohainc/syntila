# Cloudflare deployment

The public site and the authenticated app/auth edge deploy independently. The current topology and product responsibilities are described in [Architecture](../../ARCHITECTURE.md).

The app edge serves Flutter assets and handles human authentication. Its D1 database `syntila-auth` is for authentication only. Product data, Worker sessions, assignments and realtime streams live in the PostgreSQL backend. Files and artifacts use R2. Apply backend migrations using the [VPS backend procedure](VPS_BACKEND.md), independently of auth migrations.

`scripts/prod-deploy-web-app.sh` builds the app, checks the bundle and production configuration, applies the auth D1 migrations, syncs the authentication secrets and deploys the edge; `scripts/prod-deploy-frontend.sh` deploys the public site separately. See [Test and deploy scripts](../operations/TEST_AND_DEPLOY_SCRIPTS.md). Review current workflow and configuration before deploying; local tests do not constitute deployment or device acceptance.

## GitHub sign-in

Configure GitHub OAuth for the production app callback `https://syntila.app/api/auth/callback/github`. Human sign-in uses identity scopes and does not grant repository access. Configure the client ID and secret as deployment secrets; never put credentials in the repository or browser bundle.

## Durable realtime stream alignment

Realtime streams and outbox rows belong to PostgreSQL. Apply forward-only backend migrations and verify the schema lock. See [Event Streams](../specifications/EVENT_STREAMS.md) for replay and recovery behavior and [Persistence](../specifications/PERSISTENCE.md) for retention.
