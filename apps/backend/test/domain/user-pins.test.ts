import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListSpaceThreads,
  handleListSpaces,
  handleSetPin,
  handleSetPinOrder,
  handleUpdateSpace,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

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
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'S',?,?,'2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')",
      )
      .run(`m-${id}`, id, id === "alice" ? "owner" : "collaborator");
  sqlite.exec(
    "INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','S','Thread','active','alice','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')",
  );
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
        spaceRoles:
          userId === "eve"
            ? {}
            : { S: userId === "alice" ? "owner" : "collaborator" },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const as = (user: string, method = "GET") =>
    new Request("https://test/api", { method, headers: { "test-user": user } });
  const pins = async (user: string) => {
    const spaces = (await (await handleListSpaces(as(user), env)).json()) as {
      spaces: { pinnedAt: string | null }[];
    };
    const threads = (await (
      await handleListSpaceThreads(as(user), env, "S")
    ).json()) as {
      threads: { pinnedAt: string | null }[];
    };
    return [!!spaces.spaces[0]!.pinnedAt, !!threads.threads[0]!.pinnedAt];
  };
  return { env, as, pins, sqlite };
}

it("pins a Space and a Thread for the caller only, idempotently", async () => {
  const { env, as, pins } = fixture();
  expect(await pins("bob")).toEqual([false, false]);
  expect((await handleSetPin(as("bob", "PUT"), env, "space", "S")).status).toBe(
    200,
  );
  await handleSetPin(as("bob", "PUT"), env, "space", "S");
  await handleSetPin(as("bob", "PUT"), env, "thread", "T");
  expect(await pins("bob")).toEqual([true, true]);
  expect(await pins("alice")).toEqual([false, false]);
  await handleSetPin(as("bob", "DELETE"), env, "thread", "T");
  await handleSetPin(as("bob", "DELETE"), env, "thread", "T");
  expect(await pins("bob")).toEqual([true, false]);
});

it("rejects pins from people outside the Space and unknown kinds", async () => {
  const { env, as } = fixture();
  await expect(
    handleSetPin(as("eve", "PUT"), env, "space", "S"),
  ).rejects.toMatchObject({});
  await expect(
    handleSetPin(as("eve", "PUT"), env, "thread", "T"),
  ).rejects.toMatchObject({});
  await expect(
    handleSetPin(as("bob", "PUT"), env, "other", "S"),
  ).rejects.toMatchObject({});
});

it("keeps a Space's position when only sidebar view state changes", async () => {
  const { env, sqlite } = fixture();
  const update = (body: unknown) =>
    handleUpdateSpace(
      new Request("https://test/api", {
        method: "PATCH",
        headers: { "test-user": "alice" },
        body: JSON.stringify(body),
      }),
      env,
      "S",
    );
  const updatedAt = () =>
    (
      sqlite
        .prepare("SELECT updated_at AS u FROM spaces WHERE id='S'")
        .get() as {
        u: string;
      }
    ).u;
  const before = updatedAt();
  expect((await update({ settings: { sidebarExpanded: true } })).status).toBe(
    200,
  );
  expect(updatedAt()).toBe(before);
  expect((await update({ description: "changed" })).status).toBe(200);
  expect(updatedAt()).not.toBe(before);
});

it("orders pins per user, newest pin first until moved", async () => {
  const { env, as, sqlite } = fixture();
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S2','alice','Two','now','now')",
  );
  sqlite.exec(
    "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m2','S2','bob','collaborator','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')",
  );
  await handleSetPin(as("bob", "PUT"), env, "space", "S");
  await handleSetPin(as("bob", "PUT"), env, "space", "S2");
  const positions = () =>
    Object.fromEntries(
      (
        sqlite
          .prepare(
            "SELECT target_id AS id, position AS p FROM user_pins WHERE user_id='bob' AND kind='space'",
          )
          .all() as { id: string; p: number }[]
      ).map((r) => [r.id, r.p]),
    );
  const before = positions();
  expect(before.S2!).toBeLessThan(before.S!);
  const order = (user: string, ids: string[]) =>
    handleSetPinOrder(
      new Request("https://test/api", {
        method: "PUT",
        headers: { "test-user": user },
        body: JSON.stringify({ kind: "space", ids }),
      }),
      env,
    );
  expect((await order("bob", ["S", "S2"])).status).toBe(200);
  expect(positions()).toEqual({ S: 0, S2: 1 });
  await expect(order("eve", ["S"])).rejects.toMatchObject({});
  expect(positions()).toEqual({ S: 0, S2: 1 });
});
