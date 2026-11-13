import { afterEach, expect, it } from "./helpers/vitest-compat";
import {
  normalizeMcpToolStepOutcome,
  parseMcpToolStepInput,
  runMcpToolStep,
  toolStepFailure,
} from "../../src/domain/mcp-tool-step.js";
import { conversationFixture } from "./helpers/conversation.js";

const input = {
  executionWorkspaceId: "WS",
  serverId: "echo",
  tool: "echo",
  toolDefinitionHash: "a".repeat(64),
  arguments: { text: "hi" },
  timeoutMs: 5000,
};

const closers: Array<() => void> = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

async function fixture(grant: string | null, reply: () => Promise<Response>) {
  const f = await conversationFixture();
  closers.push(() => f.sqlite.close());
  if (grant)
    f.sqlite.exec(
      `INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,created_at,updated_at)
       VALUES('G','P','WS','U','${grant}','now','now')`,
    );
  const sent: unknown[] = [];
  const env = {
    SYNTILA_DB: f.db as unknown as D1Database,
    SYNTILA_WORKSPACE_GATEWAY: {
      idFromName: (name: string) => name,
      get: () => ({
        fetch: async (_url: string, init: RequestInit) => {
          sent.push(JSON.parse(String(init.body)));
          return reply();
        },
      }),
    } as unknown as DurableObjectNamespace,
  };
  return { env, sent };
}

const scope = { workRequestId: "R", taskId: "tool" };

it("calls through the Gateway with the frozen wire request", async () => {
  const { env, sent } = await fixture("active", async () =>
    Response.json({
      state: "completed",
      code: "completed",
      result: { content: [] },
    }),
  );
  expect(await runMcpToolStep(env, scope, input)).toEqual({
    state: "completed",
    code: "completed",
    result: { content: [] },
  });
  expect(sent[0]).toMatchObject({
    schemaVersion: 1,
    taskId: "tool",
    dispatchKey: "mcp-tool-v1:tool",
    serverId: "echo",
  });
});

it("refuses without an active Space grant, before contacting the Workspace", async () => {
  for (const grant of [null, "revoked", "suspended"]) {
    const { env, sent } = await fixture(grant, async () => Response.json({}));
    expect(await runMcpToolStep(env, scope, input)).toEqual({
      state: "rejected",
      code: "workspace_not_granted",
    });
    expect(sent).toHaveLength(0);
    closers.pop()!();
  }
});

it("maps transport failures conservatively", async () => {
  const offline = await fixture(
    "active",
    async () => new Response("", { status: 503 }),
  );
  expect((await runMcpToolStep(offline.env, scope, input)).code).toBe(
    "workspace_offline",
  );
  const broken = await fixture("active", async () => {
    throw new Error("network");
  });
  expect(await runMcpToolStep(broken.env, scope, input)).toMatchObject({
    state: "unknown",
    code: "gateway_unreachable",
  });
  const garbled = await fixture("active", async () =>
    Response.json({ state: "weird", code: 1 }),
  );
  expect((await runMcpToolStep(garbled.env, scope, input)).state).toBe(
    "unknown",
  );
});

it("parses the accepted tool target strictly", () => {
  expect(parseMcpToolStepInput(input)?.timeoutMs).toBe(5000);
  expect(
    parseMcpToolStepInput({ ...input, timeoutMs: undefined })?.timeoutMs,
  ).toBe(60_000);
  for (const bad of [
    null,
    [],
    { ...input, extra: 1 },
    { ...input, serverId: "Bad Id" },
    { ...input, toolDefinitionHash: "x" },
    { ...input, arguments: [] },
    { ...input, timeoutMs: 0 },
  ])
    expect(parseMcpToolStepInput(bad)).toBeNull();
});

it("explains that an unknown outcome is never retried", () => {
  expect(toolStepFailure({ state: "unknown", code: "result_timeout" })).toMatch(
    /not retried/,
  );
});

it("does not accept a completed reply without a usable result", async () => {
  for (const result of [undefined, null, [], "invalid"]) {
    const { env } = await fixture("active", async () =>
      Response.json({ state: "completed", code: "result_too_large", result }),
    );
    const outcome = await runMcpToolStep(env, scope, input);
    expect(outcome).toEqual({ state: "unknown", code: "result_unavailable" });
    expect(toolStepFailure(outcome)).toMatch(/may have run.*not retried/);
  }
});

it("fails closed when a persisted outcome cannot supply a usable result", () => {
  for (const value of [
    null,
    {},
    { state: "completed", code: "result_too_large" },
    { state: "completed", code: "ok", result: [] },
    { state: "completed", code: "ok", result: { text: "x".repeat(262145) } },
  ]) {
    expect(normalizeMcpToolStepOutcome(value).state).toBe("unknown");
  }
  expect(
    normalizeMcpToolStepOutcome({
      state: "completed",
      code: "ok",
      result: { content: [] },
    }).state,
  ).toBe("completed");
});

it("explains that a tool with unusable output may have run", () => {
  for (const code of ["result_too_large", "result_unavailable"]) {
    const message = toolStepFailure({ state: "unknown", code });
    expect(message).toMatch(/may have run and changed things/);
    expect(message).toMatch(/not retried/);
    expect(message).toMatch(/nothing was passed to later steps/);
  }
});
