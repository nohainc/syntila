# Discussion paging contract v1

`GET /api/threads/:id/discussion-messages` authorizes access on every request and
returns bounded pages. `limit` defaults to 50 and accepts integers from 1 to
100. `before` and `after` are mutually exclusive opaque cursors.

Without a cursor, the endpoint returns the newest messages. `before` returns
older messages; `after` returns newer messages. Every response orders messages
chronologically by `(created_at, id)`, including equal timestamps.

```json
{
  "schemaVersion": 1,
  "messages": [],
  "nextCursor": null,
  "newestCursor": null
}
```

`nextCursor` continues in the requested direction and is null when that page
has no continuation. `newestCursor` identifies the newest returned message;
an empty forward page retains its incoming anchor. Cursors encode version 1,
Thread identity, creation timestamp, and message ID. They are pagination
positions, not authorization tokens. Malformed, unsupported, cross-Thread,
or conflicting cursors and invalid limits produce HTTP 400. All cursor values
are bound SQL parameters. Clients must treat cursors as opaque.

The paging envelope and authored Markdown semantics remain unchanged. The AX
and Cloud changes should ship together: AX requires the versioned envelope.
`AxDataSource.loadDiscussionPage` exposes this contract; custom Dart data sources
must implement it. The retained `loadDiscussionMessages` method now returns the
newest page, rather than unbounded history. AX loads additional history through
scroll-triggered pagination. Reconnects with a known newest cursor fetch only
forward pages and never refetch loaded older pages. Reopening additionally
reconciles the newest window for edits; creation-order cursors do not track edits.

Realtime contract 1.1 adds ID-only `discussion.created` and `discussion.updated`
[signals](REALTIME_SYNCHRONIZATION.md). Creation uses the existing forward cursor.
For edits, `GET /api/discussion-messages/:id` returns `{ message }` after current
Thread view authorization (404 when missing; access denied when unauthorized).
It preserves authored Markdown and returns parsed references. AX
`loadDiscussionMessage(messageId:)` merges that single entity when already cached,
including in older pages, without changing either pagination cursor. Custom AX
data sources must implement the lookup. The paging envelope remains version 1.

## Human message attachments

Discussion create accepts an additive `attachments` array of uploaded file
references (`kind: "file"`, `fileId`, `sizeBytes`). Up to ten files, each within the
uploader's plan file limit (Free 25 MB, Plus 100 MB; ADR-025), are allowed, including file-only messages with an empty body. Every reference
must match the uploading user, Thread and size. Server-owned names, media types
and bounded display previews are loaded from private R2. The existing upload
endpoint accepts `purpose=discussion` to require discussion permission instead
of AI execution permission. Draft Thread creation retains its existing text-only
message flow; attach files after the Thread exists. Message mode places a +
control grouped with the emoji and Markdown controls on the left of the same
toolbar row, with Send aligned to the right. It opens the same
anchored Add files menu as Ask AI; no separate attachment row is shown.

Migration `0080_discussion_attachments.sql` adds `attachments_json` with an empty
array default. Create, list and single-message responses return attachments;
caption edits preserve them. The AX message cache, optimistic send, retry identity
and optional persisted read cache retain attachments. Failed sends restore files
without discarding newer draft attachments; if recovery leaves more than ten,
the user must remove files before resubmitting. New clients treat missing arrays as empty; older clients
ignore additive response fields. Apply the migration before deploying Cloud.

Cards and download authorization share the [Work attachment contract](WORK_V1_CONTRACT.md#work-request-attachments).
Thumbnails are presentation only and never assert that a Worker supports a file
format. Removal from a draft does not delete previously uploaded server objects.
