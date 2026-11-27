# Syntila Home Contract (v1)

Home (`apps/app/lib/src/features/home/home_page.dart`) is the personal attention
and collaboration hub across all of a user's Spaces. It is not a metrics
dashboard: it shows no counts of Spaces, Workers or idle queues, which belong to
their own pages. It answers three questions: what needs my attention, what was I
working on, and what is new in Syntila and in the AI I can use.

Home is a pure projection of state the client already holds. It has no Cloud
endpoint of its own (there is no `/api/home`) and no tables or shadow stores. It
reads the shared stores (`store.spaces`, `store.executionChanges`,
`store.invitations`, `store.catalogs.workers`, `store.notifications`,
`store.productUpdates`, `store.productUpdateReadStates`) through `ListenableBuilder`
and `AxQueryBuilder`, so navigating between Spaces and Home causes no reload and
opening Home triggers no independent fetch burst
([AX server state](../architecture/AX_SERVER_STATE.md)).

## Dispatcher

```text
HomePage
├── spaces.isEmpty    → NewUserHome
└── spaces.isNotEmpty → EstablishedUserHome
```

### New user

Header "Welcome to Syntila / Bring your people and AI together." Order:

1. **Join a Space** (only when invitations exist): count line, inline Accept and
   Decline, then an "or" divider.
2. **Create your first Space** with a Create Space action.
3. **How Syntila works**: People first, Private credentials, Shared conversations.
4. **Advanced local execution** (visually secondary): "Connect Worker" for people
   who want AI or tools running on their own computer.

None of the established sections appear. Having no Worker never blocks Home or adds a
setup warning.

### Established user

Sections render independently, each only when it has content, in this order:

| # | Section | Weight | Source |
| --- | --- | --- | --- |
| 1 | For You | Strongest | Attention items and pending invitations |
| 2 | Running now | Dynamic | An execution that is actually running |
| 3 | Continue working | Primary | Latest four Threads |
| 4 | What's new in Syntila | Secondary | Published product updates |
| 5 | AI updates | Secondary | Capability changes for accessible Workers |

Product news and AI updates must never visually compete with an approval, failure,
Worker problem or invitation. The header is the title "Home" plus an optional
subtitle: a supplied greeting, or `Good morning|afternoon|evening, <name>.`
(before 12, 12–17, 18–23). Neither means a bare title. There are no marketing
subtitles and no onboarding cards, metric cards, "Recent Spaces" list, permanent
"No active Runs" or "Nothing needs your attention" placeholders, or archive
shortcut. Archived Spaces are managed from the application menu, sidebar and Space
settings only.

Optional sections collapse to nothing (`SizedBox.shrink()`) with no filler text.
`For You`, `What's new` and `AI updates` render as lightweight rows with hairline
dividers; bordered cards are reserved for Continue working, Running now and
onboarding.

## For You

For You is a triage surface; the Notification Center is the full chronological
history of what happened. Rules:

- **Eligible:** pending invitations from the authoritative invitation list,
  input and approval requests, execution failures, Worker problems and open
  findings. Completion and informational events are excluded, as are invitations
  already accepted or declined (a historical notification cannot keep them).
- **Selection:** deduplicate authorized items, drop read ones, order newest first by
  event time (source order for ties or missing times), show at most four. Opening
  a card marks its notification read before navigating, which removes it from Home
  but keeps it in the Inbox. Invitations and aggregate findings without a server
  notification use session-local read IDs cleared at logout.
- **Card:** category, title, right-aligned relative time and a contextual preview;
  the whole card navigates, with no Inspect/Review/Open button. Invitations keep
  explicit Accept and Decline. The header link "View all notifications →" opens the
  Notification Center; there is no count badge.
- **Domain model.** `AxHomeAttentionItem` (`id`, `type`, `priority`, `title`,
  `description`, `spaceId`, `threadId`, `workerId`, `timestamp`, optional
  `primaryAction` and `secondaryAction` closures, `read`), with types
  `spaceInvitation`, `needsInput`, `approvalRequired`, `executionFailed`,
  `executionCompleted`, `workerProblem`, `workerOffline`. The tile is pure
  presentation: it only invokes the actions. `AxHomeAttentionProjector` turns
  invitations, findings and normalized notifications into items and binds the
  closures.
- **Notification domain.** Notifications are normalized around Thread
  (`threadNeedsInput`, `threadCompleted`, `threadFailed`), Workflow Run
  (`workflowRunCompleted`, `workflowRunFailed`, `workflowRunNeedsApproval`), Worker
  (`workerCredentialProblem`, `workerInstallFailed`) and Space
  (`spaceInvitationReceived`). High priority: needs input, failed, needs approval,
  credential problem. Normal: install failed, invitation. Low: completed. Targets
  deep-link to the Thread, Run, Workers page or Space. The Notification Center opens
  beside the desktop sidebar and as a bottom sheet on mobile; each record shows one
  status title, one leading icon coloured by attention and read state, and no
  trailing icons.

## Continue working

Up to four authorized, non-archived Threads, two columns on wide screens, ordered by
`lastMeaningfulActivityAt` descending (dated before undated, stable for ties; an
active or unresolved state does not outrank newer Threads). The card shows the Space
name (uppercase label), Thread title, relative time, and a one- or two-line last
message prefixed by its sender (`briefAuthorName`: member name, or the Worker name
for AI answers). The whole card opens the Thread (`AxNavigation.thread`). The section
is omitted when there is no history.

## Running now

