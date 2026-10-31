# AX server state — Phases 1–24

The in-memory server-state API lives in `apps/app/lib/src/ax/sync/`.
Cloud remains authoritative. Phase 1 introduced the isolated engine. Phase 2
integrated Space Thread collections into navigation and the sidebar.
Phase 3 adds focused Space details and separates navigation from bootstrap.
Phase 4 moves paginated Discussion history and optimistic writes into shared state.
Phases 5–6 add scroll pagination and infinite Work history. Phase 7 routes Work
events into individual cached requests and uses polling only during realtime
outages. Other resource UI migrations, persistence, and cache retention limits
belong to later phases.

## Query contract

Create `AxQuery<T>` with a structural `AxQueryKey`, an existing data-source
method as its loader, and a nonnegative stale duration (default: one minute).
Use one result type and stale duration per key; incompatible definitions fail.
Key parts are immutable and compared structurally, so IDs containing colons
cannot collide. Resource-specific keys and loaders remain at the integration
boundary rather than in the transport-independent engine.

- `ensure`: `cacheFirst` returns any cached data; `cacheAndNetwork` returns
  cached data immediately and revalidates only if stale; `networkOnly` awaits
  the network. Every policy fetches if data is missing.
- `refresh`: forces a read, sharing the outstanding Future by default.
  `supersede: true` starts a newer generation explicitly.
- `invalidate`: retains data, marks an exact key (or structural prefix) stale,
  and fences outstanding reads. It does not fetch by itself.
- `peek`: returns an immutable state observation and records access time.
  `hasData` distinguishes missing data from a valid nullable result.
- `watch`: subscribes only to a query, optionally delivers its initial state,
  and returns an idempotent cancellation function. It does not fetch. No root
  notifier exists. Staleness is calculated at observation time, without timers.
- `mutate`: optionally publishes optimistic data, fences previous reads,
  commits the authoritative result, or rolls back on failure. Only the latest
  query generation may commit or roll back. Indirectly affected queries must
  be invalidated by the integration after success.
- `remove` and `clear`: reset cached state and fence late reads/mutations.
  Active subscriptions remain attached to empty entries for subsequent loads.
  Entries without subscriptions are removed. Clear on session/account changes.

Detached reads still resolve/reject for their original callers; they cannot
write into the cache. Requests are not physically canceled. Background read
errors are captured in query state, while explicit reads/mutations propagate
errors to their callers. Refresh errors preserve useful data and mark it stale.
Observers cannot corrupt a successful operation; listener exceptions are
reported to the current Dart Zone.

## Normalization and realtime

`AxEntityStore<T>` supplies typed ID-indexed tables and immutable collection ID
lists. Use separate tables for Spaces, Threads, and other entity types.
Replacing P2's collection preserves P1's IDs and entities. Removed collection
members stay in the entity table until explicitly removed/cleared. This phase does not wire
normalization into existing screens. Future normalized-query integration must
apply entity writes only after generation validation; loaders should return
data without mutating the table, because detached responses must not write
entities. UI observations must go through the
engine's query listeners, not direct entity-table mutation notifications.

`AxRealtimeSync` accepts deduplicated affected query keys for targeted
invalidation. Actual Cloud event mapping/subscriptions and patch semantics are
left to the later realtime integration phase.

Optimistic callbacks should treat cached values as immutable. Mutations are
not server-side serialized: the engine protects local cache commits, while
Cloud still validates persistent transitions. A newer read or mutation wins;
when concurrent writes require reconciliation, invalidate and refresh after
completion. Cache storage has no browser persistence and is currently unbounded.

## Verification

`apps/app/test/ax_sync_engine_test.dart` exercises HTTP-loader integration,
cache policies, nullable values, shared Futures, timestamp boundaries,
errors/retries, generations, targeted listeners, removals/session clears,
optimistic races/rollback, and normalized collection isolation. Existing AX
HTTP, navigation, and shell tests remain regression coverage before migration.
No schema, wire protocol, dependency, or compatibility migration is required.

## Phase 2: Space/sidebar ownership

Space catalog/read-model loads and `SpaceStore` retain only Space fields,
with empty nested Thread lists. `AxSpaceThreads` owns each immutable
collection under structural key `['space', spaceId, 'threads']`.
`AxSnapshot.spaces[*].threads` is no longer the source for sidebar rows
or selected Thread resolution. Space-page and search inputs may compose
nested lists from the cache as view projections only.

Expanded `SpaceTree` rows use `AxQueryBuilder` subscriptions. Cold collections
show a local loading row and retry on failure. Cached rows render on the first
frame, remain visible during stale refreshes/failures, and rebuild only their
query consumer. Collapsing unsubscribes the row but retains its collection.
Selecting another expanded Space preserves expansion; clicking the focused
Space explicitly toggles it. Deep links initially expand their parent.

Sidebar Spaces and each Space's Thread collection are presented newest-update
first. Missing or invalid timestamps fall behind valid timestamps, with the
source order retained for ties. Manual Thread ordering is not part of the
presentation contract.

Both internal and browser navigation ensure the target collection rather than
reloading Spaces/session/Workspaces. Space views share the same query;
opening a Thread does not trigger a duplicate snapshot load. Space-view
collaboration loading shares the query and cannot overwrite cached collections.
Changes to a collection do not reload unrelated collaboration/Workspace data.
Thread create/update/delete actions refresh only the owning collection.
Shell Thread creation uses its authoritative Cloud method rather than
fabricating a local entity.
Logout/session loss clears the collection cache; archive/delete remove only
the affected Space collection. Other legacy snapshot refresh paths remain
for later migration and cannot replace cached Thread collections.

`ax_space_cache_test.dart` provides deterministic delayed-response tests for
cross-Space navigation, immediate cached rows, stale refreshes, local retry,
subscription isolation, and collapse during a pending refresh. Existing shell
fixtures explicitly supply keyed collections rather than implicitly reading
nested Spaces. There are no Cloud schema or endpoint changes; callers of
`loadBootstrapState` must load Threads through their separate resource query.

## Phase 3: Navigation versus bootstrap

`_navigateTo`, `_onBrowserNavigation`, and `_openThread` apply navigation
synchronously. Both navigation paths call the same `_ensureNavigationResources`
helper after updating the route; the Thread opener delegates exactly once.
The helper independently ensures `['space', spaceId]` details and
`['space', spaceId, 'threads']` collections through one shared
`AxSyncEngine`. It neither awaits network responses nor reloads the catalog,
session, or bootstrap state. Matching history callbacks skip already-applied
navigation. Fresh cache entries avoid HTTP; stale entries revalidate in the
background while retaining data. Query generations and resource keys fence
late writes, and a response never changes the active route.

`AxSpaceDetails` delegates to the additive typed `AxDataSource.loadSpace`
method for the existing `GET /spaces/:id` endpoint. The HTTP loader validates
the response identity and strips nested Threads. Space list summaries
serve as immediate view fallbacks but never mark detail queries hydrated.
Space content subscribes to details independently of the root shell. A deep
link whose Space is absent from the catalog shows local loading/retry until
its detail query resolves, rather than rendering another Space. Successful
Space create/update responses populate the detail query and fence old reads.
Session loss/logout clear both resource kinds; archive/delete remove only the
owning Space's entries.

`loadBootstrapState()` keeps its current public name temporarily. Its conceptual
role is **load bootstrap state**: initial/recovery catalog, Workspaces, and
session data. Production bootstrap no longer fetches selected Space details
or Threads; deep links ensure those focused queries separately after
bootstrap. Its `spaceId` argument remains accepted but does not select or
hydrate resources. Legacy realtime/polling snapshot refreshes remain pending
later migration. Other page-local resource loaders (collaboration, Worker
inventory, Workflow catalog, etc.) also remain for their respective phases.

`ax_space_navigation_test.dart` verifies immediate route changes, one detail
and collection request per key, matching history-event deduplication,
back/forward cache reuse, late cross-Space responses, Thread opening
without a second bootstrap, deep-link retry, and authoritative-write fencing.
HTTP tests cover detail-only requests and malformed/mismatched response
rejection. Browser navigation is injectable for deterministic history tests;
the default browser adapter and public data-source bootstrap name are retained.
There are no Cloud endpoints, schemas, dependencies, or protocol migrations.
Custom Dart `AxDataSource` implementations must implement the new focused
`loadSpace` read; all repository implementations and fixtures are updated.


## Phase 4: Shared Discussion history

`AxStore.discussion` owns `AxDiscussionCache` under structural keys
`['thread', threadId, 'discussion']`. `AxDiscussionBuilder` subscribes
only to that history. Destroying a Thread page cancels its subscription;
cached history and pending writes survive. Reopening renders cached messages
immediately and synchronizes in the background. Session loss/logout clears
history and fences late reads and writes.

The [Discussion paging contract](../specifications/DISCUSSION_PAGING.md)
provides bounded chronological pages. Synchronization catches up all pages after
the last server cursor, then reconciles the newest window, preserving previously
loaded older history. Loading older messages shares an outstanding request and
preserves the scroll position. Refresh failures retain cached messages and
expose retry locally. Existing Discussion/reconnect events request this same
scoped synchronization.

