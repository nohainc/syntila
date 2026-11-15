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

## Routes

Every route is one line in `apps/backend/src/domain/routes/table.ts`: method,
path with `:name` parameters (URL-decoded before they reach the handler) and
handler. [ROUTES.md](ROUTES.md) is generated from it (`bun run routes` in
`apps/backend`); a test fails when it is stale.

- Unknown path: `404 not_found`.
- Known path, unsupported method: `405 method_not_allowed` with an `Allow`
  header listing the methods the path accepts.

## Request validation

Bodies are read with `readBody(request, Schema)`
(`apps/backend/src/domain/routes/validation.ts`) against schemas in
`packages/protocol/src/api-requests.ts`. A body that is not JSON answers
`400 invalid_json`; a body that does not fit the schema answers:

```json
{
  "error": "name is required",
  "code": "invalid_request",
  "details": [{ "path": "name", "message": "name is required" }],
  "requestId": "…"
}
```

`error` repeats the first problem; `details` lists all of them.

Converted so far: `POST /api/spaces`, `POST /api/notes`, `PUT /api/notes/:id`,
`POST /api/people/invitations`. Other handlers still validate by hand with
`HttpError(400, …)` and move to schemas as they are changed.

## Pagination

List endpoints that can grow without bound use one shape:

- Request: `?limit=N&cursor=<opaque>`. `limit` is checked against the
  endpoint's maximum (`400` otherwise).
- Response: the list under its usual key plus `nextCursor` (a string, or
  `null` on the last page). Pass it back unchanged as `cursor`. An invalid
  cursor answers `400 invalid_cursor`.
- Order is newest first; ties on the timestamp are broken by id, so pages
  never skip or repeat an item.

| Endpoint | Default / max `limit` |
| --- | --- |
| `GET /api/notes` | 500 / 500 |
| `GET /api/spaces/:spaceId/audit` | 100 / 200 |
| `GET /api/files` | 100 (fixed) |

Discussion messages take `cursor` for older pages; `after` (a message id)
still fetches newer messages. Files and discussion messages still accept
their old `before` parameter until the app release that sends `cursor` is
everywhere; it will then be removed. Work Requests
(`beforeCreatedAt`/`beforeId`) and conversation history (`afterSequence`)
keep their own parameters for now, because the app stores those positions
in its offline cache.
Lists bounded by what one person can see (Spaces, Threads, members,
Workspaces, people) are returned whole. Notifications are a bounded feed.

## Idempotency

Create endpoints accept an `Idempotency-Key` header (16–128 characters of
`A-Z a-z 0-9 _ -`). Keys are per user and per endpoint.

- A retry with the same key and the same body returns the first response
  with `Idempotency-Replayed: true`; nothing is created twice.
- The same key with a different body: `409 idempotency_key_reused`.
- A retry while the first request is still running:
  `409 idempotency_in_progress`. A claim abandoned for more than five
  minutes (crashed request) is taken over.
- Only successful (2xx) responses are remembered; after an error the same
  key can be used again. Receipts are kept for 30 days.

Endpoints: `POST /api/spaces`, `/api/spaces/:spaceId/invitations`,
`/api/spaces/:spaceId/threads`, `/api/threads/:threadId/discussion-messages`,
`/api/threads/:threadId/work-requests`, `/api/notes`, `/api/people/invitations`,
`/api/issue-reports`, `/api/admin/issue-reports/groups`, and
`/api/threads/:threadId/work-history/clear`. ROUTES.md marks them.
