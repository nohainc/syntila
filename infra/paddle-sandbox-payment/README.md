# Paddle sandbox payment link

This isolated Worker serves Paddle's sandbox default payment link at
`https://sandbox.syntila.app/checkout/`. It initializes Paddle.js in sandbox
mode and supports Paddle transaction links. It is not a live checkout and
does not provide the webhook endpoint.

The Worker requires a sandbox client-side token (`test_...`). The token is
public by design, but the server API key and webhook signing secret must
never be supplied to this Worker. A missing or non-sandbox token fails closed.
The empty token in `wrangler.jsonc` is intentional: deploying without the
override disables the page. Deploy from this directory with the sandbox
client-side token in the environment:

```sh
WRANGLER_WRITE_LOGS=false ../../node_modules/.bin/wrangler deploy \
  --var "PADDLE_SANDBOX_CLIENT_TOKEN:$PADDLE_SANDBOX_CLIENT_TOKEN"
```

For local testing, place `PADDLE_SANDBOX_CLIENT_TOKEN` in an ignored
`.dev.vars` file in this directory, then run `wrangler dev --local`. Run the
focused checks with `node --test worker.test.mjs`. The separate local webhook
tunnel and end-to-end verification are described in
`docs/operations/PADDLE_SANDBOX.md`.
