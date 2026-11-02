# ADR-023: One concurrent AI execution for Free accounts

Status: accepted. Extends [ADR-022](ADR-022-account-plans.md).

## Policy
Free accounts run **one AI execution at a time per requesting account**;
Syntila Plus has no subscription-based cap. The limit is across all Spaces,
Threads, Workspaces, Workers and browser sessions, covers AI Chat and Work
steps, and does not apply to human messages. The Workspace's own capacity,
provider limits, permissions and Thread leases are unchanged and still apply.

The limit follows the **authenticated requester** (`worker_assignments.
requested_by_user_id`), never the Workspace owner: a Plus owner does not lift a
Free requester's limit on a shared Workspace, and a Free owner does not limit a
Plus requester. Workspace count and sharing policies are unchanged.

## Counting semantics
- **One execution = one non-terminal Worker Assignment** attributed to the
  requester. There is no separate counter: the slot is derived from
  `worker_assignments`, so it cannot drift, double-count a retry or duplicate
  event, or be lost on restart.
- **Taken** by the atomic assignment `INSERT` (the reservation). **Released**
  only when the assignment reaches `completed`, `failed`, `cancelled`,
  `timed_out` or `lost`. `revocation_pending` and `reconciling` still hold it,
  so a cancellation request or lost connectivity never frees a slot while the
  Worker may still be running.
- **Queued requests hold nothing.** A task refused a slot has no assignment.
  A Free request whose Workspace Service is only *connected* (synchronizing,
  paused or draining) also waits without a slot and reserves one once the
  Service is ready. Plus keeps the existing queue-behind-the-Service behaviour.
- **Workflow steps:** each dispatched step is one execution. Sequential steps
  release and re-reserve; parallel steps need separate slots, so on Free they
  run one after another.
- **Waiting for human input** holds nothing once the assignment is terminal.
- **Plan evaluation** (`paidOwnerSql`, same expiry/grace rules as ADR-022)
  runs inside the reservation, for every dispatch, including queued and retried
  work. Upgrade lets waiting work proceed immediately; on downgrade running
  work finishes and nothing more starts while the requester holds a slot.

## Enforcement
The single assignment choke point, `dispatchTaskAssignment`, inserts with
`WHERE executionSlotAdmissionSql(requester, task, cutoff)` (`account-plan.ts`).
Check and reservation are one SQL statement, so concurrent dispatches cannot
both take the Free slot. An internal, retry or reconnect dispatch goes through
the same path. Nothing is enforced by the client or by a process-local counter.

## Queue
Refused tasks wait durably in their Cloudflare Workflow (no new infrastructure):
the task stays `queued`, and the Workflow re-dispatches after a wake-up event or
a timed poll (15 s, then 60 s, about six hours at most, after which the step
fails with a clear message). The table `account_execution_waiters` (migration
`0097`) keeps order: a task is admitted only if no *earlier, still heartbeating*
waiter of the same requester exists, and a request that has not waited yet does
not jump ahead of waiters. A waiter that stops heartbeating (crashed Workflow,
two minutes) or is cancelled stops blocking, and requests blocked by
permissions, Thread leases or an offline Workspace are not waiters, so they
never hold up unrelated work. When an assignment becomes terminal, Cloud
nudges the requester's oldest waiter; the timed poll is the durable fallback.
The existing Thread request queue and its limits still bound how many requests
a Thread accepts.

## Reliability
- Stale-reservation recovery needs no timer: a slot is freed only by a terminal
  status, which existing leases, revocation confirmation, reconciliation and
  stale-assignment recovery already produce (`lost` included). A timer alone
  never frees a slot.
- Stale or duplicate results are rejected by the existing assignment fences.
- `account_execution_waiters` is bookkeeping only and holds no capacity.

## User experience
A queued step reports `waitReason` (`account_concurrency_limit` or
`workspace_not_ready`) and `executionPhaseDetail`: "Free runs one AI task at a
time. This request will start when your current task finishes." (distinct from
Workspace or provider capacity text). The `step.queued` event carries `reason`
and `message`. Cancelling a queued request uses the existing cancel flow. The
Free Profile plan line reads "Syntila Plus: Run AI tasks in parallel." There is
no upgrade action to link yet; no checkout flow is invented.

## Rollout
- Apply `0097_account_execution_slots.sql` before deploy. Without the
  `account_execution_waiters` table dispatch fails.
- Everyone is Free by default: grant Plus (see ADR-022) to accounts that should
  keep running in parallel *before* deploying.
- Work already running at deploy time finishes; new work queues behind it.

## Limitations
- A queued request cancelled while waiting is noticed at its next wake-up
  (at most 60 s), not instantly.
- Waking is best effort; ordering and admission never depend on it.
- Waiting tasks poll D1 about once a minute; very large numbers of queued Free
  requests add that load.
- Workflow-level waiting (the re-dispatch loop) is covered by reasoning and
  type checks plus dispatcher tests; there is no Workflow-runtime harness in
  this repository.