Optimistic sends and edits are per-message overlays, so independent writes do
not roll each other back. Sends publish temporary IDs immediately and replace
them with validated server responses. Edits retain references and reconcile the
server result; failures restore the previous message and use the existing error
notification. Pending temporary messages cannot be edited. The engine's
synchronous `update` operation fences old reads by default; pagination may
explicitly retain an active read because its loader merges current history
before committing. Updates preserve read timestamps rather than claiming a
fresh server read.

`ax_discussion_cache_test.dart` covers deduplication, catch-up, older pages,
concurrent writes, rollback, session clearing, scoped subscriptions, and widget
recreation during pending reads/writes. HTTP and Cloud tests verify bounded
pages, cursor validation, authorization, stable ordering, and exact Markdown.
Remote edits outside the newest page are not proactively fetched; targeted
entity patches remain a later realtime phase. Storage remains in memory and
unbounded, with no IndexedDB or database migration.


## Phase 5: Scroll pagination and incremental reconnects

Initial Discussion reads request the newest 50 messages. Scrolling upward to
within 24 pixels of the beginning loads the preceding page of 50; the explicit
load button remains available for short histories and retry. Each successful
page advances its older cursor, and requests share one outstanding Future.
Previously loaded older pages are retained and never requested again during
normal synchronization. Prepending preserves the viewport; programmatic jumps
do not trigger pagination, and late responses cannot move another Thread's
scroll position.

Reconnect and connected events use `synchronize(reconcileNewest: false)`.
When a newest server cursor exists, only forward pages are fetched until caught
up, advancing the anchor even across multiple pages. Empty forward responses
retain the anchor. Cold reconnects fall back to initial latest-page loading.
Reopening and Discussion change events retain newest-window reconciliation for
edits, which are not represented by creation-order cursors. The opaque `before`
and `after` parameters already implement the v1 contract; no additional wire
or schema migration is introduced by Phase 5.


## Phase 6: Infinite Work history

`AxStore.workHistory` owns `['thread', threadId, 'work-requests']`.
`loadThreadWorkRequestPage` delegates to the existing Work Requests endpoint
with a typed `(createdAt, id)` cursor and a default limit of 50. The HTTP loader
performs exactly one request, validates the envelope/cursor and request IDs,
and returns chronological immutable results. The old list method is retained
as a bounded newest-page wrapper; it no longer walks all history. Custom Dart
data sources must implement the new page method.

Work history is no longer owned by the Thread widget. Its scoped listener
renders cached requests immediately, retains history across disposal, and
merges recent head refreshes without dropping older pages. Scrolling near the
beginning or choosing **Load older Work history** fetches one older page and
preserves the viewport. Cursor pages have their own immutable cache entries
under the history key and are reused until explicitly invalidated. When a long
absence creates a gap before retained history, cursor frontiers let on-demand
pagination fill that gap and resume the original older frontier.

Opening or switching a Thread refreshes the head page, then reads details for
its active requests to restore persisted Worker operations. List pages omit
activity history, and the page-local live activity projection is cleared on
navigation. This restoration does not depend on realtime connection readiness;
detail reads use the shared cache's existing deduplication and read fences.
Completed historical requests do not incur additional detail reads.

Five-second polling and matching Work events continue to request active/recently
changed data through `activeOnly`, including its continuation pages when needed;
they do not traverse immutable history. Cloud's active filter includes requests
updated in the last fifteen minutes, so completions are reconciled. Head reads,
older reads, retries, optimistic submission placeholders and authoritative
responses all merge into shared history. Accepted submissions reconcile their
cached placeholder even after page disposal, while cleared sessions reject late
local writes. Retry/cancel refreshes use active data so old requests can update
outside the newest page. Overlapping older pages preserve newer
cached status data. Cache generations fence obsolete head reads; session clear
and explicit history invalidation also fence older reads. Invalidating history
discards its pages so subsequent scrolling can reload them. Widget disposal
only unsubscribes and stops its polling timer.

`ax_work_history_test.dart` covers page deduplication, cursor frontiers, overlap,
active updates, errors/retries, invalidation, clearing, cached reopening, and
scroll anchoring. HTTP tests cover bounded requests, chronological ordering,
exact authored Markdown, parameters, and malformed responses. No Cloud endpoint,
wire schema, persistent schema, dependency, or database migration changes are
required. Storage remains in memory and unbounded. Realtime event-to-entity patch
migration and centralized polling ownership remain later phases.


## Phase 7: Realtime-first Work reconciliation

`AxWorkRealtimeSync` is shared by the session store and Thread views through
one instance per history cache. Stream leases process shell/view delivery only
once. The shell keeps routing events into retained caches even when a Thread
view is destroyed; visible Thread scopes own fallback synchronization. There
is no page-owned five-second timer or event-driven history-list refresh.

| Event payload | Cache action |
| --- | --- |
| Known queued/running request or Step with sufficient status | Patch that entity, preserving its other fields |
| Complete request payload | Merge the authoritative request |
| Created request absent from cache, terminal event, missing Step, or retry of a terminal entity | Fetch `GET /work-requests/:id` and merge only that request |

Cloud currently emits IDs/statuses for these events; terminal results and Step
metadata therefore require the existing detail endpoint. Created, started,
completed, failed and cancelled Work Request events, and queued, running,
completed, failed and cancelled Step events are routed by Thread/request ID.
Sequence/event-ID deduplication rejects duplicate and obsolete delivery.
Per-entity revisions keep late head reads and older detail responses from
replacing event state. A burst shares one pending detail request and queues at
most one newer reconciliation. Session resets fence pending reads/recovery.
Detail failures retain cached data and expose targeted retry. An HTTP failure
alone does not enable polling while the socket remains healthy.

Healthy realtime disables polling. Reconnecting, disconnected, stale, or replay-gap
states enable a fifteen-second fallback for visible scopes. Fallback reads only
active/recently changed pages and fetches cached active/failed-read entities not
present in those pages by ID. Slow requests share one recovery operation;
timer ticks do not queue more operations. After restoration, one bounded latest
page (50 requests) discovers IDs missed during an outage, and known active or
dirty requests outside that page resynchronize by ID. Recovery neither traverses
nor reloads immutable history. If discovery leaves a gap before retained pages,
the infinite query retains its on-demand cursor frontier. Successful restoration
stops the fallback timer. Leaving a view releases its scope and stops polling
when no visible scopes remain; its cached history stays available.

During discovery, an absent retained request whose detail returns 404 is
removed individually so recovery can finish. In-progress submissions remain
available for retry, and a newer entity revision fences an outdated 404.
Concurrent detail reads for the same request and session share the HTTP read,
including reads from input delivery; a later read still fetches fresh state.

The browser client sends the existing Cloud `ping` every twenty seconds and
requires `realtime.pong` within ten seconds. A missing pong marks the connection
stale and reconnects. An idle Thread with healthy pongs does not become stale.
Timers stop on socket close/reconnect and app disposal; callbacks from replaced
sockets cannot change the current transport. `realtime.ready` now reaches consumers.

Submission acknowledgements, retries and cancellation reconcile the affected
request directly. Confirmed server IDs clear local progress placeholders without
disabling Run details after reconciliation. A server event that arrives before
the create response is retained instead of being replaced by the local placeholder.

`ax_work_realtime_sync_test.dart` covers status patches, single-request reads,
complete payloads, scope isolation, duplicate/out-of-order events, bursts, late
head reads, session clearing, failed details, stream leases, health transitions,
slow recovery and reconnect discovery. `realtime_health_test.dart` verifies idle
healthy pongs, silent failures and timer cancellation. HTTP tests check detail
identity and exact authored text. No Cloud protocol/schema or database migration
is required; the client uses existing events, detail reads and ping/pong.
Browser transport behavior is verified through its extracted monitor and web
compilation, rather than a live Cloud disconnect test. Other resource realtime
handlers and the legacy shell recovery path remain outside this Work migration.

## Phase 8: Navigation-independent cache routing

`AxRealtimeCacheRouter` receives the shared browser event envelope before shell
notification/rendering handlers. Space events revalidate registered Space
queries; Thread events revalidate the owning Space's cached Thread
collection. The parent can come from the envelope or be found in cached
collections. Discussion events synchronize the keyed Discussion query even when
its page has been destroyed. No selected Space is an input to this router.

Reconnect gaps revalidate cached or observed queries in the affected Space or
Thread scope; user scope and realtime ready revalidate all hydrated Space
and Discussion queries. Cached data remains visible during refresh and failures.
Unknown resources are not fetched eagerly. Generation fencing rejects pre-event
and pre-session responses, and bounded event-ID deduplication prevents repeated
transport delivery. Work Request/Step events continue through the shared
`AxWorkRealtimeSync` single-request reconciliation path; immutable history pages
are excluded from generic reconnect revalidation.

Space catalog notifications still refresh the shell's catalog, and unmigrated
execution/workspace resources retain their existing focused refresh handlers.
The selected-Space synchronization filter and mutable last-event Space ID
are removed. Reconnect recovery for migrated queries no longer loads a snapshot
for a background Space into the selected view. No HTTP or schema changes are
introduced. Updates require server event delivery; routes which do not publish
an entity event are recovered on reconnect or explicit refresh.

