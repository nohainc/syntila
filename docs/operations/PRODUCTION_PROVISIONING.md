# Production provisioning

Provision the auth edge, PostgreSQL backend and artifact storage according to the current configuration and deployment workflows. The Cloudflare D1 database is auth-only (`syntila-auth`); product data belongs to the backend's PostgreSQL. The artifact bucket and its access configuration are specified by the current deployment configuration. Never store credentials in the repository.

`scripts/migrate-production-d1.sh` applies the auth D1 migrations before the edge is deployed. Product schema changes use ordered, forward-only PostgreSQL migrations and `schema.lock`, as described in [Persistence](../specifications/PERSISTENCE.md#schema-lifecycle) and the [VPS backend guide](../deployment/VPS_BACKEND.md). Review pending migrations and configuration before a production rollout.

Production readiness also requires the device, real-provider, and security evidence listed in [ROADMAP](../../ROADMAP.md). A successful local check does not establish production readiness.

## Release secrets

`scripts/prod-deploy-web-app.sh` and `scripts/prod-status.sh` read these names from the shell environment or from `~/.config/syntila/prod.env` (outside the repository; `prod-lib.sh` sources it when present; `chmod 600` it). Never commit them and never print them. A missing name stops the deploy with the list of missing names.

| Name | Where it comes from |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens (Workers and D1 edit). |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard → Workers & Pages → Account ID. |
| `BETTER_AUTH_SECRET` | Random 32+ byte secret generated once (`openssl rand -base64 32`); changing it signs everyone out. |
| `SYNTILA_AUTH_GITHUB_CLIENT_ID`, `SYNTILA_AUTH_GITHUB_CLIENT_SECRET` | GitHub → Settings → Developer settings → OAuth Apps. |
| `SYNTILA_AUTH_GOOGLE_CLIENT_ID`, `SYNTILA_AUTH_GOOGLE_CLIENT_SECRET` | Google Cloud Console → APIs & Services → Credentials. |

Optional settings: `PROD_VPS`, `PROD_STAGE`, `PROD_API_URL`, `PROD_APP_URL`, `SYNTILA_API_URL`.
