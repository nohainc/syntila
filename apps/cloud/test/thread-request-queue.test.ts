import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

const created = vi.hoisted(() => ({
  calls: [] as Array<{ userId: string; body: Record<string, unknown> }>,
  fail: null as string | null,
}));
vi.mock("../src/routes/work-creation.js", () => ({
  // Records the request Cloud sends from the queue, as a queued Work request.
  createWorkRequestForUser: async (
    env: SecurityEnv,
    args: {
      userId: string;
      threadId: string;
      body: Record<string, unknown>;
    },
  ) => {
    created.calls.push({ userId: args.userId, body: args.body });
    if (created.fail)
      return Response.json({ error: created.fail }, { status: 422 });
    await env.SYNTILA_DB.prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
       VALUES(?1,?2,?3,'stateless','chat',1,'{}','{}','queued','{}','now','now')`,
    )
      .bind(`wr-${created.calls.length}`, args.threadId, args.userId)
      .run();
    return Response.json({}, { status: 202 });
  },
}));
vi.mock("../src/collaboration-events.js", () => ({
  publishCollaborationEvent: async () => {},
}));
vi.mock("../src/routes/space-permissions.js", async (original) => ({
  ...(await original<typeof import("../src/routes/space-permissions.js")>()),
  requireWorkflowPermission: async () => {},
}));
import {
  advanceThreadQueue,
  handleThreadRequestQueue,
} from "../src/routes/thread-request-queue.js";

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const close of cleanups.splice(0)) close();
});
beforeEach(() => {
  created.calls = [];
  created.fail = null;
});

const roles: Record<string, string> = {
  owner: "owner",
  member: "collaborator",
};

function fixture() {
  const { sqlite, db } = sqliteD1();
  cleanups.push(() => sqlite.close());
  for (const id of Object.keys(roles))
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id.toUpperCase());
  sqlite.exec(`
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','owner','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m1','S','owner','owner','now','now'),('m2','S','member','collaborator','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','S','Thread','active','owner','now','now');`);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (req: Request) => {
      const id = req.headers.get("test-user")!;
      return {
        userId: id,
        user: { id, email: `${id}@test`, displayName: id, status: "active" },
        workspaceId: "",
        spaceRoles: { S: roles[id] },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const call = async (
    user: string,
    method: string,
    {
      item = null,
      action = null,
      body,
    }: { item?: string | null; action?: string | null; body?: unknown } = {},
  ) => {
    const response = await handleThreadRequestQueue(
      new Request("https://cloud.test/api/threads/T/queue", {
        method,
        headers: { "test-user": user, "content-type": "application/json" },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
      env,
      "T",
      item,
      action,
    );
    return (await response.json()) as {
      paused: boolean;
      pauseReason: string | null;
      failureMessage: string | null;
      items: Array<{
        id: string;
        authorUserId: string;
        authorName: string;
        request: Record<string, unknown>;
      }>;
    };
  };
  const enqueue = (user: string, text: string) =>
    call(user, "POST", {
      body: {
        request: { workflowId: "chat", input: { originalRequest: text } },
      },
    });
  const busy = () =>
    sqlite.exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
      VALUES('running','T','owner','stateless','chat',1,'{}','{}','running','{}','now','now')`);
  const finish = (id: string) =>
    sqlite
      .prepare("UPDATE work_requests SET status = 'completed' WHERE id = ?")
      .run(id);
  return { sqlite, env, call, enqueue, busy, finish };
}

it("is shared by members and sent by Cloud as each author, in order", async () => {
  const { env, call, enqueue, busy, finish } = fixture();
  busy();
  await enqueue("owner", "first");
  const shared = await enqueue("member", "second");
  // Both members see both requests, with their authors.
  expect((await call("owner", "GET")).items.map((i) => i.authorName)).toEqual([
    "OWNER",
    "MEMBER",
  ]);
  expect(shared.items).toHaveLength(2);
  expect(created.calls).toHaveLength(0);

  finish("running");
  await advanceThreadQueue(env, "T");
  expect(created.calls).toEqual([
    {
      userId: "owner",
      body: { workflowId: "chat", input: { originalRequest: "first" } },
    },
  ]);
  // The sent request is processing now, so the next one waits for it.
  await advanceThreadQueue(env, "T");
  expect(created.calls).toHaveLength(1);
  finish("wr-1");
  await advanceThreadQueue(env, "T");
  expect(created.calls.map((c) => c.userId)).toEqual(["owner", "member"]);
  expect((await call("member", "GET")).items).toHaveLength(0);
});

it("lets only the author edit, remove or send their request now", async () => {
  const { call, enqueue, busy } = fixture();
  busy();
  const { items } = await enqueue("owner", "mine");
  const id = items[0]!.id;
  for (const [method, action] of [
    ["DELETE", null],
    ["PUT", null],
    ["POST", "send-now"],
  ] as const)
    await expect(
      call("member", method, {
        item: id,
        action,
        body: { request: { workflowId: "chat" } },
      }),
    ).rejects.toMatchObject({ status: 403 });
  const edited = await call("owner", "PUT", {
    item: id,
    body: { request: { workflowId: "chat", input: { originalRequest: "x" } } },
  });
  expect(edited.items[0]!.request).toMatchObject({
    input: { originalRequest: "x" },
  });
  expect((await call("owner", "DELETE", { item: id })).items).toHaveLength(0);
});

it("lets any member pause and resume the shared queue", async () => {
  const { env, call, enqueue, busy, finish } = fixture();
  busy();
  await enqueue("owner", "first");
  expect((await call("member", "POST", { action: "pause" })).paused).toBe(true);
  finish("running");
  await advanceThreadQueue(env, "T");
  expect(created.calls).toHaveLength(0);
  const resumed = await call("member", "POST", { action: "resume" });
  expect(resumed.paused).toBe(false);
  expect(created.calls.map((c) => c.userId)).toEqual(["owner"]);
});

it("pauses with the reason when a request fails or cannot be sent", async () => {
  const { env, call, enqueue, busy, finish } = fixture();
  busy();
  await enqueue("member", "next");
  await advanceThreadQueue(env, "T", { failedRequest: true });
  let queue = await call("owner", "GET");
  expect(queue.pauseReason).toBe("failure");
  expect(queue.items).toHaveLength(1);

  finish("running");
  created.fail = "Chat: choose a Worker.";
  await call("owner", "POST", { action: "resume" });
  queue = await call("owner", "GET");
  expect(queue.pauseReason).toBe("failure");
  expect(queue.failureMessage).toBe("Chat: choose a Worker.");
  expect(queue.items).toHaveLength(1);
});

it("rejects device files, which Cloud could not upload later", async () => {
  const { call } = fixture();
  await expect(
    call("owner", "POST", {
      body: {
        request: {
          workflowId: "chat",
          input: { attachments: [{ kind: "file", delivery: "upload" }] },
        },
      },
    }),
  ).rejects.toMatchObject({ status: 400 });
});

it("sends a reply to a plan paused for input before its remaining phases", async () => {
  const { sqlite, env, call, enqueue } = fixture();
  // Phase 1 paused for input: its Workflow finished, the request stays waiting.
  sqlite.exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
      VALUES('phase-1','T','owner','stateless','direct',2,'{}','{}','waiting','{"isPhased":true}','now','now');
    INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at)
      VALUES('task-1','phase-1','implement','stateful_thread',60000,'v1','completed',1,'now','now');
    INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
      VALUES('phase-2','T','owner','{"workflowId":"direct","isPhased":true,"input":{"isPhased":true}}',1,'queued','now','now');
    INSERT INTO thread_request_queue_state(thread_id,paused_reason,failure_message,updated_at)
      VALUES('T','failure','Phase 1 paused','now');`);
  const queue = await enqueue("owner", "tools are installed, try again");
  // The reply is sent; nothing is cancelled and phase 2 stays paused.
  expect(created.calls.map((c) => c.body.input)).toEqual([
    { originalRequest: "tools are installed, try again" },
  ]);
  expect(queue.paused).toBe(true);
  expect(queue.items.map((i) => i.id)).toEqual(["phase-2"]);
  expect(
    sqlite.prepare("SELECT status FROM work_requests WHERE id = 'phase-1'").get(),
  ).toEqual({ status: "waiting" });

  // While the reply processes, a further request waits ahead of phase 2.
  await enqueue("member", "one more thing");
  expect(created.calls).toHaveLength(1);
  expect(
    (await call("owner", "GET")).items.map((i) => i.request.isPhased ?? false),
  ).toEqual([false, true]);
  await advanceThreadQueue(env, "T");
  expect(created.calls).toHaveLength(1);
});
