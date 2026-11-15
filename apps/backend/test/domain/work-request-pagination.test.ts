import { afterEach, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleCreateThread, type SecurityEnv } from "../../src/domain/routes/handlers.js";
import { handleListWorkRequests } from "../../src/domain/routes/work-lifecycle.js";

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const close of cleanups.splice(0)) close();
});

it("pages Work Requests newest first with an opaque cursor and an id tie-break", async () => {
  const { sqlite, db } = sqliteD1();
  cleanups.push(() => sqlite.close());
  sqlite.exec("INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('u','u@test','u','now','now')");
  sqlite.exec("INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','u','Space','now','now')");
  sqlite.exec("INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m','S','u','owner','now','now')");
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async () => ({
      userId: "u",
      user: { id: "u", email: "u@test", displayName: "u", status: "active" },
      workspaceId: "",
      spaceRoles: { S: "owner" },
      sessionId: "test",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  const created = await handleCreateThread(
    new Request("https://test/api", { method: "POST", headers: { "test-user": "u" }, body: JSON.stringify({ name: "T" }) }),
    env,
    "S",
  );
  const { thread } = (await created.json()) as { thread: { id: string } };
  const insert = sqlite.prepare(
    `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
     VALUES(?,?,'u','stateless','chat',1,'{}','completed','{}',?,?)`,
  );
  // r1..r3 share one millisecond (with extra microseconds on r2).
  const at = ["2026-01-01T00:00:01.000Z", "2026-01-01T00:00:01.000400Z", "2026-01-01T00:00:01.000Z", "2026-01-01T00:00:02Z", "2026-01-01T00:00:03Z"];
  at.forEach((t, i) => insert.run(`r${i + 1}`, thread.id, t, t));
  const list = async (query: string) => {
    const response = await handleListWorkRequests(
      new Request(`https://test/api/threads/${thread.id}/work-requests${query}`, { headers: { "test-user": "u" } }),
      env,
      thread.id,
    );
    return (await response.json()) as { workRequests: { id: string }[]; nextCursor: string | null };
  };
  const seen: string[] = [];
  let cursor: string | null = null;
  for (let pages = 0; pages < 10; pages++) {
    const page = await list(`?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
    expect(page.nextCursor === null || typeof page.nextCursor === "string").toBe(true);
    seen.push(...page.workRequests.map((r) => r.id));
    cursor = page.nextCursor;
    if (!cursor) break;
  }
  expect(seen).toEqual(["r5", "r4", "r3", "r2", "r1"]);
  // An exactly full last page has no next cursor.
  expect((await list("?limit=5")).nextCursor).toBeNull();
  await expect(list("?cursor=nope")).rejects.toMatchObject({ status: 400 });
});
