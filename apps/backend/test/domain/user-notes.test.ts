import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleCreateNote,
  handleDeleteThread,
  handleListNotes,
  handleNote,
  handleThreadNote,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

type Note = {
  id: string;
  title: string;
  body: string;
  threadId: string | null;
  threadName: string | null;
  spaceName: string | null;
  linked: boolean;
  revision: number;
};

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
  const as = (user: string, method = "GET", body?: unknown) =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  const threadNote = async (user: string, method = "GET", body?: unknown) =>
    (
      (await (
        await handleThreadNote(as(user, method, body), env, "T")
      ).json()) as { note: Note | null }
    ).note;
  const list = async (user: string) =>
    ((await (await handleListNotes(as(user), env)).json()) as { notes: Note[] })
      .notes;
  return { env, as, threadNote, list, sqlite };
}

it("keeps a Thread note private to its owner", async () => {
  const { threadNote, list } = fixture();
  expect(await threadNote("bob")).toBeNull();
  const created = await threadNote("bob", "PUT", { body: "remember" });
  expect(created).toMatchObject({
    title: "Thread",
    body: "remember",
    threadId: "T",
    threadName: "Thread",
    spaceName: "Space",
    linked: true,
    revision: 1,
  });
  expect((await threadNote("bob"))?.body).toBe("remember");
  expect(await threadNote("alice")).toBeNull();
  expect(await list("alice")).toEqual([]);
  expect((await list("bob")).map((note) => note.id)).toEqual([created!.id]);
});

it("rejects stale saves and outsiders", async () => {
  const { env, as, threadNote } = fixture();
  const created = await threadNote("bob", "PUT", { body: "one" });
  await threadNote("bob", "PUT", { body: "two", revision: 1 });
  await expect(
    handleThreadNote(
      as("bob", "PUT", { body: "stale", revision: 1 }),
      env,
      "T",
    ),
  ).rejects.toMatchObject({ status: 409 });
  await expect(
    handleThreadNote(as("eve", "GET"), env, "T"),
  ).rejects.toBeTruthy();
  await expect(
    handleNote(as("alice", "GET"), env, created!.id),
  ).rejects.toMatchObject({ status: 404 });
  await expect(
    handleNote(as("alice", "DELETE"), env, created!.id),
  ).resolves.toBeTruthy();
  expect((await threadNote("bob"))?.body).toBe("two");
});

it("keeps notes, detached, when the Thread is deleted", async () => {
  const { env, as, threadNote, list } = fixture();
  await threadNote("bob", "PUT", { body: "keep me" });
  await handleDeleteThread(as("alice", "DELETE"), env, "T");
  const [note] = await list("bob");
  expect(note).toMatchObject({
    body: "keep me",
    threadId: "T",
    threadName: "Thread",
    spaceName: "Space",
    linked: false,
  });
});

it("creates, edits and deletes standalone notes", async () => {
  const { env, as, list } = fixture();
  const response = await handleCreateNote(
    as("bob", "POST", { title: "Ideas", body: "a" }),
    env,
  );
  expect(response.status).toBe(201);
  const { note } = (await response.json()) as { note: Note };
  expect(note).toMatchObject({ title: "Ideas", threadId: null, linked: false });
  const updated = (await (
    await handleNote(as("bob", "PUT", { body: "b", revision: 1 }), env, note.id)
  ).json()) as { note: Note };
  expect(updated.note).toMatchObject({
    title: "Ideas",
    body: "b",
    revision: 2,
  });
  await handleNote(as("bob", "DELETE"), env, note.id);
  expect(await list("bob")).toEqual([]);
});
