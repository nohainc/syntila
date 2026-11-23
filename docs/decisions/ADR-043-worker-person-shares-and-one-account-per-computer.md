# ADR-043: Person Shares for Workers, and one account per computer

- **Status:** Accepted and implemented
- **Date:** 2026-11-23
- **Depends on:** ADR-032 (Worker Instances), ADR-034 (Worker pairing), ADR-035 (Worker-targeted dispatch), ADR-042 (Space member access)

## Context

A Worker runs on its owner's computer with the owner's provider CLI logins.
Two gaps existed:

1. Connect accepted a pairing code from any account. Pairing a computer to a
   second account handed that account the computer and its provider
   subscription, without limits, usage visibility or a way to revoke it.
2. Sharing was Space-bound (ADR-042). An owner could not let one person use a
   Worker for Chat in that person's own Spaces and personal Threads.

## Decision

### 1. One computer, one account

`POST /api/worker-agent/claim` accepts `pairedWorkerIds`: the Workers already
paired on this computer (Connect reads them from its `Workers/` directory).
Cloud refuses the claim with 409 while any of them still has an active
credential and belongs to another account. The answer never names that
account. Connect lists the local Workers to unpair
(`syntila-connect unpair --yes --worker ID`); once they are unpaired, or removed
in the app, the new account can pair. Handing a Worker over stays an explicit
transfer.

The check relies on Connect reporting its Workers honestly. It protects the
computer's user from pairing to another account by mistake; it is not a
defence against a modified Connect on a computer its user controls.

### 2. Person Shares

`worker_person_shares(worker_id, user_id, max_concurrent_requests,
max_run_seconds_per_month)` (migration `0046`). No expiry. Deleting the row
revokes the share; it takes effect at the next admission and dispatch check.

- **Who:** only someone in the owner's People (`people_relationships` or a
  connected `person_connections` row).
- **Where:** the person's personal (direct) Threads and Spaces they own. Never a
  Space someone else owns: that would bring a third person's computer into the
  Space without its owner's consent.
- **What:** the Chat workflow only, read-only, without `thread_write` or
  `test_execution`. `acceptWorkerTarget` forces mode `chat` and marks the
  snapshot `personShare: true`.
- **Models and efforts:** the Worker-wide member allow-list (ADR-042), closed
  by default.
- **Limits:** checked at admission (`resolveWorkerTargetBindings`) from the
  person's `worker_assignments` on the Worker this month: running requests
  against `max_concurrent_requests` (default 1) and run time against
  `max_run_seconds_per_month` (null = no limit). Over either limit: 429.
- **On the owner's computer:** dispatch sends no Space folder. Connect ignores
  any `spaceFolderId`, runs in the assignment's empty scratch directory in the
  provider's read-only mode, and never grants full access.
- **Routes:** owner `GET|PUT|DELETE /api/workers/:workerId/person-shares`;
  person `GET /api/workers/shared-with-me` (options narrowed to the allowed
  models, with `sharedByName`).
- **App:** the Worker detail view has "Share with people". The person's
  composer offers shared Workers as "Name · shared by Owner" in Chat only. On the
  first use in a session it shows a notice that messages go to the owner's
  computer.

## Consequences

- An owner can share a Worker with one person without sharing a Space, and can
  stop at any time. The person never gets Work, writes, shell or the owner's
  folders through a share.
- The person's conversation is processed, and kept in the provider CLI's
  session, on the owner's computer. This is disclosed, not prevented.
- A provider CLI's read-only mode limits writes, not reads. A shared Chat can
  still ask the provider to read files the owner's account can read. The
  scratch directory and the missing Space folder keep this out of the way
  but do not sandbox it.
- The concurrency limit counts assignments, so requests still waiting in the
  Thread queue are not counted until they dispatch.
- A share is not removed when the people connection ends; the owner revokes
  it.
