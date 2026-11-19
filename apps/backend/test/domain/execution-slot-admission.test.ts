import { afterEach, expect, it, vi } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import {
  clearExecutionWaiter,
  countHeldExecutionSlots,
  recordExecutionWaiter,
  wakeNextExecutionWaiter,
  wakeWorkspaceReadyWaiters,
} from "../../src/domain/account-execution-slots.js";
import {
  FREE_CONCURRENT_EXECUTION_LIMIT,
  concurrentExecutionLimit,
} from "../../src/domain/account-plan.js";
import { conversationFixture } from "./helpers/conversation.js";

const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../../src/domain/scheduler.js", () => scheduler);

const NOW = "2026-10-07T10:00:00Z";
let readiness: "ready" | "connected" = "ready";
const open: Array<{ close(): void }> = [];
afterEach(async () => {
  readiness = "ready";
  for (const sqlite of open.splice(0)) (await sqlite.close());
});

async function fixture() {
  const f = await conversationFixture();
  open.push(f.sqlite);
  await f.sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('OWNER','o@test','Owner','now','now'),('V','v@test','Visitor','now','now');
    INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W2','P','Other','active','U','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS2','OWNER','Shared','now','now');
    INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT2','WS2','hash2','installation2','now');
    INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES('OWNER','paid','active','manual',NULL,'now','now');`);
  for (const id of ["T2", "T3", "T4", "T5"])
    (await f.sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
         VALUES(?, 'R', ?, 'stateless_read', 1000, 'v1', 'queued', 'now', 'now')`,
      )
      .run(
        id,
        id === "T2"
          ? "research"
          : id === "T3"
            ? "plan"
            : id === "T4"
              ? "test"
              : "verify",
      ));
  scheduler.selectSpaceExecutionTarget.mockImplementation(async () => ({
    spaceId: "P",
    workspaceId: currentWorkspace,
    workspaceRuntimeIdentityId: currentWorkspace === "WS" ? "RT" : "RT2",
    workspaceSpaceGrantId: null,
    workerId: "worker-a",
    workerTypeId: "chatgpt",
    engineVersion: "1.3.0",
    model: null,
    maxConcurrentAssignments: 4,
    effectivePermissions: ["repository:read"],
    permissionSnapshot: {
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
    },
    selectionExplanation: { workspace: { readiness } },
    executionClass: "stateless_read",
    readOnly: true,
  }));
  const fetch = vi.fn(async () => Response.json({}));
  const env = {
    SYNTILA_DB: f.db,
    SYNTILA_WORKSPACE_GATEWAY: {
      idFromName: () => "x",
      get: () => ({ fetch }),
    } as unknown as DurableObjectNamespace,
  };
  const dispatch = (taskId: string, user = "U", workspace = "WS") => {
    currentWorkspace = workspace;
    return dispatchTaskAssignment(env, {
      workspaceId: workspace,
      runId: "RUN",
      taskId,
      task: {
        id: taskId,
        spaceId: "P",
        requestedByUserId: user,
        role: "collaborator",
        objective: "test",
        workRequestId: "R",
        sessionPolicy: "stateless",
      },
    });
  };
  const setStatus = (taskId: string, status: string) =>
    f.sqlite
      .prepare(
        "UPDATE worker_assignments SET status = ? WHERE task_id = ? AND status NOT IN ('completed','failed','cancelled','timed_out','lost')",
      )
      .run(status, taskId);
  const plan = (user: string, status = "active", end: string | null = null) =>
    f.sqlite
      .prepare(
        `INSERT OR REPLACE INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at)
         VALUES(?, 'paid', ?, 'manual', ?, 'now', 'now')`,
      )
      .run(user, status, end);
  const waiters = () =>
    f.sqlite
      .prepare(
        "SELECT task_id, reason FROM account_execution_waiters ORDER BY enqueued_at, task_id",
      )
      .all();
  const held = (user = "U") => countHeldExecutionSlots(f.read, user);
  return { ...f, dispatch, setStatus, plan, waiters, held, fetch };
}
let currentWorkspace = "WS";

it("keeps the Free limit in the central plan policy", () => {
  expect(FREE_CONCURRENT_EXECUTION_LIMIT).toBe(1);
  expect(concurrentExecutionLimit("free")).toBe(1);
  expect(concurrentExecutionLimit("paid")).toBeNull();
});

