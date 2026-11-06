import { describe, expect, it } from "vitest";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const call = (taskId: string) => ({
  schemaVersion: 1,
  taskId,
  dispatchKey: `mcp-tool-v1:${taskId}`,
  serverId: "echo",
  tool: "echo",
  toolDefinitionHash: "a".repeat(64),
  arguments: { text: "hi" },
  timeoutMs: 5000,
});

async function fixture() {
  const f = await gatewayFixture("created");
  f.sqlite.exec(
    `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
     VALUES('tool','R','tool_call','stateless_read',5000,'tool:v1','running','now','now')`,
  );
  const request = (body: unknown) =>
    f.gateway.fetch(
      new Request("https://gateway.internal/mcp-tool-call", {
        method: "POST",
        body: JSON.stringify(body),
      }),
    );
  return { f, request };
}

async function outboundRequest(f: Awaited<ReturnType<typeof fixture>>["f"]) {
  for (let i = 0; i < 50; i += 1) {
    const found = (await f.outbound()).find(
      (m) => m.type === "mcp.tool_call.request",
    );
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("request was not sent");
}

describe("Gateway MCP tool call", () => {
  it("claims, sends the frozen request and records the Workspace's outcome", async () => {
    const { f, request } = await fixture();
    try {
      const pending = request(call("tool"));
      const sent = await outboundRequest(f);
      expect(sent.payload).toMatchObject({
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        serverId: "echo",
      });
      await f.send("mcp.tool_call.result", {
        schemaVersion: 1,
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        state: "completed",
        code: "completed",
        result: { content: [{ type: "text", text: "hi" }] },
      });
      const body = (await (await pending).json()) as Record<string, unknown>;
      expect(body).toMatchObject({ state: "completed", code: "completed" });
      // A repeat returns the recorded outcome and never re-dispatches.
      const again = await request(call("tool"));
      expect(await again.json()).toMatchObject({ state: "completed" });
      expect(
        (await f.outbound()).filter((m) => m.type === "mcp.tool_call.request"),
      ).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });

  it("answers unknown, not retryable, when a claimed call has no outcome", async () => {
    const { f, request } = await fixture();
    try {
      f.sqlite.exec(
        "INSERT INTO mcp_tool_calls(task_id,workspace_id,dispatch_key,claimed_at) VALUES('tool','WS','mcp-tool-v1:tool','now')",
      );
      const response = await request(call("tool"));
      expect(await response.json()).toMatchObject({
        state: "unknown",
        code: "dispatch_already_claimed",
      });
    } finally {
      f.sqlite.close();
    }
  });

  it("rejects malformed calls and ignores results nobody awaits", async () => {
    const { f, request } = await fixture();
    try {
      expect(
        (await request({ ...call("tool"), dispatchKey: "other" })).status,
      ).toBe(400);
      await f.send("mcp.tool_call.result", {
        schemaVersion: 1,
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        state: "completed",
        code: "completed",
      });
      expect(
        f.sqlite.prepare("SELECT count(*) n FROM mcp_tool_calls").get(),
      ).toEqual({ n: 0 });
    } finally {
      f.sqlite.close();
    }
  });
});
