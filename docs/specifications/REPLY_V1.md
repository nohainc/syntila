# Reply v1

A user can reply to any message, Work Request or AI response in a Thread, as in
Slack, Telegram or WhatsApp: the reply shows the quoted original above its text.

## Targets

| `kind`     | `id`            | Quoted text                                      |
|------------|-----------------|--------------------------------------------------|
| `message`  | Chat message id | Message body (or `📎 file names` if text is empty) |
| `request`  | Work Request id | The request's `originalRequest`                  |
| `response` | Work Request id | Text of the latest completed task of the request |

Replies work for own and others' messages, and for AI answers (archived Chat
entries use `message`; live Work answers use `response`).

## Contract

- Clients send `replyTo: {kind, id}` only, on `POST /api/threads/:id/discussion`
  (Chat) and in `input.replyTo` / `replyTo` when creating a Work Request.
- Cloud (`apps/backend/src/domain/routes/reply-references.ts`) verifies the target is in
  the **same Thread** and builds the snapshot
  `{kind, id, authorName, excerpt}` (excerpt ≤ 1000 chars). Removed messages and
  responses without text cannot be replied to (HTTP 400).
- The snapshot is stored: `discussion_messages.reply_to_json` for Chat, and the immutable Work Request
  `input.replyTo` for requests. Quotes therefore survive edits or deletion of
  the original.
- Read APIs return `replyTo` on discussion messages and Work Requests.

## AI context

For Work Requests the Worker prompt starts with
"The user is replying to this earlier message" followed by the author, source
type and the quoted excerpt (`workflow-prompts.ts`), so the Worker sees what
the user refers to.

## AX behavior

- "Reply" is in the message/request/response action menus.
- One reply target per Thread, shared by the Message and Ask AI composers. A
  banner above the input shows "Replying to <author>" with a cancel button.
- The target is cleared on send and restored if the send fails; switching
  Threads clears it. Unsaved (`temp-`/`local-`) items cannot be replied to.
- Clicking a posted quote opens Conversation and jumps seamlessly to its original message,
  request or response without exposing intermediate scroll jumps. Once positioned, the target
  message pulses with a temporary accent wash highlight. Older history is loaded as needed using
  existing authorized paging APIs. Missing originals show “Original message unavailable”.
- Replying inside draft Threads is unavailable (they have no messages).
