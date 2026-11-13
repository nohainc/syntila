import { afterEach, describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleCreateThread,
  handleUpdateThread,
  handleDeleteThread,
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
  handleDeleteDiscussionMessage,
  handleClearChatHistory,
  handleListDiscussionMessages,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";
import { handleClearWorkHistory } from "../../src/domain/routes/work-lifecycle.js";

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const close of cleanups.splice(0)) close();
});
async function fixture() {
  const { sqlite, db } = sqliteD1();
  cleanups.push(() => sqlite.close());
  sqlite.exec(
    "ALTER TABLE threads ADD COLUMN work_session_generation INTEGER NOT NULL DEFAULT 0",
  );
  const roles: Record<string, string> = {
    owner: "owner",
    creator: "collaborator",
    other: "collaborator",
    viewer: "viewer",
  };
  for (const id of Object.keys(roles))
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','owner','Space','now','now')",
  );
  for (const [id, role] of Object.entries(roles))
    sqlite
      .prepare(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'S',?,?,'now','now')",
      )
      .run(`m-${id}`, id, role);
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
  const request = (user: string, body: unknown = {}, method = "POST") =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
      body: JSON.stringify(body),
    });
  const response = await handleCreateThread(
    request("creator", { name: "Thread" }),
    env,
    "S",
  );
  const { thread } = (await response.json()) as { thread: { id: string } };
  const send = async (user: string) => {
    const response = await handleCreateDiscussionMessage(
      request(user, { body: "original content" }),
      env,
      thread.id,
    );
    return ((await response.json()) as { message: { id: string } }).message.id;
  };
  const notices = () =>
    sqlite
      .prepare(
        "SELECT event_type, body FROM discussion_messages WHERE thread_id = ? ORDER BY created_at, id",
      )
      .all(thread.id);
  return { sqlite, env, request, id: thread.id, send, notices };
}

