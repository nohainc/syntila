# Production provisioning

Provision the auth edge, PostgreSQL backend and artifact storage according to the current configuration and deployment workflows. The Cloudflare D1 database is auth-only (`syntila-auth`); product data belongs to the backend's PostgreSQL. The artifact bucket and its access configuration are specified by the current deployment configuration. Never store credentials in the repository.

`scripts/migrate-production-d1.sh` applies the auth D1 migrations before the edge is deployed. Product schema changes use ordered, forward-only PostgreSQL migrations and `schema.lock`, as described in [Persistence](../specifications/PERSISTENCE.md#schema-lifecycle) and the [VPS backend guide](../deployment/VPS_BACKEND.md). Review pending migrations and configuration before a production rollout.

Production readiness also requires the device, real-provider, and security evidence listed in [ROADMAP](../../ROADMAP.md). A successful local check does not establish production readiness.
