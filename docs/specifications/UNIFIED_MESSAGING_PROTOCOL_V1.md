# Unified Messaging Protocol v1 — Human and Worker Actors

- **Status:** Proposed technical contract (not implemented)
- **Target:** Bun + PostgreSQL, one writable region, N Bun API/realtime nodes, human browsers/mobile clients and independent Worker Agent clients
- **Version:** `syntila.messaging/1`
- **Dependencies:** ADR-031, Worker-first System Architecture

## 1. Scope and guiding rule

Implement one physical realtime gateway and one versioned envelope for human and Worker Agent connections. Separate authentication, message visibility, Worker command authorization and execution state machines by principal/capability. The protocol must tolerate restarts, disconnects, duplicate delivery, reordering across streams, slow clients and horizontally distributed gateways.

**Authoritative state = PostgreSQL commit. Network event = hint/delivery optimization.** At-least-once delivery and idempotent effects, not exactly-once transport.

### Goals

- Immutable Actor addressing for `human`, `worker`, and restricted `system` senders.
- One concurrent **active Worker Agent WebSocket session per Worker Instance**. Human users can maintain multiple devices/sessions.
- Common subscribe/unsubscribe, hello/capability negotiation, ack, resume, ping and error conventions.
- Per-stream monotonic committed sequences for durable events; cross-node fan-out; bounded replay and HTTP reconciliation.
- Separate per-Worker durable command inbox; explicit Agent admission, start, cancellation and terminal evidence.
- Ephemeral progress is coalesced/droppable; durable messages and final results remain reconstructible.
- No DB state writes proportional to recipient socket count for ordinary outbound events.

### Non-goals

- RPC through unauthenticated `actorId` fields.
- An every-Worker room subscription with access to all User/Space content.
- Host-level routing or required host/Workspace IDs.
- Treating a WebSocket send as confirmed execution or client UI application.
- Active-active cross-region writes.

## 2. Identity and authentication

### Principal classes

| Principal kind | Credential | Allowed default scope |
| --- | --- | --- |
| `human` | Cloudflare-authenticated user token/session verified by Bun | authorized user, Space, Thread subscriptions; human mutations |
| `worker` | per-Worker Agent credential, one active session epoch, rotated/revocable | own Worker inbox and assignment evidence; task-specific resources |
| `system` | internal server identity only (no public login) | constrained internal domain event emission |

**Never accept a client-authored `actorId` as authority.** Gateway injects server-derived principal and Actor identity; a `workerId` in payload is checked against authenticated Worker Instance ID. A Worker credential cannot invoke human endpoints, and human session tokens cannot impersonate Workers.

The TLS-protected WebSocket upgrade may use an Authorization header for native Agents and a short-lived, origin-bound realtime ticket for browser clients when browser WebSocket APIs cannot set headers. Never put long-lived Worker credentials in query parameters, URLs, application logs or event payloads. Ticket use is one-time/short-lived, verifies principal, origin and expiry; authorization is rechecked on sensitive subscription or action.

On Worker connection, perform atomic session claim:
1. Verify Worker Instance exists, owner status, credential binding and revocation.
2. Increment session generation/epoch in PostgreSQL or obtain an equivalent fenced claim.
3. Save `(worker_id, session_epoch, node_id, connection_id, lease_expires_at)` in shared session directory.
4. Old session is fenced, not trusted for subsequent terminal mutations; node-local old connection is closed via control notification best effort.
5. Agent synchronizes inbox/journal before claiming ready status.

A Worker cannot be duplicated merely by copying the Agent files; clones require explicit registration and new credentials. **Credential rotation and Worker transfer** invalidate old Agent credentials and session epochs. Keep credential material hashed/encrypted as appropriate (random opaque tokens stored as strong digests; secrets excluded from logs).

## 3. Envelope and type families

### Unified outbound envelope

