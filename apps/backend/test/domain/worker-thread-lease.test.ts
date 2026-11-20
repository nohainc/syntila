import { expect, it } from "./helpers/vitest-compat";
import { atomically } from "../../src/platform/data.js";
import { startStatefulLease } from "../../src/domain/thread-coordinator.js";
import { pgD1 } from "./helpers/pg-d1";

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','User','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','Space','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Thread','active','U','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS','U','Workspace','now','now');
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('worker-a','','U','chatgpt','A');
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,primary_worker_instance_id,created_at,updated_at)
      VALUES('R1','W','U','stateful','direct',1,'{}','queued','{}','worker-a','now','now');`);
  const lease = (workspaceId: string | null, workerInstanceId: string | null, leaseId: string) =>
    atomically(db, "test.lease", (q) =>
      startStatefulLease(q, { threadId: "W", workRequestId: "R1", workspaceId, workerInstanceId, leaseId, now: "2030-01-01T00:00:00.000Z", expiresAt: "2030-01-02T00:00:00.000Z" }),
    );
  return { sqlite, lease };
}

it("a Worker Instance can hold the Thread lease, with a rising fencing token", async () => {
  const { sqlite, lease } = await fixture();
  await lease(null, "worker-a", "L1");
  expect(await sqlite.prepare("SELECT workspace_id AS ws, worker_instance_id AS w, fencing_token AS t FROM thread_runtime_leases WHERE id='L1'").get()).toMatchObject({ ws: null, w: "worker-a", t: 1 });
  await sqlite.exec("UPDATE thread_runtime_leases SET status='released' WHERE id='L1'");
  await lease(null, "worker-a", "L2");
  expect((await sqlite.prepare("SELECT fencing_token AS t FROM thread_runtime_leases WHERE id='L2'").get())!.t).toBe(2);
});

it("a lease has exactly one holder and a Thread one active lease", async () => {
  const { sqlite, lease } = await fixture();
  await expect(lease("WS", "worker-a", "BOTH")).rejects.toThrow();
  await expect(lease(null, null, "NONE")).rejects.toThrow();
  await lease(null, "worker-a", "L1");
  await expect(lease(null, "worker-a", "L2")).rejects.toThrow();
  await sqlite.close();
});

it("a request names a Workspace or a Worker, not both", async () => {
  const { sqlite } = await fixture();
  await expect(sqlite.exec("UPDATE work_requests SET primary_workspace_id='WS' WHERE id='R1'")).rejects.toThrow();
  await sqlite.close();
});
