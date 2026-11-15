/**
 * Concurrency (claude/concurrency-plan.md): parallel requests queued in one
 * Thread, without the global writer lock, each get their own position.
 */
import { afterEach, beforeEach, expect, it, vi } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

const created = vi.hoisted(() => ({
  calls: [] as Array<{ userId: string; body: Record<string, unknown> }>,
  fail: null as string | null,
}));
vi.mock("../../src/domain/routes/work-creation.js", () => ({
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
vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: async () => {},
}));
vi.mock("../../src/domain/routes/space-permissions.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/space-permissions.js")>()),
  requireWorkflowPermission: async () => {},
}));
import {
  advanceThreadQueue,
  handleThreadRequestQueue,
} from "../../src/domain/routes/thread-request-queue.js";

const INVARIANTS = await Bun.file(new URL("../../scripts/check-invariants.sql", import.meta.url)).text();
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
  const { sqlite, db, sql } = pgD1({ writerLock: false, max: 24 });
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
  return { sqlite, sql, env, call, enqueue, busy, finish };
}

it("parallel requests queued in one Thread get distinct positions", async () => {
  const { sql, call, enqueue, busy } = fixture();
  busy();
  await Promise.all(Array.from({ length: 20 }, (_, i) => enqueue(i % 2 ? "owner" : "member", `r${i}`)));
  const items = (await call("owner", "GET")).items;
  expect(items).toHaveLength(20);
  const rows: { invariant: string; violations: number | bigint }[] = await sql.unsafe(INVARIANTS);
  expect(rows.filter((r) => Number(r.violations) > 0).map((r) => r.invariant)).toEqual([]);
});
