# Backend improvement status

Rule: a rule that must hold under parallel writes is a constraint, never only a
SELECT pre-check. The pre-check may stay as the friendly early message.

## Done

| Commit | Change |
|---|---|
| 0019 / 0020 (earlier) | Unique Thread names, unique group Space names |
| `ce3ff6aa` | Space invitation acceptance no longer swallows a membership conflict (`ON CONFLICT DO NOTHING` removed); `CONSTRAINT_MESSAGES` for the membership key and the three pending-invitation indexes |
| `fc9107ae` | Migration 0021: no pending Workspace invitation beside an active person grant (triggers on both tables sharing one advisory lock per Workspace and e-mail) |
| `0d804de4` | Migration 0022: `plan_approvals`, one row per plan, inserted in the same batch as the phases |
| `07a344f2` | Queue edit / delete / send-now check the changed row; a lost change is 409 "This request is already being sent" (404 if gone) |
| `be1f7905` | Work Request retry: reservation, step reset and run insert in one transaction |
| `70a056ce` | Space invitation handler maps the PostgreSQL index name itself (regression found by the full run) |
| `ac56d85d` | Route sweep: each route in its own seeded world, real rows for every path parameter, guards for unmapped parameters and missing rows |
| `549abdd3` | Route sweep also runs as plain member and stranger, with a paid owner and an archived Thread (15,936 requests) |
| `b60c0753` | Route sweep: real `wrf-<uuid>` file/input ids, open Work Request, avatar url; lists unreached routes with `FUZZ_REPORT=1` |

## Per-rule audit

| Rule | Was it safe? | Guarantee now | Existing data |
|---|---|---|---|
| Already a Space member | Index existed (`space_memberships_space_id_user_id_key`), but acceptance hid the conflict: two invitations for one person both returned 200 | The key rolls the batch back; 409 "You are already a member of this Space". Test red 3/3 before | none needed |
| Person already has access | **Not safe** (two tables; invite racing accept left a pending invitation beside an active grant, red 3/3) | Triggers + shared advisory lock, constraint `workspace_invitations_no_active_grant` -> "This person already has access"; a grant going active expires redundant pending invitations | Migration 0021 expires overlapping pending invitations (kept, never deleted) |
| Pending Space invitations (email, user) | Already safe (`idx_space_invitations_pending_email/_user`); the by-user message mapping never matched PostgreSQL | Messages mapped by index name | none needed |
| Pending Workspace invitation | Already safe (`idx_workspace_invitations_pending_email`); loser got the generic text | Message mapped | none needed |
| Plan already approved | **Not safe** (check before the queue lock; reapproval after phases left the queue). Red 12/12 | `plan_approvals_pkey`, claim inserted with the phases, loser rolls back | Backfilled from queued phases and sent phase Work Requests; see limits |
| Already being retried | Already safe (conditional `UPDATE ... RETURNING id`) | Same, now one transaction with the step reset and run insert (no manual revert) | none needed |
| Already being sent | **Not safe** (writes unchecked after the pre-check) | Conditional writes with `RETURNING`; send-now moves only a queued item. Red 3/3 (row-lock test) | none needed |

## Validation

- Full `bun run test` on the final tree: 1185 pass, 0 fail, 166 files, 143 s (after the route sweep work). No file needed a serial retry. An earlier full run failed `people.test.ts` (my regression, fixed in `70a056ce`).
- `route-fuzz`: 2 pass. `migrate`: 20 pass. Every new race passed 4 consecutive repeats after the fixes.
- `schema.lock` generated on PostgreSQL 18.6 (Homebrew) in a throwaway database (`syntila_lock`, dropped afterwards). **PostgreSQL 16 was not available** (only 18 installed; the Docker daemon was not running), so the 16-vs-18 comparison was not done. Do it before deploying.

## Route sweep (test/route-fuzz.test.ts)

Before: 164 routes, one shared seed, owner only, ~3 s. The sweep deleted its own Space mid-run, so about 45 routes after `DELETE /api/spaces/:spaceId` only ever answered 404. Now every route and pass gets a freshly seeded world; path parameters resolve per route to real rows; a guard fails on an unmapped parameter or a row that does not exist. Reach (real pass, owner, some answer other than 404 / other than 404, 401, 405 / some 2xx): 106 / 90 / 56 of 164 before, 158 / 146 / 92 after. Runs as owner, member and stranger, paid and archived: 15,936 requests, ~23 s, 0 unexpected 5xx, 0 hangs, so no handler fix was needed. All 28 mutations that answered 2xx to the wrong-typed body are body-less actions (no validation gap). 18 routes cannot reach their lookup: Workspace runtime and worker-profile routes need a machine token, billing is not configured, file downloads need object storage, admin routes need an admin. Details and the per-parameter inventory: `claude/route-sweep-baseline.md`.

## Next

- Compare `bun run schema:lock` output on PostgreSQL 16 and 18.
- Workspace invitation cap (`MAX_PENDING_PER_WORKSPACE`) is a COUNT then INSERT: parallel creates can overshoot. Unchanged.
- Space invite to an existing member (`spaces.ts` "This user is already a Space member") is a pre-check without a database guarantee (matches by e-mail through a join). Unchanged.
- Migration 0021 matches on the user's e-mail as stored; a later e-mail change is not re-checked.
- `workspace-access.ts` "already connected to the Space" and `workspaces-management.ts` "already have a Workspace named" were not audited for a backing index.
- Stop-all-phases deletes only queued phases by design; a phase already sending is left.
- Product decision: a plain Space member can clear a Thread's work history (`POST /api/threads/:id/work-history/clear` answers 200).
- Route sweep: give the test an in-memory object bucket and a machine/admin token to reach the 18 remaining routes.

## Limits of the plan-approval backfill

A plan whose phases were all sent and whose phase Work Requests were later deleted (retention) leaves no evidence, so it stays approvable.

## Lessons

- A conditional write must be checked: `UPDATE ... WHERE status = x` without looking at the returned row still reports success to the loser.
- `ON CONFLICT DO NOTHING` on a table with several unique rules hides the very conflict the user needs to hear about.
- A rule across two tables cannot be an index: share a lock key (or a shared row) and check the other table inside each writer.
- To test a check-then-write window deterministically, hold the row lock in a test transaction while the HTTP calls pass their check and block on the write.
- A race test that passes before the fix is a regression guard, not proof. Record it as such.
- A sweep that shares one seed destroys it: a DELETE midway starves every later route. Give each route its own world and prove with a guard that every mapped row exists.
- "Past the first lookup" is a weak metric (validation, 403 and 402 answer first); report it next to a stricter one.
- A clean sweep is a result, not a failure to look hard: record that no bug was found rather than inventing a fix.
- A pair of 200 responses is not always a bug: check the serial orders before asserting.
- Handler-level unit tests call handlers without the router; removing a handler's own error mapping breaks them.
