# Two-Agent rehearsal (ADR-040)

Checks on real processes what `apps/backend/test/domain/worker-stateful-conflict.test.ts` checks in the database: two Worker Agents of one owner, one Thread, and only the lease holder runs stateful work. Nothing here has been run yet; record the result in the table at the end.

## Setup (one Mac, two data directories)

1. `scripts/start-local-backend.sh` (flags on by default, including `worker_stateful_work`).
2. In the app, create two pairing codes for the same account.
3. Start each Agent with its own data directory and its own Work Root:
   - `SYNTILA_WORKER_DATA_DIR=.development/agent-a scripts/run-worker-agent.sh install --pairing-code CODE_A --no-service`
   - `SYNTILA_WORKER_DATA_DIR=.development/agent-b scripts/run-worker-agent.sh install --pairing-code CODE_B --no-service`
   - `config set engineExecutable PATH` and `config set workRoot DIR_A` / `DIR_B` in each.
   - `SYNTILA_WORKER_DATA_DIR=... scripts/run-worker-agent.sh run` in two terminals.
4. Give both Agents the same folder grant for the Space, then create one Thread in that Space.

## Steps and expected results

| # | Action | Expected |
|---|--------|----------|
| 1 | Run a stateful Workflow on Worker A | Lease held by A; the Space folder on A shows the work |
| 2 | While it runs, pick Worker B for the same Thread | Refused `thread_leased_elsewhere` or `lease_not_active`; no assignment reaches B |
| 3 | Let A finish, then run a stateful Workflow on B | Allowed; lease moves to B |
| 4 | Stop B mid-step, then run on A before the lease expires | Refused until the lease ends; after it ends A runs |
| 5 | Replay an old assignment of A's earlier lease to A (kill and restart A with the old payload) | Agent refuses `stale_fence` (`thread-fences.json`) |
| 6 | Two stateful requests to the same Worker at once | Second waits or is refused (`stateful_single_worker`), never runs in parallel |

## Evidence to keep

`syntila-worker status --json` for both Agents, the two work-request rows (`primary_worker_instance_id`), the `thread_runtime_leases` row after each step, and the Agent journals.

## Result

| Date | Machine | Steps passed | Notes |
|------|---------|--------------|-------|
|      |         |              |       |
