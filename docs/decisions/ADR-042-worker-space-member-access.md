# ADR-042: Per-Space Member Access for Worker Instances

- **Status:** Accepted and implemented
- **Date:** 2026-11-22
- **Depends on:** ADR-032 (Worker Instances), ADR-035 (Worker-targeted dispatch)

## Implementation Notes

- **Migration & Schema:** `apps/backend/migrations/0044_worker_space_members.sql` and `apps/backend/migrations/schema.lock`.
- **Cloud Routes:** `GET|PUT /api/workers/:workerId/space-access` in `apps/backend/src/domain/routes/worker-space-access.ts` (registered in `table.ts`, `handlers.ts`, `index.ts`, and `docs/api/ROUTES.md`).
- **Cleanup:** `DELETE /api/workers/:workerId` (`workers.ts`) and `handleRemoveSpaceMember` (`spaces.ts`) delete matching `worker_space_members` rows.
- **Enforcement & Discovery:** `acceptWorkerTarget` (`worker-eligibility.ts`), `handleListEligibleWorkers` (`work-creation.ts`), and `GET /api/workers?includeShared=true` (`workers.ts`).
- **App Data & UI:** `AxWorkerSpaceAccess` / `AxWorkerSpaceMemberAccess` (`ax_models.dart`), `AxWorkerManagementSource` (`ax_data.dart`, `thread_api.dart`), `WorkerSpaceMembersSection` (`worker_space_members_section.dart`, mounted in `worker_instances_section.dart`), and `WorkerTargetPicker` / `workersFromInstances` (`worker_target_picker.dart`, `instance_workers.dart`).

## Context

Worker Instances (`worker_instances`, ADR-032) are owned by a single user (`owner_user_id`). By default, Worker management and execution eligibility (`acceptWorkerTarget` in `apps/backend/src/domain/worker-eligibility.ts`) are owner-only. Owners need a way on the Worker detail page to share a Worker with selected members of one of their Spaces, with per-member enable/disable state and permission levels.

## Decision

### 1. Storage Schema: `worker_space_members`

Access is scoped per `(worker_id, space_id, user_id)`:

```sql
CREATE TABLE worker_space_members (
  worker_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  permissions_json text NOT NULL DEFAULT '{"mode":"chat"}' CHECK (permissions_json IS JSON),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (worker_id, space_id, user_id)
);

CREATE INDEX worker_space_members_space_user_idx
  ON worker_space_members (space_id, user_id);
CREATE INDEX worker_space_members_user_idx
  ON worker_space_members (user_id);
```

Because `worker_instances` uses a `revoked_at` tombstone on `DELETE /api/workers/:workerId` rather than a SQL `DELETE`, revoking a Worker or removing a member from a Space (`space_memberships`) must also delete the corresponding `worker_space_members` rows.

### 2. Permission Semantics

`permissions_json` defines the member access ceiling:

```json
{ "mode": "chat" | "work" | "work+shell" }
```

- **`chat`** (default, safest): Member may run `chat` / read-only requests on the Worker; steps requiring `thread_write` (`repository:write`) or `test_execution` (`shell:execute`) are rejected.
- **`work`**: Member may run `chat` and `work` (`thread_write`) requests; steps requiring `test_execution` (`shell:execute`) are rejected.
- **`work+shell`**: Member may run `chat`, `work`, and `test_execution` (`shell:execute`) steps.

Effective permissions for a non-owner member are the **intersection** of:
1. Space & Thread execution rights (`requesterMayExecute`: active `space_memberships`, `spaceMemberPermissions`, and Thread `access_policy_json`),
2. The `worker_space_members` row (`enabled = true` and `permissions_json.mode`), and
3. The Workflow/step's `requiredCapabilities` and `readOnly` flag.

The Worker owner (`w.owner_user_id = requesterUserId`) requires no member row. The Space owner's Workers are also available to eligible Space members under their Space rights, subject to any explicit member restriction and the Worker model allow-list.

### 3. Edit Rights and Cloud Routes

Only the **Worker owner** (`w.owner_user_id = context.userId`, with `w.revoked_at IS NULL`) may read or update `worker_space_members` for that Worker, and only for a Space in which the owner holds manage rights:

- `GET /api/workers/:workerId/space-access?spaceId=<spaceId>` — returns the Space's members paired with their current Worker access (`enabled`, `permissions`).
- `PUT /api/workers/:workerId/space-access` — replaces the Space member access entries for `(workerId, spaceId)` from `{ spaceId, members: [{ userId, enabled, permissions }] }`. Validates Worker ownership and non-revoked status, Space existence and caller manage rights, that every target `userId` is a current member of `spaceId`, and plan limits.