## Phase 9: Collaboration synchronization signals

Cloud now emits the durable Space, Thread, Discussion and Workspace Grant
signals in the [realtime synchronization contract 1.1](../specifications/REALTIME_SYNCHRONIZATION.md).
Collaboration has its own Space/user stream identity; `workspaceId` continues
identifying real execution Workspaces on existing execution events only.

The browser connects and subscribes to user scope without requiring execution
infrastructure. Transport cursors distinguish stream kinds even when their IDs
match. `discussion.created` follows forward pages from the shared cache's newest
cursor. `discussion.updated` loads and merges a single cached message by ID, so
remote edits to older loaded pages do not trigger full history fetches. Space
catalog recovery includes missed creation/deletion signals. Space tombstones
remove cached Space queries and reject their late reads; collaboration gaps
do not activate execution polling. Older execution envelopes and cursor maps
remain supported. Existing D1 installations require the documented one-time
stream-schema alignment; fresh databases use the updated v8 baseline.

## Phase 10: Scoped reconnect recovery

`AxSyncScope` resolves the explicit transport scope, falling back to the durable
stream identity and legacy execution `workspaceId`. A user subscription can
therefore recover one Space stream without treating it as a user-wide gap.
Malformed narrow scopes never trigger broad recovery. Navigation is not an input.

`AxSyncEngine.invalidateScope` marks affected query entries stale, fences older
reads, and retains data. Immutable Work cursor-page entries are excluded.
The cache router refreshes registered relevant queries in explicit scopes;
user-wide recovery invalidates retained resources but eagerly refreshes only
observed queries. Inactive Space queries revalidate when next ensured.
Repeated recovery frames for one scope share the pending recovery operation.

| Gap scope | Recovery |
| --- | --- |
| Space | Space details and its Thread collection, without child Chat reads |
| Thread | Forward Discussion pages from the newest cursor; active/recent Work discovery and known active/dirty requests by ID |
| Execution Workspace | Workspace state and Worker inventory; existing visible execution recovery remains bounded |
| User/ready | Observed migrated resources and catalog recovery; no bootstrap snapshot reload |

Discussion reconnect handling belongs to the session cache router rather than
individual Thread widgets. Cold observed Discussions recover with one latest
page. Existing messages, optimistic overlays, expanded sidebar rows and older
history stay visible during recovery and failures. Transport stale/disconnected
states use the existing subtle reconnect status. A completed gap cannot clear a
newer connection status, and session clearing fences delayed cache writes.

Workspace HTTP APIs currently return user-wide lists. Recovery shares those
reads under Workspace-specific query keys and merges only the affected Workspace
and its Workers into the existing view projection. This does not introduce a
new endpoint or reload `loadBootstrapState`. Catalog recovery remains a focused list
read for user/ready frames; Space/Thread gaps do not reload the catalog.
Unmigrated execution mutation events retain their existing read-model handler,
which is separate from reconnect recovery.

Router, Work realtime, Discussion widget and Workspace recovery tests cover scope
isolation, in-flight generations, shared recovery, cache preservation, immutable
pages, incremental cursors, failures and session clearing. Phase 10 introduces
no Cloud schema, protocol, dependency or compatibility migration. Live browser
WebSocket outage testing remains separate from deterministic tests and web builds.

## Phase 11: Shared Workflow catalog and Worker inventory

`AxStore.catalogs` owns `AxSessionCatalogs` on the session's existing sync engine.
The immutable `['workflow-catalog']` query has a 45-minute stale window;
`['workers']` has a 30-second stale window. Both survive Thread disposal and
navigation, share in-flight reads, and clear with other server state on logout
or session loss. Fresh empty responses are valid cached results. There is no
IndexedDB, cache eviction timer or background polling for these queries.

The shell, Thread pages and execution Workspace recovery all use the same
Worker query. `/workers` remains the existing user-wide HTTP read. A Thread
spaces that inventory through its own Space Workspace grants and applies
activation, readiness and catalog eligibility filters locally. The Space
grant read remains separate; grant-change signals reload the affected view's
grants without bypassing the Worker cache. A delayed grant read uses the latest
cached inventory, rather than restoring an older inventory response.

Thread query subscriptions populate cached Workflow choices immediately and
update Worker choices when a stale background refresh or realtime invalidation
completes, including already-open settings dialogs. Page disposal unsubscribes
without evicting shared data. Shell inventory rendering observes the same query.
Explicit scopes and user/ready recovery invalidate the Worker inventory where
appropriate; reconnect does not expire the rarely-changing Workflow catalog.

`worker.inventory.*` signals revalidate only the global Worker query, independently
of the selected Space/Workspace. The legacy shell handler no longer requests
another inventory copy. `invalidateWorkflows()` is an explicit cache hook for
publication/admin integrations: observed catalog views refresh immediately,
while detached queries revalidate on the next ensure. No new Workflow publication
wire event is introduced; such a publisher can call this hook when available.

`ax_session_catalogs_test.dart` covers stale-time boundaries, retained stale data,
immutable results, in-flight sharing, observer updates, explicit invalidation,
errors, session fencing, reconnect behavior and Thread recreation. Existing
Workspace recovery and Space/Thread widget tests remain regression coverage.
No HTTP contract, Cloud schema, protocol or compatibility migration is required.
Standalone Thread consumers may inject the session catalog cache; the default
source-associated fallback shares reads for consumers using the same data source.

Workflow Workspace selection is the only user-facing Space-to-Workspace
authorization surface. The Workflows query is cached by Space and the Thread
page derives its Worker list from the selected Workflow Workspace; it does not
load a separate grant collection. Cloud repairs a missing internal grant when
the selected Workspace is read and keeps the grant table authoritative for
admission and dispatch. The Workspaces list does not compute or display Space
grant counts.


## Phase 14: lazy Space tabs

`AxSpaceTabQueries` shares session-scoped Space resources in the sync engine.
SpacePage observes and ensures only its selected tab: Threads use
`space:<id>:threads`; Members use `space:<id>:members` and
`space:<id>:invitations`. Tab switches
remove listeners without removing cached data. Reopening a tab or Space shows
cached results immediately and refreshes stale results in the background.
Members/invitations use the default one-minute stale interval. Space gap
recovery recognizes these queries and the audit query alongside existing keys.

Owned Workspace inventory (`workspaces`, 30-second stale interval) is ensured
only when Connect Workspace opens. The current Space page has no visible audit
section, so it no longer fetches audit on entry. `space:<id>:audit` is available
for an explicit future consumer; membership and Thread writes invalidate it
without fetching it. Membership writes revalidate only the affected Members or
Invitations collection. Successful Thread mutations record their results in
the shared collection; the shell no longer refreshes it on every Space edit.
Space snapshot nested Threads are never a fallback authority.

Loading and errors are scoped to the selected tab. Failed refreshes preserve
cached data, with retry controls for tab reads. Session clearing fences pending
requests and removes all tab data. Existing HTTP methods and Cloud contracts are
unchanged; this phase requires no schema migration.

Widget and query tests cover request isolation, cache reuse across navigation,
stale background refresh, completion after leaving a tab, error recovery, lazy
Workspace inventory, targeted membership reconciliation, and session-clear race
protection. Live-browser interaction is not part of this automated verification.


## Phase 15: selective rendering

`AxStore` owns the bootstrap/recovery projection and observable Space and
Workspace lists. The shell retains navigation, expansion, authentication flow,
and presentation state, with read accessors for the store rather than independent
server-data copies. Worker inventory is read from the shared query; the shell
has no Worker subscription that calls root `setState`.

SpaceTree subscribes to the Space list and each expanded Space's Thread
query. The collapsed rail's Space menu subscribes locally without fetching
unopened Threads. Home and Workspaces subscribe to the lists and Worker
inventory they display. Focused execution views subscribe to their retained
execution projection, which does not emit for Space/Workspace-only writes.
Search observes existing Thread collections without eagerly loading them.
Navigation and bootstrap loading/error transitions may still rebuild the shell.
Background Space/Workspace refreshes and successful recovery update their
stores without shell rebuilds; existing HTTP APIs remain unchanged.

Within ThreadPage, Discussion observes its own cached query. Work history
and Workflow/Worker/grant controls have separate local listenables. Catalog,
inventory, and grant updates do not rebuild Chat or Work history. History updates
do not rebuild Chat, and Discussion updates do not rebuild Work history.
Chat and Work composers size independently without a shared spacing listenable.
The Work composer
observes Space Workflow choices, including realtime inventory changes; editing
those choices belongs to the Space Workflows surface. Reconnect notices,
notification badges, execution-health popovers, and account-security data have
local subscriptions instead of root server-update `setState` calls.

Session clearing removes list projections, notifications, security data, and
query caches. Delayed list/bootstrap reads are fenced across clearing/disposal;
failed refreshes retain existing data. Build-count widget tests verify update
isolation for Worker inventory, Workflow publication, Space lists, Chat, Work
history, Workspace consumers, reconnect notices, and notification counts.
Existing navigation, optimistic write, reconnect, and responsive-layout tests
remain regression coverage. No HTTP, database, or protocol migration is needed.
Live-browser profiling remains outside this automated verification.

