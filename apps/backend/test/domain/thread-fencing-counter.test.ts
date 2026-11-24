import { expect, it, vi } from "./helpers/vitest-compat";
import { readFileSync } from "node:fs";
vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: vi.fn(async () => ({
    context: { userId: "U", user: { displayName: "User" } },
    spaceId: "P",
  })),
}));
vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { atomically } from "../../src/platform/data.js";
import { startStatefulLease } from "../../src/domain/thread-coordinator.js";
import { handleClearWorkHistory } from "../../src/domain/routes/work-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
import { pgD1 } from "./helpers/pg-d1";

async function fixture() {
  const { sqlite, db } = await pgD1();
  // Clearing Work history bumps threads.work_session_generation (migration 0054
  // is not part of the shared fixture baseline).
  (await sqlite.exec(
    "" /* D1 migration: schema is final in PostgreSQL */,
  ));
  await sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','User','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','Space','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Thread','active','U','now','now');
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES('worker-a','','U','chatgpt','Worker');`);
  const queue = (id: string) =>
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,primary_worker_instance_id,created_at,updated_at)
         VALUES(?,'W','U','stateful','direct',1,'{}','queued','{}','worker-a','now','now')`,
      )
      .run(id);
  const acquire = async (workRequestId: string, leaseId: string) => {
    await atomically(db, "test.lease", (q) =>
      startStatefulLease(q, {
        threadId: "W",
        workRequestId,
        workspaceId: null,
        workerInstanceId: "worker-a",
        leaseId,
        now: "2030-01-01T00:00:00.000Z",
        expiresAt: "2030-01-02T00:00:00.000Z",
      }),
    );
    return (await sqlite
      .prepare(
        "SELECT fencing_token AS token FROM thread_runtime_leases WHERE id = ?",
      )
      .get(leaseId))!.token as number;
  };
  const finish = async (id: string, leaseId: string) => {
    await sqlite
      .prepare("UPDATE thread_runtime_leases SET status='released' WHERE id=?")
      .run(leaseId);
    await sqlite
      .prepare("UPDATE work_requests SET status='completed' WHERE id=?")
      .run(id);
  };
  const counter = async () =>
    (await sqlite
      .prepare("SELECT lease_fence_counter AS c FROM threads WHERE id='W'")
      .get())!.c as number;
  return { sqlite, db, queue, acquire, finish, counter };
}

it("issues strictly increasing tokens and starts the Work Request", async () => {
  const f = await fixture();
  try {
    await f.queue("R1");
    expect(await f.acquire("R1", "lease-1")).toBe(1);
    expect(
      (await f.sqlite.prepare("SELECT status FROM work_requests WHERE id='R1'").get())!
        .status,
    ).toBe("running");
    await f.finish("R1", "lease-1");
    await f.queue("R2");
    expect(await f.acquire("R2", "lease-2")).toBe(2);
    expect(await f.counter()).toBe(2);
  } finally {
    await f.sqlite.close();
  }
});

it("keeps tokens increasing after Work history is cleared", async () => {
  const f = await fixture();
  try {
    await f.queue("R1");
    await f.acquire("R1", "lease-1");
    await f.finish("R1", "lease-1");
    await f.queue("R2");
    await f.acquire("R2", "lease-2");
    await f.finish("R2", "lease-2");

    const response = await handleClearWorkHistory(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { SYNTILA_DB: f.db } as unknown as SecurityEnv,
      "W",
    );
    expect(response.status).toBe(200);
    // The Thread's counter survives, so the Workspace's recorded fence
    // (token 2 for lease-2) is never undercut by the next lease.
    expect(await f.counter()).toBe(2);
    await f.queue("R3");
    expect(await f.acquire("R3", "lease-3")).toBe(3);
  } finally {
    await f.sqlite.close();
  }
});

it("heals a counter that lags behind recorded lease tokens", async () => {
  const f = await fixture();
  try {
    await f.queue("R1");
    await f.acquire("R1", "lease-1");
    await f.finish("R1", "lease-1");
    await f.sqlite
      .prepare("UPDATE thread_runtime_leases SET fencing_token = 7")
      .run();
    await f.sqlite.prepare("UPDATE threads SET lease_fence_counter = 0").run();
    await f.queue("R2");
    expect(await f.acquire("R2", "lease-2")).toBe(8);
  } finally {
    await f.sqlite.close();
  }
});