it("admits one Free execution across Threads and Workspaces and defers the rest", async () => {
  const f = await fixture();
  const first = await f.dispatch("T");
  const second = await f.dispatch("T2", "U", "WS2");
  expect(first).toMatchObject({ accepted: true });
  expect(second).toMatchObject({
    accepted: false,
    status: "deferred",
    waitReason: "account_concurrency_limit",
    assignmentId: "",
  });
  expect(await f.held()).toBe(1);
  // A deferral writes no assignment and sends nothing to the Service.
  expect(f.fetch).toHaveBeenCalledTimes(1);
  expect(await f.waiters()).toEqual([
    { task_id: "T2", reason: "account_concurrency_limit" },
  ]);
});

it("lets only one of many simultaneous Free reservations win", async () => {
  const f = await fixture();
  const results = await Promise.all(
    ["T", "T2", "T3", "T4", "T5"].map((id) => f.dispatch(id)),
  );
  expect(results.filter((r) => r.accepted)).toHaveLength(1);
  expect(results.filter((r) => r.status === "deferred")).toHaveLength(4);
  expect(await f.held()).toBe(1);
});

it("has no plan-based cap on Plus, and the cap follows the requester not the Workspace owner", async () => {
  const f = await fixture();
  await f.plan("U");
  const results = await Promise.all(
    ["T", "T2", "T3"].map((id) => f.dispatch(id)),
  );
  expect(results.every((r) => r.accepted)).toBe(true);
  expect(await f.held()).toBe(3);
  // A Free visitor on the Plus owner's shared Workspace is still limited:
  // their first run starts, their second waits.
  expect(await f.dispatch("T4", "V", "WS2")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T5", "V", "WS2")).toMatchObject({
    status: "deferred",
  });
});

it("attributes shared Workspace executions to the requester", async () => {
  const f = await fixture();
  expect(await f.dispatch("T", "V", "WS2")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T2", "V", "WS2")).toMatchObject({
    status: "deferred",
  });
  // The owner (Plus) and another requester are unaffected by V's slot.
  expect(await f.dispatch("T3", "OWNER", "WS2")).toMatchObject({
    accepted: true,
  });
  expect(await f.held("V")).toBe(1);
  expect(await f.held("OWNER")).toBe(1);
});

it("releases the slot only on a terminal status, never on a cancellation request", async () => {
  const f = await fixture();
  await f.dispatch("T");
  for (const pending of ["revocation_pending", "reconciling"]) {
    await f.setStatus("T", pending);
    expect(await f.dispatch("T2")).toMatchObject({ status: "deferred" });
    expect(await f.held()).toBe(1);
  }
  await f.setStatus("T", "lost");
  expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
  expect(await f.held()).toBe(1);
  for (const terminal of ["completed", "failed", "cancelled", "timed_out"]) {
    await f.setStatus("T2", terminal);
    expect(await f.held()).toBe(0);
    const next = await f.dispatch("T3");
    expect(next.accepted).toBe(true);
    await f.setStatus("T3", "completed");
  }
});

