# Duplicate SQL statements: baseline (Package 2, Phase 3)

Reproduce: `cd apps/backend && bun run dup-statements -- --all --cross-file`
(detector: `scripts/dup-statements.ts`, tests: `test/dup-statements.test.ts`). The output below is that command's output at the baseline commit.

## What counts as the same statement

Syntax-aware: the TypeScript parser finds `.prepare(sql)`, `.query(sql)`, `.unsafe(sql)` and the data layer's tagged templates (`rows`, `row`, `run`, `frag`, generic type arguments included); comments, prose and unrelated strings are not SQL. Two statements are the same when, after removing only what cannot change meaning, the text is identical: SQL comments dropped, whitespace collapsed outside quotes, `?N`/`$N` placeholders renumbered by first appearance (so `?3 ... ?3` equals `$1 ... $1`, but `?1 ... ?2` is not `?1 ... ?1`). Kept as written, so never merged: quoted text, casts, locking clauses (`FOR UPDATE`), predicates, keyword case, and every interpolated expression (a statement with `${...}` inside prepare/query/unsafe is "dynamic" and keyed by that source text).

- **groups**: distinct statements that occur at least twice in one file.
- **excess occurrences**: occurrences beyond the first, summed. This is how many definitions folding removes.

## Baseline

| | |
|---|---|
| Statements found | 756 (prepare 708, query 0, unsafe 41, tagged 7); 65 dynamic |
| Same-file duplicate groups | **34** in 18 files |
| Excess occurrences (same file) | **39** |
| `.prepare(` calls | 719 = 708 compared + 11 unresolved (below) |

## Reconciling the estimate of "about 49"

The 49 does not match the same-file definition. Alternative counts over the same 756 statements:

