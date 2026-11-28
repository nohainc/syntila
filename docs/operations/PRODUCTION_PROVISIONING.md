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

Connect release builds (`scripts/prod-build-connect-*.sh`) also need `SYNTILA_PROFILE_TRUST_ROOTS` (public Profile roots; falls back to the GitHub variable via `gh`). The value must be a flat JSON map of key IDs to public keys; nested publisher maps are rejected. `SYNTILA_RELEASE_TRUST_KEYS_JSON` is a separate publisher-scoped configuration and is not a fallback for Connect. Publishing Connect releases also requires `SYNTILA_RELEASE_R2_ACCESS_KEY_ID` and `SYNTILA_RELEASE_R2_SECRET_ACCESS_KEY` for an R2 Object Read & Write token limited to the public `syntila-releases` bucket. `SYNTILA_RELEASE_R2_BUCKET` optionally overrides the default bucket name. The private application artifact bucket must remain separate. Publishing to APT needs the repository signing key in your gpg keyring or `SYNTILA_APT_PRIVATE_KEY_FILE`, and optionally `SYNTILA_APT_SIGNING_FINGERPRINT`; the Homebrew tap needs `gh` logged in with write access to `nohainc/homebrew-tap`.

Optional settings: `PROD_VPS`, `PROD_STAGE`, `PROD_API_URL`, `PROD_APP_URL`, `SYNTILA_API_URL`.

## Profile signing identity

Connect must trust the public half of the backend signing key. For an existing base64-encoded 32-byte Ed25519 seed, save the public GitHub trust-root JSON to a local file, then run:

```sh
node scripts/profile-signing-env.mjs /path/to/seed.base64 /path/to/public-trust-roots.json KEY_ID --verify-only
node scripts/profile-signing-env.mjs /path/to/seed.base64 /path/to/public-trust-roots.json KEY_ID --output /path/to/new-private-env
```

The script checks the public key before writing a new owner-only file and refuses to overwrite an existing file. It accepts the flat `SYNTILA_PROFILE_TRUST_ROOTS` mapping. The output contains the private key: transfer it securely, add its two assignments to the protected `/etc/syntila/backend.env` on the VPS, and securely remove temporary copies. Preserve existing configuration and restrict access to the file. Restart `syntila-backend` after updating it. Verify Profile delivery with a released Connect client. A new signing key requires distributing its public root in Connect builds before using it.

## Profile signing key ID rollout

Use `syntila-profile-v1` for the current Profile signing key. Configure the GitHub repository or Windows release environment variable `SYNTILA_PROFILE_TRUST_ROOTS` as a flat JSON map, for the current production key as `{"syntila-profile-v1":"JWm4CR8Sfke3q60SaD1AP8QhEH8ISmAWlUi6C/+zEOY="}`, using the public key that corresponds to the existing backend private JWK. Remove any stale local `SYNTILA_PROFILE_TRUST_ROOTS` override or update it to the same value; local overrides take precedence over GitHub. Keep the separate publisher-scoped `SYNTILA_RELEASE_TRUST_KEYS_JSON` unchanged unless its own consumers require a change.

Build and publish a new Connect version on all platforms using that flat map. Change only `SYNTILA_PROFILE_SIGNING_KEY_ID` to `syntila-profile-v1` in `/etc/syntila/backend.env` and restart the backend after the new clients are available; preserve the existing private JWK. Until backend and clients use the same ID, Profile downloads fail closed. Existing clients that trust only the old ID must upgrade; users of the broken 0.1.0 release must upgrade too. Reconnect Workers and refresh models to verify. No database migration or re-pairing is required. Roll back by restoring the old backend key ID and using clients built with the old flat trust map. On a future actual key rotation, use a new ID and coordinate rollout separately.

## First-release rehearsal

Run on the dev machine (the Mac) from a clean `main` equal to `origin/main`. Commands are exactly these.

1. **Prerequisites on the VPS** (asks for the sudo password; prints no secrets):
   `ssh -t syntila@46.225.103.109 'psql --version; systemctl is-active postgresql caddy syntila-backend syntila-monitor.timer; sudo grep -c . /etc/syntila/backend.env; sudo grep SYNTILA_PROFILE_SIGNING_KEY_ID /etc/syntila/backend.env'`
   PostgreSQL must be 16 or newer. The printed key id must be the one in the GitHub variable `SYNTILA_PROFILE_TRUST_ROOTS` (`gh variable list`), otherwise Connect refuses every Profile.
2. **State:** `scripts/prod-status.sh`, then `scripts/prod-migrate-db.sh status` (the migration list needs the sudo password; run it in a terminal).
3. **Plan, then release:** `scripts/prod-deploy-all.sh --site --dry-run`, then `scripts/prod-deploy-all.sh --site`. Note the deployed commit from the first line of each script's output.
4. **Smoke test** (a clean sign-up; tick each item):
   - [ ] Sign up with GitHub; sign out; sign up with Google (a second account).
   - [ ] Create a Space and a Thread.
   - [ ] Add a Worker and copy the pairing code.
   - [ ] On Windows, install the Connect release (see [Connect onboarding](CONNECT_ONBOARDING.md)) and pair with the code; the Worker shows "ready".
   - [ ] Chat: send a message and get an answer.
   - [ ] Work with a Space folder (`syntila-connect folders add PATH`) and an attached file.
   - [ ] Start a long request and cancel it; the request ends as cancelled.
   - [ ] With Connect online run `scripts/prod-deploy-backend.sh --yes`; Connect reconnects without a restart (`syntila-connect status`) and the next Chat works.
5. **Resilience:** on the VPS (the VPS installer in `infra/vps/phase5` put the script there):
   `ssh -t syntila@46.225.103.109 'sudo bash /usr/local/lib/syntila/run-resilience-test.sh'`
   It restarts the backend and PostgreSQL several times with a temporary signing key and removes the key afterwards.
6. **Defects:** fix each one in the scripts or these docs as a small commit, then repeat the failed step.

Reset instead of repair while the app is not live: `scripts/prod-reset-db.sh --i-understand-this-deletes-all-data`.