Non-owners are rejected (403/404 per route security policy).

### 4. Enforcement Point

Server-side enforcement lives in `acceptWorkerTarget` (`apps/backend/src/domain/worker-eligibility.ts`), which is the single gatekeeper called by:

- **Request admission & retry:** `resolveWorkerTargetBindings` and `recheckWorkerTarget` (`apps/backend/src/domain/routes/worker-target-bindings.ts`, invoked by `work-creation.ts` and `thread-request-queue.ts`).
- **Step dispatch:** `dispatchWorkerAssignment` (`apps/backend/src/domain/worker-dispatch.ts`).

For a non-owner requester, `acceptWorkerTarget` enforces the applicable Space rights, Worker access and model policy against the step. Workers owned by the Space owner follow the Space rights; an explicit member row can further restrict access. Workers owned by other members require an enabled access row. `handleListEligibleWorkers` (`apps/backend/src/domain/routes/work-creation.ts`) also includes shared Workers (`worker_space_members` where `space_id = spaceId AND user_id = requesterUserId AND enabled = true`) in its candidate query so members can see and select them in the picker.

## Consequences

- **Positive:** Relational isolation; foreign-key cascades and explicit cleanup on Worker revoke or Space departure; single server-side enforcement point covering both admission and per-step dispatch; reuses the familiar `chat` / `work` / `work+shell` mode semantics.
- **Negative / Risks:** Additive migration and new Cloud/App endpoints are required before UI and dispatch enforcement can be enabled. Existing `worker_instances` owner-only assumptions in tests must be preserved for the owner path.

## Amendment: Worker-wide model and effort allow-list for members

The owner ticks which models and efforts members may use on a Worker once; it applies to every non-owner member in every Space the Worker is shared with. There is no per-Space or per-member table. It is an allow-list: nothing is available to members until the owner ticks it, so a new Worker, or a model the Worker reports later, starts closed. (The owner's own selector visibility is the opposite: everything starts visible.)

- **Storage:** `worker_member_model_access(worker_id PK, allowed_models_json, allowed_efforts_json)` (migration `0045_worker_member_model_access.sql`). No row means nothing is allowed. It cascades with the Worker.
- **Route:** `GET|PUT /api/workers/:workerId/member-model-access` (owner only), body `{ modelAccess: { allowedModels, allowedEfforts } }`.
- **Enforcement:** `acceptWorkerTarget` rejects a non-owner request whose model (chosen or default) is not allowed with `model_not_supported`, or whose effort is not allowed for that model with `effort_not_supported`. A request that names no model is not checked. The owner is never limited.
- **UI:** the "Models for members" card on the Worker detail view reuses the Worker's own model/effort table (`WorkerModelVisibilityTable`), all unticked by default.
- **Known gap:** the member-side picker does not yet hide models that are not allowed. The server refuses them.

## Amendment: Space owner's Workers follow Space rights

The Space owner's Workers are the Space's AI. A member no longer needs a `worker_space_members` row to use them: the Space rights "Use Space AI for Chat" / "Use Space AI for Work" (`spaceMemberPermissions`, checked by `requesterMayExecute`) decide the workflow, and the Worker-wide model/effort allow-list above still limits models and efforts (closed by default).

- **Enforcement:** `acceptWorkerTarget` admits a non-owner without a row when the Worker's owner owns the Space. Without a row the mode ceiling is `work+shell`, so the Space Work right governs Work. An explicit row still applies: `enabled = false` refuses (`execute_not_permitted`) and its `mode` caps the member. Workers of other members still need a row. Personal (direct) Spaces accept only the requester's own Workers.
- **Discovery:** `handleListEligibleWorkers` includes the Space owner's Workers. `GET /api/spaces/:spaceId/workers` lists them to a member with a Chat or Work right (empty for the owner, personal and support Spaces), leaving out ones the member is explicitly disabled for, with `executionOptions` narrowed to the allowed models and efforts. This closes the picker gap noted above.
- **App:** the Thread page passes these as shared Workers to `workersFromInstances` in shared Spaces.

## Plan requirement

Giving members access to a Worker needs the Plus feature `worker.sharing`
(`requirePaidFeature`, ADR-022). Turning access off stays free. When the
owner's plan lapses, member access is refused at dispatch until the owner is
paid again; the stored access is kept. A Worker that belongs to the Space
follows Space rights and is not affected.
