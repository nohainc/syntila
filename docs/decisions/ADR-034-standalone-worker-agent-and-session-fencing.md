# ADR-034: Standalone Worker Agent, Pairing and Session Fencing

- **Status:** Proposed
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D2, D3 local Manager, invariants 1, 5 and 10)
- **Order:** 3 of 8. Depends on ADR-032 and ADR-033.
- **Related:** `WORKER_AGENT_RUNTIME_V1.md`, ADR-012/013/014, `WORKER_PROFILE_V9.md`

## Context

Today one Workspace runtime holds one connection and multiplexes every local Worker through it. To make Workers independent, each one needs its own credential, connection, journal and lifecycle, and must work without a Workspace application.

## Decision

1. **One Worker Instance = one Agent installation = one credential = at most one current session.** An Agent never multiplexes several Worker identities.
2. **Single `syntila-worker` binary**, extracted from `apps/workspace`, reusing the generic CLI Worker Engine and signed Profiles. There is no binary per provider. The provider CLI starts on demand and is never kept running just to hold the connection.
3. **Pairing:** the owner requests a single-use pairing challenge that expires and is bound to `(owner, worker_id, nonce, expiry)`. The **Agent generates a key pair** and sends only the public key with the challenge proof. The server atomically consumes the challenge and stores the public key. The private key never leaves the host. (Fallback if key pairs are infeasible: a random opaque token returned once and stored only as a digest.)
4. **Authentication:** the Agent proves possession of its private key, for example by signing a server nonce at connection time. Long-lived secrets never appear in URLs, query strings or logs.
5. **Session fencing.** Connecting atomically increments `worker_agent_sessions.session_epoch`, which locks out the previous session. Every command acknowledgement and terminal result is checked against the current epoch **in the same database write**. A local lock file stops two processes on one host from sharing a data directory.
6. **Clones and transfers.** A copied installation is not a valid Worker. Moving a Worker to another host means an explicit transfer: rotate the credential, lock out the old session, then activate the new one.
7. **Durable local journal** (fsync) per Worker. Acceptance is acknowledged only after the journal write. Replaying a command returns the recorded state and never starts a second Engine.
8. **Three separate state dimensions:** Registration (`unpaired → paired → revoked`), Connection (`disconnected → authenticated → syncing → ready`) and Execution (`idle → admitted → running → terminal`, plus `revocation_pending`).
9. **Optional local Worker Manager** handles installation, supervision and updates through local IPC or OS services. It is never on the network path and never holds an umbrella Cloud credential.
10. **Isolation honesty.** Agents running as the same OS user are **not** isolated from each other's local files or provider CLI credentials. The product documents this and offers a "separate OS user" install mode for anyone who needs real isolation.
11. During migration, Agents may connect through a compatibility adapter on the existing Workspace gateway. The unified gateway (ADR-038) is not a prerequisite.

## Consequences

- Workers can run with no Workspace installed.
- Idle cost grows with the number of Workers: N sockets, N heartbeats and N session rows. This is budgeted and measured (idle memory per Agent, lease writes per second).
- Release gate: Agents of the same Type and same name on two hosts stay independent. A cloned or stale session can never commit results.