Shown only when an authorized execution is genuinely running (`run.isRunning`). The
card shows the objective, a `Worker · Model · Effort` line, the `Space / Thread` path,
elapsed time or task progress, and an `Open →` action into the Thread or Run. It
disappears when the run reaches a terminal state.

## What's new

Server-shaped `AxProductUpdate` content: `id`, `slug`, `title`, `summary`, `details`,
`category` (feature, improvement, security, workflow, collaboration, worker),
`publishedAt`, `minimumAppVersion`/`maximumAppVersion`, `audience`, `status`
(draft, published, archived), optional action and learn-more links. Home shows up to
four newest `published`, version-compatible updates, each with a category icon and
badge, a right-aligned date (`Oct 7, 2026`), the bold title and the full summary and
details. Rows are informational (not clickable) and have no Hide control; `See all`
opens `AxWhatsNewDialog`, grouped by month. Per-user state (`AxUserProductUpdateState`:
`seenAt`, `openedAt`, `dismissedAt`) is tracked, but Home ignores dismissal and shows
no unread count; the count (`computeUnreadCount`) exists for analytics. There is
currently no Cloud endpoint that supplies product updates; the store is filled
client-side and by realtime `product.update.published` events, so the section is
empty until content is provided.

## AI updates

`AxAiCapabilityUpdate` records a change for one Worker Type: `workerProfileId`,
`provider`, `type` (`model_added`, `model_removed`, `model_deprecated`,
`capability_added`, `capability_changed`, `profile_updated`,
`authentication_changed`), optional model ID and name, `title`, `summary`,
`publishedAt`, `actionTarget`, `minimumProfileVersion`.

- **Access filter** (`AxAiCapabilityUpdateService.resolveAccessibleWorkerProfileIds`):
  only Worker Types the user can actually use appear, from their own Workers, Workers
  available through shared Space Threads and Space Worker grants. Gemini news is
  hidden for a ChatGPT-only user and disappears when access is revoked. No accessible
  Worker, or no matching update, means no section.
- **Sources.** System-generated updates are synthesized when discovery shows a model
  added or retired ("New model available" / "Model retired"); editorial updates are
  curated. For the same `workerProfileId:modelId`, the editorial one wins
  (`mergeUpdates`).
- Home shows up to four newest, each with the Worker's brand icon (generic fallback),
  Worker name, type badge, dated right-aligned title and full text. Rows are not
  clickable; `See all` opens the dialog.

## Invitations: one source of truth

`store.invitations` and `store.collaboration` own invitation state. The New-user Join
card, For You, the Notification Center's pending section and the sidebar's
"Pending invitations" group all project it. Accepting from Home runs
`store.acceptInvitation(invite)`, which optimistically updates the invitation and
Space stores, so Home drops the item, the badge decreases, the sidebar adds the Space,
Space membership queries refresh and the client opens the joined Space.

## Navigation: every item has a destination

An item on Home always resolves to a concrete destination: invitation → Accept or
Decline and Space entry; input, review, failure and recent work → the exact Thread
(`onOpenThread(spaceId, threadId)` is preferred over a Space landing page); Worker
problems → the Workers page (`onOpenWorkers()`); Running now → the live Thread or Run;
What's new and AI updates → their dialogs.

## Loading, faults and offline

- Home renders immediately from the in-memory stores, then refreshes attention,
  recent work and updates in the background.
- Sections fail independently. A product-update or capability-update error or empty
  result never blocks For You, Running now or Continue working and never produces a
  page-level error; a throwing secondary projection collapses locally.
- Offline, cached Continue working, What's new and AI updates stay readable under a
  small "Offline · Cached data" indicator; server-dependent actions degrade without
  removing read access.
- Realtime events (invitation received, thread needs input or completed, Worker
  problem, product update published) update the stores through `_recordNotification`
  and `_refreshRealtimeFeatures`, and Home rebuilds from merged listeners with no
  polling. Duplicate transport events are deduplicated by ID.

## Privacy and authorization

Cloud returns only Spaces and Threads the user belongs to, and every client
projector (`AxHomeAttentionProjector`, `EstablishedUserHome`, `AxRecentWorkRanker`,
`AxAiCapabilityUpdateService`) additionally validates each item against the user's
active Space set. After access to a Space or Worker is revoked, Home shows none of its
Space name, Thread title, activity, message previews or Worker-specific AI updates,
even from stale cache.

## Telemetry

`AxHomeAnalytics` records interactions through a pluggable sink
(`AxHomeAnalytics.setSink`), is non-blocking and fail-safe, and sends no impression
events: `home.continue_thread`, `home.accept_invitation`, `home.resolve_attention`,
`home.open_whats_new`, `home.open_ai_update`, `home.create_space`,
`home.open_running_run`.

## Compact screens

On compact screens Home and `/spaces` show the full-page Spaces/Threads list; Spaces
expand in place, Threads open as full-screen pages, and the HUD logo returns to the
list with its scroll position and expansion kept. Pending invitations stay reachable
from the list and Inbox. Desktop keeps the Home dashboard and sidebar.

## Verification

`apps/app/test/home_page_test.dart` covers: new account, new user with an invitation,
a Space without a Worker, realtime invitation and acceptance, needs input, running and
completing work, recent and archived Threads, product updates and read state, AI
update access (granted, missing, revoked), hidden empty sections, offline, revoked
Space access, realtime reconnect deduplication and a 360×640 layout. Run it from
`apps/app` with `flutter test test/home_page_test.dart`.
