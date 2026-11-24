# ADR-032: Worker Instance and Actor Identity

- **Status:** Accepted and implemented
- **Date:** 2026-11-19
- **Related:** ADR-012, ADR-027, ADR-029, `WORKER_PROFILE_V9.md`

## Context

Today a local Worker is a slot inside a Workspace (`workspace_worker_inventory`). It has no durable identity of its own. Routing, authorization and history attribution go through `execution_workspace_id` and `worker_display_name`. Before we can connect, route or attribute Workers independently, a Worker needs its own stable identity.

## Decision

1. **Worker Instance** (`worker_instances.id`) is a durable, user-owned object. It is separate from **Worker Type** (`worker_catalog.worker_type_id`) and that type's signed Profile. Profiles stay per Type; we don't fork them per Instance.
2. **Actor** (`actors.id`, `kind ∈ {human, worker, system}`) is the immutable principal that authors messages. A human has exactly one Actor, mapped to `users.id`. Each Worker Instance has exactly one Actor. System Actors are fixed and created only by the server.
3. Workers are **not** rows in `users`. They have no email, billing, People approval, Space creation or human rights.
4. `name` is editable by the user and **not unique**. Binding, routing and authorization always use immutable IDs. An optional `description` or alias can tell duplicates apart. History stores a display snapshot (name and type) for when a Worker is renamed or removed.
5. Keep three fields separate: configured `enabled`, observed `online`, and observed `ready`.
6. Changing a Worker's Type means creating a new Instance. We don't change the Type in place.
7. The data model has no host, machine, platform or location fields. Diagnostic agent version and session data may be stored separately and are never used for routing.
8. Ownership changes only through an explicit transfer. Removing a Worker turns its record into a tombstone. Its Actor is never deleted while messages still reference it.

## Schema (additive)

- `actors(id, kind, user_id NULL UNIQUE, created_at, tombstoned_at)`
- `worker_instances(id, actor_id UNIQUE, owner_user_id, worker_type_id, name, description, enabled, default_model, created_at, updated_at, revoked_at)`. Indexes: `(owner_user_id, created_at)` and `(worker_type_id)`. There is **no** unique constraint on name.
- Backfill: one human Actor per user. One `worker_instances` row per existing `workspace_worker_inventory` entry, keeping `worker_id` where it is valid, plus a `legacy_worker_mapping` table where it isn't.

## Consequences

- Workers can be listed, created, renamed and revoked without touching Workspaces (`/api/workers` CRUD, owner-only).
- All later ADRs reference `worker_instance_id` and `actor_id`. Nothing changes yet in execution or transport.
- Two Workers with the same name and Type are a valid, tested case.

## Non-goals

Sharing a Worker with another user (deferred; see ADR-035), connection and credentials (ADR-034), and message authorship (ADR-036).
