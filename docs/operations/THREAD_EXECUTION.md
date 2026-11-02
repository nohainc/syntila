# Chat and Work execution

Opening a Space shows its description, when available, and an optional Thread
name field. The Message | Ask AI switch sits directly above the composer at the bottom;
the empty history area stays blank. The Space page's Chat composer always shows
its Markdown toolbar without a Show/Hide toggle, including in the single-tab
layout. **Create Thread** inside the name field
creates and opens a Thread without sending a message, and is disabled when the
trimmed name is empty. Names are limited to 22 characters.
The first nonempty Chat message or Work request also creates the Thread before
submitting. It uses the entered name, or the opening words of the request when
the name is empty; an oversized first word is truncated. The app then opens that Thread in the composer mode
used to send. Creation failures keep the draft. If creation succeeds but sending
fails, retry uses the same Thread. Existing Threads remain in the sidebar.

AI Chat is selected in the Thread **Work** composer. The **Chat** discussion
tab stores human/team messages separately. Both surfaces preserve Markdown source.
Own Chat messages and Work prompts longer than four preview lines start collapsed.
Use **Show more** to view the full Markdown and **Hide more** to collapse again.
Copy and edit actions retain the complete source.
Chat and Work composer Send, Preview/Write, and Show/Hide Markdown controls
use the theme text color. Work keeps its Markdown toolbar hidden in both layouts. The expanded Markdown toolbar has no top divider.
Sidebar and collapsed-tray controls suppress hover hints while retaining
accessibility labels, including menu controls and activity indicators.
Application, Space, and Thread menus match the sidebar background, including
the collapsed sidebar’s Space/Thread switcher and search popup. Composer
attachment, workflow, and execution popups match the input background in each theme.
Selected file attachments appear above the Work composer with their name and
size. They are held in browser memory until Send and can be removed before
submission. Selection alone
does not mean the Worker has processed the file. The web picker accepts up to
10 files, each within the uploader's plan limit (Free 25 MB, Plus 100 MB;
decimal bytes, loaded from Cloud); native AX file picking is
not implemented. Deploy the matching Cloud, AX, and Workspace updates together:
a Workspace without Input Delivery v1 never downloads inputs, so requests
with files fail after the 10-minute delivery limit.
On Send, the request is accepted at once and the composer unlocks; the files
then upload in the background while the Workspace downloads each one, and the
request card shows per-file progress ("Delivering files to the Workspace
(1/3 ready)…"). The Worker starts only when every file is on the Workspace; a
file that cannot be uploaded or delivered after three whole-file attempts
fails the request with its reason. See
[Input Delivery v1](../specifications/INPUT_DELIVERY_V1.md).
Cloud stores file bytes in artifact storage bound to the user and Thread and
records file references on the request; an explicit resend of the same
submission replays the same request and file IDs. Changing the authentication
session clears in-progress delivery status in AX. At dispatch, Workspace receives
its delivered copy of each file and writes `.syntila/inputs/<workRequestId>/file-NNN` below the
execution directory before starting the generic CLI Worker Engine. Chat,
Research and Implement prompts include these local paths; Plan receives
attachment metadata. File delivery is provider-independent: reading each file
format depends on the selected CLI/model's capabilities and Profile permissions.
Syntila does not extract PDF/image contents or confirm that a provider read a
file. Selected chips clear after submission. Sent user messages retain file names and
sizes in Conversation and AI History, including after refresh; these are
attachment records, not per-file processing receipts. History responses expose
only display metadata, without file bytes or storage identifiers.

When the saved Worker is absent from the composer inventory (including after all
Workers are removed), the execution selector shows **Select a Worker** instead
of unavailable model and effort labels. The picker remains available; inventory
refreshes do not overwrite saved preferences.

The Work execution popup applies preferences immediately, without Cancel/Done.
Completing an effort slider gesture accepts the selection and closes the popup.
Its discrete effort slider sits above the model list; available Worker icons sit
at the bottom. Selecting a Worker refreshes its model and effort choices, and
selecting a model retains a supported effort or initializes it to the first
available effort when effort selection is permitted. Tapping the leftmost slider
point explicitly accepts that value even when no effort was previously selected. Workflow selection permissions
still govern each control. Dismissing the popup keeps the applied preferences. The restore icon at the
bottom right restores the complete selection from when the popup was opened,
including its Worker, model, effort, and catalog revision, then closes the popup.
In both composers, Enter sends and Shift+Enter inserts a new line. Ctrl/Cmd+Enter
also sends. Editing an existing discussion retains Enter for a new line and
Ctrl/Cmd+Enter to save.
Selecting a different Space loads its Threads into the sidebar. Manual
expansion/collapse is preserved during background refreshes. Pinned Spaces and
Threads retain their manual pin order above unpinned items. Unpinned Threads
sort by latest activity, ignoring saved `threadOrder`; unpinned Spaces sort by
latest activity within their ownership group. Accepted requests, new discussion
messages, and request lifecycle updates advance both the Thread and its Space,
including while the Thread is open. Sidebar refreshes coalesce activity bursts.

Ask AI keeps **Chat | Work | More ▾** visible. Chat and Work select their current
catalog versions directly. More lists other available workflows by name in a
fixed catalog order. Selecting one replaces More with its name; click that name to choose
another, or Chat/Work to return immediately. Only the selected control is
highlighted, by text color as in the Message / Ask AI rail. Missing primary workflows and an empty More menu remain disabled.
Workflow selection stays with the Thread and applies to the next request;
switching does not alter or cancel a running request. History preserves the
workflow used for each request.

1. Open the Space Workflows surface and configure a Ready Worker/model for
   **Chat** and **Work**. These bindings are independent and may use different
   registered Workers.
2. Choose **Chat** for explanation, investigation or conversation. Its Profile
   must enforce read-only execution. Requests resume the Thread's Chat
   conversation without acquiring a mutation lease. Asking for implementation
   does not grant write access; select Work when changes should be performed.
3. Choose **Work** for implementation. It uses writable Thread policy,
   mutation coordination and fencing, and a separate durable conversation.
   The Space Workspace grant must permit the required repository access.
4. Inspect progress and Markdown results in Work history. Retry failed turns
   explicitly. History retains Direct for old `direct:v1` snapshots and Work
   for current `direct:v2`; the stored Workflow ID and binding remain `direct`.

| Step | Existing authority and coordination | Provider session scope |
| --- | --- | --- |
| Research | Read-only analysis; stateless Step | Request/Step |
| Plan | Read-only planning; stateless Step | Request/Step |
| Implement | Writable; stateful Thread Step | Request/Step, except Work's durable Thread conversation |
| Test | Read-only validation with authorized test commands; stateful Step | Request/Step |
| Verify | Read-only independent review; stateful Step | Request/Step |

Workflows containing stateful Steps retain one mutation lease for the request.
Chat has only its read-only stateless Step and never enters that coordination.
Chat and Work never share a provider session, even with the same Worker/model.

Deploy ordered migrations through `0008_codex_compatibility_approval_policy.sql`
using the [production provisioning runbook](PRODUCTION_PROVISIONING.md).

Cloud serves the authoritative Workflow catalog. If both the default selector
and composer menu still show Direct and omit Chat, the connected Cloud is running
the older catalog; deploy the updated Cloud after migrations, then reopen the
Thread. The default local launcher proxies this same hosted catalog.

Cloud owns Chat versus Work workflow eligibility. Legacy signed Profiles may
still contain a `capabilities` array for migration compatibility, but Cloud,
Workspace, and the Engine ignore that metadata. AGY Chat uses the signed
Profile's `--mode plan` mapping and Work uses its restricted `accept-edits`
mapping. Release qualification and live provider acceptance remain required;
see [regression coverage](../acceptance/CHAT_WORKFLOW.md).

### Newly configured Worker scheduling

If a newly configured Worker reports `not enabled for scheduling`, its Cloud
scheduling row may predate its ready state. Cloud inventory synchronization
enables ready, locally enabled Workers in an already selected Workflow
Workspace. After deploying that reconciliation fix, refresh the Workspace's
Worker readiness/inventory or reconnect it to repair existing rows. On an
older Cloud deployment, saving an unchanged Workspace selection is a no-op;
switching Workspaces can reset workflow overrides, so use the reconciliation
fix to repair scheduling without changing workflow settings. Draining Workers
remain blocked.

### Worker usage from Workspaces

Open **Workspaces** and select a Workspace. Click the **Worker usage** icon on a
Worker card to run its Profile-defined usage command. The action is enabled for
ready, enabled Workers on online Workspaces you own; shared Workspace usage
remains owner-only. The report opens in a local dialog with refresh,
original-output, and close controls. It does not create a Thread message or Work
Request. Workers without a usage command show an unavailable report.

Grok billing reports use the same usage table as other Workers.
`config.creditUsagePercent` is shown as percent used, with the reported period
end driving the reset countdown (for example, 69% used in the Week window).
Missing period metadata uses a Credits label; malformed percentages or reset
values fall back to the original output. Prepaid balances remain available
in Original because the CLI response does not identify their units.

### Queued messages in the composer

Messages queued while an AI request runs appear as an inset layer extending
upward from behind the active input. The queue and input share rounded styling;
the queue background overlaps behind the input without covering its controls.
The queue remains scrollable and retains Edit, Send now, Remove, and Pause/Resume
actions. When it empties, the composer returns to its normal single-input shape.
The queue header uses the soft accent background in both themes, distinct from
the conversation canvas, panel content, and input background. A thin divider
above it appears while usage or command history is open, keeping the boundary
between panels clear without hiding queued messages or their controls.

The command history opened with Arrow Up/Down in an empty AI input uses the same
inset layer and rounded styling. Arrow keys move the selection, Enter or a click
copies a request into the input, and Escape closes history and restores input
focus. History remains scrollable above the input on desktop and narrow screens.
The selected history row uses the same active background as sidebar Space and
Thread items in both light and dark themes.

The composer's `/usage` report uses the same attached styling, with a scrollable
view capped at 240 pixels. Usage, command history, and queue form a continuous
stack: only the panel nearest the input extends behind it, while upper panels
end against the next layer. Slash suggestions remain above the stack as a
separate suggestion list. Usage opened from Workspaces retains its standalone
dialog card, including refresh, summary/original output, and close controls.
The Conversation usage panel has no close icon: click outside it or press Escape
while interacting with the composer to dismiss it. Interactions inside the panel
and keyboard focus changes alone keep it open. The standalone Workspace dialog
retains its close button.

A successfully discovered, Profile/CLI-bound model catalog may contain no
explicit model choices (for example, an account restricted to provider Auto).
Cloud projects `models.catalogAvailable` to distinguish this from missing or
invalid discovery. Auto remains usable with a valid empty catalog; explicit
models/efforts, stale catalogs, and mismatched Profile/CLI metadata remain
subject to capability validation. No database migration is required.