describe("shared thread history permissions", () => {
  it("lets the owner moderate in place and protects notices from editing or deletion", async () => {
    const f = await fixture();
    const message = await f.send("other");
    await expect(
      handleDeleteDiscussionMessage(f.request("creator"), f.env, message),
    ).rejects.toMatchObject({ status: 403 });
    await handleDeleteDiscussionMessage(f.request("owner"), f.env, message);
    expect(
      f.sqlite
        .prepare(
          "SELECT author_user_id, body, event_type, attachments_json, references_json FROM discussion_messages WHERE id=?",
        )
        .get(message),
    ).toEqual({
      author_user_id: "other",
      body: "Message removed by owner · Space owner",
      event_type: "message.removed",
      attachments_json: "[]",
      references_json: "[]",
    });
    for (const user of ["owner", "other"]) {
      await expect(
        handleEditDiscussionMessage(
          f.request(user, { body: "restore" }),
          f.env,
          message,
        ),
      ).rejects.toBeDefined();
      await expect(
        handleDeleteDiscussionMessage(f.request(user), f.env, message),
      ).rejects.toMatchObject({ status: 409 });
    }
  });
  it("lets viewers archive and restore, without granting rename rights", async () => {
    const f = await fixture();
    await handleUpdateThread(
      f.request("viewer", { status: "archived" }),
      f.env,
      f.id,
    );
    await handleUpdateThread(
      f.request("other", { status: "active" }),
      f.env,
      f.id,
    );
    expect(f.notices().map((n) => n.body)).toEqual([
      "viewer archived this thread.",
      "other restored this thread.",
    ]);
    await expect(
      handleUpdateThread(
        f.request("viewer", { status: "archived", name: "changed" }),
        f.env,
        f.id,
      ),
    ).rejects.toMatchObject({ status: 403 });
  });
  it("keeps contribution protection after moderation and conversation clearing", async () => {
    const f = await fixture();
    const message = await f.send("other");
    await handleDeleteDiscussionMessage(f.request("owner"), f.env, message);
    await expect(
      handleClearChatHistory(f.request("creator"), f.env, f.id),
    ).rejects.toMatchObject({ status: 403 });
    await handleClearChatHistory(f.request("owner"), f.env, f.id);
    await expect(
      handleDeleteThread(f.request("creator"), f.env, f.id),
    ).rejects.toMatchObject({ status: 403 });
    await handleDeleteThread(f.request("owner"), f.env, f.id);
  });
  it("allows creator cleanup of their own AI exchanges and leaves one clear notice", async () => {
    const f = await fixture();
    await f.send("creator");
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R',?,'creator','stateless','chat',1,'{}','completed','{}','now','now')`,
      )
      .run(f.id);
    f.sqlite
      .prepare(
        "INSERT INTO discussion_messages(id,thread_id,author_user_id,body,kind,created_at) VALUES('answer',?,'creator','AI answer','ai_answer','now')",
      )
      .run(f.id);
    for (let i = 0; i < 2; i++)
      await handleClearChatHistory(f.request("creator"), f.env, f.id);
    expect(f.notices()).toEqual([
      {
        event_type: "conversation.cleared",
        body: "creator cleared the conversation.",
      },
    ]);
    await handleDeleteThread(f.request("creator"), f.env, f.id);
  });
  it("permits a viewer to reset during active work and records one notice on idempotent retry", async () => {
    const f = await fixture();
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R',?,'creator','stateless','chat',1,'{}','running','{}','now','now')`,
      )
      .run(f.id);
    const request = () => {
      const r = f.request("viewer");
      r.headers.set("Idempotency-Key", "reset-context-0001");
      return r;
    };
    await handleClearWorkHistory(request(), f.env, f.id);
    await handleClearWorkHistory(request(), f.env, f.id);
    expect(f.notices()).toHaveLength(1);
    expect(f.notices()[0]!.event_type).toBe("ai.context_reset");
    expect(
      f.sqlite
        .prepare("SELECT ai_context_generation FROM threads WHERE id=?")
        .get(f.id)!.ai_context_generation,
    ).toBe(1);
    expect(
      f.sqlite
        .prepare(
          "SELECT status,ai_context_generation FROM work_requests WHERE id='R'",
        )
        .get(),
    ).toEqual({ status: "running", ai_context_generation: 0 });
    await expect(
      handleDeleteThread(f.request("creator"), f.env, f.id),
    ).rejects.toMatchObject({ status: 409 });
    const page = await handleListDiscussionMessages(
      new Request("https://test/api", { headers: { "test-user": "viewer" } }),
      f.env,
      f.id,
    );
    expect(await page.json()).toMatchObject({
      messages: [{ eventType: "ai.context_reset" }],
    });
  });
  it("counts requests from another human as a lasting contribution", async () => {
    const f = await fixture();
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R',?,'other','stateless','chat',1,'{}','completed','{}','now','now')`,
      )
      .run(f.id);
    await expect(
      handleDeleteThread(f.request("creator"), f.env, f.id),
    ).rejects.toMatchObject({ status: 403 });
  });
});

it("atomically refuses cleanup when another contribution arrives after authorization", async () => {
  const f = await fixture();
  const batch = f.env.SYNTILA_DB.batch.bind(f.env.SYNTILA_DB);
  f.env.SYNTILA_DB.batch = async (statements) => {
    f.sqlite
      .prepare(
        "INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at) VALUES('racing',?,'other','Keep this','now')",
      )
      .run(f.id);
    return batch(statements);
  };
  await expect(
    handleDeleteThread(f.request("creator"), f.env, f.id),
  ).rejects.toThrow(/CHECK/);
  expect(
    f.sqlite.prepare("SELECT id FROM threads WHERE id=?").get(f.id),
  ).toBeTruthy();
  expect(
    f.sqlite
      .prepare("SELECT body FROM discussion_messages WHERE id='racing'")
      .get()!.body,
  ).toBe("Keep this");
});
