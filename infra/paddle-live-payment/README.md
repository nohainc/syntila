# Paddle live payment link (prepared, not deployed)

This isolated Worker serves Paddle transaction and payment-method-update links.
It is based on the sandbox payment-link page but accepts only a `live_` Paddle
client-side token and never switches Paddle.js to sandbox. The token is public;
never put an API key or webhook secret in this Worker. Missing or invalid token
configuration fails closed. No route or token is configured here.

Before deployment, choose an approved domain and route that does not replace
an existing site. The live checkout domain must be approved by Paddle. Configure
`PADDLE_LIVE_CLIENT_TOKEN` at deployment, deploy the Worker, verify the page and
transaction-link behavior, and only then set the exact deployed URL as Paddle's
default payment link. Do not use the sandbox URL. The link page alone does not
implement account checkout or subscription fulfillment; production billing must
remain closed until those paths are implemented and verified.