```json
{
  "protocol": "syntila.messaging/1",
  "eventId": "evt_01...",
  "type": "message.created",
  "stream": {"kind": "thread", "id": "thread_123"},
  "sequence": 42,
  "occurredAt": "2026-11-19T12:00:00Z",
  "actor": {"kind": "worker", "id": "actor_567"},
  "correlationId": "work_request_123",
  "payload": {"messageId": "msg_987"}
}
```

Fields `eventId`, `type`, `stream` and `occurredAt` mandatory; `sequence` mandatory for **durable stream** frames. No durable stream sequence on ephemeral-only frames (or a separate explicitly named ephemeral sequence). Payload limits and redaction apply; long message content lives behind authenticated HTTP read endpoints and is not copied to every notification.

`stream.kind` initial values: `user`, `space`, `thread`, `worker_inbox`, `assignment`; streams have stable IDs. Avoid creating a separate durable stream for every transient activity update. Subscribe permissions are evaluated from principal, Space/Thread visibility and assignment rights.

A `correlationId` links events to a Work Request, `assignmentId` or user mutation. An envelope's `actor` identifies **attribution**, not the privilege source; the authenticated principal and server domain authorization determine what the request can do.

### Client → server command frame (not a persisted conversation message)

```json
{
  "protocol": "syntila.messaging/1",
  "requestId": "req_opaque",
  "type": "command",
  "command": "assignment.ack",
  "idempotencyKey": "ack_opaque",
  "payload": {
    "assignmentId": "assignment_123",
    "attemptId": "attempt_456",
    "sessionEpoch": 8,
    "accepted": true
  }
}
```

Wire payload `sessionEpoch` is validated against the **server session binding**, never accepted as proof by itself. Acknowledgement response references the requestId and authoritative resulting state.

### Event classification

| Type examples | Durability | Consumer |
| --- | --- | --- |
| `message.created/edited/deleted` | durable | Thread clients |
| `work_request.created/completed/failed` | durable | Thread clients, scheduler |
| `agent.command.available` | durable inbox, notification only | addressed Worker |
| `assignment.admitted/started/terminal` | authoritative execution DB + durable event | scheduler / Thread clients |
| `activity.lifecycle` | selected durable | Thread clients / execution history |
| `activity.snapshot` | ephemeral replaceable | currently viewing clients |
| `presence.changed`, `typing` | ephemeral | subscribers |
| `sync.required`, `session.fenced`, `subscription.denied` | control | connection owner |

`agent.command.available` may carry just a command ID; Agent fetches command with a capability-bound request, minimizing sensitive full payload on fan-out. Executable commands themselves MUST exist durably in the Agent inbox before wakeup.

## 4. WebSocket lifecycle

```mermaid
sequenceDiagram
  participant C as Human or Worker client
  participant G as Gateway node
  participant P as PostgreSQL
  C->>G: WSS handshake with verified credential / ticket
  G->>P: authenticate, claim Worker epoch if relevant
  G-->>C: hello.ready(sessionId, protocol, capabilities)
  C->>G: subscribe(scope, appliedCursor)
  G->>P: authorize scope; read stream watermark/snapshot boundary
  G-->>C: subscription.ready(scope, headCursor)
  G-->>C: durable event notifications (if newer)
  C->>G: event.ack(stream, lastAppliedSequence)
  Note over C,G: on gap, replay or HTTP reconcile; transient frames may be skipped
  C-->>G: heartbeat/ping (transport keepalive)
```

Client ack means the durable event was **applied to local client state or covered by a successful authoritative reconciliation**, not just received as bytes. Server sends `subscription.ready` with watermark, uses replay/HTTP snapshot race-safe ordering, and rejects invalid/malformed/unauthorized subscriptions.

One safe initial subscription recipe:
1. Connect and subscribe to scope, obtaining a **server-established head/watermark** (or subscribe first and buffer incoming events).
2. Fetch HTTP snapshot/page with matching authoritative high-watermark or compatible cursor.
3. Apply buffered/replayed events `> snapshotCursor` with idempotent entity merge.
4. Ack last contiguous applied durable sequence. If a gap/overflow/retention hole exists, re-fetch authoritative state and rebase cursor to verified watermark.

