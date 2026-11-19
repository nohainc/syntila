# Worker pairing, credentials and session fencing

Implements the server side of ADR-034 (Worker-first P3). Related: `EVENT_STREAMS.md`, `docs/decisions/ADR-034-*.md`. Flags: owner routes need `worker_identity`; Agent routes and the gateway adapter need `worker_agent_connect`.

## Trust model

- **One Worker Instance = one credential = at most one current session.**
- The **Agent generates an Ed25519 key pair**. Only the raw public key (32 bytes, base64url, 43 characters) is sent. The private key never leaves the host.
- Nothing long-lived is stored in the clear: the pairing secret and the session token are kept as SHA-256 digests; nonces are public challenges.
- No secret goes into a URL or a log. Responses that carry one are `Cache-Control: no-store`.

## Signed messages

All signed text starts with `syntila-worker/v1` and a line naming the purpose, so a signature made for one purpose cannot be replayed for another.

| Purpose | Signed by | Message (lines joined by `\n`) |
| --- | --- | --- |
| `pair` | the new key | `syntila-worker/v1`, `pair`, challengeId, workerId, publicKey |
| `session` | the current key | `syntila-worker/v1`, `session`, workerId, nonceId, nonce, *(empty)* |
| `rotate` | the current key | `syntila-worker/v1`, `rotate`, workerId, nonceId, nonce, newPublicKey |
| `rotate-new` | the new key | `syntila-worker/v1`, `rotate-new`, workerId, nonceId, nonce, newPublicKey |

Helpers: `pairingMessage` and `actionMessage` in `apps/backend/src/domain/worker-agents.ts`. The P4 Agent signs exactly these strings.

## Flow

1. **Owner** `POST /api/workers/:workerId/pairing` returns `{challengeId, secret, expiresAt}` (10 minutes, shown once). `POST /api/workers/:workerId/transfer` does the same for a Worker that is already paired. Only the newest challenge is valid. A stranger's Worker is 404.
2. **Agent** `POST /api/worker-agent/claim` with `{challengeId, secret, publicKey, signature}`. One conditional `UPDATE … WHERE consumed_at IS NULL AND expires_at > now()` consumes the challenge, so two claims race to one winner. A transfer claim revokes the old credential and ends the old session in the same transaction.
3. **Agent** `POST /api/worker-agent/nonce {workerId}` returns `{nonceId, nonce}` (60 seconds, at most 8 open per Worker). Then `POST /api/worker-agent/sessions {workerId, nonceId, signature, clientVersion?}` returns `{sessionId, epoch, sessionToken, leaseSeconds, leaseExpiresAt, actorId}`. `POST /api/worker-agent/rotate` replaces the key (signed by the old and the new key).
4. **Owner** `DELETE /api/workers/:workerId/credential` revokes the credential and ends the session (idempotent).

Refusals:

| Case | Answer |
| --- | --- |
| unknown challenge or wrong secret | 403 (the same for both) |
| claim made while signed in as another user | 403 |
| expired, already used or superseded challenge | 410 |
| wrong signature on a claim | 401 (the challenge is not consumed) |
| the key is already active on another Worker | 409 |
| nonce expired, replayed, unknown or wrong signature | 401 (the nonce is spent in its own statement, so a failed try cannot be retried) |
| Worker unknown, removed or not paired (nonce request) | 404 |
| disabled Worker | 403 on connect |

## Session fencing

`worker_agent_sessions` has one row per Worker. Connecting runs one `INSERT … ON CONFLICT DO UPDATE` that sets `session_epoch = session_epoch + 1` and replaces `session_id`; the row is locked first, so concurrent logins get distinct epochs and the last one is current. The audit records whether a live session was superseded.

Every Agent acknowledgement, start permit and terminal result carries `{workerInstanceId, sessionId, epoch}` and is written with `agentFenceSql` (`agent-session-fence.ts`) **inside the same UPDATE** of `worker_assignments`: the assignment must belong to that Worker and the session must be current and not disconnected. The matching session row is locked for the duration of the transaction so a concurrent replacement cannot pass between the check and commit. Covered writes include `transitionAssignment`, `grantStartPermit`, `recordAssignmentResult`, `recordAssignmentError`, `recordAssignmentCancelled`, and Agent-confirmed revocation finalization. Terminal writers also check the attempt in the update. A rejected terminal update cannot project a task transition. The gateway does not send the terminal acknowledgement for a result from a session that is no longer current, and closes that socket.

A result that arrives late from an older session is therefore rejected, and the older session cannot tell that it was recorded. After a lapse the Agent connects again (new epoch) and replays from its journal.

## Lease and heartbeat

- Lease: 300 seconds, renewed by `AgentLeaseKeeper`. A heartbeat writes to the database **at most once per 100 seconds per session**, however often the Agent pings (the keeper holds the last write time in memory). A renewal that matches no row means a newer session replaced this one, and the gateway closes the socket.
- `expireLapsedSessions` (run by the outbox sweep, every 5 minutes) closes sessions whose lease lapsed (`lease_expired`). Presence ("online") uses the lease; the write fence uses `disconnected_at`, so a connected Agent is never rejected because of a late renewal.
- A replaced session can stay open for up to a renewal interval. It can write nothing in that time: its writes are fenced.

## Compatibility adapter on the Workspace gateway

A Worker Agent connects to `/api/workspace-gateway/connect` with `workerId` and `workerSessionId` query parameters and `Authorization: Bearer <sessionToken>`, instead of `workspaceRuntimeId` and a runtime credential. The gateway authenticates the session, requires that the Worker was adopted from the gateway's own Workspace, and uses the Worker principal and its session fence as the Agent's identity. The Workspace's active runtime id is borrowed as a correlation id only; no runtime identity row is created for the Agent. Fences and audit use the Worker's identity, not the Workspace's.

Limits until P5 retires the Workspace gateway:

- One Agent per Workspace gateway at a time (the gateway holds one connection per Workspace; a second connection replaces the first).
- WebSocket only (no HTTP long-poll).
- An Agent may send only its own contract: hello, heartbeat, sync, readiness, `assignment.*` and `thread.status`. Workspace-wide messages (inventory, usage, MCP) are refused.

The public WebSocket route authenticates an Agent's bearer session and routes
the request to its mapped Workspace. The gateway then authenticates the same
session again before accepting it. The Dart Agent consumes the server's
`{nonce: ...}` and `{session: ...}` response envelopes. The real Agent/backend
pairing and hello/reconciliation path is exercised by
`apps/backend/test/domain/worker-agent-live.test.ts` with local PostgreSQL and
the Dart SDK (it skips when Dart is unavailable). This test uses the compatibility path and an unconfigured
Engine; it does not establish standalone Worker dispatch or provider execution.

## Audit (`worker_audit_log`)

`pairing.created`, `pairing.claimed`, `pairing.refused` (with a reason, no secret), `transfer.requested`, `transfer.completed`, `credential.rotated`, `credential.revoked`, `session.connected`, `session.superseded`. Written per event, never per ping.

## Invariants

`check-invariants.sql` adds: no open session on a revoked credential, no live credential or session on a removed Worker, no session past its lease for over an hour.