## Phase 16: optimistic mutations

`AxMutationRunner` owns the explicit `optimisticUpdate`, `execute`, `commit`,
`rollback`, and `invalidate` lifecycle. Execution runs once; there is no retry
queue or persisted mutation replay. Optional mutation keys reject simultaneous
writes to the same entity before another optimistic change or HTTP request.
Session clearing releases leases and fences late completions.

`AxCollaborationMutations` coordinates Space and Thread writes across shared
queries. Temporary entities appear immediately and are replaced by server IDs.
Pending temporary entities cannot be selected. Independent optimistic layers
remain visible during reads; rollback removes only its own layer and preserves
newer canonical data and unrelated writes. Discussion and Workspace grant writes
use the same lifecycle with their retained collection overlays.

Work Request creation, eligibility progress, temporary IDs, and reconciliation
now belong to `AxWorkHistoryCache`, surviving view destruction. A successful POST
is followed by a targeted read; a failed read never rolls back accepted work.
If a submission response is lost, AX retains the failed local representation and
reports that submission status is unknown. Phase 17 permits explicit retries of unchanged input with the retained operation key. Reconnect, polling, cache refresh, and navigation never repeat
the POST. Eligibility failures occur before submission.

This phase changes client state ownership only. Existing `AxDataSource` HTTP
methods and wire contracts remain intact; no database migration is required.

## Phase 17: durable mutation identities

Work Request creation, Discussion sends, and Thread creation carry opaque
client-generated `Idempotency-Key` headers. In-memory attempt identities survive
response loss and view destruction. Sending the same unchanged input explicitly
after failure retains its key; successful completion starts a new identity for
a subsequent intentional action. Session clearing discards retained identities.
This map contains no executable callbacks, timers, offline queue, or automatic
replay. Work submission progress uses the key as its temporary row identity, so
a retry replaces the failed local row instead of duplicating it.

An explicit Work submission retry skips browser eligibility preflight, since the
original request may already be running. Cloud still authorizes every attempt
and validates any uncommitted submission; a committed receipt is recognized
before evaluating mutable Worker readiness or configuration again. Confirmed
active work in the cache still prevents another submission.

Cloud atomically commits the receipt with the domain write and returns the same
IDs for repeated attempts, including concurrent requests. Work dispatch can be
resumed explicitly with its original Run/Workflow identity; terminal work is
never restarted. See the [v1 mutation idempotency contract](../specifications/MUTATION_IDEMPOTENCY.md).

## Phase 18: optional browser read persistence

`AxPersistentReadCache` observes authoritative query values without affecting
rendering subscriptions. The web backend uses native IndexedDB through
`package:web`; other platforms have no persistence unless a backend is injected.
`AX_PERSIST_READ_CACHE=false` disables it. Storage failure or blocked startup
falls back to in-memory state; startup storage reads have a bounded timeout.

Cloud session authentication determines the Syntila user ID before hydration.
The database `syntila-read-cache-v1` stores versioned safe read DTOs per user,
never the session, viewer email, tokens, account security, credentials, grants,
pending forms, mutation keys, local optimistic entities, or executable operations.
Space settings, Thread configuration and Workflow snapshots use explicit
field allowlists; arbitrary maps are not serialized. Existing user-authored
Space/Chat/Work text is cached as product data, not interpreted as credentials.
Cached roles and Worker readiness are display hints, never authorization.

Hydration restores Spaces, per-Space Threads, Space detail, recent Chat
and Work, Workflow catalog, Workspace summaries, and safe Worker descriptors.
All restored queries are stale. Their data renders before bootstrap completes;
active navigation queries and bootstrap revalidate in the background. Failed
reads retain cached UI. Hydration cannot overwrite a newer value or a pending
Cloud read. The authenticated user, generation, and query fences reject late
restoration after logout or an account change.

The Profile security view starts its linked-account and active-session read as
soon as the authenticated profile route is known and deduplicates overlapping
loads. Session actions preserve the current session; **Revoke all** only
revokes other active sessions. Better Auth account linking permits more than
one trusted provider, so the view keeps the linked-method list while omitting
provider account identifiers from the UI. Better Auth's internal `credentials`
account is also omitted from linked methods. The current session is rendered as
an inert green action-shaped status so it lines up with revoke actions without
being clickable.

Persistence coalesces writes and saves only the most recently used 20 Thread
histories, at most 50 confirmed messages and requests per collection. This bounds
the persisted history independently of the Phase 19 RAM retention policy. Work cursors
resume at the retained oldest request. Truncated Chat must revalidate its recent
head before enabling older pagination, preserving the opaque cursor contract.

Logout clears memory and that user's persisted data. A revision tombstone
contains no user data and prevents stale writers, including other tabs, from
repopulating the cleared cache. Schema versions/corrupt records are discarded,
not migrated into auth or server state. Storage errors are retained diagnostically
as `lastError`; persistence is optional, so an unavailable browser storage API
does not disable the app. Retry identities remain memory-only as in Phase 17.
There is no Cloud schema, HTTP, or runtime protocol change.

### Local Thread view state

Thread view state uses a separate browser-local storage namespace from the
server read cache. Its user/thread-scoped, versioned record contains the active
Chat/Work tab, selected Workflow, currently available one-step Worker/model/
effort selection, and Chat/Work draft text. Drafts and selections never enter
Cloud queries, mutation payloads, or Workflow configuration APIs. Attachments,
pending mutations, and credentials are excluded. Restore reconciles the saved
Workflow and execution choices against the current catalog, selected Workspace,
Worker readiness and signed Profile execution options; stale choices are ignored rather than
silently substituted. Logout removes the authenticated user's local view records.


## Phase 19: bounded in-memory retention

`AxSyncEngine` retains the 20 most recently accessed Thread histories by
structural Thread ID, grouping Discussion, Work, and immutable page queries.
Query activity and subscription release schedule one coalesced retention sweep.
Eviction cancels internal bridge subscriptions and releases each cache owner's
pagination, revision, error, and reconciliation metadata. Engine removal fences
late writes. It never deletes Cloud entities or issues a network request.

Visible histories, in-flight reads, and pending optimistic mutations are protected.
The limit is temporarily soft when protected histories exceed it; completion or
subscription release schedules another sweep. Internal bridge listeners do not
pin an inactive history. Hydrated histories participate in the same limit without
requiring a screen to visit them first. Retry operation identities survive history
eviction so an ambiguous Work submission cannot become a duplicate operation.
They remain session-only and are not replayed automatically.

Each inactive retained collection keeps at most 200 recent rows by default.
Active screens may retain explicitly loaded older pages until they are released.
Work compaction releases immutable page entries and consumed-cursor bookkeeping,
retains reconciliation metadata only for surviving rows, and resumes older reads
at the retained oldest request. Discussion compaction keeps visible recent rows,
marks the head stale, and resets the opaque older cursor until head revalidation
returns a valid frontier. Revisiting an evicted history fetches one recent page;
older pages are fetched again only on demand after compaction/eviction.

Spaces, Threads, and the Workflow catalog are outside this retention policy
and remain available for the authenticated session. Unobserved `run:*` query
entries expire after five idle minutes at the next retention sweep. The legacy
Run projection already holds only the current Run rather than a multi-Run cache.
The history count, inactive row limit, and Run duration are constructor options.
IndexedDB continues to keep its separate 20-history/50-row read snapshot; RAM
eviction can remove a history from the next persisted snapshot as well. Logout
still clears all session state.


## Phase 20: browser lifecycle synchronization

The browser navigation adapter emits lifecycle notifications only when the
Document becomes visible, plus optional online/offline connectivity notifications.
Existing non-browser navigation adapters require no connectivity implementation.
Native browser listeners and shell subscriptions are removed on disposal.

The shell retains its session check on foreground return, then asks the
session-owned `AxLifecycleSync` to revalidate active stale queries. Network
restoration requests the same targeted read synchronization. Staleness includes
each query's configured age as well as explicit invalidation. Fresh queries,
inactive histories, internal cache bridges, and immutable older cursor pages do
not trigger lifecycle reads. Visible expanded Spaces, active Space tabs,
Discussion/Work heads, and subscribed shared catalogs use their existing loaders.

Lifecycle synchronization does not clear, invalidate, or replace cached data and
does not call snapshot/bootstrap APIs for a normal authenticated session. Only a
real authentication transition follows the existing bootstrap/logout paths.
Repeated notifications share one synchronization flight and existing per-query
request deduplication. A pending read that fails after network restoration can
be retried once by that restoration signal; this is read-only recovery, never a
mutation queue or Work replay. Logout/reset and disposal fence pending status
updates and deferred recovery reads.

A narrow status banner reports background refresh, offline connectivity, or
stale cached data after read failure. It is independent of the WebSocket notice,
so socket events cannot hide an offline/cache-stale warning. Cached content
remains visible throughout. Browser online status is only a connectivity hint;
HTTP failures still remain on the affected query and retain its previous value.
Cloud execution summary notices use the same transient banner and wait three
seconds before appearing, including completed and failed outcomes. Copying a
user-authored Chat or Work message writes to the clipboard without a second
confirmation toast.


