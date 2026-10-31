# Syntila

Syntila is the Flutter application for human authentication, Spaces,
Threads, Chat, Work, Workspace access, Worker catalog visibility, and
account security. The Thread Chat tab is the human discussion surface;
Work remains the execution surface.
Logout sends an authenticated JSON request and clears the local session token
after Cloud confirms success. Failed logout retains the session for retry.

Private account avatars load through Syntila's configured authenticated API origin,
including when Cloud returns an absolute URL behind a web proxy. A successful
upload displays the selected bytes immediately while the stored image is read
back; read failures are reported without clearing that preview.

Syntila's shared `SyntilaMarkdownBody` renders authored content as explicit GitHub
Flavored Markdown with selectable text and soft line breaks. Its theme-derived
style sheet covers headings, emphasis, code, quotes, lists, read-only task lists,
tables, links and rules. HTML is not rendered. Source stays an ordinary Markdown
string through storage and Worker execution; diagnostics stay plain text.
The canonical [Thread authored-content contract](../../docs/specifications/WORK_V1_CONTRACT.md#thread-authored-content-contract)
keeps Chat `body`, Work `originalRequest`, Worker `finalText` and Step
`resultText` as source strings. Existing plain text remains valid Markdown.
No generated HTML, AST, renderer data or `contentFormat` field is persisted.
Links are validated as absolute HTTP/HTTPS URLs without embedded credentials
and opened outside Syntila using `url_launcher`. Other schemes and malformed URLs
are rejected. Markdown images display an indicator and alt text without loading
their source; controlled images belong to the attachment system.
Chat messages, Work prompts and Worker responses use this renderer, as do
original requests and Step results in Run Details. Errors, eligibility failures
and stable diagnostic codes remain plain selectable text. Copy and edit actions
continue to use the original source. Entire authored messages use **Copy
Markdown**, preserving formatting markers, links and whitespace. **Copy code**
copies only the code body; rendered text selection remains available for plain
text. Diagnostics retain their specific error-copy labels.

Chat input uses the reusable `MarkdownComposer`: Write edits raw multiline
source, and Preview uses the shared renderer. Its toolbar formats selections
as emphasis, headings, code, quotes, links and lists. Cmd/Ctrl+B, I and E apply
bold, italic and inline code. Enter inserts a newline; Cmd/Ctrl+Enter or the
Send button submits the source. Chat uses a compact bordered input with its Send
button inline. Markdown controls are hidden by default; the formatting toggle
reveals a row below the input with Write/Preview and formatting actions. Chat
places Preview after the formatting icons, replacing it with Write in the same
row during preview, with a Send button beside Write and no send icon below the
preview. Authored messages and the Chat input use regular 16px system sans-serif
text with 1.6 line height and theme-appropriate near-white/dark text. Chat
inputs and message editors have no placeholder hint.
Sending from Preview returns the composer to Write mode. Chat timestamps always
include the local date and time, including newly sent messages before refresh.
Own-message footers align right in date/time, edit, copy order; other-message
footers align left in copy, edit, date/time order.
Syntila response timestamps follow the action icons directly in the left-aligned
footer. Work errors use the same message font, size and line height as Chat,
with red as their semantic color.
Own Chat bubbles use the active navigation background (a light accent wash in
light mode). Other bubbles stay transparent; both have no outline border.
Chat and Work keep their composers and action controls fixed at the bottom of
the Thread page. Only message history scrolls. Long Markdown previews scroll
inside a bounded preview area so they cannot displace the controls.
Existing Chat messages open the same composer in compact mode with their
original raw source, including formatting markers. Cmd/Ctrl+Enter saves edits;
Save and Cancel remain available. Link insertion selects the `url` placeholder
for replacement.

Work prompts use the same compact composer with multiline editing and no hint.
Markdown icons are hidden by default behind the formatting toggle and appear
below the input; Preview switches to Write in that row. Work messages use the
same borderless bubbles, own-prompt background and alignment as Chat.
Work uses the same send icon beside the formatting toggle to start execution;
Cmd/Ctrl+Enter also sends the request. A second row contains a plus menu for
files, links and workflow choices, followed by refresh/settings icons and the
selected workflow name. Revealed Markdown tools occupy their own second row,
moving attachment/workflow controls to the third row. The plus menu grows upward
from the input's bottom edge, has no opening/closing animation, and uses the
same 10px corner radius as the input.
The original Markdown source is submitted unchanged, including whitespace and
fenced code. Viewer access and submission readiness still gate execution.
Sending immediately adds the prompt and a Syntila preparation message to the
timeline and clears the composer. Readiness checks and Cloud submission update
that response in place; accepted requests resolve to live progress, an answer or
an error. Refresh preserves pending local entries until Cloud returns their
canonical requests. Rejected submissions remain visible for the current page
session, with the original prompt and attachments restored for correction.
Local preparation messages are UI state, not persisted Cloud Work Requests.

Fenced code uses a distinct themed block with its language label, horizontal
scrolling, selectable content and Copy code. Syntax coloring supports Dart,
TypeScript/JavaScript, JSON, YAML, SQL, Bash, Python, HTML and CSS, including
common short language aliases. Unknown tags and blocks over 50,000 characters
remain plain monospace code. Copy preserves code whitespace and trailing lines.

Run failures include a **Copy Run error** icon that copies the full message.
Worker replies appear as compact Syntila messages in Work history. Failed
Step diagnostics and implementation details are available from the **Run
details** info action, keeping the main timeline focused on the response.
Syntila sends commands and reads history over HTTP, with WebSocket notifications
triggering immediate history refresh. It subscribes to the active Thread
and resynchronizes after reconnecting. While Work is queued, running, or waiting,
a five-second HTTP refresh also reconciles progress and completion if a live
notification is missed. The fallback stops after completion or leaving the page.
To enable Work, open **Space → Workspaces → Edit Workspace access** (shield
icon), select **Read repository files** and **Change repository files**, then
confirm. Test steps also require **Execute commands and tests**. Both Workspace
connection flows present these choices explicitly; permissions are never
automatically widened. Existing connections retain their permissions.

The Work composer loads the current Workflow catalog: Chat, Work, Research,
Plan & Implement, Implement & Verify, and Full Cycle. Work displays `direct:v2`;
historical `direct:v1` requests still display Direct. Choose Chat here for an AI
conversation: it is read-only, resumes a separate Thread provider session,
and acquires no mutation lease. Work is writable and uses mutation coordination.
The team Chat discussion tab remains a separate collaboration surface.

The package intentionally has no native desktop targets. Desktop execution is
provided by Syntila Workspace; Syntila communicates with Cloud through
the Human Product Protocol and realtime event stream.

If live data cannot load, the recovery screen shows the failing resource,
HTTP status, and Cloud's JSON error detail when available. **Copy error**
copies that message with recovery context; **Try again** reloads the data.
Error text is also selectable. Non-JSON proxy responses use the resource
and status without copying the response page.

Worker availability is derived from Cloud's readiness and activation fields.
Enabled, Ready Workers count as available; disabled Workers do not. Worker
cards distinguish unchecked, sign-in, Profile/runtime, setup, and test failures
instead of treating a missing legacy status field as “Needs attention”.

The Home page's What's new and AI updates sections use the same compact,
clickable update rows. Each section has a See all dialog with the complete
available update summaries. Continue working is populated from cached Space
thread collections and shows the three most recently updated, navigable
Threads; thread timestamps and message snippets come from the authorized
Cloud thread read model.

## Getting Started

Markdown regression coverage includes toolbar selection transformations,
quote/unquote, GFM rendering in both themes, unsafe links, blocked network
images, malformed content, keyboard submission, and lossless Chat create/edit
and message copying. Cloud contract tests exercise SQLite-backed Chat storage
and Work history/details with Markdown delimiters and fenced code. Work
execution regression tests also forward the original Markdown prompt unchanged.
Chat validates nonblank content without trimming its stored source.
