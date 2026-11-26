# Mutation idempotency v1

**Boundary:** Human Product Protocol, AX ↔ Cloud. **Contract version:** 1.

The following creation routes accept `Idempotency-Key`:

| Route | Scope | Success |
| --- | --- | --- |
| `POST /spaces/:id/threads` | Space + create Thread | 201 |
| `POST /threads/:id/discussion-messages` | Thread + send Discussion | 201 |
| `POST /threads/:id/work-requests` | Thread + create Work Request | 202 |

Keys contain 16–128 ASCII letters, digits, underscores, or hyphens. AX generates
64-character cryptographically random hexadecimal keys. A key identifies one
logical operation, not a resource, credential, or payload hash. Explicit retries
must resend exactly the same JSON input and key. JSON object property order does
not matter; array order and all field values do. Reusing a key for different input
returns 409. Malformed keys return 400. Omitted keys preserve the existing API
behavior for callers during rollout; current AX supplies keys for these routes.

Cloud authorizes the current user and resource before looking up a receipt.
Receipts are scoped by user and route/resource, so another user or endpoint cannot
recover the response. The `mutation_receipts` primary key is committed atomically
with the domain writes. Concurrent duplicates lose the unique-key transaction,
roll back their domain writes, and recover the winner's response. Threads
and Discussion creation events and audit writes are in that same transaction.
A replay returns the original success status and JSON and adds
`Idempotency-Replayed: true`. It does not repeat a collaboration creation event.

Work receipts are committed together with the Work Request, Run, and audit before
runtime dispatch. An explicit retry after interrupted dispatch resumes only the
original Work Request and Run. Existing Workflow instance identity and coordinator
fencing prevent a second execution instance. Replaying terminal or deleted work
returns the original response without restarting it. Execution creation signals
retain their existing event idempotency identities. This contract does not retry
failed Work Steps; those remain separately authorized, intentional product actions.

Failed validation or a rolled-back transaction leaves no receipt. A committed
mutation retains its receipt even when subsequent dispatch or delivery fails.
Receipts have no TTL: expiry could silently convert an old retry into new AI work.
They survive deletion of the created resource and are removed with the user.
The original response may describe an entity later changed or deleted; clients
reconcile the current entity using targeted reads. Receipts do not store tokens,
authentication or provider credentials.

AX retains operation keys in authenticated-session memory for explicit retries
of unchanged input after failure. Success clears that retry identity so a later
intentional action gets a new key. Session clearing discards it. Changing the
input creates a new operation; it must not be presented as a retry. There is no
offline mutation queue, automatic connectivity replay, or persisted pending Work
execution. Across a browser restart, safe retries require the original key to be
supplied explicitly; AX does not currently persist pending operation identities.

## Storage rollout and verification

The fresh v8 schema baseline now includes `mutation_receipts`. Existing deployed
schemas require the same table before the updated Cloud routes are deployed.
The production schema preflight checks its columns and canonical definition so
deployments cannot silently omit the receipt storage required by AX requests.
This change introduces no Worker Agent or Local Worker Protocol change.
Cloud must be updated before AX relies on retained-key retries; an older Cloud
that ignores the header does not provide this guarantee.

SQLite-backed tests exercise atomic rollback, concurrent creation, key mismatch,
user/endpoint isolation, authorization revocation, resource deletion, interrupted
Work dispatch, and terminal execution safety. AX tests cover headers, response
loss, explicit retry identity, no background replay, success/session reset, and
shared temporary row replacement.