## Phase 21: narrow APIs and conditional stable reads

Discussion and Work Request history already use bounded cursor pages rather than
unbounded downloads. Their initial AX reads remain 50 rows and older history is
requested only on demand. The existing paging envelopes and SQL cursor contracts
are unchanged.

Space detail, Space Threads, and Workflow catalog now support optional
ETag conditional reads. A stale sync-engine revalidation sends the last retained
revision; unchanged authorized content returns an empty `304`, and the typed
loader reuses the transport representation as a successful fresh read. Changed
content returns the existing JSON body. Authorization, current permissions, and
resource existence are checked before a Space conditional response.

The memory-only validator cache is separately bounded and fenced by session and
request generations. Logout and account changes clear it alongside server state;
it is never persisted. Missing ETags preserve compatibility with older servers.
No schema migration or client data-source signature change is required. The
optimization saves response bytes while keeping database reads unchanged; see
[conditional reads v1](../specifications/AX_CONDITIONAL_READS.md).


## Phase 22: remove coarse snapshot polling

The shell no longer owns the five-second Run snapshot refresh timer or schedules
another bootstrap read after receiving an active/running/waiting/paused Run.
Run, Task, Attempt, Assignment, Artifact, Finding, and Verification events never
call `_loadBootstrapState()`. Events carrying `workRequestId` and `threadId` enter
the shared Work realtime reconciler: complete payloads patch the cached request;
otherwise one `GET /work-requests/:id` supplies authoritative details. The existing
request deduplication, event sequencing, identity validation, and late-read fences
apply. No Work history list, Space list, Workspace list, or session read is
needed for those execution signals.

Progress-only execution bursts trigger no HTTP reads. Execution frames without a
Work Request identity remain notification/progress signals. They cannot authorize a broad read or invent a legacy Run endpoint.
The current Cloud read-model bootstrap does not expose a standalone Run-detail
read; its retained legacy Run projection is not a reason to reload application
state. `_loadBootstrapState()` remains only for authenticated bootstrap, a real
authentication transition, and explicit recovery UI retry.

The only execution safety reconciliation timer is the shared fifteen-second Work
fallback. It runs while realtime is unavailable/stale and a Thread view is
subscribed, discovers active requests in those visible scopes, and refreshes
retained active/dirty entities by ID. It does not traverse immutable old history,
poll inactive cached Threads, or accumulate overlapping reads. Restored
realtime performs targeted recovery and cancels the timer; releasing the last
visible scope cancels it as well. The unrelated desktop authentication approval
status timer remains part of its explicit sign-in flow.

Shell regression tests advance an active Run beyond five seconds and a full
minute without another bootstrap/Space/Workspace/session request. Execution
frames produce exactly one detail request each without broad reads. Shared
realtime tests verify no healthy-socket polling, visible-only outage fallback,
no overlapping fallback reads, and cancellation after recovery/view disposal.
No HTTP, realtime schema, database, or persistent read-cache migration is needed.

## Phase 23: remove the obsolete server-state facade

`AxStore.snapshot`, `replaceSnapshot()` and `reload()` are removed. Bootstrap is
explicitly named `loadBootstrapState()` in both the store and data-source
interface. It initializes independent Space, Workspace and session stores;
Space rows discard nested Threads. Navigation, reconnect and realtime
continue to use scoped queries and never use bootstrap as their routine loader.
Earlier phase notes describing retained snapshot paths are superseded here.

`AxStore.execution` is a read-only legacy Run/execution projection, updated by
`replaceExecution()`. It excludes Spaces, Workspaces and viewer state, and
copies its execution collections into immutable lists. Replacing it cannot write
collaboration caches or session state. Space archive/delete writes target the
Space query directly. Search and command-palette inputs are explicit Space,
Workspace and cached per-Space Thread collections instead of a snapshot.
Search observes cached collections without fetching every Space.

The list-shaped `loadThreadWorkRequests()` and `loadDiscussionMessages()`
data-source methods are removed; production consumers use cursor page methods.
Chat/Work history, catalog, Worker inventory, grants and lazy Space tabs remain
owned by their existing shared queries. No widget-owned canonical histories or
coarse snapshot polling are reintroduced.

Custom Dart data-source adapters must rename `loadReadModels` to
`loadBootstrapState` and implement page loaders; there are no HTTP contract or
schema changes. Tests cover bootstrap separation, immutable execution state,
collaboration writes without execution notifications, cached navigation/search,
pagination, realtime recovery and the absence of snapshot polling.

## Phase 24: regression and performance acceptance coverage

Acceptance tests run against the shared engine and real Flutter consumers with
controlled data-source reads. Completers deliberately hold responses pending:
first-frame assertions prove cached rendering does not depend on Cloud completion.
Request counts measure data-source invocations, not wall-clock Cloud latency.

| Acceptance behavior | Executable coverage |
| --- | --- |
| Expand A, select B, return A: both children remain; one list read per fresh Space | `ax_space_cache_test.dart`, full shell and SpaceTree sequences |
| Stale return: A rows visible on first frame, exactly one background A read, B untouched | `ax_space_cache_test.dart`, injected cache clock and navigation ensure |
| Five callers share one Space collection read; old slow generation cannot overwrite new fast result | `ax_space_cache_test.dart`; generic engine equivalents in `ax_sync_engine_test.dart` |
| Space route changes synchronously; cached back/forward makes no detail/list/bootstrap reads | `ax_space_navigation_test.dart` |
| W1 → W2 → W1 shows previous Chat/Work while synchronization is pending | `ax_discussion_cache_test.dart`, `ax_work_history_test.dart` |
| 5,000-row Chat and Work histories load 50 initially; next 50 only on demand, no cursor traversal | `ax_discussion_cache_test.dart`, `ax_work_history_test.dart` |
| Scrolling requests older pages once, deduplicates rows, preserves viewport and does not refetch exhausted history | Widget and engine cases in both history suites |
| Non-selected expanded A receives realtime changes while selected B remains untouched | `ax_space_cache_test.dart`, `ax_realtime_cache_router_test.dart` |
| Scoped reconnect keeps both cached collections visible during the pending read | `ax_space_cache_test.dart`; router, Discussion and Workspace recovery suites |
| Execution events and a minute of active Run time cause no application bootstrap reload | `ax_snapshot_polling_test.dart` |

Measured expectations are deterministic: fresh A/B list totals are 1/1, fresh
return adds 0, stale A return adds 1, five concurrent calls add 1, initial history
responses contain 50 rows and one explicit older request brings the cache to 100.
These are cache/consumer acceptance measurements; they do not claim production
network latency or a hardware-specific frame-time benchmark. Browser execution
also exercises native IndexedDB and lifecycle recovery alongside these tests.
No runtime, schema or public API changes are required for this test phase.

### Chat read failure presentation

A failed Discussion synchronization displays the request error with a Copy Chat
error icon and an inline Retry Chat sync link. Malformed envelopes identify the invalid fields
without including message bodies. It never labels a failed read as “No chat messages yet”; that empty state
is reserved for a successful empty result. Cached messages remain visible on
failure and retry clears the error after a successful response.

Invitation and membership invalidations addressed to a non-member use a durable
recipient `user` stream in addition to the normal Space stream. Adding a user
only to Space-event fanout is insufficient: the realtime gateway correctly
rejects that stream before invitation acceptance or after membership removal.
Recipient signals contain entity IDs only, retain existing event types, and
refresh the authenticated user's invitations and Space list. Space stream
membership checks remain enforced; no Space access is granted by an invitation
notification. Offline recipients recover through their user stream or initial
invitation loading. Existing pending invitation records need no migration.

Owned Workspace inventory uses the shared `ownedWorkspacesQuery` definition for
WorkspaceStore, the Space Connect Workspace picker and persisted-cache restore.
The `workspaces`
key has a single 30-second freshness policy and immutable list result shape.
Consumers may register in either order without conflicting query definitions;
they observe the same cached data and refresh updates. No API or schema change
is required.

Sidebar Spaces are grouped from the authenticated user's role: `owner` entries
appear in Your spaces, and other accessible roles in Shared with you. Each
group preserves the server's ordering and existing Thread expansion state.
Owned-only expanded sidebars omit the group heading; shared groups remain labeled
and empty groups are hidden. The collapsed rail shows separate folder and shared
folder selectors only for populated groups, each containing its own Spaces and
Threads. Groups derive from the reactive Space list, so invitation
acceptance and refresh update both views without a separate persisted category.
No server contract or data migration is required.

Space list and detail responses include the authenticated viewer's membership
`role`. Sidebar grouping must use that server attribution, including after a
Space detail refresh, rather than inferring ownership from a missing field.

On compact screens, Home and `/spaces` present a full-width Spaces/Threads
list instead of a drawer. Space rows expand in place; their menus open Space
settings, with Open Space immediately before Edit Space. Thread selection opens the full-screen conversation. The HUD logo
returns to the mounted list with its scroll offset and expanded Spaces preserved.
Tapping a Space name in the compact HUD opens a list scoped to that Space,
expanded to show its Threads. The logo restores the full list and its retained
scroll position. Open Space in the row menu still opens Space settings. The
list scope is session-local presentation state; routes and deep links are unchanged.
Pinned ordering, unread/running indicators, membership permissions, invitations,
and collaboration actions use the same query state and handlers as desktop.
Page rows have larger touch targets. Action icons appear only on selected or
hovered Space and Thread rows; New Thread
appears beside each Space when permitted. Invitations open Inbox.

