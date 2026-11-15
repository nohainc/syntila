# Backend API contract

What every endpoint of `api.syntila.app` shares. Implemented in
`apps/backend/src/domain/routes/api-contract.ts` and applied once in
`domain/index.ts`. The route list is in [ROUTES.md](ROUTES.md).

## Errors

Every JSON error response has this shape:

```json
{ "error": "Space not found", "code": "not_found", "requestId": "…" }
```

- `code` is the stable, machine-readable part. **Clients branch on `code`.**
- `error` is text for people and may be reworded at any time.
- `requestId` equals the `x-request-id` response header; quote it in support
  requests and search the logs for it.
- Extra fields (for example `retryAfterSeconds`) may be present.

A handler that knows a specific reason sets its own code
(`workspace_offline`, `paid_plan_required`, `personal_workspace_limit_reached`, …).
Otherwise the code follows the status:

| Status | Code | Status | Code |
| --- | --- | --- | --- |
| 400 | `bad_request` | 413 | `payload_too_large` |
| 401 | `unauthenticated` | 415 | `unsupported_media_type` |
| 402 | `payment_required` | 422 | `unprocessable` |
| 403 | `forbidden` | 429 | `rate_limited` |
| 404 | `not_found` | 500 | `internal_error` |
| 409 | `conflict` | 503 | `unavailable` |

Only deliberate errors reach the client with their own text: a handler
throws `HttpError(status, message)` (optionally with a `code`). A body that
is not JSON is answered with `400 invalid_json`. Every other exception,
database failures included, is answered with `500 internal_error` and a
generic message; the real error and its stack are in the server log as
`http.unhandled_error`, findable by `requestId`.

A handler that wants the client to see a validation message must therefore
throw `HttpError(400, …)`, never a plain `Error`.

## Version

Every response carries `x-syntila-api: 1`. The number changes only when a
request or response shape changes incompatibly. Additive changes (new
fields, new endpoints, new error codes) do not change it, so clients must
ignore unknown fields and treat unknown codes by their status.

## Rate limits

Per caller (the credential, or the client address when there is none):
3000 requests and 600 mutating requests per minute, with a burst of a
quarter of that. Over the limit: `429`, code `rate_limited`, a
`retry-after` header and `retryAfterSeconds` in the body. Connected
Workspace traffic (`/api/workspace-runtime/*`) and the realtime socket are
exempt. Configure with `SYNTILA_RATE_LIMIT_PER_MINUTE` and
`SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE` (0 disables).

Limits are kept in the memory of the one backend process. A second
backend process would need a shared store.

## Not yet uniform

- Request validation is hand-written per handler.
- List endpoints do not share one pagination shape.
- Idempotency keys are honoured only where a handler implements them.
