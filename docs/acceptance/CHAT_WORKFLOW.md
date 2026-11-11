# Chat and Work workflow regression coverage

Chat is a provider-neutral read-only Work Request with stateless mutation
coordination and a durable Thread provider conversation. Work is current
`direct:v2`, with writable stateful coordination and a separate durable session.
Historical `direct:v1` remains Direct. Tests cover these independent contracts:

| Contract | Executable coverage |
| --- | --- |
| Immutable versions, read/write Step policies and Full Cycle isolation | [Core workflows](../../packages/core/test/thread.test.ts) |
| Read-only Chat instructions, implementation Work intent, Markdown source | [Prompt profiles](../../apps/cloud/test/workflow-prompts.test.ts) |
| Actual Gateway dispatch execution class, read-only flag and binding/model | [Cloud workflow acceptance](../../apps/cloud/test/work-v1-v8-regression.acceptance.test.ts) |
| Stateless Chat without mutation lease, coordinated Work | [Request coordination](../../apps/cloud/test/work-request-coordination.test.ts) |
| Generic Workspace execution policies and fail-closed Profile admission | [Workspace policy](../../apps/workspace/test/assignment_execution_policy_test.dart) |
| Actual Codex argv, explicit approval policy, sandbox policy in normal/compatibility layouts and fresh/resumed sessions | [Profile interpreter](../../packages/tool-profile/test/interpreter.test.ts) |
| Durable Chat reuse, cross-Thread and Chat/Work session isolation | [Session keys](../../apps/cloud/test/work-session-key.test.ts) |
| Historical rows, snapshots, cancellation, foreign keys, indexes, triggers, rollback and Chat schema admission | [Migration alignment](../../apps/cloud/test/chat-workflow-migration.test.ts) |
| Canonical starter synchronization and preservation of existing templates/releases | [Starter provisioning](../../scripts/provision-profile-starter-templates.test.mjs) |
| Snapshot/version history names and unchanged Markdown through Cloud read models | [Storage/read contract](../../apps/cloud/test/markdown-storage-contract.test.ts) |
| Current dynamic Workflow menu, separate Chat/Work bindings, Markdown rendering and historical labels | [AX widget acceptance](../../apps/app/test/spaces_pages_test.dart) |
| Snapshot name precedence and compatibility with older read models | [AX history model](../../apps/app/test/work_request_history_test.dart) |

Provider argument tests expand canonical Profile data; they do not prove a live
provider obeys its sandbox. Signed Profile qualification and real-provider
acceptance remain separate release requirements. Antigravity's current starter
has no verified read-only capability and is rejected for Chat execution.

The compatibility approval correction uses forward migration
`0008_codex_compatibility_approval_policy.sql`, which updates only the unchanged
official development starter. It never edits signed releases or historical
acceptance evidence; existing releases require a newly qualified successor.

## Naming and identifier cleanup audit

The final repository search reviewed `Direct`, `direct:v1`, Direct workflow
branches, `bindings.direct`, `STEP_KINDS`, `WORKFLOW_IDS` and
`THREAD_BINDING_IDS`. The remaining version-1 names belong to immutable
catalog definitions, historical snapshots/evidence and compatibility tests.
Stable `direct` branches resolve Work's binding, session scope and explicit
retry/prompt behavior; they are not presentation-name lookups. Domain unions
include Chat once and leave the persisted Work ID unchanged. Generic uses of
“direct” database access and generated platform documentation are unrelated.
Current operator guidance and generic new-Work test fixtures use Work.

## Request recall

The Work composer’s + menu includes **Request history**, alongside **Add files**,
on phone and desktop widths. It opens the existing request picker, also reachable
with Up/Down in an empty composer. Opening or dismissing the picker preserves the
draft; selecting a request replaces the composer text without sending it. The
request-history widget test in `apps/app/test/spaces_pages_test.dart` covers menu
access, draft preservation, dismissal and touch selection at both widths.

## Navigation row actions

Press and hold a Space or Thread row to open its existing actions menu without
navigating, changing expansion, or closing the mobile drawer. Releasing the hold
does not navigate; moving to scroll before the hold threshold cancels activation.
Ordinary taps retain navigation/expansion behavior, and desktop hover menus remain
available. Screen readers have named **Space actions** and **Thread actions**
custom actions. Pending local rows do not expose hold actions.
`apps/app/test/space_tree_hover_test.dart` covers touch holds, drawer retention,
scroll cancellation, ordinary taps, accessibility action exposure and hover.

