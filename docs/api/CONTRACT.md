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
(`worker_offline`, `paid_plan_required`, …).
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
is not JSON is answered with `400 invalid_json`. Two database outcomes of
parallel requests are answered as such, without internals: a unique
violation (something was created at the same moment) or a foreign-key
violation (what it belongs to was just deleted) is `409 conflict`, and
a lock, deadlock or serialization timeout is `503 busy` (retry). Every other
exception, database failures included, is answered with `500 internal_error`
and a generic message; the real error and its stack are in the server log as
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
Connect traffic (`/api/workspace-runtime/*`) and the realtime socket are
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

Every route that takes a JSON body reads it this way. A wrong-typed or
over-limit field is `400 invalid_request`, never ignored; field limits are
checked before the 2 MiB body cap matters, which answers `413
payload_too_large`. Some handlers keep a fixed message for a rejected body
(for example `Invalid folder selection`); the code is still `invalid_request`
and `details` still lists every problem. The Connect runtime and desktop
registration routes and the plugin routes keep their own error JSON (`code` such
as `invalid_installation_id`, or the plugin route codes) because the desktop
client reads them.

The one free-form body is `POST /api/workspaces/:id/mcp-action`: an object
forwarded verbatim to the Connect gateway, which owns that contract. The
guard in `apps/backend/test/domain/request-body-guard.test.ts` allows no other
route to read a body without a schema.

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
| `GET /api/threads/:threadId/work-requests` | 100 / 100 |
| `GET /api/threads/:threadId/discussion-messages` | 50 / 100 |
| `GET /api/threads/:threadId/conversations/:conversationId/history` | 50 / 100 |

Every list takes its next page as `cursor`; there are no other paging
parameters. Two lists differ in direction:

- Discussion messages also take `after` (the `newestCursor` of a page) to
  read newer messages; `cursor` and `after` cannot be combined.
- Conversation history is oldest first. The first page fixes the end of
  the history (`throughSequence`); its cursors keep reading that snapshot
  while new entries are appended.

Timestamp cursors (notes, Space audit, files, Work Requests) are
`base64url(JSON [createdAt, id])`. Clients pass them back unchanged; the
one exception is the app's Work history, which keeps positions in its
offline cache and may build the cursor that pages after a request it holds.
Lists bounded by what one person can see (Spaces, Threads, members,
Workers, people) are returned whole. Notifications are a bounded feed.

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
