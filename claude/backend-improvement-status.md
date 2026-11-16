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

## Package 1: request bodies read with schemas

Before: 39 `readJson(` sites in 22 route files, fields checked by hand. After: 1 allowlisted site (`mcp-action.ts`, forwarded verbatim to the Workspace gateway); every other body is `readBody(request, Schema)` with schemas in `packages/protocol/src/api-requests.ts`. A wrong-typed or over-limit field is 400 `invalid_request`; `readBody` takes an optional message so the text the app already shows is kept. Handlers that reject unknown keys themselves use loose schemas; the Workspace runtime/registration routes and plugin routes map a rejected body to their own error JSON. Guard: `request-body-guard.test.ts` fails on a new `readJson(` outside the allowlist. Per-schema valid / wrong-typed / over-limit tests: `test/domain/request-body-schemas.test.ts` (32 cases, schema level) plus the route sweep. Commits: `101f74f1`, `867b1ef4`, `65c24c7f`, `ef5aa6bc`, `b529f9eb`, `b7883bca`, `188c6813`, `e48393b2`. Not done: the Flutter contract test (`apps/app/test/ax_api_contract_test.dart`) was not run (no Flutter/Dart on this machine); `ROUTES.md` unchanged (no route changed). Plugin routes have no handler-level unit tests (gap). The existing failure `workspace-member-access.test.ts` comes from other people's uncommitted edits (assignment-dispatcher.ts, workflow-execution-configuration.ts) and fails without these commits too.

## Package 2: one definition per repeated SQL statement

Detector: `apps/backend/scripts/dup-statements.ts` (`bun run dup-statements`), baseline in `claude/dup-statements-baseline.md`. Before: 34 same-file groups, 39 excess occurrences (the estimate of about 49 matched the any-file count). After: **5 groups, 6 excess**. 29 groups were folded into 29 named constants (one each) in 15 files (calls and bindings unchanged, one commit per file: `1b42db1b`, `76ebec1c`, `d4bef5ff`, `a72b561f`, `c92a9bed`, `a8c4bb50`, `e59826ff`, `edaea1f8`, `d2968825`, `1ba82c63`, `65a4cdba`, `f4298699`, `156e724f`, `3e279dea`, `43164c07`). Only literal statements and two dynamic ones that interpolate module constants were folded; execution stays at each call site, so connection, transaction and lock order are untouched.

Retained (documented one by one in `test/dup-statements.test.ts`, which also pins the ceiling): `workspace-gateway.ts` (3 groups) and `workflow-execution-configuration.ts` (1 group) have uncommitted edits by someone else, so folding them would mix into that work; `platform/pg-d1.ts` (1 group) is the adapter's own code and is removed in Package 3.

Write-path inventory: `scripts/write-paths.ts` now counts a shared SQL constant for every function that uses it, so folding does not change `docs/backend/WRITE_PATHS.md` (verified by diffing the tool's output on the unfolded and folded sources, and no diff after each batch). The one regeneration (`8ae66d46`) only brought the stale document from 175 to 178 paths, caused by earlier work in this task. Each batch passed the full suite (the one failure, `workspace-member-access.test.ts`, is from others' uncommitted edits and also fails without these commits) and the concurrency tests three times.

Lesson: moving a statement into a module constant silently weakens a static inventory that attributes statements to functions; teach the tool the new shape first and prove the output is identical before and after.

## Package 3: tagged SQL pilot (design review)

Done: `claude/backend-sql-layer-design.md` records the tagged API and its compatibility gaps. The only domain pilot is the read-only Profile Lab owner lookup in `routes/profile-lab-policy.ts`; its predicate and authorization checks are unchanged. Focused coverage checks active, missing and suspended users, case normalization, transaction joining and rollback, plus tagged fragments, repeated inputs, nulls and counts. The duplicate detector's prepare-count baseline moved from 719 to 718; the ceiling remains 5 groups / 6 excess. The previously failing member-access test was fixed with the parallel changes in `e827313c`; the old failure statements above are historical. The previously uncommitted files mentioned in the retained duplicate reasons are now committed, but their duplicate groups have not yet been folded.

Validation: clean full backend `bun run test`: 1231 pass / 0 fail across 169 files, with no serial retries; separate route sweep: 3 pass; concurrency: three consecutive runs, each 43 pass / 0 fail, including seeded PostgreSQL `check-invariants.sql` assertions. `bun run write-paths` produced no diff. The earlier pilot suite initially failed the detector's old prepare-count floor; its automatic serial retry passed after the floor was updated, and the full suite was then rerun cleanly. An earlier focused test used an invalid status and overlapped a second test process with the runner's global test-database cleanup; the fixture was corrected and the focused run passed (15/15). Subsequent database test runs were serialized.

