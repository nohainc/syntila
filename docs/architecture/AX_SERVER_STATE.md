# AX server state

How the Flutter web app (`apps/app`) holds, refreshes and recovers Cloud data.
The engine lives in `apps/app/lib/src/ax/sync/`; stores are composed in
`apps/app/lib/src/ax/ax_stores.dart` (`AxStore`). Cloud is authoritative. The
client keeps typed, cached, keyed queries, observes them locally, and never
treats a cache as authorization.

## Query engine

`AxQuery<T>` has a structural `AxQueryKey` (immutable parts compared by value,
so IDs containing colons cannot collide), a loader that wraps an existing
`AxDataSource` method, and a stale duration (default one minute). One result type
and stale duration per key.

| Operation | Behavior |
| --- | --- |
| `ensure` | `cacheFirst` returns any cached data; `cacheAndNetwork` returns cached data and revalidates if stale; `networkOnly` awaits the network. Missing data always fetches. |
| `refresh` | Forces a read and shares the outstanding Future (`supersede: true` starts a newer generation). |
| `invalidate` | Keeps data, marks an exact key or prefix stale, fences outstanding reads. Does not fetch. |
| `peek` / `watch` | Observe state. `watch` never fetches and has no root notifier; staleness is computed at observation time. |
| `mutate` | Optional optimistic value, commit of the authoritative result, or rollback. Only the latest generation may commit or roll back. |
| `remove` / `clear` | Reset state and fence late reads. Clear on logout or account change. |

Rules that hold everywhere:

- **Generations fence late writes.** A detached read still resolves for its
  caller but cannot write the cache. Reads are not physically cancelled.
- **Stale data stays visible.** A failed refresh keeps the last value and marks
  it stale; explicit reads and mutations propagate errors to their caller.
- **Single flight.** Concurrent callers of one key share one read.
- **Navigation never reloads bootstrap.** Routes change synchronously and ensure
  only the focused queries.
- **Loaders return data without side effects**, so detached responses cannot
  mutate entities.

## Query families

| Key | Owner | Notes |
| --- | --- | --- |
| `['space', id]` | `AxSpaceDetails` | `GET /spaces/:id`; nested Threads stripped. List summaries are only display fallbacks. |
| `['space', id, 'threads']` | `AxSpaceThreads` | The only source of sidebar rows and Thread resolution. Newest update first; invalid timestamps last. |
| `space:<id>:members`, `:invitations`, `:audit` | `AxSpaceTabQueries` | Only the selected Space tab is ensured. Audit is fetched only by an explicit consumer. |
| `['thread', id, 'discussion']` | `AxDiscussionCache` | Chat history; see below. |
| `['thread', id, 'work-requests']` | `AxWorkHistoryCache` | Work history; see below. |
| `['workflow-catalog']` (45 min), `['workers']` (30 s) | `AxSessionCatalogs` | Shared by shell, Thread pages and recovery. No polling. |
| `['user-workflow-configurations']` (45 min), `['space-workflow-configurations', id]` | `AxStore.workflowConfigurations` | See [User workflow configuration](../specifications/USER_WORKFLOW_CONFIGURATION_V1.md). Memory-only. |
| `['people']` | `AxPeople` | One cache for the People page and the invitation picker; see [People v1](../specifications/PEOPLE_V1.md). |

`loadBootstrapState()` loads the catalog, Workers and session once at start and
on explicit recovery. There is no snapshot object, no snapshot polling, and no
list-shaped history loader: consumers use cursor page methods. `AxStore.execution`
is a read-only legacy Run projection that cannot write collaboration caches.

## Chat and Work history

- **Chat.** Initial read is the newest 50 messages
  ([Discussion paging](../specifications/DISCUSSION_PAGING.md)). Scrolling to
  within 24 px of the top loads the previous 50, sharing one in-flight request
  and preserving the viewport. Synchronization catches up forward pages from the
  newest cursor, then reconciles the newest window so edits appear. Reconnect
  uses forward catch-up only. A failed sync shows the error with Copy and Retry
  and never the "No chat messages yet" empty state; cached messages stay visible.
- **Work.** `(createdAt, id)` cursor pages of 50, validated by the HTTP loader.
  Opening a Thread refreshes the head page, then reads details of active requests
  to restore Worker operations. Cursor frontiers let on-demand pagination fill a
  gap after a long absence. Immutable history is never traversed by polling or
  recovery.
- **Writes.** Optimistic sends and edits are per-message overlays; a rollback
  removes only its own layer. Pending temporary messages cannot be edited.