## Response effort attribution

AI sender headers show the recorded effort inline beside the sender/owner labels
(for example, **Medium** or **High**), with **Default effort** when no override
was recorded. The former model/effort info icon is removed. Immutable turn
attribution takes precedence over current step settings, so historical responses
keep their original effort. The Chat/Work response-details widget tests cover
these labels at phone and desktop widths.

## Timeline icon sizing and touch selection

Sender marks use a 24 × 24 logical-pixel footprint for human avatars,
AI model/Worker icons (including initial-avatar fallbacks), and the Syntila
logo. Footer action glyphs use 16 logical pixels for messages, requests, and
responses. On touch platforms, the date/menu row stays visible;
message-body long press remains available for selecting text rather than
opening a competing actions menu.

## Timeline action menus

A 16 px ⋯ button beside the timestamp opens applicable actions for messages,
requests, and responses. Message menus retain Copy, Edit, and confirmed Delete
under the existing eligibility rules; requests and AI responses do not gain
message editing. Response menus include permitted Retry and diagnostic reporting.
Failure text asks the user to retry only when the menu offers Retry; failures
without a permitted Retry (and timed-out or lost requests) ask for a new message.
Cancel remains directly accessible for queued/running requests. Mobile platforms
keep the footer visible with a 48 × 48 logical-pixel menu target and 48 px menu
rows. Desktop footers reveal on hover or keyboard focus and stay revealed while
the menu is open. Failed-request footers stay visible for recovery actions.
Message-body long press continues to select text.

AX widget tests cover menu action callbacks, exact Markdown copying, edit/save,
delete confirmation, retry approval and diagnostic reporting, plus iOS/Android
touch targets and desktop focus visibility.

## Timeline following

Opening a Thread that has unread messages (for example from its sidebar unread
dot) starts at the first unread message with its sender line at the top, and
holds there while rows settle and history loads, until the reader scrolls.
Unread items include Work requests and AI answers shown in the Conversation,
not only Chat messages; an answer counts once it has content.

While a reader is at the latest content, Worker progress and new requests keep
the timeline at its end. When a final answer arrives, the timeline stops at the
answer's first line and stays there while the answer grows, so long responses
are read from the top. Messages from other participants stop the timeline at
the first unread message's sender line; when several arrive, later ones do not
move the view past it, and the first unread message always shows its sender
line even inside a same-author group. Scrolling releases the hold; sending a
request or message returns to the end.

## Queued Work messages

Messages sent while a request is processing wait in the Thread's queue and are
sent one at a time as each request finishes. The queue keeps sending after the
user leaves the Thread: a background sender re-reads the Thread's requests
every few seconds and sends the next message once nothing is processing. It
stops when the queue is empty or paused, or when the Thread is opened again
(the page then dispatches itself). A failed send keeps the message first in
line and pauses the queue until the user resumes it from the Thread. Queues
live for the app session; closing or reloading the app discards them.

Timeline footers sit directly against the message bubble or response content,
without an extra vertical spacer. Timestamp text and horizontal menu dots are
vertically centered within the footer button height, retaining the full touch
target.

Timeline footer controls use circular hover/pressed effects. When exactly one
action is available, its labeled icon runs it directly (for example, Copy)
instead of opening a one-item menu. Multiple actions retain the horizontal ⋯
menu. The centered alignment and 48 px mobile targets are retained.

## Northstar Studio demo rehearsal

The [demo script](../demo/scenes.md) exercises human discussion, two Chat
workflow requests, and a separate Work execution. It is a manual scene plan,
not acceptance evidence. Rehearse on an isolated local backend with a separate
demo Workspace; record the actual Worker/model readiness and observed outcomes.
Chat is read-only; the checklist execution uses Work. Review generated content
for fictional consistency and accuracy, and defer unavailable or unsuccessful
scenes rather than implying success. Production accounts, Workspace preparation,
requests, and captures require the explicit approval described in the
[demo guide](../demo/README.md).
