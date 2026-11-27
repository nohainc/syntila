# Paddle sandbox test

This flow is for a local development backend and a separate Paddle sandbox
account. It does not enable live billing. The local plans page links to
`http://localhost:3000/paddle-sandbox.html` in a debug web build.

Set the `PADDLE_SANDBOX_*` values listed in `.env.example` in the backend
environment or in `.development/local-backend/paddle.env` (one `KEY=value`
per line, readable only by the developer). The client token must start with
`test_`; the two price IDs must belong to the sandbox. The reference secret
must be at least 32 characters, must be kept private and stable, and must not
be reused in production. The webhook secret is the signing secret for the
sandbox notification destination, not a Paddle API key. The separate sandbox
API key needs only `customer_portal_session.write` for portal access. Restart
the local backend after changing these values. Apply migrations before testing.

Configure the sandbox destination to send subscription lifecycle events to
`/api/billing/sandbox/webhook` through a publicly reachable HTTPS endpoint.
For local testing, restrict forwarding to that exact path and method. A quick
tunnel has a temporary URL and must be updated in Paddle when it changes; it
is not suitable for production. Verify an invalid signature receives a 401.
For example, start `node scripts/local-paddle-sandbox-forwarder.mjs`, then run
`pnpm exec wrangler tunnel quick-start http://127.0.0.1:18789`. Append the
webhook path above to the tunnel URL in the existing sandbox destination.

Sign in locally, open the sandbox checkout, and use Paddle's published test
card. Confirm the transaction succeeds and a verified notification updates
the corresponding local account. Do not infer access from the browser's
checkout completion event. The sandbox default payment link is
`https://sandbox.syntila.app/checkout/`, a separate sandbox-only Worker that
initializes Paddle.js for transaction links. See
`infra/paddle-sandbox-payment/README.md` for deployment instructions.

The local sandbox page can open Paddle's customer portal for the authenticated
account. Production billing is not implemented. Live deployments must not use
the sandbox endpoints or secrets.

## Live preparation

The backend includes a disabled-by-default live checkout configuration endpoint
(`/api/billing/live/checkout-config`). It authenticates the production user,
validates separate live token and price configuration, and signs an account
reference with a production-only secret. The endpoint is not a complete live
billing integration: production subscription notifications, fulfillment,
customer portal, and the customer-facing checkout are not implemented.
**Do not set `PADDLE_LIVE_CHECKOUT_ENABLED=true` or accept live purchases until
those paths and the deployment have been verified end to end.** The sandbox
endpoint and sandbox settings stay separate.