The current `realtime.hello` and per-stream cursor design can be adapted, but code must not consider “queued to a socket” as “applied by a client.” **Never advance an authoritative client ack cursor on send.** If keeping connection-local send cursors, name them `lastEnqueuedSequence`; do not reuse them for durability claims.

Human client may subscribe to user, Space and Thread scopes subject to authorization. Worker Agent subscribes to its own inbox/assignment control scopes only by default; it fetches assignment-scoped prompt/context through server-approved temporary access. Worker does **not** join all Threads like a Human just because the Worker authored an answer.

## 5. Durable write / event publication design

### DB entities (illustrative)

- `thread_messages` — canonical conversation content, author Actor and relevant Work Request linkage.
- `realtime_stream_cursors(stream_kind, stream_id, next_sequence)` — committed ordered sequence allocator.
- `realtime_events(event_id, stream_kind, stream_id, sequence, event_type, payload_json, occurred_at, ...)` — bounded durable replay log.
- `realtime_outbox(outbox_id, event_id, available_at, published_at, attempt_count, last_error, ...)` — reliable wakeup signal issuance/repair.
- `agent_commands(command_id, worker_id, assignment_id, attempt_id, command_type, payload_ref, status, created_at, expires_at, ...)` — durable Worker inbox.
- `message_mutation_receipts(actor_id, mutation_id, result_message_id, ...)` — idempotent human submission.

Keep existing tables initially and add compat layers to avoid destructive data rewrite. Named schemas require migration review against actual PostgreSQL `0001_initial.sql` and later migrations.

### Commit ordering and per-stream sequence correctness

Under concurrency, `sequence` must reflect a **single serialized commit order within each durable stream**. Allocate by `UPDATE realtime_stream_cursors SET next_sequence = next_sequence + 1 ... RETURNING` in the same transaction as message/event/outbox insertion. The row lock serializes concurrent writers for that stream. On rollback no event or permanent sequence advance appears. Avoid reserving values from a PostgreSQL `SEQUENCE` or generating durable per-stream seq outside the transaction if strict gap detection treats skipped numbers as loss.

The same transaction must:
1. Validate conditional, idempotent domain mutation.
2. Write message/Work terminal state (and request answer projection if relevant).
3. Allocate and insert durable event with unique `(stream_kind, stream_id, sequence)` and `event_id`.
4. Insert outbox wakeup record.
5. Commit atomically.

`NOTIFY` can be issued transactionally as a wakeup on commit, but it must **not** replace the outbox/replay log. Outbox dispatcher retries alerts; periodic reconciliation covers lost notices and listener downtime. Avoid forwarding raw prompt, Worker output or credentials through `NOTIFY`.

### Cross-node delivery

```mermaid
sequenceDiagram
  participant A as Bun node A (write)
  participant P as PostgreSQL
  participant B as Bun node B (reader)
  participant U as Human on B
  A->>P: BEGIN; domain row + sequence + event + outbox; COMMIT
  A->>P: wakeup (transactional NOTIFY or outbox publisher)
  P-->>A: notify(event pointer)
  P-->>B: notify(event pointer)
  B->>B: filter local subscription index
  B->>P: fetch event by pointer / cursor if relevant
  B-->>U: message.created(eventId, seq, messageId)
  U->>B: event.ack(seq)
  Note over U,B: If NOTIFY lost, reconnect or periodic cursor reconciliation finds event
```

Use a shared node-local registry keyed by Actor/User/Thread/Worker inbox subscriptions. No per-connection PostgreSQL write on each publication. For massive Groups, avoid SQL-per-socket authorization: authorize once on subscribe, cache membership version per connection, invalidate immediately on revocation; verify again on sensitive action and when revocation events occur.

