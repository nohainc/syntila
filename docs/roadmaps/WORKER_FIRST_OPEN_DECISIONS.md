# Worker-first: items that need a decision before code (2026-11-20)

Done in code: durable-session recovery for steps with their own session (a
`session_resume_failed` attempt retries with a fresh native session), thread-level
cursor resume for the `user` and `space` streams (`cursor` on
`subscription.subscribe`, kept events replayed, otherwise `sync.required`), the
bridge parity test, Profile `capabilities`, Git-reference handoff, Work Root import.

## 1. Stateful Workflows on the Worker path (see ADR-040)
Today `work-creation.ts` refuses Workflows with a `stateful_thread` step on a
Worker target, because the Thread lease (`scheduler.ts` `statefulLease`) is bound
to a Primary Workspace. Decide: (a) the lease binds to one Worker Instance plus
its Space folder (the Agent owns the checkout; one writer per Thread), or (b)
stateful Work stays Workspace-only. Option (a) needs a lease table keyed by
`worker_instance_id`, fencing by Agent session epoch, and a write-conflict rule
when two Workers target one Space folder. This changes who may write to a
repository, so it should be an ADR first.

## 2. Plugin Types on the Agent (see ADR-041)
Plugin Types (ADR-027) carry an owner-defined `executor`, i.e. a local command.
Running those on an Agent means the Agent executes a command the Cloud sent.
Decide how it is signed and approved (owner approves each executor digest on the
Agent, like Allowed Folders) before the Agent may run one. Until then
`worker-eligibility.ts` keeps refusing plugin Types on the Worker path.

## 3. Thread-level streams (decided and implemented)
A Thread stream is the Thread's slice of its Space stream, numbered by the Space
sequence (no migration, no publisher change). `subscription.subscribe` accepts
`{kind:"thread"}` with an optional `cursor`; the head is the Space head; replay
returns the Thread's kept events above the cursor (ordered, not gapless, null when
more than 500 or unavailable, then `sync.required`). Live Space events carrying a
`threadId` are also delivered to the Thread's subscribers, and losing Space access
ends the Thread subscription. A durable per-Thread sequence stays an option later.

## 4. Removing the legacy human frames
The Flutter app (`apps/app/lib/src/realtime/*`, `ax/sync/*`) still speaks the
legacy `realtime.hello` / `subscribe` / `event` frames; it does not use
`syntila.messaging/1`. Remove the legacy frames in `realtime-gateway.ts` only after
the Flutter client is migrated and tested on a device.