The mobile HUD starts with the Syntila logo, linking to the Spaces/Threads list.
An 8px gap separates the logo from the page title. HUD action icons use a
consistent 20px size, including the application menu. It has no account avatar
or Back to Spaces icon. On the list page, the account name replaces the Spaces title and links to
the account page. The name uses the current-title weight and size (bold,
14.5px); the mobile account page HUD title is Profile. The application menu
has no Account entry. Its HUD button
uses the same 36×40px bounds as the other HUD action buttons.
New Space, Search, Notifications, and the application menu are HUD actions.
There is no mobile drawer, collapse button, or resize grip. Desktop keeps its
sidebar, account control, application menu, and collapse/resize behavior.

The expanded desktop sidebar defaults to 200 logical pixels. Its right-edge
resize grip supports dragging between 200 and 300 pixels. The resize line is visible only while the pointer
is over the grip, uses the same neutral color in all interaction states, and
has no tooltip. When focused, Left
and Right adjust by 10 pixels; Home and End select the limits. Width is local
shell state, retained through navigation, collapse/expand, and responsive layout
changes for the current app session; it is not stored in Cloud or across reloads.
Narrow widths use a compact header, wrapped search/actions, and reduced Thread
indentation. The mobile drawer and collapsed icon rail keep their existing sizes.

Sidebar group labels use uppercase text. Shared Space pages omit the empty
instructions section while continuing to show configured instructions. The
Members tab retains cached rows and an inline loading-failure notice without a
Retry Members button; reopening the tab retries its stale query.

## Global Workflows page

`/workflows` is a user-wide destination in the application menu. Workflows and
Workspaces have no dedicated sidebar or collapsed-rail buttons. It has no Space/Thread route arguments. It renders the
newest version per stable catalog ID; historical definitions remain available to
execution history. Cards combine definitions with typed user preferences and
owned Worker presentation metadata, including unavailable selections.

The AX presentation currently exposes only the implemented `chat` and
`direct`/Work workflows to regular accounts. Definitions for the remaining
catalog entries stay available to the `vitalii@nohainc.com` preview account so
they can be exercised before release. This is a presentation filter; Cloud
continues to own execution authorization and validation.

`AxStore.workflowConfigurations` owns the session query
`['user-workflow-configurations']`. The page uses cache-first ensures on entry:
cold concurrent consumers share one read, and returning to the page retains even
stale preferences without a navigation-triggered read. Space, Thread and sidebar
changes do not invalidate this query. Catalog definitions use the existing shared
catalog query. Worker inventory retains its existing 30-second freshness policy.

Preference freshness is 45 minutes. Explicit Refresh revalidates page resources;
the existing foreground/network recovery refreshes active stale queries. No
preference polling, new realtime event, or bootstrap reload is introduced. Save/reset commit authoritative API results through the shared query,
not through a subsequent GET. Failed reads retain cached data with an inline
notice; cold failure is unavailable rather than `Auto`. Failed writes preserve
prior preferences. Concurrent preference writes are rejected while pending.
Session clearing fences pending reads/writes, including writes waiting for their
initial read; account changes cannot repopulate preferences from a prior session.
Preferences remain memory-only, outside the persistent read-cache allowlist.

Edit exposes an explicit Worker for each enabled step plus optional step
overrides using Profile-owned model/effort metadata. `Auto` model and effort
choices inherit workflow defaults. Cards mark missing or unavailable Workers as
unresolved, and offline Worker selections remain visible. Cloud resolves these
preferences at execution admission; new Thread/composer
resolution layers remain deferred. The
[configuration contract](../specifications/USER_WORKFLOW_CONFIGURATION_V1.md)
continues to own persistence and API semantics. No Phase 2 migration is required.

`workflows_page_test.dart` covers query sharing, stale return reuse, mutation
updates/failure retention, reset, session races, latest-version cards, cold error
recovery, and full-shell Space/Thread navigation without preference reloads.

The Phase 3 Workflow editor subscribes to the shared Worker inventory while open;
refresh revalidates the unsaved draft without rewriting selections. Default and
step edits stay local until Save. Workflow and step resets retain the existing
shared-query mutation boundary. Workflow selection/card clicks do not reload
preferences. Advanced controls remain confined to global Workflows and the Space Workflows tab.

Space Workflows and Thread controls share the session query
`['space-workflow-configurations', spaceId]`. The Space endpoint returns effective
preferences: saved whole-workflow Space overrides replace owner-global defaults;
absent workflows inherit those defaults. No workflow definitions are copied.
Each tab returns to its cached data. Save/reset update the query reactively across
Threads without a follow-up GET. Global mutations invalidate and refresh cached
Space queries so inherited choices reflect the new defaults. Space mutations do
not alter globals or another Space. Owner-only editing is enforced both in AX and
Cloud; other members can view the effective configuration. Active stale queries
refresh through existing lifecycle recovery or explicit Refresh.

Thread controls project these Space choices without a second draft or an execution
override. Authored Thread configuration retains instructions and initial Workflow
selection. Immutable Run/Step configurations remain independent of live preferences.

Workspace selectors share typed `AxWorkflowWorkspaceSettings` queries at
`['workflow-workspace', 'user' | spaceId]`, with cache-first navigation and the
same 45-minute preference freshness. Global/Space selectors filter the shared
Worker inventory by selected Workspace before presenting Profile choices.
Confirmation cancellation restores the displayed selection. Pending switches
disable editing; mutation failure retains current preferences.

A confirmed switch updates the Workspace query, then refreshes reset preferences.
Global selection invalidates registered Space preference/Workspace queries;
Space selection only updates that scope. Grant queries refresh after authorization
changes. Existing `space.updated` events revalidate affected Workspace/preference
queries, including other members' open views; reconnect recovery recognizes the
same scoped keys. Normal Space/Thread/sidebar navigation does not reload global
Workspace settings. The Space Workspaces tab and its obsolete connection controls
are removed, leaving Threads, Members, and Workflows.

## People directory

People is one session-global `['people']` cache shared by the read-only People page and Space invitation picker. Cache-first bootstrap/navigation deduplicate reads; opening a dialog never reloads the directory. Authorized Space membership events and durable `people.updated` user-stream signals revalidate registered People. User and Space reconnect recovery includes this query even without an observer. Session clearing fences late responses. See [People v1](../specifications/PEOPLE_V1.md) for identity, persistence, and API rules.

People list search is local to the hydrated session query. Shared Space names and authorized invitation destinations arrive together in the People response; details and invitation pickers observe the same query without another load. Add to Space refreshes People and registered target invitation/audit queries after success and fences refreshes at session boundaries. Transport reconnect status uses the existing shell banner; failed reads preserve cached details and disable invitation submission until recovery.

The Space picker and reverse People flow use one `SpaceInvitationDialog` and `AxSpaceInvitations` writer. Open dialogs observe People and existing registered Space member/invitation queries without fetching on opening. `pendingInvitationSpaceIds` carries authorized per-Person status by stable identity. Successful invitations refresh People and target invitation/audit caches; partial failures preserve only unsent selections. All write outcomes are fenced at session changes. Cached private search remains local, including the invitation picker.

### Confirmed Chat history clearing

Clearing Chat calls `POST /threads/:id/chat/clear` before touching local state.
Cloud deletes the Thread's `discussion_messages` in the same commit as the
`thread.chat_cleared` event. Rejected requests preserve the displayed Chat, and
the action works for Threads whose Chat was never loaded. Sessions receiving the
event tombstone retained messages and re-synchronize. A Work Request detail read
that returns 404 resets Work history, covering sessions that missed
`thread.work_cleared`. Work-clear retries publish the event again, including on
idempotent replay.

### Confirmed Work history clearing

Work history clearing calls the Cloud deletion endpoint before clearing local
state. Rejected deletion preserves the displayed history. A successful deletion
replaces the history context, discards retained pages, and fences outstanding
head, detail, discovery, and older-page reads. Remote `thread.work_cleared` events
apply the same cache reset before refresh so retained rows cannot reappear.
The action also works for Threads whose history has not been opened locally.

Cloud clears the owning Conversations and their cascading canonical history,
then the Thread's Work Requests, in one transaction with the provider session
generation increment. Existing Discussion Chat messages are untouched. In the
same transaction, each completed Work Request with a non-empty final Worker
answer is archived into `discussion_messages` as two entries: `kind = ai_request`
(the original request) and `kind = ai_answer` (the last completed turn's answer,
with `worker_display_name`). Both are owned by the requester, keep
`work_request_id` as a plain reference, and use deterministic IDs
(`discussion-ai-{request|answer}-<workRequestId>`), so retries cannot duplicate
them. Failed, cancelled, and answerless requests are not archived. Archived
entries cannot be edited (409), can be deleted by their owner, and are removed
by Chat clearing. Clearing still resets Worker session continuity: later Workers
do not receive archived entries as context. AX re-synchronizes Chat after a
local or remote Work clear and renders `ai_answer` entries as the Worker
speaking (migration `0078_discussion_ai_entries.sql`).
The clear endpoint returns a JSON Response on both receipt and non-receipt paths.
AX includes Cloud's error detail when deletion is rejected. The existing
`0054_thread_work_session_generation.sql` baseline must be applied before this
endpoint is deployed; this correction adds no migration.

