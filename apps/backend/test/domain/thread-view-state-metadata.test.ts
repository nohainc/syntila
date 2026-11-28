import { expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import {
  handleListSpaceThreads,
  handleUpdateSpace,
  handleUpdateThread,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

const created = "2020-01-01T00:00:00.000Z";

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite
    .prepare(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('alice','alice@test','alice','now','now')",
    )
    .run();
  await sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','alice','Space','now','now')",
  );
  await sqlite
    .prepare(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('bob','bob@test','bob','now','now')",
    )
    .run();
  await sqlite
    .prepare(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m','S','alice','owner',?,?),('m2','S','bob','collaborator',?,?)",
    )
    .run(created, created, created, created);
  await sqlite
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
  const { env, patch } = await fixture();
  const first = await handleUpdateThread(
    patch({
      metadata: {
        viewState: {
          workflowReference: "direct:2",
          model: "sonnet",
          reasoningEffort: "medium",
        },
      },
    }),
    env,
    "T",
  );
  expect(first.status).toBe(200);
  const second = await handleUpdateThread(
    patch({ metadata: { viewState: { model: null } } }),
    env,
    "T",
  );
  const body = (await second.json()) as {
    thread: { metadata: unknown; updatedAt: string };
  };
  expect(body.thread.updatedAt).toBe(created);
  expect(body.thread.metadata).toEqual({
    viewState: {
      workflowReference: "direct:2",
      reasoningEffort: "medium",
    },
  });
  const listed = (await (
    await handleListSpaceThreads(patch({}), env, "S")
  ).json()) as { threads: { metadata: unknown }[] };
  expect(listed.threads[0]!.metadata).toEqual(body.thread.metadata);
});

it("rejects unsupported Thread metadata", async () => {
  const { env, patch } = await fixture();
  for (const metadata of [
    { other: 1 },
    // Device-local state never travels to Cloud.
    { viewState: { tabIndex: 1 } },
    { viewState: { selectionUpdatedAt: "2026-10-21T20:00:00.000Z" } },
    { viewState: { unknown: "x" } },
    { viewState: { model: 5 } },
  ]) {
    await expect(
      handleUpdateThread(patch({ metadata }), env, "T"),
    ).rejects.toMatchObject({ status: 400 });
  }
});

it("stores Space sidebar state in Space settings and validates it", async () => {
  const { env, patch } = await fixture();
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
  const { env, envFor, patch, sqlite } = await fixture();
  const bob = envFor("bob");
  // Both members can manage the Thread: Alice owns the Space, Bob leads it.
  (await sqlite.exec("UPDATE threads SET lead_user_id = 'bob'"));
  const select = (workerId: string) =>
    patch({
      metadata: { viewState: { workerId } },
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
  (await sqlite.exec(
    `UPDATE threads SET metadata_json = syntila_json_set(metadata_json, '$.viewState', '{"workerId":"shared"}')`,
  ));
  expect(await viewState(env)).toBe("alice-worker");
});

it("lets a member who cannot manage the Thread keep their own selection", async () => {
  const { env, envFor, patch } = await fixture();
  const bob = envFor("bob"); // Collaborator; Alice leads the Thread.
  expect(
    (
      await handleUpdateThread(
        patch({ metadata: { viewState: { workerId: "bob-worker" } } }),
        bob,
        "T",
      )
    ).status,
  ).toBe(200);
  // Anything beyond the caller's own view state still needs manage access.
  await expect(
    handleUpdateThread(
      patch({ name: "Renamed", metadata: { viewState: { workerId: "x" } } }),
      bob,
      "T",
    ),
  ).rejects.toMatchObject({ status: 403 });
  const listed = (await (
    await handleListSpaceThreads(patch({}), env, "S")
  ).json()) as { threads: { metadata: { viewState?: unknown } }[] };
  expect(listed.threads[0]!.metadata.viewState).toBeUndefined();
});
