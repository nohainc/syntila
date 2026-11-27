# AX conditional reads v1

The stable read endpoints support optional HTTP content revisions:

- `GET /api/spaces/:id`
- `GET /api/spaces/:id/threads`
- `GET /api/workflows/catalog`

A normal response retains its existing JSON envelope and adds an `ETag` of the
form `"ax-read-v1-<sha256>"`. The hash covers the exact response representation,
including permissions, settings, Workflow versions, entity additions/deletions,
and collection order. Equal timestamps cannot hide changes. This is a content
revision, not an execution stream sequence or database version.

The caller can send `If-None-Match` with its retained tag. Unchanged resources
return `304 Not Modified` with zero body bytes. Changed resources return the
normal `200` JSON and a new tag. Weak validators and validator lists use HTTP
weak comparison; `*` matches an existing authorized representation. Both statuses
include `ETag`, `Cache-Control: private, no-cache`, and `Vary: Cookie, Authorization`.
See [HTTP conditional request semantics](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/If-None-Match).

Space authorization and existence checks run before revision comparison.
Thread revisions are computed after membership-specific permissions and
Space ordering are applied. Denied or missing resources never become `304`
responses. Workflow catalog publication remains on its existing public route.
The server still queries and constructs the authorized representation; this
change reduces response bandwidth, not database reads. No shared edge cache is added.
Hashing uses the Web Crypto API (`crypto.subtle`).

AX sends validators only for these three reads and retains their authoritative
JSON in a bounded, memory-only transport cache: at most 16 representations,
at most 1 MiB total UTF-8 body bytes, and at most 256 KiB per representation.
LRU eviction or oversized responses fall back to a normal read. `304` reuses the
retained JSON through the existing typed loader and sync engine. Unexpected `304`
without a current representation is an explicit read error. `401`/`403` and other
errors never return cached transport data as successful reads; the sync engine
continues showing its prior value with query error state.

Token changes, authenticated user changes, session clearing, and logout discard
validators. Generation fences prevent cleared-session responses from repopulating
the transport cache; request sequencing prevents an older successful response
from replacing a newer representation. Credentials, validators, and this transport
cache are never written to IndexedDB. Existing read-cache persistence is unchanged.

Discussion keeps its [paging contract v1](DISCUSSION_PAGING.md): latest 50 messages
by default, limits of 1–100, opaque before/after cursors, and one older page on
demand. Work Requests retain their existing cursor API and initial 50-row AX
head read. These paginated/volatile reads do not use the new validator cache and
never automatically traverse immutable history. The existing pagination and
request-deduplication tests remain required.

Compatibility is additive: old clients ignore the response headers; AX works
with servers that omit ETags. No database, persisted read-cache, or message schema
migration is required. The API bodies and `AxDataSource` signatures are unchanged.
