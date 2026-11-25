# ADR-034: Syntila Connect, pairing and session fencing

- **Status:** Accepted and implemented
- **Date:** 2026-11-19, revised 2026-11-24
- **Depends on:** ADR-032 (Worker identity), ADR-033 (durable commands)
- **Specifications:** [Worker pairing and sessions](../specifications/WORKER_PAIRING_AND_SESSIONS.md), [Connect CLI and services](../specifications/CONNECT_CLI_AND_SERVICES.md)

## Context

Each Worker needs its own credential, connection, journal and lifecycle, and
must run without any other Syntila application on the computer.

## Decision

1. **Syntila Connect** (`apps/connect`, CLI `syntila-connect`, desktop app
   `apps/connect_gui`) runs a computer's Workers. Each Worker has its own
   credential, session and journal; Connect never shares one identity between
   Workers. It reuses the generic CLI Worker Engine and signed Profiles; there is
   no binary per provider. The provider CLI starts only for an assignment.
2. **Pairing.** The owner gets a single-use, expiring pairing code for one
   Worker. Connect generates an Ed25519 key pair and sends only the public key
   with the code; the server consumes the code and stores the key atomically.
   The private key never leaves the computer.
3. **Authentication.** At connect time Connect signs a server nonce. Long-lived
   secrets never appear in URLs or logs.
4. **Session fencing.** Each login increments `worker_agent_sessions.session_epoch`
   and fences out the previous session. Every acknowledgement, start permit and
   terminal result is checked against the current epoch inside the same
   database write. A lock file stops two processes from sharing a Worker's
   data directory.
5. **Copies and transfers.** A copied installation is not detected; fencing
   means only one copy is current at a time and a stale copy can never commit a
   result. Moving a Worker is an explicit transfer that rotates the credential.
6. **Journal.** Connect acknowledges an assignment only after an fsync'd journal
   write. A replayed command returns the recorded state and never starts a
   second Engine; an attempt a crash may have started ends as a retryable
   failure and the server retries on a new attempt.
7. **States.** Registration (`unpaired → paired → revoked`), connection
   (`disconnected → authenticated → syncing → ready`) and execution
   (`idle → admitted → running → terminal`) are separate.
8. **Readiness and models.** Connect reports readiness (credential, Profile,
   folders, Engine) when it connects and publishes the models and efforts its
   provider CLI offers; the owner can ask for a refresh.
9. **Credentials at rest** use the platform store: macOS Keychain, Windows
   DPAPI, Linux Secret Service (opt-in) or an owner-only file.
10. **Current user only.** Connect is installed per OS user, runs as that user
    (launchd agent, systemd user unit, Windows logon task), and never needs
    administrator rights. Workers under one OS user share that user's files and
    provider logins; this is documented, not isolated.
11. **One account per computer** (ADR-043): a Connect installation pairs Workers
    of one account only.
12. **Updates** are manual (download or package manager) for now; a signed
    update channel is a later decision.

## Consequences

- Workers run with nothing else installed.
- Idle cost grows with the number of Workers (one socket, heartbeat and session
  row each).
