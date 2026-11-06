import { readFileSync } from "node:fs";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { afterEach, expect, it } from "vitest";
import { claimMcpToolDispatch } from "../src/mcp-tool-dispatch-claim.js";
import { conversationFixture } from "./helpers/conversation.js";

const databases: DatabaseSync[] = [];
afterEach(() => {
  for (const db of databases.splice(0)) db.close();
});

function fixture() {
  const sqlite = new DatabaseSync(":memory:");
  databases.push(sqlite);
  sqlite.exec(`PRAGMA foreign_keys = ON;
    CREATE TABLE workflow_tasks(id TEXT PRIMARY KEY, step_kind TEXT NOT NULL);
    CREATE TABLE execution_workspaces(id TEXT PRIMARY KEY);
    CREATE TABLE worker_assignments(id TEXT PRIMARY KEY, task_id TEXT NOT NULL,
      execution_workspace_id TEXT NOT NULL);
    INSERT INTO workflow_tasks VALUES ('task','tool_call'),('chat','chat');
    INSERT INTO execution_workspaces VALUES ('w1'),('w2');
    INSERT INTO worker_assignments VALUES
      ('a1','task','w1'),('a2','task','w2'),('a3','chat','w1');`);
  sqlite.exec(
    readFileSync(
      new URL(
        "../migrations-v8/0104_mcp_tool_dispatch_fence.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const db = {
    prepare(sql: string) {
      return {
        bind(...values: SQLInputValue[]) {
          return {
            async first<T>() {
              return (sqlite.prepare(sql).get(...values) ?? null) as T | null;
            },
          };
        },
      };
    },
  } as unknown as D1Database;
  const input = {
    taskId: "task",
    assignmentId: "a1",
    workspaceId: "w1",
    claimedAt: "2026-11-06T00:00:00Z",
  };
  return { db, sqlite, input };
}

it("claims one logical task once, including across attempts and Workspaces", async () => {
  const { db, sqlite, input } = fixture();
  expect(await claimMcpToolDispatch(db, input)).toEqual({
    dispatchKey: "mcp-tool-v1:task",
  });
  expect(await claimMcpToolDispatch(db, input)).toBeNull();
  expect(
    await claimMcpToolDispatch(db, {
      ...input,
      assignmentId: "a2",
      workspaceId: "w2",
    }),
  ).toBeNull();
  expect(
    sqlite.prepare("SELECT count(*) n FROM mcp_tool_dispatch_claims").get(),
  ).toEqual({ n: 1 });
});

it("refuses a mismatched assignment, Workspace, or non-tool step", async () => {
  const { db, input } = fixture();
  expect(
    await claimMcpToolDispatch(db, { ...input, workspaceId: "w2" }),
  ).toBeNull();
  expect(
    await claimMcpToolDispatch(db, { ...input, assignmentId: "a2" }),
  ).toBeNull();
  expect(
    await claimMcpToolDispatch(db, {
      ...input,
      taskId: "chat",
      assignmentId: "a3",
    }),
  ).toBeNull();
  expect(await claimMcpToolDispatch(db, input)).not.toBeNull();
});

it("cannot claim an existing normal Worker assignment in the real schema", async () => {
  const fixture = await conversationFixture();
  try {
    fixture.assign("worker-assignment");
    expect(
      await claimMcpToolDispatch(fixture.db as unknown as D1Database, {
        taskId: "T",
        assignmentId: "worker-assignment",
        workspaceId: "WS",
        claimedAt: "2026-11-06T00:00:00Z",
      }),
    ).toBeNull();
  } finally {
    fixture.sqlite.close();
  }
});
