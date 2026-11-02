# Persistence Contracts

Cloud owns server-side persistence and accesses D1 from its route and service
modules. The v8 schema in
[0001_syntila_v8.sql](../../apps/cloud/migrations-v8/0001_syntila_v8.sql) is
the clean development baseline. Workspace owns its local registry, Profiles,
Engines, session state, logs, and Work Root in the local data directory.

## Conversation persistence

[0010_conversation_workflows.sql](../../apps/cloud/migrations-v8/0010_conversation_workflows.sql)
adds Workflow-owned `conversations` and immutable `conversation_work_requests`
associations. Accepted-request revisions advance atomically with Work creation
and idempotency receipts; context revisions remain zero until materialization
exists. No historical backfill or provider-session storage is introduced in Cloud.
See [Conversation Continuity v1](CONVERSATION_CONTINUITY_V1.md).

[0011_conversation_turns.sql](../../apps/cloud/migrations-v8/0011_conversation_turns.sql)
adds immutable Conversation user messages and per-assignment worker turns.
Assignment creation and status transitions produce/update turn records atomically
through D1 triggers. Attribution is frozen from selection evidence; retries have
separate records. Cloud stores only opaque logical session-scope references,
never native CLI handles. Existing associated user messages are seeded from their
immutable request inputs; historical assignments are not guessed/backfilled.
See the Phase 4 lifecycle and release requirements in the continuity contract.

## D1 schema lifecycle

`0001_syntila_v8.sql` has been applied to production and is now immutable,
even though the v8 release declaration remains withheld. Its contents must not
be edited to repair production. All schema changes use new, ordered forward
migrations (for example, `0002_<purpose>.sql`) and the normal production
migration flow. The desktop auth audience correction is recorded in
[`0002_desktop_auth_multi_audience.sql`](../../apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql).

[`0006_chat_workflow_admission.sql`](../../apps/cloud/migrations-v8/0006_chat_workflow_admission.sql)
extends Workflow/Step constraints for Chat. It preserves historical immutable
snapshots and related records during an atomic rebuild with foreign keys enabled.
The production runner prepares pending 0006 from deployed schema metadata,
preserving historical additions and the complete foreign-key dependency closure.
Its assertions reject schema changes between preparation and application. The
checked-in canonical migration remains unchanged; already-applied migrations are
never regenerated or replayed. See the
[production runbook](../operations/PRODUCTION_PROVISIONING.md).
[`0007_chat_profile_starter_attestation.sql`](../../apps/cloud/migrations-v8/0007_chat_profile_starter_attestation.sql)
updates only the unchanged official Codex development starter. It preserves
operator-edited templates, Drafts and published releases.
[`0008_codex_compatibility_approval_policy.sql`](../../apps/cloud/migrations-v8/0008_codex_compatibility_approval_policy.sql)
synchronizes explicit non-interactive approval policy across the Codex starter's
argument layouts, again preserving customized templates and published releases.
[`0003_workspace_installations.sql`](../../apps/cloud/migrations-v8/0003_workspace_installations.sql)
introduces stable installation ownership independently from runtime
credentials. It seeds ownership from runtime identity history and release audit
events. If legacy history reuses an installation ID across multiple Workspaces,
it preserves a single owner and selects the sole non-revoked Workspace; when
all associated Workspaces and runtime identities are revoked, it selects the
newest historical Workspace while retaining that owner. It aborts on mixed
owners, multiple non-revoked Workspaces, a live runtime on a revoked Workspace,
or one Workspace mapped to multiple installation IDs.
[`0004_workspace_runtime_identity_uniqueness.sql`](../../apps/cloud/migrations-v8/0004_workspace_runtime_identity_uniqueness.sql)
adds a unique partial index that permits at most one unrevoked runtime identity
per Workspace. It aborts if preexisting rows violate that invariant.
[`0005_workspace_schema_alignment.sql`](../../apps/cloud/migrations-v8/0005_workspace_schema_alignment.sql)
aligns the deployed `execution_workspaces` and `workspace_runtime_identities`
table definitions and indexes with the v8 canonical contract while preserving all
existing rows.

Wrangler records applied migrations by filename. Editing an applied migration
does not make it run again, so never rewrite, remove, or reorder an applied
migration. New development databases apply the complete ordered migration set.
Production migrations must preserve existing records, verify migration
invariants such as before/after row counts, and fail atomically if those checks
do not pass. Never silently discard active human sessions during a schema
change.

Space-scoped records derive authorization from Space membership. Execution
Workspaces are user-owned and connect to Spaces only through explicit
Workspace Space Grants. Human and runtime bearer credentials are held in OS
secure storage; Cloud stores only their token hashes. Provider CLI sign-in is
owned by the provider CLI's local configuration. Plaintext credentials are not
stored in D1.