**Stage 1 bus:** PostgreSQL `LISTEN/NOTIFY` with dedicated connection per node, compact event pointer, reconnect logic, retrying outbox and periodic gap check. PG listener delivery is not durable and NOTIFY recipients may miss a signal while disconnected; any effect requiring guaranteed handling must be recovered from DB. Benchmark notification rate and PostgreSQL queue pressure (`pg_notification_queue_usage()`) before expanding. On an already saturated database, a separate bus may be preferable.

**Stage 2 bus only if required:** Valkey/Redis Pub/Sub for high-frequency *ephemeral* cross-node activity and presence. For durable notifications, even if a bus is introduced, PostgreSQL remains the source and recovery layer. Kafka/NATS/Valkey Streams are not required by this proposal, but could be reconsidered if durable notification load actually warrants a separate log.

### Recipient and stream semantics

For a Thread event, gateway nodes first filter by active subscribed Thread IDs; backend still needs authorization and membership enforcement. Avoid permanent “recipient-per-message” expansion into database rows unless needed for unread, explicit notifications or moderation/audit semantics. A Worker inbox command is always addressed to one `worker_id`. Multi-user Group event fan-out must be driven by local subscription indices and permission snapshots, not host routing.

## 6. Worker Agent delivery and execution semantics

Worker command path has a separate authoritative state machine:

```text
accepted Work Request -> command persisted -> notified / claimed
 -> Agent journals command and sends admission ack
 -> provider start evidence -> activity (transient / durable)
 -> terminal result durable in Agent journal -> backend terminal transaction
 -> backend terminal ack -> Agent marks journal complete
```

- `command_id`, `assignment_id`, `attempt_id` and `idempotency_key` stable across retry of same logical command.
- Ingress checks Actor identity and session epoch. Terminal transitions also validate assignment/attempt fence and requested Work ownership; connection epoch is not a substitute for assignment fencing.
- Agent journals before admission ack. If journal cannot persist, reject; do not acknowledge then lose task.
- Backend may deliver command more than once. Agent deduplicates by command/assignment/attempt and reconciles its journal. Starting a duplicate attempt must not launch another provider process.
- Terminal local result resends until backend acknowledges durable commit. Backend uniqueness/conditional update makes repeat idempotent.
- Cancel/revoke is a durable command with its own ID; cancellation is only terminal once local process termination is confirmed or verified through established recovery semantics.
- Backend must not mark a queued-but-not-accepted command as “running.”
- On reconnect, Agent exchanges a bounded sync watermark and authoritative active command/terminal ledger; server reconciles pending commands and old attempt status. Old session is fenced.
- Offline Worker queue has explicit `expires_at`, cancellation, never silent fallback to another Worker. Local Agent must revalidate the latest command state/lease before starting.

## 7. Backpressure and memory bounds

Bun `ServerWebSocket.send()` return values convey sent / accepted-backpressured / dropped status, and `drain` signals availability. The runtime adapter MUST preserve this result, and the gateway MUST subscribe to `drain` rather than only scheduling timer polls. Each connection has:

- Hard cap on **queued bytes** and frame count.
- High/low watermark hysteresis on socket buffered amount.
- Maximum age for the oldest queued item.
- Priority classes: `critical-control`, `durable`, `ephemeral`.
- Ephemeral coalescing keys specific to Worker/assignment/activity kind; only snapshots can be replaced, not required append-only deltas without snapshot repair.
- On overflow: drop/coalesce ephemeral first; durable frames cause scope resync requirement and/or graceful close; never silently discard and advance durable applied cursor.
- Per-Actor/event ingress rate limits, payload size limits, max subscription counts, connection counts per user, and Worker activity ingress budget.
- Slow Agent receiving critical assignment commands must not trigger lost commands: durable inbox re-presents after reconnection.

**Initial tuning targets, not promised SLA:** app queue up to 128 frames AND 512 KiB; socket bufferedAmount high 256 KiB/low 64 KiB; configurable send/close deadline 5–10 s; bounded replay pages 256 events; settings to be validated with real frame sizes and 1k/5k load tests. The existing Bun runtime adapter uses a larger underlying backpressure limit; tune it deliberately.