- **Clearing** calls Cloud first (`POST /api/threads/:id/chat/clear` and `POST .../work-history/clear`)
  and touches local state only after success. Remote
  `thread.chat_cleared` / `thread.work_cleared` events reset the same caches, and
  a Work detail 404 resets Work history for sessions that missed the event. Clearing AI
  History stamps the Thread with a cutoff and keeps the original requests (see
  [Conversation continuity](../specifications/CONVERSATION_CONTINUITY_V1.md)).

## Realtime

Transport is `syntila.messaging/1` ([realtime contract](../specifications/REALTIME_SYNCHRONIZATION.md),
[Work realtime](../specifications/WEB_WORK_REALTIME_V9.md)). Event handling is
independent of the selected Space.

- **`AxRealtimeCacheRouter`** receives the browser envelope before shell
  handlers. Space events revalidate registered Space queries; Thread events
  revalidate the owning Space's Thread list; Discussion events synchronize the
  keyed Discussion even if its page is gone (`discussion.created` follows forward
  pages, `discussion.updated` merges one message by ID). Unknown resources are not
  fetched eagerly, and event IDs are deduplicated.
- **`AxWorkRealtimeSync`** (one instance per history cache) reconciles Work
  events:

  | Event payload | Cache action |
  | --- | --- |
  | Known queued/running request or Step with enough status | Patch that entity |
  | Complete request payload | Merge it |
  | Created request not cached, terminal event, missing Step, retry of a terminal entity | One `GET /work-requests/:id`, merged for that request only |

  Per-entity revisions stop late reads from overwriting event state; a burst
  shares one pending detail read. Execution frames without a Work Request
  identity trigger no reads.
- **Health.** The client pings every 20 s and needs `realtime.pong` within 10 s,
  otherwise it marks the connection stale and reconnects. While healthy there is
  no polling. When reconnecting, disconnected, stale or after a replay gap, visible
  Thread scopes run a 15 s fallback that reads only active or recently changed
  requests; restoration runs one bounded discovery page (50) and resynchronizes
  known active requests by ID, then stops the timer. A retained request whose
  detail returns 404 is removed individually.
- **Scoped recovery.** `AxSyncScope` resolves the gap scope (explicit scope,
  else the stream identity). `AxSyncEngine.invalidateScope` marks entries stale and
  fences reads while retaining data; immutable cursor pages are excluded.

  | Gap scope | Recovery |
  | --- | --- |
  | Space | Space details and its Thread list |
  | Thread | Forward Discussion pages; active Work discovery and known active requests by ID |
  | Worker | Worker state and inventory |
  | User / ready | Observed migrated queries and catalog; People; no bootstrap reload |

  Malformed narrow scopes never cause broad recovery. Cloud replay is cursor-aware
  and limited to 256 rows; a full page emits a scope-wide `sync.required`.
- Invitation and membership signals for non-members use the recipient's durable
  `user` stream; they grant no Space access. `worker.inventory.*` signals
  revalidate only the global Worker query. `invalidateWorkflows()` is the hook for
  catalog publication.

## Lifecycle, retention and persistence

- **Lifecycle** (`AxLifecycleSync`). When the document becomes visible or the
  network returns, active stale queries revalidate through their existing
  loaders. Fresh queries, inactive histories and immutable pages are skipped;
  nothing is cleared. A narrow banner reports background refresh, offline, or
  stale-after-failure, independent of the WebSocket notice.
- **In-memory retention.** The engine keeps the 20 most recently accessed Thread
  histories (Discussion, Work and pages together) and at most 200 rows per inactive
  collection. Visible, in-flight and optimistic histories are protected; the limit
  is soft while they exceed it. Eviction releases cursor and reconciliation
  metadata, and a revisit fetches one recent page. Spaces, Thread lists and the
  catalog are not evicted; unobserved `run:*` entries expire after 5 idle minutes.
- **Browser read cache** (`AxPersistentReadCache`, IndexedDB `syntila-read-cache-v1`,
  web only, disabled by `AX_PERSIST_READ_CACHE=false`). Keyed by the authenticated
  user. It stores versioned, allowlisted read DTOs (Spaces, Threads, Space detail,
  recent Chat and Work, catalog, Worker summaries) for the 20 most recent
  histories and at most 50 rows each. It never stores sessions, tokens, security
  data, grants, mutation keys, optimistic entities or Workflow preferences. All
  restored data is stale and revalidated; hydration cannot overwrite newer data.
  Logout clears memory and the user's records, and a revision tombstone stops other
  tabs from repopulating. Storage failure falls back to memory.
- **Local Thread view state** (separate browser namespace). Active tab, selected
  Workflow and Worker/model/effort, and Chat/Work drafts. Never sent to Cloud;
  restored choices are reconciled with the current catalog and ignored when stale.
  Appearance (Light/Dark/System) is stored in `syntila-theme-v1`.