The Work history clear handler is exported through `routes/handlers.ts` and
registered in the Cloud entrypoint's production route map. Regression coverage
executes the clear endpoint through that map against the migrated SQLite schema,
so a direct-handler test cannot hide missing production registration.


## Cursor-aware bounded Cloud replay (2026-10-15)

Cloud excludes acknowledged events using each stream's cursor before limiting
replay to 256 rows. Unknown streams begin at their first retained event. A full
page emits a scope-wide `reconnect.required` (`replay_limit`), without advancing
an omitted stream's cursor, so consumers reconcile resources even when the
page cannot include every stream. See the [realtime contract](../specifications/REALTIME_SYNCHRONIZATION.md).

AX retains full observed Discussion reconciliation on `realtime.ready` and on
reported gaps. Incremental-only ready recovery remains deferred pending request
measurements. Space events revalidate Space resources without fetching People;
`people.updated` owns People invalidation. Event revalidation retains the
existing read-fencing behavior; the experimental coalesced follow-up was removed.
No schema, wire version, or client migration is required.

## Sidebar activity indicators

The collapsed icon rail aggregates running and unread states separately on the
Your Spaces and Shared With You icons, using Space summaries and cached Thread
flags. Its switcher menu also shows markers beside each Space and Thread.
Expanded and collapsed sidebars share the same 9-pixel markers, synchronized
25%–100% running pulse, static unread state, and reduced-motion behavior. The
rail observes the existing Space/Thread stores without loading extra histories.

Sidebar Space folder icons use the same color as their text labels in both
selected and unselected rows. Sidebar activity dots are 9 logical pixels in diameter.
The running marker pulses between 25% and 100% opacity, with each fade lasting
2 seconds. All dots in a sidebar share one animation clock; newly added
markers join the current opacity and phase. Reduced-motion mode uses a static
marker at 40% opacity. Unread markers use solid brand violet (`#5E20F8`); running markers use
pulsing light brand violet (`#966EFA`, brand violet mixed with 35% white). A running marker takes priority over an unread marker
when both states apply, including on collapsed Space folders. Collapsed rows observe cached Thread updates without fetching Threads;
the Space aggregate also preserves activity for Threads outside the cached list.

Space and Thread reads carry two per-user booleans: `hasActiveWork` (a Work
Request in `queued`, `running` or `waiting` that was updated within the last
day) and `hasUnread` (another user's Discussion message or Work Request prompt,
sent after the user's read marker whatever its later status, or any completed
or failed Work Request newer than the marker). Space values
aggregate their Threads. Markers live in `thread_read_states`
(`0064_thread_read_states.sql`); existing history is backfilled as read, and
users without a marker fall back to their Space membership date.

`POST /api/threads/:id/read` advances the marker and publishes a
recipient-scoped `thread.updated`, so the user's other sessions refresh their
indicators. AX marks the open Thread read after one second while the tab is
visible, and again for activity that arrives in it. Discussion creation and
Work Request lifecycle events for other Threads refresh the Space and Thread
lists through one 400 ms trailing batch. Accepting a new Work Request also
advances its Thread and Space update timestamps, so both move to the top of
their newest-update-first sidebar lists immediately, including when the Thread
is open. No wire version change.

### Notification feed

`GET /api/notifications` lists finished (`completed` or `failed`) Work Requests
from the last 14 days in the caller's Spaces, newest first, at most 50. The
caller's own successful Work is left out; their own failures stay. The feed is
derived from `work_requests`, so no status writer needs a hook. Read markers
live in `user_notification_reads` (`0067_notification_reads.sql`);
`POST /api/notifications/read` marks the listed ids, or every visible item
when `ids` is omitted. The `work_request.completed` and `.failed` realtime
events carry `requestedByUserId`. AX merges the feed with live events under
the shared id `work-request:<id>`, drops the viewer's own successful Work, and
marks Work on the open Thread read. Opt-in desktop alerts (browser permission
plus a local switch) show for every unread notification except the Thread
or Run being viewed in a visible tab.

### Pins

Pins are per user. `user_pins` (`0068_user_pins.sql`) holds
`(user_id, kind, target_id, pinned_at)` for `space` and `thread`.
`PUT` and `DELETE /api/pins/:kind/:id` are idempotent, require Space
membership, and publish a recipient-scoped `space.updated` or `thread.updated`
so the user's other sessions refresh. Space and Thread list reads return
`pinnedAt` (null when not pinned). The collapsed sidebar uses one Space/Thread
selection panel for all Spaces. Pins affect ordering only: pinned Spaces lead
in manual order, followed by unpinned owned and shared Spaces. Both sidebar
forms show active Threads with pins first, followed by activity order.
The expanded sidebar lists pinned Spaces first, without a group label,
above the usual groups, and pinned Threads first within their Space,
newest pin first, ahead of the shared `threadOrder`. Archived Threads ignore
pins. Pins have a per-user manual order (`position`, migration
`0069_user_pin_position.sql`): a new pin takes the lowest position, so it lands
on top, and ties fall back to newest pin first. `PUT /api/pins/order`
(`{kind, ids, spaceId?}`) stores the order of the caller's own pins; threads
send their `spaceId`. Lists return `pinPosition` next to `pinnedAt`. Move
Up / Move Down appear only on pinned Spaces and pinned Threads, and move the
item among the pinned ones. Only moves that can change the order are shown: Move Up is hidden for the
first item, Move Down is hidden for the last, and both are hidden for the
only pinned item or when reordering is unavailable. Unpinned Spaces and Threads have no Move items (they stay in activity order;
the shared `threadOrder` setting is no longer edited from the sidebar). Unpinned Spaces stay newest-activity first. Space settings stay owner-only and are not used for pins. No wire
version change; the field is additive.

### Private notes

Notes belong to a user, not to a Space or Thread. `user_notes`
(`0081_user_notes.sql`) holds `title`, `body`, a `revision`, and an optional
link (`thread_id`, `space_id`, `linked_title`) with no foreign keys, so
deleting a Thread or Space, or leaving it, never deletes a note; only deleting
the user does. Reads report `linked: true` only while the Thread exists and
the owner is still a member of its Space; otherwise the note is detached and
shows the saved Space and Thread names (`linked_space_title`, migration
`0082_user_note_space_title.sql`). Reads return `spaceName` and `threadName`,
and My Notes shows a Thread note's path as `Thread < Space`. A new Thread note
is titled after its Thread; the owner can rename it. There is no warning on Thread deletion because
nothing is lost.

- `GET /api/notes`, `POST /api/notes`, and `GET`/`PUT`/`DELETE
  /api/notes/:id` serve the caller's own notes (My Notes, `/notes`).
- `GET /api/files` and `DELETE /api/files/:fileId` serve the caller's own
  uploads and storage quota (My Files, `/files`); see
  `docs/specifications/WORK_V1_CONTRACT.md`.
