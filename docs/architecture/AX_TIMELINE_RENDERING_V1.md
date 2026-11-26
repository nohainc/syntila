# AX Timeline Rendering V1

Status: Phase 2 implementation

## Rendering contract

Chat and Work history use the shared `AxTimelineContainer`. Each instance owns
one `CustomScrollView` and one independent `ScrollController`:

- Chat uses `chat-history-scroll` and `_chatHistoryController`.
- Work uses `work-history-scroll` and `_workHistoryController`.

Pagination controls, loading indicators, errors, and empty states are
`SliverToBoxAdapter` or `SliverFillRemaining` content. Timeline entries are
variable-height children of a keyed `SliverList`; no fixed item extent or full
history intrinsic measurement is used. Markdown, code blocks, and expandable
Work activity cards retain their natural heights.

## Identity and pagination

Chat message IDs and Work request IDs are used as stable `ValueKey`s. The
sliver delegate maps those keys back to their current item indexes so updates,
insertions, and pagination do not unnecessarily discard child state.

Older-page loading records the scroll offset and extent before the page is
fetched, then compensates for the new extent after older entries are prepended,
so prepends never move the reader.

## Scroll rules (identical for Chat and Work)

A Chat item is a message. A Work item is a request or a response, so a response
arriving later counts as new. Each tab remembers the last item the reader fully
saw (`chatSeenId` / `workSeenId` in the local `AxThreadViewState`; never sent to
Cloud). An item is seen when the tab is active and the viewport is at the bottom.

1. **Opening a tab** (Thread open, tab switch, Thread switch), once the Thread
   view state and history are loaded:
   - no new items after the last-seen item (or no stored marker): scroll to the
     bottom;
   - new items exist: scroll so the last-seen item, i.e. the message before the
     first new one, is at the top of the viewport (short content is clamped).
2. **Incoming items while the tab is active and the reader is near the bottom**
   scroll down to show the new item: short items fit fully above the composer;
   an item taller than the viewport aligns its beginning with the top. The anchor
   is kept through response growth and later arrivals until the reader scrolls.
3. A manual scroll cancels pending corrections; a reader scrolled away from the
   bottom is not pulled down by new items.
4. Older-page prepends and Chat edits never create anchors.

Anchors use rendered positions (`AxTimelineFollowAnchor`). When the anchored row
is virtualized away, the scroll position is first estimated from the item's
fraction of the content and then corrected as the row mounts. Keys are pruned
when their messages leave cached history.

Each timeline has a centered floating down-arrow just above the composer. It
appears when the reader scrolls down away from the bottom, hides on upward
scrolling or reaching the bottom, and smoothly scrolls to the latest content
when clicked. The destination is rechecked after layout because virtualized
variable-height rows can change the estimated bottom during scrolling. A user
scroll cancels further corrections. The final row remains immediately above
the composer gap. The action overlays history without reserving layout space.

The composer remains outside the timeline viewport in both tabs. Switching
tabs therefore does not transfer or reuse a scroll controller, and switching
Threads retains the existing controller lifecycle and saved view state.

## Compatibility

The scroll surface keeps the existing test and accessibility keys, pagination
callbacks, retry actions, activity-specific listeners, and data/cache APIs.
This is a client rendering change only; no Cloud, Connect, Engine, or wire
protocol contract changes are required.

## Verification

The Work history and Discussion cache widget tests exercise the `CustomScrollView`
controllers, large histories, older-page loading, and viewport preservation.
The dedicated timeline test verifies that a 5,000-entry variable-height history
does not build the complete list. Incoming-message tests check Chat and nested
Work response anchors, response growth, subsequent arrivals, and short content;
a ThreadPage integration test checks both histories and manual-scroll preservation. Existing Thread layout tests remain available
for responsive Chat/Work and composer-placement follow-up.