- **Conditional reads** ([conditional reads v1](../specifications/AX_CONDITIONAL_READS.md)).
  Space detail, Space Threads and the Workflow catalog send the last ETag on
  revalidation; `304` is treated as a fresh read. The validator cache is
  memory-only, bounded and cleared at logout.

## Mutations and idempotency

`AxMutationRunner` runs `optimisticUpdate → execute → commit | rollback →
invalidate` once; there is no retry queue or offline replay. Optional mutation
keys reject simultaneous writes to one entity. `AxCollaborationMutations`
coordinates Space and Thread writes: temporary entities appear immediately and are
replaced by server IDs, and rollback preserves newer canonical data.

Work Request creation, Discussion sends and Thread creation send an opaque
`Idempotency-Key` ([mutation idempotency](../specifications/MUTATION_IDEMPOTENCY.md)).
The key survives response loss and view destruction (memory only) and is reused
only when the user explicitly retries unchanged input. Work submission lives in
`AxWorkHistoryCache`, so it survives view disposal: a successful POST is followed by
a targeted read, a failed read never rolls back accepted work, and a lost response
is reported as "status unknown". An explicit retry skips the browser eligibility
preflight; Cloud still authorizes it and recognizes a committed receipt. Reconnect,
polling and navigation never repeat the POST.

## Sidebar, activity and personal data

- **Grouping.** Spaces with viewer role `owner` appear under Your spaces, others
  under Shared with you (the server's `role` field is the source). Pinned Spaces
  lead without a heading. The expanded sidebar defaults to 200 px (200–300 px,
  session-local); phones use a full-width list instead of a drawer.
- **Activity.** Space and Thread reads return `hasActiveWork` (a request queued,
  running or waiting and updated within a day) and `hasUnread`, computed per user
  from `thread_read_states` (Space values aggregate). `POST` on the Thread read
  route advances the marker and publishes a recipient-scoped `thread.updated`; the
  app marks the open Thread read after 1 s while visible. Running takes priority
  over unread. Other Threads' events refresh lists in one 400 ms trailing batch.
- **Notifications.** `GET /api/notifications` derives finished Work Requests from
  the last 14 days (max 50, the caller's own successes excluded), with read markers
  in `user_notification_reads`. The app merges the feed with live events under
  `work-request:<id>`; desktop alerts are opt-in.
- **Pins** are per user (`user_pins`: kind, target, `pinnedAt`, `position`), idempotent
  `PUT`/`DELETE /api/pins/:kind/:targetId`, reorder with `PUT /api/pins/order`.
  Pins affect ordering only; archived Threads ignore them.
- **Private notes** (`user_notes`, optimistic `revision`; a stale update gets 409).
  A note may link to a Thread without a foreign key, so deleting or leaving the
  Thread detaches the note instead of deleting it. Notes are never published as
  events or included in Worker context. Per-Thread note: `GET`/`PUT /api/threads/:id/note`.
- **Persisted Thread view state.** `threads.metadata_json` stores the caller's
  choices under `metadata.viewStates[userId]`, exposed as `metadata.viewState`
  (`tabIndex`, `workflowReference`, `workerId`, `workerTypeId`, `model`,
  `reasoningEffort`, `catalogRevision`, `selectionUpdatedAt`). Patching it does not
  change `updatedAt`. Restore: re-bind a vanished Worker by `workerTypeId` only when
  exactly one of the viewer's Workers has that type; a superseded Workflow
  resolves to its current version; a missing one falls back to the default
  Workflow but keeps the Worker and model. Cloud wins on reopen unless the local
  `selectionUpdatedAt` is newer. Space settings (`spaces.settings_json`) hold
  `threadOrder`, `sidebarExpanded` and `color`, and only the owner writes them.
- **Workflows page** (`/workflows`, user-wide). Shows the newest version per
  catalog ID; regular accounts see only the implemented `chat` and Work workflows
  (a presentation filter; Cloud authorizes execution). Save and reset commit the
  API result to the shared query; concurrent writes are rejected; a Space override
  replaces the owner's global default per whole workflow; only the owner edits,
  other members view the effective configuration.

## Testing

Executable behavior lives in `apps/app/test`: `ax_sync_engine_test.dart`,
`ax_space_cache_test.dart`, `ax_space_navigation_test.dart`,
`ax_space_lazy_tabs_test.dart`, `ax_discussion_cache_test.dart`,
`ax_work_history_test.dart`, `ax_work_realtime_sync_test.dart`,
`ax_realtime_cache_router_test.dart`, `realtime_health_test.dart`,
`ax_snapshot_polling_test.dart`. They hold responses
pending to prove cached first frames, shared in-flight reads and generation
fencing, and count data-source calls rather than latency. Run the focused file
from `apps/app` with `flutter test test/<file>`.