it("does not double count a retried or duplicated dispatch of the same task", async () => {
  const f = await fixture();
  expect(await f.dispatch("T")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T")).toMatchObject({ status: "deferred" });
  expect(await f.dispatch("T")).toMatchObject({ status: "deferred" });
  expect(await f.held()).toBe(1);
  expect(await f.waiters()).toHaveLength(1);
});

it("starts waiting requests in order and never lets a new request jump the queue", async () => {
  const f = await fixture();
  vi.useFakeTimers();
  try {
    vi.setSystemTime(new Date(NOW));
    await f.dispatch("T");
    vi.setSystemTime(new Date(Date.parse(NOW) + 1_000));
    await f.dispatch("T2");
    vi.setSystemTime(new Date(Date.parse(NOW) + 2_000));
    await f.dispatch("T3");
    expect((await f.waiters()).map((w) => (w as { task_id: string }).task_id)).toEqual([
      "T2",
      "T3",
    ]);
    await f.setStatus("T", "completed");
    vi.setSystemTime(new Date(Date.parse(NOW) + 3_000));
    // The younger waiter and a brand-new request both lose to the oldest.
    expect(await f.dispatch("T3")).toMatchObject({ status: "deferred" });
    expect(await f.dispatch("T4")).toMatchObject({ status: "deferred" });
    expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
    expect((await f.waiters()).map((w) => (w as { task_id: string }).task_id)).toEqual([
      "T3",
      "T4",
    ]);
    await f.setStatus("T2", "completed");
    expect(await f.dispatch("T4")).toMatchObject({ status: "deferred" });
    expect(await f.dispatch("T3")).toMatchObject({ accepted: true });
  } finally {
    vi.useRealTimers();
  }
});

it("lets a stale or cancelled waiter stop blocking eligible work", async () => {
  const f = await fixture();
  await f.dispatch("T");
  await f.dispatch("T2");
  await f.setStatus("T", "completed");
  // T2's Workflow vanished (no heartbeat): it must not block T3.
  (await f.sqlite.exec(
    "UPDATE account_execution_waiters SET heartbeat_at = '2000-01-01T00:00:00Z'",
  ));
  expect(await f.dispatch("T3")).toMatchObject({ accepted: true });
  await f.setStatus("T3", "completed");
  // A cancelled request clears its place immediately.
  await f.dispatch("T4");
  await f.dispatch("T5");
  await clearExecutionWaiter(f.read, "T5");
  await f.setStatus("T4", "completed");
  expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
});

it("re-evaluates the plan on every dispatch: upgrade, downgrade and expiry", async () => {
  const f = await fixture();
  await f.dispatch("T");
  expect(await f.dispatch("T2")).toMatchObject({ status: "deferred" });
  await f.plan("U"); // upgrade: the queued request proceeds immediately
  expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T3")).toMatchObject({ accepted: true });
  await f.sqlite.exec("DELETE FROM account_plans WHERE user_id = 'U'"); // downgrade
  expect(await f.held()).toBe(3); // executing work finishes, nothing is cut
  expect(await f.dispatch("T4")).toMatchObject({ status: "deferred" });
  for (const id of ["T", "T2", "T3"]) await f.setStatus(id, "completed");
  expect(await f.dispatch("T4")).toMatchObject({ accepted: true });
  await f.setStatus("T4", "completed");
  // An expired subscription is Free; past_due inside its period stays Plus.
  await f.plan("U", "active", "2000-01-01T00:00:00Z");
  await f.dispatch("T5");
  expect(await f.dispatch("T")).toMatchObject({ status: "deferred" });
  await f.setStatus("T5", "completed");
  await f.plan("U", "past_due", "2999-01-01T00:00:00Z");
  expect(await f.dispatch("T")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
});

it("never holds a Free slot while the Service is only connected", async () => {
  const f = await fixture();
  readiness = "connected";
  expect(await f.dispatch("T")).toMatchObject({
    status: "deferred",
    waitReason: "workspace_not_ready",
  });
  expect(await f.held()).toBe(0);
  // It is waiting for the Service, not for the slot, so it blocks nobody.
  readiness = "ready";
  expect(await f.dispatch("T2")).toMatchObject({ accepted: true });
  expect(await f.dispatch("T")).toMatchObject({
    status: "deferred",
    waitReason: "account_concurrency_limit",
  });
  // Plus keeps the existing behaviour: the work queues behind the Service.
  await f.plan("U");
  readiness = "connected";
  expect(await f.dispatch("T3")).toMatchObject({ accepted: true });
});

it("wakes the oldest eligible waiter after a slot is released", async () => {
  const f = await fixture();
  await f.sqlite.exec(
    "UPDATE runs SET workflow_instance_id = 'instance-1' WHERE id = 'RUN'",
  );
  await recordExecutionWaiter(f.read, {
    taskId: "T2",
    requesterUserId: "U",
    runId: "RUN",
    reason: "account_concurrency_limit",
  });
  const sendEvent = vi.fn(async () => undefined);
  const get = vi.fn(async () => ({ sendEvent }));
  expect(
    await wakeNextExecutionWaiter(
      { SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get } },
      "U",
      "assignment-terminal",
    ),
  ).toBe(true);
  expect(get).toHaveBeenCalledWith("instance-1");
  expect(sendEvent).toHaveBeenCalledTimes(1);
  // No workflow binding or no waiter: nothing happens and nothing throws.
  expect(await wakeNextExecutionWaiter({ SYNTILA_DB: f.db }, "U", "x")).toBe(
    false,
  );
  await clearExecutionWaiter(f.read, "T2");
  expect(
    await wakeNextExecutionWaiter(
      { SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get } },
      "U",
      "x",
    ),
  ).toBe(false);
});

