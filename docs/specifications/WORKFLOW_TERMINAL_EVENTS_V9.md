# Workflow terminal events

A Workflow wakes as soon as one of its assignments is terminal, instead of polling
PostgreSQL every two seconds. PostgreSQL remains the only authority for the outcome;
the wake-up is a hint.

The Workflow runtime is a PostgreSQL-backed host (`apps/backend/src/platform/workflows.ts`)
that implements the durable-step subset the run Workflow uses: memoised `step.do`,
`step.sleep`, `step.waitForEvent` (events sent before a wait are buffered) and
`sendEvent`. Instances are replayed from the start on resume and claimed with a lease,
so a crashed process's instances are picked up by another.

## Sequence

1. Connect reports `assignment.result`, `error` or `cancelled`.
2. Cloud persists the terminal status in PostgreSQL through the guarded writers.
3. Cloud sends `assignment.ack` to Connect.
4. Cloud sends the `assignment-terminal` event to the run's Workflow instance
   (`apps/backend/src/domain/assignment-workflow-signal.ts`) and stamps
   `worker_assignments.workflow_signaled_at`.
5. The Workflow wakes, re-reads the assignment and classifies the outcome with
   `classifyStepAssignmentOutcome`.
6. Publication to the web app is unchanged.

Signalling is never a precondition for the acknowledgement, and a failure to signal
cannot change the outcome. The event type is `assignment-terminal` (no dots). Its
payload (`assignmentId`, `attemptId`, `taskId`, `runId`, `status`) identifies the
instance, task and attempt through `worker_assignments` joined to
`runs.workflow_instance_id`, and is never trusted: a stale, duplicate or forged event
costs at most one extra read.

## Outbox and recovery

A terminal assignment with `workflow_signaled_at IS NULL` is the outbox; there is no
second write path.

- **Immediate:** the gateway signals after the terminal acknowledgement.
- **Sweep:** a periodic job retries unsignalled terminal rows from the last 24 hours
  with fewer than 5 attempts (`workflow_signal_attempts`), a bounded batch per run.
- **Waiter:** every wait ends by itself within
  `ASSIGNMENT_RECONCILIATION_INTERVAL_MS` (30 s), so a lost event costs at most one
  reconciliation interval regardless of the sweep.
- A run without a Workflow instance is stamped as handled.

## Waiting for a Step

For each Work Step the Workflow dispatches, then loops: read the assignment (and nudge
queued work); continue if terminal; apply the phase-deadline revocation; otherwise
`step.waitForEvent("…assignment-wait:<attempt>:<n>", { type: "assignment-terminal",
timeout })`, where `timeout` is the time left in the current phase, capped at 30 s and
floored at 1 s. Wait names are deterministic per attempt and wake-up, so a duplicate
event cannot repeat a step.

- An event before the wait is buffered, and the read at the top of the loop sees the
  terminal row anyway. A lost event makes the wait time out (caught, not an error).
- A running assignment is treated as timed out when it is past `timeoutMs` plus a
  two-minute grace measured from `running_at`, so Connect can report its own timeout
  first.
- Revocation confirmation uses three 10-second wait rounds, re-sending the cancel
  between rounds, then one final read.
- The normal path performs no periodic reads; the remaining reads are the 30-second
  reconciliation and phase-deadline wake-ups.

Startup deadlines (command delivery, startup, queue wait) are enforced at wake-up
granularity: exact for the phase being waited on, and up to 30 seconds late when a
phase change shortens a deadline mid-wait. Queued (`created`) assignments are nudged on
each wake-up; the gateway's own flush on readiness is the primary path.

## Latency

The interval from `cloud_accepted` to `workflow_dispatch_started` (T2→T3 in
[Latency trace](LATENCY_TRACE_V1.md)) includes sequential work before the dispatch step
(prompt-input load, request-mode read, a status batch, task persistence, the
`work_request.started` and `step.queued` events, the queued task write), then the
dispatch step itself (target selection, assignment insert, gateway call). Several of
those reads are independent and could run concurrently; `started` must stay ordered
before `step.queued`.
