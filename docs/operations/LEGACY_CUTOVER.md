# Workspace to Worker Agent cutover (P10)

Phase 10 of [WORKER_FIRST_IMPLEMENTATION_PHASES.md](../roadmaps/WORKER_FIRST_IMPLEMENTATION_PHASES.md). Run it after milestone M1 (the Worker flags are on for the whole cohort). Each step is a switch in the `legacy_cutover` table, so each one can be rehearsed and undone during the rollback window.

## Steps

| Step | Command | Effect |
| --- | --- | --- |
| 1. Convert each Workspace | `scripts/run-worker-agent.sh install --pairing-code CODE`, then `import-workspace --from <old data dir>` | One Agent per Worker. The pairing code is made from the existing Worker, so its id, Actor and history stay. `import-workspace` brings over the Work Root and folders (read-only unless `--write`); it never copies keys, Profiles or native sessions and never changes the old data. `--dry-run` shows the plan. |
| 2. Stop new registrations | `scripts/legacy-cutover.sh close-registration` | `POST /api/workspace-runtime/register` answers 410 `workspace_registration_closed`. Registered Workspaces keep working. |
| 3. Require a Worker | `scripts/legacy-cutover.sh require-worker` | New `worker_assignments` and `agent_commands` rows without a Worker Instance are refused (`worker_instance_required`). Existing rows are untouched. Refuses while an inventory Worker has no Worker Instance (`--force` overrides). |
| 4. Let legacy work finish | `scripts/legacy-cutover.sh status` | Wait until "legacy assignments still running" is 0. |
| 5. Close the gateway | `scripts/legacy-cutover.sh close-gateway` | The Workspace gateway and runtime transport answer 410 `workspace_gateway_closed`. Refuses while legacy assignments run (`--force` overrides). |
| 6. Archive the identity map | `scripts/legacy-cutover.sh archive-mapping` | Copies `legacy_worker_mapping` into `legacy_worker_mapping_archive`. Safe to repeat. |

On the VPS run the same script from the release directory with the service's environment (`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). The script prints the state after each step.

## Rollback

`scripts/legacy-cutover.sh reopen [registration|gateway|worker|all]` clears the switches. Nothing was dropped, so legacy Workspaces connect again and assignments without a Worker are accepted again. This works until the cleanup migration below ships.

### Rehearsal

`scripts/rehearse-legacy-cutover.sh` builds a scratch database from the migrations, runs steps 2, 3, 5 and 6, checks each one, rolls everything back and checks that. Run it before the real cutover and keep the output with the release notes. It has not been run in the authoring environment; run it on your Mac.

Also rehearse on real data: restore the latest production dump into a scratch database (`infra/vps/phase5/restore-test.sh`), run the steps there, and run `apps/backend/scripts/check-invariants.sql`.

## Cleanup after the rollback window

Not part of this phase's migration. When the window has passed (suggested: two weeks after step 5 with no `reopen`), ship one migration that drops the legacy paths. Do these in order and re-run `scripts/test-all.sh` after each:

1. Run `archive-mapping` once more and keep a dump.
2. Make `worker_assignments.worker_instance_id` and `agent_commands.worker_instance_id` `NOT NULL` (validate a `CHECK ... NOT VALID` first). Remove the trigger and `legacy_cutover`.
3. Drop the Workspace grant, Space selection and session tables and routes (`workspace_space_grants`, `workspace_selection*`, `workspace_runtime_*`, `execution_workspaces`, the `/api/workspace-runtime/*` and `/api/workspace-gateway/*` routes, `workspace-gateway.ts`, the compatibility bridge in `messaging/bridge.ts`). The list comes from `docs/roadmaps/WORKER_FIRST_P0_INVENTORY.md`; regenerate it with `node apps/backend/scripts/worker-first-inventory.mjs --write` first.
4. Remove `apps/workspace` from the release scripts once no Workspace builds are needed.

## Exit gate

- No new Work depends on a Workspace: after step 3, `SELECT count(*) FROM worker_assignments WHERE worker_instance_id IS NULL AND created_at > <step 3 time>` is 0.
- Nothing is lost: `status` shows 0 inventory Workers without a Worker Instance, and the archive row count equals the mapping row count.
- The rollback rehearsal passed and its output is attached to the release.