Monitoring: the pilot is a read, which neither records adapter writer-lock statistics nor tagged transaction statistics. Static inspection confirms `server.ts` emits `db.tx`, `db.writes` and `db.writer_lock`, and `scripts/backend-logs.sh` includes them. No production logs were accessed. No schema changes or migrations.

Next: stop for review before converting another domain file. In particular, resolve per-site result normalization, error-message dependencies, optional global writer locking, ordered atomic batches and the monitoring label transition before migrating writes. Lesson: a count-based detector guard must change when an intentionally converted call moves to a different supported query form; preserve the duplicate ceiling separately.

## Package 3: incremental conversion

Batch 1: `routes/auth.ts` converts the desktop-session user lookup to `dataOf(env).read.row`; the mixed-case alias is quoted and status, ID predicate and authorization are unchanged. The statement is a read and emits neither adapter write statistics nor tagged transaction statistics. `claude/backend-tagged-sql-procedure.md` documents the manual conversion and review process. Product `.prepare(` occurrences: 718 → 717. Duplicate ceiling remains 5 groups / 6 excess; the detector's minimum legacy-call count was adjusted for the one intentional conversion.

Validation: `bun run test runtime.test dup-statements` 15 pass; full suite 1231 pass / 0 fail across 169 files, no serial retries; concurrency three times, 43 pass each, including seeded PostgreSQL invariants; separate route sweep 3 pass; `bun run write-paths` produced no diff. Static inspection confirmed `server.ts` and `scripts/backend-logs.sh` still agree on `db.tx` and `db.slow_tx` names. No production logs were accessed and no schema changed. Remaining work: migrate the other areas only after per-site review of adapter normalization, transaction and fallback lock semantics, error handling, batch ordering and monitoring. Do not remove the adapter in Phase 6.

Batch 2: `routes/space-workflow-configurations.ts` uses tagged reads for the existing two-branch configuration query. The optional workflow filter is bound repeatedly with the same value; configuration columns remain JSON text. The read retains the existing caller transaction and generates no writer statistics. D1-only test doubles in three test files were given explicit tagged query fixtures. Product `.prepare(` occurrences: 717 → 716; duplicate ceiling remains 5 groups / 6 excess. Write-path regeneration produced no diff; the same static monitoring checks apply.

Validation: focused configuration and detector tests passed (27 tests), followed by a full run that exposed nine failures in two additional D1-only fixture files. After adapting those fixtures, their focused tests passed (26 tests) and the complete suite passed 1231 / 0 across 169 files with no serial retries. Concurrency passed three times (43 each) with seeded invariants, and the route sweep passed 3 tests. The first failed full run and its automatic serial retries are not counted as the final gate. No schema changed.

Batch 3: `routes/notifications.ts` uses tagged SQL for feed reads and both mark-read cases, preserving Space membership checks, JSON text casting and the `notifications.read` transaction label. `releaseUpload` now receives the full environment and performs the delete in the existing or a new `files.release` transaction; this intentionally fixes the prior loss of the outer transaction when only its adapter was passed. A PostgreSQL test verifies that releasing a reservation rolls back with the enclosing transaction. No compatibility adapter was added. Product `.prepare(` occurrences: 716 → 712; duplicate ceiling remains 5 groups / 6 excess. Write-path regeneration produced no diff. The existing transaction labels and `db.tx` / `db.slow_tx` monitoring formats are unchanged. No schema changed.

Validation: 34 focused tests passed. The first full run failed one Thread attachment test after the runner's serial retry because its D1-only fake could not execute the new tagged cleanup; the reservation remained. Replacing that fake with the existing PostgreSQL fixture yielded 29 focused passes, then a clean full suite of 1232 / 0 across 169 files without serial retries. Three concurrency runs passed 43 each, including seeded invariants; the separate route sweep passed 3 tests.

Further conversion is incomplete: 712 `.prepare(` occurrences remain, including shared helpers, transaction and batch paths. A transaction-bound adapter exposes the underlying pool as `sql`, so `dataOf({ SYNTILA_DB: txEnv.SYNTILA_DB })` uses a separate connection and loses the open transaction. `releaseUpload` now passes the full joined environment; other bare-database helpers still require the same audit. The optional global writer lock, adapter error/value normalization, and write metrics also need per-site review. Phase 6 as a whole is not complete.

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
