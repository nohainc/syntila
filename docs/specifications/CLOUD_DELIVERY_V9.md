# Cloud execution delivery — V9 Phase 5

**Status:** Phase 5 implementation contract

## Transport ownership

Cloud keeps one Connect transport with two interchangeable delivery modes:

| Mode | Use | Reliability rule |
| --- | --- | --- |
| WebSocket | Preferred live Service connection | Sends the same versioned runtime messages as fallback delivery |
| HTTPS long poll | Fallback and recovery transport | Server-to-Service messages remain in the persisted Durable Object queue until acknowledged by the next poll cursor |

Changing transport does not create an assignment or change its lifecycle. The
Cloud assignment row, not the active socket, is the source of truth. Reconnect
uses synchronization to recover active assignments and the recent terminal
window.

## Assignment command delivery

An assignment is admitted with a unique `assignmentId`, `attemptId`, and
`idempotencyKey`. The outbound `assignment.start` command also has a unique
runtime `messageId`. These identities have different purposes:

- `assignmentId` identifies the immutable Cloud work unit;
- `attemptId` fences retries and stale execution observations;
- `idempotencyKey` deduplicates Service admission and terminal redelivery;
- `messageId` identifies one transport delivery attempt.

The Gateway dispatch response explicitly reports delivery disposition:

```json
{
  "delivered": true,
  "shouldSend": true,
  "duplicate": false,
  "terminal": false,
  "accepted": false,
  "commandId": "message-...",
  "deliveryState": "queued",
  "acceptance": "pending"
}
```

`created` and `dispatched` assignments may be sent again. `acknowledged` and
`running` assignments are already accepted and are not reopened. Terminal
assignments are never redispatched. A full fallback queue returns retryable
backpressure instead of silently discarding a command or acknowledgement.

Dispatch acceptance means only that Cloud queued the command on the active
transport. Service admission and provider startup remain separate evidence:

```text
command queued → assignment acknowledged → provider started → terminal outcome
```

The final capacity guard is an atomic conditional insert. It counts only
`created`, `dispatched`, `acknowledged`, and `running` assignments for the same
Connect Worker, so concurrent dispatches cannot both claim the final slot.
Terminal states release the slot through the same persisted assignment row.

## Terminal delivery

The terminal path is durable at both ends:

1. Connect writes the local journal terminal record before sending it.
2. Cloud validates the complete assignment and attempt identity.
3. Cloud records the assignment and task terminal projection idempotently.
4. Cloud sends a terminal acknowledgement containing the persisted status.
5. Connect marks the journal delivery reconciled only after that acknowledgement.

If the transport or acknowledgement is lost, Connect resends the same
assignment and attempt identity during synchronization. Repeated terminal
delivery is a no-op after the first terminal transition. A previous attempt,
foreign runtime, or terminal assignment cannot rewrite the current outcome.

Cloud terminal persistence is independent of activity delivery. A result may
arrive before the final activity event; delayed activity is ignored after the
assignment becomes terminal.

## Activity delivery and retention

Activity uses the normalized provider-independent stream from
[`EXECUTION_ACTIVITY_V9.md`](EXECUTION_ACTIVITY_V9.md). The activity handler
validates correlation and source sequence before publishing.

| Activity | Cloud policy |
| --- | --- |
| Tool start, completion, failure, execution lifecycle | Bounded durable history and replayable realtime event |
| Cosmetic model status and partial message updates | Ephemeral realtime delivery, coalesced or dropped when a client is behind |
| Assignment result, error, cancellation | Durable assignment lifecycle, independently acknowledged |

Cloud does not execute a D1 transaction for every model-output fragment.
Replayable activity is persisted through the event publisher, while cosmetic
updates remain bounded by the realtime connection queue. When a durable client
queue cannot retain an event, the realtime gateway requests cursor resync and
the client performs an authoritative read; it never infers a terminal status
from a missing activity event.

## Recovery and deadlines

The Cloud workflow enforces the acceptance and startup windows before the
configured execution deadline. Scheduled recovery also handles cancelled Work
Requests, expired Connect grants, disconnected runtimes, and execution
deadlines. All recovery writes use the same terminal transition guard as normal
terminal deliveries, so recovery is safe to repeat after a retry or isolate
restart.

The compatibility boundary remains the existing Connect Runtime Protocol.
No additional network channel or provider-specific Cloud executable is
introduced by Phase 5.
