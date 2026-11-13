# Realtime protocol `syntila.realtime.v1`

Endpoint: `wss://<backend>/v1/realtime`. Auth: `Authorization: Bearer <token>`
(native clients, Workspace Services) or `?ticket=<ticket>` from
`POST /v1/realtime/tickets` (browsers). Optional subprotocol
`syntila.realtime.v1`. Text frames, one JSON object each, `t` = frame type.
Requests may carry an `id`; the reply (`ack`, `sync` or `error`) echoes it.

## Server → client

| `t` | Fields | Meaning |
| --- | --- | --- |
| `welcome` | `protocol, connId, principal` | sent on open |
| `ack` | `id, …` | request succeeded |
| `error` | `id?, code, message` | request failed (`forbidden`, `not_found`, `rate_limited`, …) |
| `event` | `threadId, seq, type, data, actorId, at` | **persistent** thread event |
| `sync` | `id, threadId, since, events[], headSeq, more` | events with `seq > since` (max 500) |
| `transient` | `threadId, taskId, kind, data, at` | AI progress; no `seq`, not stored |
| `space` | `spaceId, type, data` | space notice: `thread.created`, `thread.updated`, `space.updated`, `member.updated`, `member.removed`, `workspace.linked` |
| `revoked` | `spaceId` | caller lost access; its subscriptions in that space were dropped |
| `pong` | `id, at` | reply to `ping` |

Persistent event `type`s: `thread.created`, `thread.updated`,
`message.created`, `message.updated`, `message.deleted`, `task.updated`.

## User → server

```json
{"t":"sub","id":"1","threadId":"…","since":42}
{"t":"sync","id":"2","threadId":"…","since":42}
{"t":"unsub","id":"3","threadId":"…"}
{"t":"subSpace","id":"4","spaceId":"…"}      {"t":"unsubSpace","spaceId":"…"}
{"t":"send","id":"5","threadId":"…","clientMessageId":"c-01J…","body":"hi","replyTo":{"messageId":"…"}}
{"t":"ping","id":"6"}
```

`send` → `{"t":"ack","id":"5","messageId","seq","duplicate","message"}`.
Retrying with the same `clientMessageId` (also across REST) never creates a
second message.

### Client algorithm (required for correct ordering)

Per thread keep `lastSeq` (persist it locally if the client has storage).

1. On (re)connect, send `sub` with `since = lastSeq`.
2. For every `event`/`sync` event: if `seq <= lastSeq` ignore (duplicate);
   if `seq == lastSeq + 1` apply and advance; if `seq > lastSeq + 1` buffer it
   and send `sync` with `since = lastSeq`.
3. If a `sync` reply has `more: true`, request again from the new `lastSeq`.
4. Render `transient` frames as ephemeral UI (typing/streaming). Drop them when
   the matching `task.updated` reaches a terminal status or the final
   `ai_answer` message arrives.
5. Reconnect with exponential backoff and jitter on any close (1012 = server
   restart, 1006/1009/backpressure = resync).

The server subscribes before reading the log, so an event can arrive both live
and in `sync`, or live before `sync`; the rules above make that harmless.

## Workspace Service ↔ server

Server → workspace: `{"t":"task.assign","task":{…,"input":{body,options,references,attachments}},"redelivery":bool}`
and `{"t":"task.cancel","taskId"}`. On connect all open tasks are sent;
unacknowledged tasks are re-sent every 30 s. De-duplicate by `task.id`.

Workspace → server:

```json
{"t":"task.ack","id":"1","taskId":"…"}
{"t":"task.status","id":"2","taskId":"…","status":"running","detail":"starting claude"}
{"t":"task.progress","taskId":"…","kind":"token","data":{"text":"Hel"}}
{"t":"task.result","id":"3","taskId":"…","resultId":"<stable per result>","status":"completed","body":"…","workerDisplayName":"Claude"}
{"t":"task.result","id":"4","taskId":"…","resultId":"…","status":"failed","error":{"code":"worker_crashed"}}
```

`task.progress` is fire-and-forget (no ack, silently shed under rate limits).
`task.ack`, `task.status`, `task.result` are acknowledged; the workspace must
keep the result in durable local storage and retry (WS or
`POST /v1/workspace/tasks/:id/result`) until it gets an `ack`. A result for a
cancelled task is acknowledged but does not create an answer.

## Limits

1 MB per frame, 500 subscriptions per socket, 20 frames/s (burst 60) per user
socket, 400 frames/s (burst 1000) per workspace socket, 64 KB per progress
payload, 120 s idle timeout with automatic pings, 4 MB send backlog before a
slow consumer is disconnected.
