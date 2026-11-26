import { afterAll, describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { atomically } from "../../src/platform/data.js";
import { acceptWorkerTarget } from "../../src/domain/worker-eligibility.js";
import { dispatchWorkerAssignment } from "../../src/domain/worker-dispatch.js";
import { startStatefulLease } from "../../src/domain/thread-coordinator.js";

// ADR-040: two Workers of one owner on one Thread. Only the lease holder may run
// a stateful step, and a superseded holder is refused after the lease moves on.
const priorFlags = process.env.SYNTILA_FEATURE_FLAGS;
afterAll(() => {
  if (priorFlags === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
  else process.env.SYNTILA_FEATURE_FLAGS = priorFlags;
});

async function fixture() {
  process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch,worker_stateful_work";
  const f = await pgD1();
  const worker = (n: string) => `
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('worker-${n}','','alice','chatgpt','${n}');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('cred-${n}','worker-${n}','${n.repeat(43)}','${n.repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at)
      VALUES ('worker-${n}','session-${n}',1,'cred-${n}','digest',now() + interval '5 minutes');`;
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
    INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at)
      VALUES ('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}',1,'${"a".repeat(64)}',now());
    ${worker("a")} ${worker("b")}
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,primary_worker_instance_id,created_at,updated_at)
      VALUES('R1','th','alice','stateful','direct',1,'{}','queued','{}','worker-a','now','now');`);
  const accept = async (workerId: string) => {
    const r = await acceptWorkerTarget(f.read, { workerId, requesterUserId: "alice", spaceId: "sp", threadId: "th", workflowId: "direct", readOnly: false, capabilities: ["thread_write"], requireOnline: true });
    if (r.ok === false) throw new Error(`not accepted: ${r.code}`);
    return r.snapshot;
  };
  const lease = (workerInstanceId: string, leaseId: string) =>
    atomically(f.db, "test.lease", (q) =>
      startStatefulLease(q, { threadId: "th", workRequestId: "R1", workerInstanceId, leaseId, now: "2030-01-01T00:00:00.000Z", expiresAt: "2999-01-02T00:00:00.000Z" }),
    );
  const dispatch = async (workerId: string, leaseId: string, fencingToken: number) =>
    dispatchWorkerAssignment({ SYNTILA_DB: f.db } as never, {
      runId: "run1", taskId: `task-${leaseId}`, workerTarget: await accept(workerId),
      task: { id: `task-${leaseId}`, role: "implement", objective: "x", capabilities: ["thread_write"], requestedByUserId: "alice", spaceId: "sp", threadId: "th", workRequestId: "R1", leaseId, fencingToken, executionClass: "stateful_thread", sessionPolicy: "stateless" } as never,
    } as never).catch((error) => ({ status: "threw", error: String(error) }));
  return { ...f, lease, dispatch };
}

describe("two Agents, one Thread", () => {
  it("refuses the Worker that does not hold the lease", async () => {
    const f = await fixture();
    await f.lease("worker-a", "L1");
    const refused = (await f.dispatch("worker-b", "L1", 1)) as { status: string; error?: string };
    expect(refused).toMatchObject({ status: "failed", error: "thread_leased_elsewhere" });
    // The holder is not refused by the lease check (it may fail later for other reasons).
    const holder = (await f.dispatch("worker-a", "L1", 1)) as { error?: string };
    expect(holder.error ?? "").not.toMatch(/thread_leased_elsewhere|lease_not_active/);
    await f.sqlite.close();
  });

  it("refuses a wrong or released lease and a stale fencing token", async () => {
    const f = await fixture();
    await f.lease("worker-a", "L1");
    expect(await f.dispatch("worker-a", "L1", 99)).toMatchObject({ error: "lease_not_active" });
    await f.sqlite.exec("UPDATE thread_runtime_leases SET status='released' WHERE id='L1'");
    expect(await f.dispatch("worker-a", "L1", 1)).toMatchObject({ error: "lease_not_active" });
    // The lease moves to the other Worker with a higher token; the first holder's old lease stays refused.
    await f.lease("worker-b", "L2");
    expect((await f.sqlite.prepare("SELECT fencing_token AS t FROM thread_runtime_leases WHERE id='L2'").get())!.t).toBe(2);
    expect(await f.dispatch("worker-a", "L1", 1)).toMatchObject({ error: "lease_not_active" });
    expect(await f.dispatch("worker-a", "L2", 2)).toMatchObject({ error: "thread_leased_elsewhere" });
    await f.sqlite.close();
  });
});