- `GET`/`PUT /api/threads/:id/note` serve the caller's single note for a
  Thread (the Thread's Notes tab) and require Thread view access. `GET`
  returns `note: null` until the first `PUT` creates it.
- Every update sends the `revision` it edited; a stale one gets 409 and the
  editor reloads the latest text instead of overwriting it.

Notes are never published as collaboration events, never shown to other
members or Space owners, and never included in Worker context. The app saves
automatically shortly after typing stops. The body is Markdown: the editor
has an emoji picker, a Markdown formatting menu, browser speech dictation with
language selection (same as chat composers). A saved note opens rendered and
read-only; the edit icon or a double click opens the editor, and Done returns
to the rendered view. Notes previews preserve blank and whitespace-only lines as
visible spacing, including repeated blank lines and empty headings created by
multiline heading formatting, without rewriting the saved
Markdown. Code-block whitespace remains literal. This rendering option is scoped
to Notes; conversation Markdown keeps its existing spacing. An empty note opens
in the editor. Notes emoji and Markdown buttons share the input area’s
32px button size, 20px icons, and rounded-square styling; Edit/Done uses
the same height and corner radius. Notes page and editor controls suppress
hover and long-press tooltips while retaining their accessibility labels. The Thread’s Clear Note action asks for
confirmation, waits for any initial note load, and saves an empty body using
the same revision checks as editing. Cancel leaves the note unchanged.

## Phase 9: Persisted sidebar and Thread view state

Presentation state follows the user across browsers through metadata, never
through execution paths:

- **Thread** (`threads.metadata_json`, migration 0066, returned as
  `thread.metadata`): `viewState` holds `tabIndex` (0 Chat, 1 Work),
  `workflowReference`, `workerId`, `workerTypeId`, `model`,
  `reasoningEffort`, `catalogRevision`, and `selectionUpdatedAt` (UTC
  ISO-8601 time of the user's last selection change). View state is personal:
  it is stored per user under `metadata.viewStates[userId]`, and Thread
  responses return only the caller's entry as `metadata.viewState`, so one
  member's selection never replaces another's. A shared top-level `viewState`
  written before per-user storage is ignored. `PATCH /threads/:id` accepts
  `{ "metadata": { "viewState": { ... } } }` as a JSON merge patch (`null`
  clears a key) and scopes it to the caller. A `selectionUpdatedAt` ahead of
  the server clock is clamped to it, so a device with a fast clock cannot
  outrank later choices. The route validates keys and bounds values, and a
  metadata-only write does not change `updatedAt`, so it never reorders the
  sidebar. Writing requires Thread manage access. Drafts stay browser-local.
- **Space** (`spaces.settings_json`): `threadOrder` (unique Thread ids),
  `sidebarExpanded` (boolean), and optional `color` (a named navigation
  palette value). A missing color uses neutral icons and no recent-Thread
  marker; a JSON merge patch with `color: null` clears it. Only the Space owner
  can write Space settings, so other members keep session-local expansion.

The app applies the stored selection once the workflow and Worker catalogs
load, and never writes defaults over a stored choice while it is pending. The
stored Space order places Threads missing from it (new ones) first, then the
listed Threads in order; reordering uses the Thread menu's Move Up/Down.

Only explicit Thread choices are stored: the Workflow configuration default
shown when nothing is chosen is never written as the Thread's Worker, model,
or effort. Restore rules: when the stored `workerId` no longer exists (Worker
rebuilt or re-registered), the app re-binds by the stable `workerTypeId` only
when exactly one of the viewer's Workers (Space Workspace or own) has that
type, and refreshes `catalogRevision`; model and effort codes are kept as
saved. A stored `workflowReference` whose version was superseded resolves to
the current version of the same workflow id; a stored Workflow that no longer
exists falls back to the default Workflow but keeps the stored Worker, model,
and effort. Switching to a Workflow that fixes its own Worker and back restores
the last Worker selection. Leaving a Thread writes its Cloud `viewState` for that
Thread, and a selection still waiting for the catalogs is saved as-is rather
than replaced by defaults. An explicit Workflow/Worker/model change made while
that selection is pending supersedes it, so the late restore cannot overwrite
the user's choice. On reopen the Cloud selection wins over the browser-local
copy unless the local `selectionUpdatedAt` is newer (the Cloud write failed or
the Thread list predates it).

The Work tab retains cached history after synchronization failures without an
inline Retry Work sync button. Existing automatic synchronization and recovery
continue to reconcile Work history.

### Space landing composition

The Space landing page starts with the Space name and description when present,
then a Create a new thread field. Creation
requires an explicit name unique within the Space (trimmed and case-insensitive,
including archived Threads); cached Thread queries provide inline validation,
and Cloud remains authoritative for concurrent conflicts. Errors display below
the field. The Space page has no message composers or Discussion/Work tabs.
Workspace selection retains owner editing and read-only display for other members.
The landing content shares the Members title’s left edge at all viewport widths.
Below the field, Settings (when available), Members, and Archived Threads appear
in that order. Settings holds Workspace selection. Members is collapsed by
default and expandable from its title,
with a rotating arrow immediately beside the Members label;
Share Space is in the member grid’s name/email
column header. Member permissions and invitations observe existing Space queries.
Old Members routes render the Space landing page. Existing Thread pages retain
their history and composer layout.

### Shared page content width

The shell's scrollable pages fill the available content width up to 840 logical
pixels, centered within their responsive page padding. People and Archived
Spaces use the same width and left edge as Home even when their lists are empty
or loading; text length must not determine the page width. Space and Thread
pages retain their dedicated layout owners.

### Account creation navigation

The Create your account form offers email registration without Google or GitHub
buttons. A Back to sign in link returns to email sign-in, clears sensitive form
inputs and authentication notices, and restores the social sign-in buttons.
The same return link remains available during email-code verification.

### Home timestamps and linked sign-in methods

Continue working cards place the last-activity time at the right of the Thread
heading. What's new and AI updates place publication dates at the right of each
item's metadata row, including on narrow screens.

Account settings offer Unlink Google and Unlink GitHub for linked accounts.
The client posts the local Better Auth account record ID to the existing
`/api/auth/unlink-account` endpoint and reloads account security after success.
Failed unlink attempts keep the provider visible and display the server error.
Better Auth retains ownership of fresh-session checks and last-account protection;
this change does not enable unlinking the last sign-in method.

### About description

The About dialog describes Syntila as collaboration between people and AI
Workers in Spaces and Threads, with team conversations, AI requests, and results
kept together. It introduces Workflows and local execution through Syntila
Workspace and provider CLIs without presenting AI orchestration as the sole
product purpose.

### Login presentation

The standard sign-in form omits the generic “Sign in securely” subtitle and
centers Forgot password below the email sign-in action. Google and GitHub use
matching outlined buttons with the bundled official provider marks. Contextual
instructions remain for password recovery, account creation, email verification,
and desktop sign-in approval.

### Home update cards and password hint

Continue working shows up to four authorized ranked Threads. What's new and AI
updates use separated surface cards with a category icon and badge, a prominent
title, readable summaries, and publication dates aligned right. Full update
content and the existing See all actions remain available.

Account creation and password reset display “At least 8 characters” as the
password field's placeholder, without a helper line below it. Password
validation is unchanged.

### Consistent Thread composer layout

Message and Ask AI inputs share the two-row MarkdownComposer layout, including
text padding, bottom-row insets, send-button placement, and a six-line growth
limit. Message keeps emoji and Markdown actions on the left; Ask AI keeps its
workflow and execution controls there and hides emoji. Emoji and Markdown
popups use the shared Syntila composer menu surface, border, radius, and shadow.

The Message / Ask AI mode selector uses two icon buttons inside the
32-pixel-wide left rail beside the input and bottom row, with Message above Ask AI.
The icons stay vertically centered as multiline input increases composer height. Selected styling identifies the current
mode; tooltips and accessible labels identify both actions. Switching mode keeps
the existing separate message and request drafts and submission paths.

Thread composer controls suppress hover hints while retaining accessible action
labels. Message and Ask AI share the largest input height reached during the
current Thread view, including multiline drafts, so switching mode does not
collapse the composer. The height resets when the view moves to another Thread;
it is transient UI state and is not stored in Cloud or restored across visits.

The full-height mode strip uses the adjacent composer background darkened with a
12% black overlay in both themes. Mode icons and selection highlights follow the
current theme to maintain contrast.

The selected Message / Ask AI icon has a rounded background darkened by 24%
relative to the input surface; the surrounding mode strip remains 12% darker.

### Sidebar header actions

The expanded sidebar header shows the app mark without a visible app name.
Search, New Space, and Notifications follow the mark, with the sidebar toggle
at the end. The compact action group wraps at narrow sidebar widths.
Search starts as an icon and opens the same focused search popup used by the
collapsed rail. Typing updates search, Enter opens results, and Escape clears
and closes the popup. Notification unread badges and action callbacks are retained.

### Appearance preference

AX saves the latest Light, Dark, or System appearance selection in browser-local
storage (`syntila-theme-v1`) and restores it synchronously before the first
render after a refresh. This device-local preference is independent of sign-in
and is not sent to Cloud. Missing, invalid, or inaccessible storage defaults to
System; unavailable writes leave the current session's selection working.

### Provider usage-limit failures

Provider quota/session-usage exhaustion uses the existing `quota_exhausted`
execution code. AX shows a fixed message to wait for the provider's limit to
reset or choose another Worker and retry, instead of a generic failure or a
misleading provider-start headline. This is separate from conversation context
limits and unavailable native sessions. Raw CLI text, reset strings, and
provider diagnostics remain outside conversation messages.

## Space Thread archive navigation

The sidebar lists active Threads only. The Space landing page does not repeat
active Threads; below the Thread name field it shows three collapsed areas:
**Settings** (when available), **Members**, and **Archived Threads**, in that
order. Archived Threads come from
the same Space-scoped query cache as the sidebar. Authorized managers restore an
archived Thread from its row's actions menu. These menus use shared rounded
menu rows, icons, typography, and hover styling. The collaboration mutation updates
the shared cache so the Thread returns to the sidebar. Archiving does not delete
Threads or change their permissions.

The Members name/email column header shows only the + Share Space control
when the viewer can invite; its tooltip retains the action label.

Settings holds the Space's Workspace choice. Owners change it through the same
compact list selector used by the Work composer and workflow model pickers;
other members see the current Workspace read-only.

### Workspace sharing controls

Each shared-person card places its At once and monthly run-time selectors
directly below usage statistics, before the access table. Both selectors use
the shared styled popup controls and wrap onto separate lines at narrow widths.
Show access is an expandable header for the permissions table; it does not
change to Done. The table retains its existing explicit save/reset actions.
Collapsing refreshes the person's policy summary. Quota values, monthly limit
units, and authorization are unchanged.

My Files exposes `POST /api/files/sync` as an explicit user mutation. The client
follows bounded reconciliation continuations, then reloads its file list and
usage. Progress and retry state remain local to the page.
