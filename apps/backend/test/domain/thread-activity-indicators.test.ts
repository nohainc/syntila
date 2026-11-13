import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListSpaceThreads,
  handleListSpaces,
  handleMarkThreadRead,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

const joined = "2020-01-01T00:00:00.000Z";

function fixture() {
  const { sqlite, db } = sqliteD1();
  for (const id of ["alice", "bob"]) {
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  }
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','alice','Space','now','now')",
  );
  for (const id of ["alice", "bob"])
    sqlite
      .prepare(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'S',?,?,?,?)",
      )
      .run(
        `m-${id}`,
        id,
        id === "alice" ? "owner" : "collaborator",
        joined,
        joined,
      );
  for (const id of ["T1", "T2"])
    sqlite
      .prepare(
        "INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES(?,'S',?,'active','alice',?,?)",
      )
      .run(id, id, joined, joined);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const userId = request.headers.get("test-user")!;
      return {
        userId,
        user: {
          id: userId,
          email: `${userId}@test`,
          displayName: userId,
          status: "active",
        },
        workspaceId: "",
        spaceRoles: { S: userId === "alice" ? "owner" : "collaborator" },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const as = (user: string, method = "GET") =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
    });
  const flags = async (user: string) => {
    const response = await handleListSpaceThreads(as(user), env, "S");
    const { threads } = (await response.json()) as {
      threads: { id: string; hasActiveWork: boolean; hasUnread: boolean }[];
    };
    return Object.fromEntries(
      threads.map((t) => [t.id, [t.hasActiveWork, t.hasUnread]]),
    );
  };
  const spaceFlags = async (user: string) => {
    const response = await handleListSpaces(as(user), env);
    const { spaces } = (await response.json()) as {
      spaces: { hasActiveWork: boolean; hasUnread: boolean }[];
    };
    return [spaces[0]!.hasActiveWork, spaces[0]!.hasUnread];
  };
  return { sqlite, env, as, flags, spaceFlags };
}

it("marks a Thread unread for other members until they read it", async () => {
  const { sqlite, env, as, flags, spaceFlags } = fixture();
  sqlite
    .prepare(
      "INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at) VALUES('m1','T1','alice','hello',?)",
    )
    .run(new Date().toISOString());
  expect(await flags("alice")).toEqual({
    T1: [false, false],
    T2: [false, false],
  });
  expect(await flags("bob")).toEqual({ T1: [false, true], T2: [false, false] });
  expect(await spaceFlags("bob")).toEqual([false, true]);
  expect(await spaceFlags("alice")).toEqual([false, false]);

  const response = await handleMarkThreadRead(as("bob", "POST"), env, "T1");
  expect(response.status).toBe(200);
  expect(await flags("bob")).toEqual({
    T1: [false, false],
    T2: [false, false],
  });
  expect(await spaceFlags("bob")).toEqual([false, false]);
});

it("flags a Thread while Work is active and unread when it finishes", async () => {
  const { sqlite, flags, spaceFlags } = fixture();
  const now = new Date().toISOString();
  sqlite
    .prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
       VALUES('w1','T2','alice','stateless','direct',1,'{}','running',?,?)`,
    )
    .run(now, now);
  // Alice's prompt is unread for Bob as soon as it is sent, and running.
  expect(await flags("bob")).toEqual({ T1: [false, false], T2: [true, true] });
  expect(await spaceFlags("bob")).toEqual([true, true]);
  expect(await flags("alice")).toEqual({
    T1: [false, false],
    T2: [true, false],
  });

  sqlite
    .prepare("UPDATE work_requests SET status='completed', updated_at=?")
    .run(new Date(Date.now() + 1000).toISOString());
  expect(await flags("bob")).toEqual({ T1: [false, false], T2: [false, true] });
});

it.each(["queued", "running", "cancelled"])(
  "marks another member's %s prompt unread until read",
  async (status) => {
    const { sqlite, as, env, flags } = fixture();
    const now = new Date().toISOString();
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
         VALUES('w1','T2','alice','stateless','direct',1,'{}',?,?,?)`,
      )
      .run(status, now, now);
    expect((await flags("bob")).T2![1]).toBe(true);
    expect((await flags("alice")).T2![1]).toBe(false);
    await handleMarkThreadRead(as("bob", "POST"), env, "T2");
    expect((await flags("bob")).T2![1]).toBe(false);
  },
);

it("does not mark prompts sent before the member joined", async () => {
  const { sqlite, flags } = fixture();
  sqlite
    .prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
       VALUES('w1','T2','alice','stateless','direct',1,'{}','cancelled','2019-01-01T00:00:00.000Z','2019-01-01T00:00:00.000Z')`,
    )
    .run();
  expect((await flags("bob")).T2![1]).toBe(false);
});

it("ignores abandoned Work older than a day", async () => {
  const { sqlite, flags } = fixture();
  const old = new Date(Date.now() - 2 * 86_400_000).toISOString();
  sqlite
    .prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
       VALUES('w1','T1','alice','stateless','direct',1,'{}','queued',?,?)`,
    )
    .run(old, old);
  expect((await flags("bob")).T1).toEqual([false, false]);
});

it("orders Thread and Space lists by messages and request lifecycle activity", async () => {
  const { sqlite, env, as } = fixture();
  sqlite.exec(`UPDATE spaces SET updated_at='2020-01-01T00:00:00.000Z';
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at)
      VALUES('S2','alice','Other','2021-01-01T00:00:00.000Z','2021-01-01T00:00:00.000Z');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at)
      VALUES('m-other','S2','alice','owner','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z');`);
  async function order(stamp: string) {
    const threadBody = (await (
      await handleListSpaceThreads(as("alice"), env, "S")
    ).json()) as { threads: { id: string; updatedAt: string }[] };
    expect(threadBody.threads[0]).toMatchObject({ id: "T2", updatedAt: stamp });
    const spaceBody = (await (
      await handleListSpaces(as("alice"), env)
    ).json()) as { spaces: { id: string; updatedAt: string }[] };
    expect(spaceBody.spaces[0]).toMatchObject({ id: "S", updatedAt: stamp });
  }
  const sent = "2022-01-01T00:00:00.000Z";
  sqlite
    .prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
    VALUES('recent','T2','alice','stateless','direct',1,'{}','queued',?,?)`,
    )
    .run(sent, sent);
  await order(sent);
  const message = "2023-01-01T00:00:00.000Z";
  sqlite
    .prepare(
      "INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at) VALUES('recent-message','T2','bob','hello',?)",
    )
    .run(message);
  await order(message);
  const completed = "2024-01-01T00:00:00.000Z";
  sqlite
    .prepare(
      "UPDATE work_requests SET status='completed',updated_at=? WHERE id='recent'",
    )
    .run(completed);
  await order(completed);
});
