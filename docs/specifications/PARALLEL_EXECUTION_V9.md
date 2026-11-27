# Parallel execution and queue management

Queueing is an explicit part of the assignment lifecycle. Cloud persists and
dispatches assignments even when the selected Worker is at its effective
capacity. Syntila Connect is the final admission authority: it atomically
reserves a local slot, starts one isolated Engine process per assignment, and
transfers a released slot to the next waiter without changing the assignment
identity.

## Effective capacity

Each Worker reports its `localConcurrencyLimit` to Cloud. Cloud counts queued
and active assignments for Worker scheduling and applies account execution slot
limits at dispatch. Queued assignments are durable in
`worker_assignments.status = 'created'` and do not claim a provider process.
Connect owns the final slot reservation and is the only place that claims a
live process slot. Waiters are admitted first-in-first-out; one whose provider
session is busy is skipped rather than blocking the others.

## Local controls

Capacity and sleep-prevention preferences are managed locally through Connect
while the service is running or stopped, independently of Cloud connectivity.
Raising the limit immediately admits eligible waiters. Lowering it preserves
running assignments and admits no further work until capacity is available.
Resetting slots remains a separate confirmed recovery action that stops running
and waiting work.

## Deadlines

`timeoutMs` is the provider/Engine execution deadline and starts after local
slot admission. `queueWaitTimeoutMs` is an independent deadline beginning when
the assignment enters the local queue. The default queue deadline is two
minutes. Cloud workflow polling and stale-assignment recovery use the queue
deadline before startup and the execution deadline after the explicit
provider-start acknowledgement.

## Isolation and cancellation

Every admitted assignment has its own Engine process, process ownership
record, event correlation IDs, and cancellation path. Durable provider session
locks serialize attempts that intentionally resume the same native session;
different logical sessions can execute concurrently. Stateful repository
mutations continue to use the Space/Thread mutation coordinator, while
read-only assignments do not acquire that write lock.

Cancellation removes a queued waiter without releasing a slot it never held.
When a running assignment terminates, its slot is transferred atomically to
the next waiter. The transfer is marked reserved before the waiter resumes so
a cancellation racing with dequeue cannot launch an unwanted process.

## Recovery

Process ownership records remain durable under Application Support. Service
startup reaps only an exact Engine identity (executable, state directory and
start identity), then rebuilds capacity from the live supervisor state. A
terminal Cloud result remains idempotent by assignment and attempt identity;
transport reconnects do not re-execute an assignment.

## Compatibility

Older assignment payloads without `queueWaitTimeoutMs` or
`maxConcurrentAssignments` remain accepted during rollout. New Cloud payloads
always include both fields. The queue deadline is persisted so Cloud recovery does not mistake a
healthy local queue for a lost execution.
