# Syntila Service supervision — V9 Phase 3

> **Superseded in part (P10).** Workspaces are replaced by Worker Agents ([ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md), [ADR-035](../decisions/ADR-035-worker-targeted-execution.md)). This document describes the legacy Workspace path, which is closed in stages and then removed ([LEGACY_CUTOVER.md](../operations/LEGACY_CUTOVER.md)). Do not build new features on it.

**Status:** Phase 3 implementation contract

## Local assignment lifecycle

The Workspace Service records operational phases independently from Cloud's
durable assignment outcome:

`received → validated → admitted → queued → launching → executing → terminated`

The journal remains the durable local source for terminal evidence. Structured
diagnostics record the operational phases so a missing provider event cannot
leave the assignment apparently active forever.

## Process ownership

Every supervised Engine process has a local JSON ownership record containing:

- schema and record identity;
- assignment, attempt, requested execution, and Worker identity;
- Engine PID, executable, start identity, and start time;
- Engine state and provider state;
- state and working-directory identities;
- execution deadline.

Recovery validates the executable, private state directory, command line, and
process start identity before signaling a PID. A PID alone is never treated as
ownership proof. Malformed or reused records are removed without signaling the
process they reference.

## Failure and capacity rules

- A journal entry is written before Engine launch is requested.
- Duplicate assignment admission is rejected while a local execution or
  ownership record exists.
- Queue cancellation completes without starting an Engine and without
  releasing a slot that was never acquired.
- Engine stream closure before a terminal frame is a provider-neutral process
  failure with local exit evidence, not an inferred timeout.
- Engine startup, process exit, cancellation, timeout, protocol failure, and
  terminal delivery failure all pass through the same cleanup path.
- Slot release is in the supervisor's `finally` path, including initialization
  exceptions and process-start failures.
- Terminal journal evidence is retained when Cloud is disconnected and is
  retried during synchronization after reconnect.

## Restart behavior

The Workspace installation lock is acquired before journal recovery. Existing
non-terminal journal entries become outcome-unknown and are not executed again;
orphaned Engine ownership records are then validated and reaped. A later Cloud
delivery can reconcile the journal evidence, but Service restart never guesses
that an interrupted provider succeeded.