## Row and payload split

D1 stores identifiers, relationships, statuses, compact JSON contracts, provenance, digests, and R2 references. Artifact content that is large or unstructured is written to R2 and represented by an immutable reference containing bucket, key, size, media type, and digest. Small content may use an inline form under the same artifact contract.

## Canonical Conversation history

Syntila D1 owns the append-only Conversation history: original user messages,
completed Worker responses, workflow/execution facts, important artifact events,
and context revision events. Transactional triggers record these facts alongside
source changes. Source execution cleanup preserves history; deleting its owning
Conversation is the retention boundary. Full recorded text is available through
an authorized, bounded-cursor history API; provider-native sessions stay local to
Workspace. See [Conversation Continuity v1](CONVERSATION_CONTINUITY_V1.md#phase-5--canonical-conversation-history)
for the versioned contract, import limits, and ordered migration requirements.

## Work v1 state

Work Requests and Workflow Steps are persisted with dependencies, immutable
Workflow/execution snapshots, and assignment references. Runs and Worker
assignments record execution state. A Work Request containing any stateful
Step holds one Thread runtime lease for its lifetime; the lease selects the
Primary Workspace, serializes stateful requests for that Thread, and
provides a fencing token checked before filesystem mutation. Workspace resolves
the Thread directory from immutable Space and Thread IDs. Research
and Plan remain stateless, read-only Steps and may run on another eligible
granted Workspace; they do not mutate that directory. D1 persists Work and
lease metadata, not the local Thread directory or its Git state. Persisted
v8 records are authoritative current state; durable realtime events notify AX
of changes and let it refresh that state. The schema does not include the
retired pre-v8 Goal/Phase/Attempt/ModelCall/Finding/Verification aggregate.

Workspace Space Grants authorize a Space to use an owner-controlled
Workspace. A grant does not register repositories or map Space
repository/path identifiers to local paths. Provider CLIs manage Git inside
the ID-derived Thread directory through the generic CLI Worker Engine;
Workspace exposes only read-only Git observability for repositories found
there.

Thread authorization is evaluated from current Space membership and the
Thread access policy. The database does not duplicate Space roles in a
separate Thread membership table.

Every Workspace runtime identity has a credential hash. Stable installation
ownership lives in `workspace_installations`, which records the owner,
canonical Workspace, and active/released state. Its primary key permits one
ownership row per installation, and a unique partial index permits a Workspace
to have only one active installation binding. Runtime identity rows can be
rotated or revoked independently; a unique partial index permits one unrevoked
runtime identity per Workspace. Explicit release revokes runtime identities,
clears their legacy installation ID values, and marks the ownership row
released so another account can register the installation. The legacy runtime
`installation_id` column remains for schema compatibility but does not decide
ownership.

If a known pre-v8 registration has its runtime identity but lacks the v8
`workspace_installations` row, Workspace may request explicit reconciliation
after a fresh browser-approved desktop sign-in. Cloud verifies the exact local
Workspace/runtime IDs, current Workspace owner, persistent installation ID,
absence of competing active bindings, and absence of a recorded Release. Cloud
then inserts the canonical ownership row and an audit event atomically. Email
matching is never used. Ambiguous or foreign-owner state fails closed; an
active foreign owner must Release the installation first.

`worker_assignments.worker_type_id` identifies the logical Worker type;
`workspace_worker_id` identifies the Workspace's local Worker slot. The clean
v8 baseline stores the Cloud Workflow instance ID on
`runs.workflow_instance_id` and limits Thread execution policy to logical
Worker type IDs. It has no external-execution side table or provider allowlist.
Apply this baseline only to a fresh development database; it is not an upgrade
migration for an existing database.

Migration `0100_assignment_cloud_queue.sql` adds Gateway-owned
`worker_assignments.cloud_queue_reason` and `cloud_queue_since`. They record
capacity versus Service readiness waiting before delivery, independently of
Service-reported startup evidence. The first observation of a reason sets its
clock; repeated polls retain it. Only accepted Research v2 capacity waits are
exempt from the ordinary pre-delivery queue deadline. Assignment lifecycle and
confirmed-termination rules continue to own capacity release.

## Durable realtime event retention

Durable realtime events are change notifications, not the authoritative
business record. Cloud retains event rows and their idempotency keys for 90
days. The browser must refresh current Space, Thread, and Work state from
the authenticated read APIs after a reconnect or sequence gap; the realtime
transport does not promise historical event replay. Ephemeral events are never
persisted.

Cloud runs retention cleanup hourly and deletes up to 10,000 expired rows per
run, oldest first. Cleanup can take multiple runs to catch up after an outage
or a large backlog. Per-stream sequence cursors are retained indefinitely
and are never reset when old events are deleted, so sequence numbers remain
monotonic. Idempotency is guaranteed for the 90-day event retention window; a
retry after expiration may create a new event.

Human Product, Workspace Runtime, and Local Worker Protocol contracts have separate owners, endpoints, authentication, versions, and wire schemas. Keep one canonical schema source per boundary and generate language bindings from it. Shared domain IDs do not justify sharing transport envelopes.

The Work Request, Step, and lease behavior here must match the
[Work v1 Contract](WORK_V1_CONTRACT.md) and
[Architecture v8](../architecture/ARCHITECTURE_V8.md). Local directory identity
and mutation fencing are specified in
[ADR-011](../decisions/ADR-011-thread-working-directories.md).

See [Protocol Boundaries](../architecture/PROTOCOL_BOUNDARIES.md).

Durable realtime stream identity is `(kind, id)` for execution Workspace,
Space, or user synchronization. Collaboration events have no execution
Workspace identity. The fresh v8 baseline and one-time hosted alignment preserve
existing execution counters and events; see [realtime synchronization 1.1](REALTIME_SYNCHRONIZATION.md).

## Human mutation receipts

The fresh v8 baseline includes `mutation_receipts`, keyed by authenticated user,
mutation endpoint/entity scope, and opaque client idempotency key. A SHA-256 input
fingerprint and successful response are committed in the same D1 transaction as
the created entity. Receipts have no automatic expiry and no foreign key to the
created resource: deleting it must not permit a retry to resurrect it. User
deletion cascades receipts; authorization is rechecked before every replay.
See [Mutation idempotency v1](MUTATION_IDEMPOTENCY.md). Existing deployed databases
need this table created before deploying the updated routes; no migration chain
is introduced for the unreleased v8 baseline.


Phase 15 exact-history context versions follow accepted Conversation request
revisions. Snapshot base context is the owning request revision minus one; history
sequence separately freezes dispatch-time canonical facts. Migration
[0014_exact_history_context.sql](../../apps/cloud/migrations-v8/0014_exact_history_context.sql)
initializes existing context counters and updates implicit turn attribution without
rewriting historical snapshots. Workspace-local sessions separately track the
successfully consumed request revision and history sequence. See
[Conversation Continuity Phase 15](CONVERSATION_CONTINUITY_V1.md#phase-15--different-worker-continuity).


### Structured context assembly

The provider-independent Context Engine materializes versioned context facts from
Syntila's canonical history and immutable Work Request configuration. Workflow
state comes from the scoped Work Request and its tasks at dispatch. No additional
table or Phase 16 migration is introduced; native sessions remain Workspace-owned.
See [Phase 16](CONVERSATION_CONTINUITY_V1.md#phase-16--provider-independent-context-engine).


Workflow-aware context reads the scoped Work Request task/dependency graph,
completed prerequisite outputs, immutable instructions and scoped artifact
identity/digests. Core separates execution context from persistent Conversation
facts and rejects invalid graphs. No Phase 17 tables or migration are introduced.
See [Phase 17](CONVERSATION_CONTINUITY_V1.md#phase-17--workflow-aware-context).


### Logical WorkflowRun ownership

`conversation_workflow_runs` holds immutable Conversation/user-message/Work Request
ownership and pinned workflow identity; Work Request remains the single lifecycle
owner. `conversation_turns.workflow_run_id` links each actual invocation to that
logical execution. Existing `runs` are runtime attempts, including explicit retry
attempts. Migration `0015_conversation_workflow_runs.sql` backfills ownership without
rewriting historical turn evidence or canonical history. See
[Phase 18](CONVERSATION_CONTINUITY_V1.md#phase-18--workflowrun-and-workerturn-ownership).


### WorkflowStepRun identity and run lifecycle evidence

`conversation_workflow_step_runs` stores stable per-task identity, WorkflowRun
ownership, definition step ID and role. `workflow_tasks` own step lifecycle/results;
immutable Worker turns own actual selection and link via `workflow_step_run_id`.
Work Requests own run status and drive persisted WorkflowRun `started_at` and
`completed_at` evidence. Migration `0016_workflow_step_runs.sql` backfills these
associations/timestamps without rewriting turn evidence or canonical history.
Accepted Chat/Work requests create queued tasks and StepRuns in the acceptance
transaction, before scheduling. See
[Phase 19](CONVERSATION_CONTINUITY_V1.md#phase-19--workflowrun-and-workflowsteprun-data-model).