| Definition | Groups | Excess occurrences |
|---|---|---|
| Same file, normalized (this baseline, the task's definition) | 34 | 39 |
| Same file, whitespace-only normalization (no placeholder renumbering), literal arguments only | 32 | 37 |
| Same text anywhere in src, any file | 41 | 48 |

The estimate of about 49 matches the **any-file** count (48 excess occurrences): it counted the nine statements repeated across files (listed below) as well. Placeholder renumbering adds 2 same-file groups over whitespace-only matching; case-insensitive matching and ignoring placeholders entirely add none, so the normalization is not what separates 34 from 49. Statements built with `${...}` fragments are compared by their interpolated text and are almost never equal across places.

Unresolved `.prepare(` arguments (11, not compared): nine are assembled from shared fragments such as `${reportSelect()}` or `${INSERT}` (already one definition each; the fragment is the shared part), one is a conditional (`workflow-configurations.ts:297`), one is a constant (`MONTHLY_RUN_SECONDS_SQL`).

## Phase 4 notes

- Cross-file repeats are listed for information; Phase 4 folds same-file groups, and moves a cross-file statement into a shared module only when two files already share a data module.
- Groups with different locking, transaction or connection needs (for example the same `UPDATE` once inside a transaction and once outside) are reviewed one by one; the detector cannot see that.

## Output

```
statements: 756 (prepare 708, query 0, unsafe 41, tagged 7); dynamic: 65
same-file duplicate groups: 34 in 18 files; excess occurrences: 39 (min length 0)

src/domain/realtime-gateway.ts  lines 315, 338
    SELECT 1 AS owner FROM execution_workspaces WHERE id = $1 AND owner_user_id = $2 AND status <> 'revoked'
src/domain/routes/http-security.ts  lines 150, 164
    SELECT workflow_instance_id FROM runs WHERE id = $1
src/domain/routes/people.ts  lines 350, 353
    INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES ($1, $2, FALSE, $3, $3) ON CONFLICT(space_id, user_id) DO NOTHING
src/domain/routes/people.ts  lines 371, 409
    UPDATE person_invitations SET status = 'accepted', accepted_by_user_id = $1, updated_at = $2 WHERE id = $3
src/domain/routes/people.ts  lines 383, 415
    UPDATE person_connections SET direct_space_id = $1 WHERE user_low_id = $2 AND user_high_id = $3 AND status = 'connected'
src/domain/routes/people.ts  lines 597, 711
    SELECT id, inviter_user_id, invitee_user_id, status, expires_at, created_at FROM person_invitations WHERE status = 'pending' AND expires_at > $1 AND ((invite...
src/domain/routes/people.ts  lines 957, 1076, 1144
    SELECT * FROM person_invitations WHERE id = $1
src/domain/routes/people.ts  lines 1207, 1255
    UPDATE person_connections SET status = 'disconnected', disconnected_at = $1 WHERE user_low_id = $2 AND user_high_id = $3 AND status = 'connected'
src/domain/routes/releases.ts  lines 207, 361
    SELECT key_id FROM release_signing_key_revocations WHERE key_id = $1
src/domain/routes/route-idempotency.ts  lines 82, 97  [dynamic]
    DELETE FROM mutation_receipts WHERE user_id = $1 AND scope = $2 AND idempotency_key = $3 AND response_status = {{PENDING}}
src/domain/routes/spaces.ts  lines 621, 817
    SELECT u.id, u.display_name AS displayName, u.avatar_url AS avatarUrl, state.personal_name AS personalName FROM direct_spaces ds JOIN users u ON u.id = (CASE...
src/domain/routes/spaces.ts  lines 1159, 1286
    UPDATE spaces SET settings_json = syntila_json_set(settings_json, $1, $2), updated_at = $3 WHERE id = $4
src/domain/routes/spaces.ts  lines 1349, 1415, 1683
    UPDATE spaces SET settings_json = syntila_json_remove(settings_json, $1) WHERE id = $2
src/domain/routes/thread-request-queue.ts  lines 482, 592, 612
    SELECT COUNT(*) AS n FROM thread_request_queue WHERE thread_id = $1
src/domain/routes/threads.ts  lines 135, 466
    SELECT id, space_id AS spaceId, user_id AS userId, role, created_at AS createdAt, updated_at AS updatedAt FROM space_memberships WHERE space_id = $1 AND user...
src/domain/routes/threads.ts  lines 206, 698
    SELECT pc.status, ds.user_low_id AS userLowId, ds.user_high_id AS userHighId, EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = ds.space_id) AS isS...
src/domain/routes/threads.ts  lines 838, 871
    SELECT dm.id, dm.thread_id AS threadId, dm.author_user_id AS authorUserId, COALESCE(u.display_name, 'Member') AS authorName, dm.body, dm.attachments_json AS ...
src/domain/routes/user-files.ts  lines 162, 250
    DELETE FROM user_files WHERE id = $1 AND user_id = $2
src/domain/routes/work-lifecycle.ts  lines 622, 692
    SELECT policy_snapshot_json AS policySnapshotJson FROM runs WHERE work_request_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1
src/domain/routes/worker-plugins.ts  lines 253, 427
    SELECT manifest_digest AS digest FROM account_worker_plugin_versions WHERE plugin_ref = $1 AND version = $2
src/domain/routes/worker-plugins.ts  lines 318, 389
    SELECT 1 AS ok FROM account_worker_plugins WHERE plugin_ref = $1 AND owner_user_id = $2
src/domain/routes/workflow-default.ts  lines 105, 140
    SELECT configuration_json AS configurationJson FROM user_workflow_configurations WHERE user_id = $1 AND workflow_id = $2 AND workspace_id = $3
src/domain/routes/workflow-execution-configuration.ts  lines 108, 404
    SELECT i.workspace_id AS workspaceId FROM workspace_worker_inventory i JOIN execution_workspaces ew ON ew.id = i.workspace_id WHERE i.worker_id = $1 AND ew.o...
src/domain/routes/workflow-workspace.ts  lines 50, 99
    SELECT id FROM execution_workspaces WHERE id=$1 AND owner_user_id=$2 AND status != 'revoked'
src/domain/routes/workflow-workspace.ts  lines 140, 180
    INSERT INTO space_audit_log(id,space_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at) VALUES($1,$2,'user',$3,'workflow.workspace....
src/domain/routes/workspaces-registration.ts  lines 65, 209, 406
    SELECT wi.installation_id AS installationId, wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId, wi.status AS status, wi.released_at AS released...
src/domain/routes/workspaces-registration.ts  lines 243, 421
    SELECT i.id AS runtimeId, w.status AS workspaceStatus FROM workspace_runtime_identities i JOIN execution_workspaces w ON w.id = i.workspace_id WHERE i.worksp...
src/domain/routes/workspaces-registration.ts  lines 325, 436
    SELECT 1 AS released FROM workspace_audit_log WHERE action = 'workspace.ownership.released' AND CASE WHEN details_json IS JSON THEN (details_json::jsonb #>> ...
src/domain/routes/workspaces-registration.ts  lines 632, 785  [dynamic]
    SELECT COUNT(*) AS count FROM worker_assignments WHERE execution_workspace_id = $1 AND status IN ({{ACTIVE_ASSIGNMENT_STATUS_SQL}})
src/domain/thread-coordinator.ts  lines 397, 614
    UPDATE thread_runtime_leases SET expires_at = $1 WHERE id = $2 AND status = 'active'
src/domain/workspace-gateway.ts  lines 461, 942
    UPDATE execution_workspaces SET status = 'online', updated_at = $1 WHERE id = $2
src/domain/workspace-gateway.ts  lines 604, 802, 1066
    UPDATE execution_workspaces SET status = 'offline', updated_at = $1 WHERE id = $2
src/domain/workspace-gateway.ts  lines 2413, 2442
    SELECT id, execution_workspace_id, runtime_identity_id, worker_type_id, workspace_worker_id, run_id, task_id, attempt_id, idempotency_key FROM worker_assignm...
src/platform/pg-d1.ts  lines 299, 318
    SELECT parameter_types::text[] AS types FROM pg_prepared_statements WHERE name = $1

unresolved .prepare( arguments (not literals; not compared): 11
  src/domain/realtime-gateway.ts:1129 does not start like SQL {{query}} WHERE {{conditions.join(" AND ")}} ORDER BY e.occurred_at ASC, e.seque
  src/domain/routes/issue-reports.ts:850 does not start like SQL {{reportSelect()}}{{filters.length ? ` WHERE ${filters.join(" AND ")}` : ""}} OR
  src/domain/routes/issue-reports.ts:914 does not start like SQL {{reportSelect()}} WHERE ir.id = ?1
  src/domain/routes/issue-reports.ts:1177 does not start like SQL {{reportSelect()}} WHERE ir.id = ?1
  src/domain/routes/profiles.ts:57 does not start like SQL {{columns}} WHERE i.owner_user_id = ?1 AND ew.status != 'revoked' AND (?2::text 
  src/domain/routes/profiles.ts:74 does not start like SQL {{columns}} WHERE ew.status != 'revoked' AND i.owner_user_id <> ?1 -- A custom p
  src/domain/routes/queue-positions.ts:34 does not start like SQL {{INSERT}} COALESCE((SELECT MAX(position) FROM thread_request_queue WHERE thread
  src/domain/routes/queue-positions.ts:39 does not start like SQL {{INSERT}} COALESCE((SELECT MIN(position) FROM thread_request_queue WHERE thread
  src/domain/routes/queue-positions.ts:47 does not start like SQL {{INSERT}} (WITH phase AS ( SELECT MIN(position) AS p FROM thread_request_queue 
  src/domain/routes/workflow-configurations.ts:297 ConditionalExpression spaceId ? `INSERT INTO ${table} (${key}, workflow_id, schema_version, configurat
  src/domain/routes/workflow-execution-configuration.ts:220 Identifier MONTHLY_RUN_SECONDS_SQL

repeated across files: 9
  src/domain/attachment-storage.ts:106 src/domain/routes/work-request-files.ts:388
    DELETE FROM user_file_reservations WHERE id = $1 AND user_id = $2
  src/domain/event-publisher.ts:272 src/domain/routes/spaces.ts:897
    SELECT user_id FROM space_memberships WHERE space_id = $1
  src/domain/people.ts:128 src/domain/routes/people.ts:347
    INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at) VALUES ($1, $2, $3, NULL, $4)
  src/domain/queries.ts:122 src/domain/routes/people.ts:957 src/domain/routes/people.ts:1076 src/domain/routes/people.ts:1144
    SELECT * FROM person_invitations WHERE id = $1
  src/domain/routes/people.ts:341 src/domain/routes/spaces.ts:308
    INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES ($1, $2, $3, 'owner', $4, $4) ON CONFLICT(space_i
  src/domain/routes/thread-policy.ts:385 src/domain/routes/threads.ts:135 src/domain/routes/threads.ts:466
    SELECT id, space_id AS spaceId, user_id AS userId, role, created_at AS createdAt, updated_at AS updatedAt FROM space_memberships WHERE space
  src/domain/routes/workflow-configurations.ts:45 src/domain/routes/workflow-default.ts:61
    SELECT s.owner_user_id AS ownerUserId, COALESCE(s.kind, 'group') AS kind FROM spaces s JOIN space_memberships m ON m.space_id = s.id JOIN us
  src/domain/routes/workspaces-management.ts:281 src/domain/routes/workspaces-registration.ts:831
    UPDATE workspace_space_grants SET status = 'revoked', updated_at = $1 WHERE workspace_id = $2 AND status IN ('active', 'suspended')
  src/domain/routes/workspaces-management.ts:287 src/domain/routes/workspaces-registration.ts:1058
    UPDATE workspace_runtime_identities SET revoked_at = $1 WHERE workspace_id = $2 AND revoked_at IS NULL
```
