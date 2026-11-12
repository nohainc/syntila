# Service Readiness and Immediate Routing (V9, Phase 4)

Cloud distinguishes a **connected** Service (liveness) from a Service that is
**ready to accept Work** (`readyForAssignments`). Scheduling and delivery use
readiness; `online` is liveness only. Worker eligibility is a separate,
unchanged decision made after a Service is considered.

## Service states

`disconnected` → `connecting` → `authenticated` → `synchronizing` →
`ready` ⇄ `paused_draining`; `reconnecting` follows loss of an established
connection. Only `ready` has `readyForAssignments = true`.

## Publishing

- The Service publishes `workspace.readiness` (additive, protocol stays 5.1)
  carrying `state`, `readyForAssignments`, `runtimeId`, `sessionId` and
  `syncGeneration`. It is sent only after `hello.ack.cloudCapabilities`
  announces `workspace.readiness.v1`; older Clouds never receive it.
- Readiness is published immediately on sync complete, pause/resume, drain,
  shutdown and connection replacement. Heartbeats piggyback readiness so a lost
  message self-heals.
- When Cloud announces `workspace.idle_ping.v1`, a WebSocket Service with no
  active assignment, pending start permit or unacknowledged outcome replaces
  heartbeats with idle pings once three consecutive heartbeats carrying its
  current readiness were acknowledged. It still sends a full heartbeat every
  `hello.ack.idleHeartbeatIntervalMs` (default two minutes), returns to full
  heartbeats as soon as readiness or work changes, and sends one immediately
  before a start permit is judged so the permit clock sample is current.
- A Service without the capability is inferred ready only after Cloud answered
  its sync request and received inventory.

## Acceptance rules (Gateway)

A report is accepted only if its session and runtime match the authenticated
connection, its `syncGeneration` is not stale, and `ready` is claimed only after
Cloud answered the sync request. Effective readiness also requires a live
connection. State is persisted in Durable Object storage and mirrored to D1
(`workspace_service_readiness`, migration 0059), so hibernation and DO restarts
restore runtime identity, session and readiness; readiness belonging to a
replaced session is discarded. A close delivered to a freshly woken instance
adopts the closing socket's attachment so the workspace is marked offline.

## Scheduling and the durable queue

The scheduler prefers `ready` Services and uses a connected-but-unready Service
only as a fallback, to queue. For an unready Service the dispatcher persists the
full `assignment.start` payload (`worker_assignments.command_payload_json`),
leaves the assignment `created`, writes no command and reports `202 queued`
(`deliveryState: waiting_for_service_ready`, `acceptance: none`). It is never
"delivered". When the Service becomes ready the Gateway flushes queued rows,
claiming `created → dispatched` conditionally so a command is sent exactly once.
The Workflow nudges `/flush-queued` as a safety net. `created` rows carry a
`readiness_wait` deadline measured from `created_at`; on expiry they are
finalized directly (nothing was ever sent). Workspace disconnect does not fail
`created` rows.

## Transport

WebSocket is preferred. HTTPS long-poll is preserved: `send()` persists the
event then wakes the waiter, so a waiting poll returns as soon as a command is
available (the wait is never a per-message delay). A newer poll supersedes an
older one (the older returns an empty page) instead of returning 409. Pending
assignments received by the Service during sync are buffered, reconciled against
the sync result, and explicitly rejected if the connection ends first.

## Mixed versions

Legacy Service + new Cloud: inferred readiness. New Service + legacy Cloud: no
dedicated message, Service behaves as before. Offline dispatch now queues (202)
instead of 503.

Phase 9 adds a separate execution-safety gate: inferred readiness does not
authorize unfenced execution. New start commands require
`assignment.start_permit.v1` advertised by the current authenticated
session/runtime. An older Service remains connected for recovery but new
assignments stay queued with `deliveryState: service_upgrade_required` until
upgrade or the readiness-wait deadline. Reconnect with a fresh hello is required
when the existing session predates session-bound capability storage. See the
[rollout runbook](../rollouts/EXECUTION_RELIABILITY_V9.md).