it("wakes requests parked on Service readiness, not slot waiters", async () => {
  const f = await fixture();
  await f.sqlite.exec(
    "UPDATE runs SET workflow_instance_id = 'instance-1' WHERE id = 'RUN'",
  );
  await recordExecutionWaiter(f.read, {
    taskId: "T2",
    requesterUserId: "U",
    runId: "RUN",
    reason: "workspace_not_ready",
  });
  await recordExecutionWaiter(f.read, {
    taskId: "T3",
    requesterUserId: "U",
    runId: "RUN",
    reason: "account_concurrency_limit",
  });
  const sendEvent = vi.fn(async () => undefined);
  const get = vi.fn(async () => ({ sendEvent }));
  expect(
    await wakeWorkspaceReadyWaiters(
      { SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get } },
      "WS",
      "assignment-terminal",
    ),
  ).toBe(1);
  expect(sendEvent).toHaveBeenCalledWith({
    type: "assignment-terminal",
    payload: { taskId: "T2", reason: "workspace_ready" },
  });
  // Without a Workflow binding nothing happens and nothing throws.
  expect(
    await wakeWorkspaceReadyWaiters({ SYNTILA_DB: f.db }, "WS", "x"),
  ).toBe(0);
});

it("wakes every matching readiness waiter across pages and leaves other Workspaces parked", async () => {
  const f = await fixture();
  await f.sqlite.exec(`
    UPDATE runs SET workflow_instance_id = 'instance-1' WHERE id = 'RUN';
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at,primary_workspace_id)
      SELECT 'R-MATCH',thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at,'WS' FROM work_requests WHERE id = 'R';
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at,primary_workspace_id)
      SELECT 'R-OTHER',thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at,'WS2'
      FROM work_requests WHERE id = 'R';
  `);
  for (let i = 0; i < 25; i++) await recordExecutionWaiter(f.read, {
    taskId: `batch-${String(i).padStart(2, '0')}`, requesterUserId: 'U', runId: 'RUN', workRequestId: 'R-MATCH', reason: 'workspace_not_ready',
  });
  await recordExecutionWaiter(f.read, {
    taskId: 'other', requesterUserId: 'U', runId: 'RUN', workRequestId: 'R-OTHER', reason: 'workspace_not_ready',
  });
  const sendEvent = vi.fn(async () => undefined);
  const get = vi.fn(async () => ({ sendEvent }));
  expect(await wakeWorkspaceReadyWaiters({ SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get } }, 'WS', 'assignment-terminal')).toBe(25);
  expect(sendEvent).toHaveBeenCalledTimes(25);
  expect(sendEvent.mock.calls.map((call) => (call[0] as { payload: { taskId: string } }).payload.taskId)).not.toContain('other');
  expect((await f.waiters()).length).toBe(26);
  const flakySend = vi.fn(async (event: { payload: { taskId: string } }) => {
    if (event.payload.taskId === 'batch-00') throw new Error('unavailable');
  });
  const flakyGet = vi.fn(async () => ({ sendEvent: flakySend }));
  expect(await wakeWorkspaceReadyWaiters({ SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get: flakyGet } }, 'WS', 'assignment-terminal')).toBe(24);
  expect(flakySend).toHaveBeenCalledTimes(25);
});

it("wakes and readmits a request after its Workspace becomes ready", async () => {
  const f = await fixture();
  await f.sqlite.exec("UPDATE runs SET workflow_instance_id = 'instance-ready' WHERE id = 'RUN'");
  readiness = 'connected';
  expect(await f.dispatch('T')).toMatchObject({ status: 'deferred', waitReason: 'workspace_not_ready' });
  expect(await f.held()).toBe(0);
  readiness = 'ready';
  const sendEvent = vi.fn(async () => undefined);
  expect(await wakeWorkspaceReadyWaiters({ SYNTILA_DB: f.db, SYNTILA_RUN_WORKFLOW: { get: async () => ({ sendEvent }) } }, 'WS', 'assignment-terminal')).toBe(1);
  expect(sendEvent).toHaveBeenCalledTimes(1);
  expect(await f.dispatch('T')).toMatchObject({ accepted: true });
});

it("rechecks readiness after registration when the ready signal raced the waiter", async () => {
  const f = await fixture();
  readiness = 'connected';
  f.fetch.mockImplementation(async (url: string) => {
    if (url.endsWith('/status')) {
      readiness = 'ready';
      return Response.json({ online: true, readyForAssignments: true, executionWorkspaceId: 'WS' });
    }
    return Response.json({});
  });
  expect(await f.dispatch('T')).toMatchObject({ accepted: true });
  expect(await f.waiters()).toHaveLength(0);
});
