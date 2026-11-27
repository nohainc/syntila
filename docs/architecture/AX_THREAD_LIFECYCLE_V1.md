# AX Thread interaction lifecycle V1

Interaction side effects live outside ThreadPage rendering callbacks.

## Space draft lifecycle

The Space landing view reuses `ThreadPage` in draft mode through `NewThreadPage`.
It loads Space execution choices while leaving history subscriptions, Thread
realtime subscriptions, and Thread view-state storage inactive. The draft
identity is a UI placeholder and is never submitted to Cloud. On first send,
`NewThreadPage` creates the Thread and dispatches through the existing caches
using its real ID. A nonempty explicit name can also create and open the Thread
without a submission. Both creation paths share the same busy guard and reuse
an already-created identity. Failed sends retain that ID for retries. Successful sends
transfer local text drafts and selection to the real Thread view and navigate
to it. No Cloud protocol or schema changes are involved.

## Scheduling ownership

- Chat and Work use separate `ScrollController` instances. Each controller
  keeps its own follow-latest flag and deferred follow operation.
- Cache snapshots, normalized activity notifications, and tab changes request a
  follow pass. Timeline builders only describe the current snapshot; they do
  not schedule scrolling.
- Chat and Work composers size independently. No cross-pane height measurement
  or deferred alignment is scheduled.
- Older-page anchor restoration is also deferred, but is guarded by the same
  interaction generation as the Thread navigation lifecycle.

## Navigation generation

`_interactionGeneration` changes whenever the State switches Thread and when it
is disposed. Every deferred post-frame operation captures the generation that
created it. A callback from an earlier Thread therefore cannot jump a current
scroll position, reveal stale content, or restore
an older-page anchor.

Cache and presentation subscriptions are detached and reattached by
`ThreadPresentationController.attach`, whose own generation fence prevents
notifications from an inactive Thread from updating the active projection.

## Draft and focus safety

Asynchronous view-state restoration only fills an empty composer. It never
overwrites non-empty input that the user entered while the restore was in
flight, and it does not clear a draft when Work submission fails. Explicit
Thread navigation may clear the old Thread's draft before restoring the new
Thread's saved draft; stale restore completions are rejected by both the view
state and interaction generations.

## Required regression coverage

Lifecycle tests should cover rapid tab changes, Thread replacement, history
deletion/archive events, reconnect/replay, older-page insertion, incoming Chat
messages, incoming Worker activity, and failed Work submission while a draft is
present. A terminal or stale callback must never reopen a scroll position or
replace composer text from another Thread.
