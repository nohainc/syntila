# Cloudflare Access for non-production environments

Cloudflare Access is optional infrastructure protection for staging,
administrative, debug, and other internal environments. It is not the human
authentication boundary for production AX. Production users sign in through
Better Auth at `/api/auth/*`, and Syntila resolves that session to its own
Connect and authorization model.

## Configure Access

1. Deploy the Worker and static app on the internal hostname.
2. In Zero Trust, create an Access application for that internal hostname.
3. Protect only the intended staging, admin, debug, or internal routes and
   keep the policy scoped to the appropriate operators.
4. Keep production AX public and verify that disabling this Access
   application does not affect Better Auth login or Syntila authorization.

## Machine-to-machine API calls

Machine and CI calls use their explicitly scoped Syntila credentials. Access
service tokens may protect separate internal administration routes, but they
are not converted into human identities and are not accepted by the
production application-auth path.

## Local development

Local manual development can use the explicit `/api/dev/sign-in` helper. It is
available only when `SYNTILA_ENVIRONMENT=development` and redirects into the
normal Better Auth GitHub or Google flow; it does not synthesize a user or
session. Automated tests inject a test authentication function instead.

For an authenticated local Access simulation, Wrangler supports an `access.dev`
configuration with a test identity. Keep that configuration local and do not
use it as a substitute for Better Auth in production.

## Deployment checks

The app deployment scans the compiled Flutter web directory and fails if server
authentication names are present. Flutter receives only `SYNTILA_API_URL`;
human session credentials are never passed through `--dart-define`.
