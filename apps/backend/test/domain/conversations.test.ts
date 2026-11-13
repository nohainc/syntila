import { readFileSync } from "node:fs";
import { expect, it, vi } from "./helpers/vitest-compat";
import { CONVERSATION_WORKFLOWS } from "@syntila/core";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
const { authorize } = vi.hoisted(() => ({
  authorize: vi.fn(async () => ({})),
}));
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: authorize,
}));
import {
  conversationSubmissionStatements,
  resolveThreadConversationId,
  threadConversationId,
  handleListConversations,
} from "../../src/domain/routes/conversations.js";

it("shares one Thread Conversation across workflows, preserves context revision, and gates Conversation reads", async () => {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','U','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','P','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','W','active','U','now','now');`);
  // The ordered feature migration works against an existing v8 schema.
  sqlite.exec(`INSERT INTO work_requests
    (id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,created_at,updated_at)
    VALUES ('historical','W','U','stateful','direct',1,'{"name":"Direct"}','{"originalRequest":"Keep history"}','completed','2019-01-01T00:00:00Z','2019-01-01T00:00:00Z')`);
  expect(
    sqlite
      .prepare(
        "SELECT workflow_snapshot_json, snapshot_json FROM work_requests WHERE id = 'historical'",
      )
      .get(),
  ).toEqual({
    workflow_snapshot_json: '{"name":"Direct"}',
    snapshot_json: '{"originalRequest":"Keep history"}',
  });
  expect(
    sqlite
      .prepare("SELECT count(*) AS n FROM conversation_work_requests")
      .get(),
  ).toEqual({ n: 0 });
  const insertRequest = (id: string) =>
    db
      .prepare(
        `INSERT INTO work_requests
    (id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
    VALUES (?1,'W','U','stateful','direct',2,'{}','queued','now','now')`,
      )
      .bind(id);
  await db.batch([
    insertRequest("R1"),
    ...conversationSubmissionStatements(
      db as unknown as D1Database,
      threadConversationId("W"),
      "W",
      CONVERSATION_WORKFLOWS.work!,
      "R1",
      "2030-01-01T00:00:00.000Z",
    ),
  ]);
  const id = threadConversationId("W");
  expect(
    await resolveThreadConversationId(db as unknown as D1Database, "W"),
  ).toBe(id);
  const request = new Request("https://cloud.test/api/threads/W/conversations");
  const env = { SYNTILA_DB: db } as unknown as SecurityEnv;
  const response = await handleListConversations(request, env, "W");
  expect(await response.json()).toEqual({
    conversations: [
      {
        id,
        threadId: "W",
        workflowId: "work",
        workflowVersion: 1,
        conversationRevision: 1,
        contextRevision: 1,
        createdAt: "2030-01-01T00:00:00.000Z",
        updatedAt: "2030-01-01T00:00:00.000Z",
      },
    ],
  });
  expect(authorize).toHaveBeenLastCalledWith(
    request,
    env,
    "W",
    "view",
    undefined,
  );
  // Receipt/request failure rolls back both the counter and association.
  await expect(
    db.batch([
      ...conversationSubmissionStatements(
        db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.work!,
        "missing-request",
        "later",
      ),
    ]),
  ).rejects.toThrow();
  expect(
    sqlite.prepare("SELECT conversation_revision FROM conversations").get(),
  ).toEqual({ conversation_revision: 1 });
  expect(
    sqlite
      .prepare("SELECT count(*) AS n FROM conversation_work_requests")
      .get(),
  ).toEqual({ n: 1 });
  authorize.mockRejectedValueOnce(new Error("access denied"));
  expect(() =>
    sqlite.exec("UPDATE conversations SET workflow_id = 'chat'"),
  ).toThrow(/immutable/);
  expect(() =>
    sqlite.exec("UPDATE conversations SET conversation_revision = 0"),
  ).toThrow(/cannot decrease/);
  expect(() =>
    sqlite.exec("UPDATE conversations SET context_revision = 2"),
  ).toThrow();
  expect(() =>
    sqlite.exec(
      "UPDATE conversation_work_requests SET conversation_revision = 2",
    ),
  ).toThrow(/immutable/);
  await expect(handleListConversations(request, env, "W")).rejects.toThrow(
    "access denied",
  );
  sqlite.close();
});

it("continues Chat and Work in one Thread Conversation and keeps a legacy one canonical", async () => {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','U','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','P','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','W','active','U','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('L','P','L','active','U','now','now');
    INSERT INTO conversations(id,thread_id,workflow_id,workflow_version,conversation_revision,context_revision,created_at,updated_at)
      VALUES('legacy-chat','L','chat',1,3,3,'2021-01-01T00:00:00Z','2021-01-01T00:00:00Z'),('legacy-work','L','work',1,1,1,'2022-01-01T00:00:00Z','2022-01-01T00:00:00Z');`);
  const d1 = db as unknown as D1Database;
  const submit = async (id: string, workflow: "chat" | "work") => {
    const conversation = await resolveThreadConversationId(d1, "W");
    await db.batch([
      db
        .prepare(
          `INSERT INTO work_requests
      (id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
      VALUES (?1,'W','U','stateful',?2,?3,'{}','queued','now','now')`,
        )
        .bind(
          id,
          CONVERSATION_WORKFLOWS[workflow]!.execution.workflowId,
          CONVERSATION_WORKFLOWS[workflow]!.execution.workflowVersion,
        ),
      ...conversationSubmissionStatements(
        d1,
        conversation,
        "W",
        CONVERSATION_WORKFLOWS[workflow]!,
        id,
        "2030-01-01T00:00:00.000Z",
      ),
    ]);
  };
  await submit("R1", "chat");
  await submit("R2", "work");
  expect(
    sqlite
      .prepare(
        "SELECT id, workflow_id, conversation_revision, context_revision FROM conversations WHERE thread_id = 'W'",
      )
      .all(),
  ).toEqual([
    {
      id: threadConversationId("W"),
      workflow_id: "chat",
      conversation_revision: 2,
      context_revision: 2,
    },
  ]);
  expect(
    sqlite
      .prepare(
        "SELECT work_request_id, conversation_revision FROM conversation_work_requests ORDER BY conversation_revision",
      )
      .all(),
  ).toEqual([
    { work_request_id: "R1", conversation_revision: 1 },
    { work_request_id: "R2", conversation_revision: 2 },
  ]);
  expect(await resolveThreadConversationId(d1, "L")).toBe("legacy-chat");
  sqlite.close();
});