## 8. Retention and replay

- Keep canonical `thread_messages`, Work execution/terminal outcomes and command records according to product retention; do not delete them merely because event replay retention expired.
- Current backend durable event log retention is **7 days**; preserve as an initial design value with validated retention cleanup/indexes, or explicitly change policy with tests and storage estimates.
- Replay bounded to `N` events and a time budget. If requested cursor is older than retained floor, stream has gap, or result page limit is exhausted, server sends `sync.required`; client performs scoped HTTP reconciliation and obtains a safe new cursor.
- All clients persist **last applied** cursors (or reconstructable snapshot boundaries), not latest received or last sent. Actor cursors are independent per stream.
- Old or inaccessible streams cannot leak data through replay; scope authorization is rechecked. On removal from Space, invalidate subscriptions and cease access; do not assume a stale cached membership remains valid.
- Use stable event IDs/dedupe and monotonically applied entity revisions. Out-of-order arrival across *different streams* is allowed; do not infer global chronological order from per-stream sequence.

## 9. Multi-node session directory and ownership/fencing

```sql
-- Illustrative only; migration needs FK and lifecycle review.
CREATE TABLE worker_session_directory (
  worker_id text PRIMARY KEY,
  session_epoch bigint NOT NULL,
  node_id text NOT NULL,
  connection_id text NOT NULL,
  lease_expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL
);
```

Worker Agent sends heartbeat/transport pings; gateway refreshes lease at a **bounded cadence** (not per message) and validates each command/terminal action against session epoch plus assignment attempt fence. A new session atomically increments epoch. All nodes can accept any Worker connection; no sticky balancing correctness requirement. On node failure, lease expires, Agent reconnects to another node and obtains new epoch. Presence is eventually consistent and **must not** drive terminal execution truth.

Scheduler/Workflow runners on N nodes require separate durable leases and tokens (e.g., `owner_node`, `lease_expires`, `fence`). Use compare-and-swap conditional DB writes and `SKIP LOCKED` for claimable queue rows. Never allow two nodes to start the same assignment because both read “ready” before an update. Postgres fencing applies to all terminal writes; local Agent start permission and attempt checks remain enforced.

Backend outbox worker needs leader/row-claim coordination for publishing without duplicate costly work, but duplicate wakeups remain safe. Normal server shutdown drains or closes sockets with reconnect hints, stops claiming work, releases/lets expire leases, and waits boundedly for accepted writes to finish.

## 10. Public APIs and error contracts

HTTP write operations retain `Idempotency-Key` semantics. `POST /api/threads/:threadId/work-requests` accepts `workerId` (plus model/effort/Workflow) and returns stable workRequestId/requestMessageId, with `queued|accepted|rejected` public status. `POST /api/worker-agent/pair` requires proof of an approved one-time binding. Agent command reads are tied to current Worker credential and session. Direct Worker WebSocket commands never permit arbitrary SQL/mutation payloads.

Recommended stable errors:

| Code | Meaning | Client behavior |
| --- | --- | --- |
| `worker_not_found` | Unknown or deleted ID | Remove stale selection and reload Workers |
| `worker_not_authorized` | Not owned/granted or Thread execution not allowed | Deny; no data leak |
| `worker_disabled` | Owner disabled | Offer a different Worker |
| `worker_offline` | No ready Agent | Show offline / offer explicit queue |
| `worker_capability_unavailable` | Model/Profile/permission mismatch | Reselect compatible option |
| `worker_session_fenced` | Older Agent connection | Disconnect, re-register/reconcile; never retry obsolete terminal blindly |
| `assignment_stale_attempt` | Old attempt/lease | Stop provider if required and reconcile |
| `replay_expired` | Cursor older than retention | HTTP state recovery |
| `slow_consumer` | Outbound queue overflow | Reconnect and reconcile |

Agent receives structured, redacted errors and correlation IDs; no secrets, native session handles or absolute filesystem paths in public errors.

