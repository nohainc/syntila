import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListNotifications,
  handleMarkNotificationsRead,
  type SecurityEnv,
} from "../src/routes/handlers.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  for (const id of ["alice", "bob", "eve"])
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','alice','Space','now','now')",
  );
  for (const id of ["alice", "bob"])
    sqlite
      .prepare(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'S',?,?,'2020','2020')",
      )
      .run(`m-${id}`, id, id === "alice" ? "owner" : "collaborator");
  sqlite.exec(
    "INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','S','Thread','active','alice','2020','2020')",
  );
  const now = new Date().toISOString();
  for (const [id, status] of [
    ["w-done", "completed"],
    ["w-fail", "failed"],
    ["w-run", "running"],
  ] as const)
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
         VALUES(?,'T','alice','stateless','direct',1,'{}',?,?,?)`,
      )
      .run(id, status, now, now);
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
        spaceRoles: userId === "eve" ? {} : { S: "collaborator" },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const as = (user: string, method = "GET", body?: unknown) =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const list = async (user: string) =>
    (
      (await (await handleListNotifications(as(user), env)).json()) as {
        notifications: { id: string; type: string; read: boolean }[];
      }
    ).notifications;
  return { env, as, list, sqlite };
}

it("returns the latest failure per thread before applying the feed limit", async () => {
  const { list, sqlite } = fixture();
  const now = new Date().toISOString();
  for (let i = 0; i < 55; i++) {
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
      VALUES(?,'T','alice','stateless','direct',1,'{}','failed',?,?)`,
      )
      .run(`z-${String(i).padStart(2, "0")}`, now, now);
  }
  expect((await list("alice")).map((n) => n.id)).toEqual(["z-54"]);
});

it("lists finished Work for Space members and keeps others out", async () => {
  const { list } = fixture();
  const bob = await list("bob");
  expect(bob.map((n) => n.id).sort()).toEqual(["w-done", "w-fail"]);
  expect(bob.find((n) => n.id === "w-fail")!.type).toBe("work_request.failed");
  expect(bob.every((n) => !n.read)).toBe(true);
  expect(await list("eve")).toEqual([]);
});

it("leaves out the caller's own successful Work but keeps their failures", async () => {
  const { list } = fixture();
  const alice = await list("alice");
  expect(alice.map((n) => n.id)).toEqual(["w-fail"]);
});

it("marks selected or all notifications read per user", async () => {
  const { env, as, list } = fixture();
  await handleMarkNotificationsRead(
    as("bob", "POST", { ids: ["w-done", "nope"] }),
    env,
  );
  expect((await list("bob")).filter((n) => n.read).map((n) => n.id)).toEqual([
    "w-done",
  ]);
  expect((await list("alice")).some((n) => n.read)).toBe(false);
  await handleMarkNotificationsRead(as("bob", "POST", {}), env);
  expect((await list("bob")).every((n) => n.read)).toBe(true);
});
