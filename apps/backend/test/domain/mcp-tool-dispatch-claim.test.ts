import { afterEach, expect, it } from "./helpers/vitest-compat";
import {
  claimMcpToolDispatch,
  loadMcpToolCall,
  recordMcpToolOutcome,
} from "../../src/domain/mcp-tool-dispatch-claim.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

const closers: Array<() => void> = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  closers.push(() => sqlite.close());
  sqlite.exec(`
 INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','User','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','Space','now','now');
 INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','U','now','now');
 INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS','U','Workspace','now','now'),('WS2','U','Other','now','now');
 INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
 VALUES('R','W','U','stateless','chat',1,'{}','running','{}','now','now');
 INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
 VALUES('tool','R','tool_call','stateless_read',1000,'tool:v1','running','now','now'),
       ('chat','R','chat','stateless_read',1000,'chat:v1','running','now','now');`);
  const d1 = db as unknown as D1Database;
  const input = {
    taskId: "tool",
    workspaceId: "WS",
    claimedAt: "2026-11-06T00:00:00.000Z",
  };
  return { d1, sqlite, input };
}

it("claims one logical task once, even for another Workspace", async () => {
  const { d1, input, sqlite } = fixture();
  expect(await claimMcpToolDispatch(d1, input)).toEqual({
    dispatchKey: "mcp-tool-v1:tool",
  });
  expect(await claimMcpToolDispatch(d1, input)).toBeNull();
  expect(
    await claimMcpToolDispatch(d1, { ...input, workspaceId: "WS2" }),
  ).toBeNull();
  expect(sqlite.prepare("SELECT count(*) n FROM mcp_tool_calls").get()).toEqual(
    { n: 1 },
  );
});

it("refuses a non-tool step", async () => {
  const { d1, input } = fixture();
  expect(
    await claimMcpToolDispatch(d1, { ...input, taskId: "chat" }),
  ).toBeNull();
});

it("records the first outcome only, and keeps results to known outcomes", async () => {
  const { d1, input } = fixture();
  await claimMcpToolDispatch(d1, input);
  expect((await loadMcpToolCall(d1, "tool"))?.state).toBeNull();
  expect(
    await recordMcpToolOutcome(d1, {
      taskId: "tool",
      state: "completed",
      code: "completed",
      result: { content: [] },
      completedAt: "2026-11-06T00:00:01.000Z",
    }),
  ).toBe(true);
  expect(
    await recordMcpToolOutcome(d1, {
      taskId: "tool",
      state: "unknown",
      code: "outcome_unknown",
      completedAt: "2026-11-06T00:00:02.000Z",
    }),
  ).toBe(false);
  expect(await loadMcpToolCall(d1, "tool")).toMatchObject({
    state: "completed",
    result: { content: [] },
  });
});
