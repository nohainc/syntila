import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListSpaceThreads,
  handleUpdateSpace,
  handleUpdateThread,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

const created = "2020-01-01T00:00:00.000Z";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite
    .prepare(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('alice','alice@test','alice','now','now')",
    )
    .run();
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','alice','Space','now','now')",
  );
  sqlite
    .prepare(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('bob','bob@test','bob','now','now')",
    )
    .run();
  sqlite
    .prepare(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m','S','alice','owner',?,?),('m2','S','bob','collaborator',?,?)",
    )
    .run(created, created, created, created);
  sqlite
    .prepare(
      "INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','S','T','active','alice',?,?)",
    )
    .run(created, created);
  const envFor = (userId: string) =>
    ({
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async () => ({
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
      }),
    }) as unknown as SecurityEnv;
  const env = envFor("alice");
  const patch = (body: unknown) =>
    new Request("https://test/api", {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  return { env, envFor, patch, sqlite };
}

it("stores Thread view state in metadata without touching updatedAt", async () => {
  const { env, patch } = fixture();
  const first = await handleUpdateThread(
    patch({
      metadata: {
        viewState: {
          tabIndex: 1,
          workflowReference: "direct:2",
          model: "sonnet",
          reasoningEffort: "medium",
          selectionUpdatedAt: "2026-10-21T20:00:00.000Z",
        },
      },
    }),
    env,
    "T",
  );
  expect(first.status).toBe(200);
  const second = await handleUpdateThread(
    patch({ metadata: { viewState: { model: null, tabIndex: 0 } } }),
    env,
    "T",
  );
  const body = (await second.json()) as {
    thread: { metadata: unknown; updatedAt: string };
  };
  expect(body.thread.updatedAt).toBe(created);
  expect(body.thread.metadata).toEqual({
    viewState: {
      tabIndex: 0,
      workflowReference: "direct:2",
      reasoningEffort: "medium",
      selectionUpdatedAt: "2026-10-21T20:00:00.000Z",
    },
  });
  const listed = (await (
    await handleListSpaceThreads(patch({}), env, "S")
  ).json()) as { threads: { metadata: unknown }[] };
  expect(listed.threads[0]!.metadata).toEqual(body.thread.metadata);
});

it("rejects unsupported Thread metadata", async () => {
  const { env, patch } = fixture();
  for (const metadata of [
    { other: 1 },
    { viewState: { tabIndex: 2 } },
    { viewState: { unknown: "x" } },
    { viewState: { model: 5 } },
  ]) {
    await expect(
      handleUpdateThread(patch({ metadata }), env, "T"),
    ).rejects.toMatchObject({ status: 400 });
  }
});

it("stores Space sidebar state in Space settings and validates it", async () => {
  const { env, patch } = fixture();
  const response = await handleUpdateSpace(
    patch({ settings: { threadOrder: ["T"], sidebarExpanded: true } }),
    env,
    "S",
  );
  const { space } = (await response.json()) as {
    space: { settings: Record<string, unknown> };
  };
  expect(space.settings).toMatchObject({
    threadOrder: ["T"],
    sidebarExpanded: true,
  });
  await expect(
    handleUpdateSpace(
      patch({ settings: { threadOrder: ["T", "T"] } }),
      env,
      "S",
    ),
  ).rejects.toMatchObject({ status: 400 });
  await expect(
    handleUpdateSpace(
      patch({ settings: { sidebarExpanded: "yes" } }),
      env,
      "S",
    ),
  ).rejects.toMatchObject({ status: 400 });
});

it("keeps each member's Thread view state separate", async () => {
  const { env, envFor, patch, sqlite } = fixture();
  const bob = envFor("bob");
  // Both members can manage the Thread: Alice owns the Space, Bob leads it.
  sqlite.exec("UPDATE threads SET lead_user_id = 'bob'");
  const select = (workerId: string) =>
    patch({
      metadata: {
        viewState: { workerId, selectionUpdatedAt: "2026-10-21T20:00:00.000Z" },
      },
    });
  expect(
    (await handleUpdateThread(select("alice-worker"), env, "T")).status,
  ).toBe(200);
  expect(
    (await handleUpdateThread(select("bob-worker"), bob, "T")).status,
  ).toBe(200);
  const viewState = async (who: SecurityEnv) =>
    (
      (await (await handleListSpaceThreads(patch({}), who, "S")).json()) as {
        threads: { metadata: { viewState?: { workerId?: string } } }[];
      }
    ).threads[0]!.metadata.viewState?.workerId;
  expect(await viewState(env)).toBe("alice-worker");
  expect(await viewState(bob)).toBe("bob-worker");
  // A shared copy from before per-user storage is never shown to anyone.
  sqlite.exec(
    `UPDATE threads SET metadata_json = syntila_json_set(metadata_json, '$.viewState', '{"workerId":"shared"}')`,
  );
  expect(await viewState(env)).toBe("alice-worker");
});

it("clamps a future selection time to the server clock", async () => {
  const { env, patch } = fixture();
  const response = await handleUpdateThread(
    patch({
      metadata: {
        viewState: { selectionUpdatedAt: "2999-01-01T00:00:00.000Z" },
      },
    }),
    env,
    "T",
  );
  const body = (await response.json()) as {
    thread: { metadata: { viewState: { selectionUpdatedAt: string } } };
  };
  const at = Date.parse(body.thread.metadata.viewState.selectionUpdatedAt);
  expect(at).toBeLessThanOrEqual(Date.now());
  await expect(
    handleUpdateThread(
      patch({ metadata: { viewState: { selectionUpdatedAt: "soon" } } }),
      env,
      "T",
    ),
  ).rejects.toMatchObject({ status: 400 });
});