## 11. Observability, benchmarks and acceptance

Metrics (histograms/counters, per node and aggregate): `ws_active{principal}`, `ws_buffered_bytes`, `ws_queue_bytes`, `ws_queue_oldest_age`, `ws_frames_dropped{class}`, `realtime_commit_to_delivery_ms`, `client_ack_lag_events`, `replay_duration_ms`, `replay_gap_count`, `outbox_unpublished_age`, `pg_notify_queue_usage`, `active_worker_sessions`, `fenced_worker_sessions`, `agent_command_accepted_latency`, `agent_terminal_ack_lag`, `activity_ingest_rate`, DB query/transaction/lock wait, CPU/RSS/event loop lag.

Do not call server enqueue time “UI rendered latency.” Optional client telemetry can measure actual receive/apply/render latency with privacy-safe sampling.

**Correctness tests:**
1. Two Bun nodes; human A on node 1, human B on node 2; both observe one durable message effect.
2. Worker A on node 1; owner UI on node 2; assignment, progress and final result arrive; no duplicate result on retried terminal.
3. Commit mutation then crash node before NOTIFY: outbox/recovery converges.
4. Disconnect PG LISTEN and reconnect: replay/outbox catches missed events.
5. Kill node while Worker executes: Worker reconnects to another node, old session fenced, one logical assignment outcome.
6. Start two Agent sessions with same Worker credential: newer session fences older; stale terminal rejected.
7. Two simultaneous writers to one Thread produce contiguous per-stream committed sequence, and consumer never invents missing event on rollback.
8. Slow client stops reading; memory bounded; durable messages recover after close; replaceable status coalesced.
9. Revoke a Space grant/membership during active subscription: no further unauthorized data or commands.
10. Offline Worker with queued Work Request reconnects after expiry: no unauthorized launch.

**Performance tests:** 1k and 5k idle sockets, 500 active human senders, 100–1k simulated Workers at 1–2 activity events/sec, 50+ concurrent streaming runs, slow readers, 30–60s disconnect bursts, 24-hour soak. Initially target p99 backend API under 150ms and fan-out under 250ms at 2k sockets as already outlined in the VPS migration plan; define target machine, workload and baseline before using as release criteria. No claim of existing compliance.

## 12. Implementation boundaries and code map

- Shared protocol: `packages/protocol/src/realtime-events.ts` and Worker runtime protocol package (new common envelopes, old adapters).
- Unified gateway: replace/refactor `apps/backend/src/domain/realtime-gateway.ts`, `workspace-gateway.ts`, `src/runtime.ts` and `src/platform/durable-objects.ts`.
- Durable publisher/outbox: `apps/backend/src/domain/event-publisher.ts`, `realtime-retention.ts`, new migrations and outbox worker.
- Executor: `assignment-dispatcher.ts`, `assignment-transitions.ts`, workflow/task runner; add Worker ID mapping and fencing.
- Clients: `apps/app/lib/src/realtime/realtime_cursors.dart`; Worker Agent transport/reconnect and journal.
- Tests: `apps/backend/test/domain/realtime-stream-delivery.test.ts`, `realtime-gateway.test.ts`, runtime integration, Agent command delivery; add real two-process Postgres suites and network fault tests.

## 13. External standards / runtime references

- Bun WebSocket API, `send()` backpressure and `drain`: https://bun.com/docs/runtime/http/websockets
- PostgreSQL `NOTIFY` commit and listener semantics: https://www.postgresql.org/docs/current/sql-notify.html
- PostgreSQL `LISTEN` startup race considerations: https://www.postgresql.org/docs/current/sql-listen.html
- Repo current realtime synchronization: `docs/specifications/REALTIME_SYNCHRONIZATION.md`
- Repo current assignment lifecycle: `docs/specifications/EXECUTION_LIFECYCLE_V9.md`, `docs/specifications/COMMAND_DELIVERY_AND_REVOCATION_V9.md`
