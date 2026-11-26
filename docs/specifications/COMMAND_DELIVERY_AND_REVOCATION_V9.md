# Worker command delivery and revocation

Cloud persists a command for a specific Worker assignment before sending a wakeup. Delivery is at least once; a delivery acknowledgement does not mean the Engine or provider has started. Connect journals the attempt before acknowledgement and returns recorded state for a replay instead of launching a second Engine. See [Event Streams](EVENT_STREAMS.md) and [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md).

## Start fencing

Cloud and Connect correlate assignment, attempt and Worker identities and check the current session fence. An assignment is marked running on its explicit start evidence, not on queueing or delivery. Where the start-permit protocol applies, Connect requests a permit before starting the Engine; revocation and permit issuance are checked against current assignment state. A stale Worker session cannot commit an acknowledgement or result.

## Revocation lifecycle

Cancellation, a deadline or a lost Worker can require work to stop. For work that may already have been delivered, Cloud records revocation intent and sends cancellation; it must not claim the process has stopped until Connect confirms the stop or reports a terminal outcome. While the outcome is uncertain the assignment can remain `revocation_pending` or `reconciling` and retains its capacity slot. A never-dispatched assignment, or one proven not to have received a start permit, can be finalized without waiting for a process stop. The transition rules are implemented in `apps/backend/src/domain/assignment-revocation.ts`.

## Reconnect and retry

Connect reconciles its journal after reconnect and resends unacknowledged terminal results. A crash that may have started an Engine ends that attempt as a retryable failure; it is never restarted under the same attempt. Cloud retries only when its lifecycle and revocation rules permit a new attempt. A disconnected Worker can leave an uncertain revocation awaiting reconciliation; a timeout alone is not proof that the provider stopped.

## Acceptance

Backend revocation and Worker gateway tests exercise conditional writes, cancellation and session fences. Connect's Agent matrix covers crash points and duplicate delivery; the live Agent test covers a real backend restart and a newer session epoch. Installed-device, real-provider and in-flight production restart evidence remain separate acceptance requirements.
