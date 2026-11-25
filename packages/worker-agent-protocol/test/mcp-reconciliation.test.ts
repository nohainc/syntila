import { describe, expect, it } from "vitest";
import {
  McpToolCallStatusRequestSchema,
  McpToolCallStatusResultSchema,
  parseWorkspaceRuntimeMessage,
  SERVICE_MCP_INVENTORY_CAPABILITY,
  SERVICE_MCP_TOOL_CALL_STATUS_CAPABILITY,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "../src/index.js";

const key = (taskId: string) => ({
  taskId,
  dispatchKey: `mcp-tool-v1:${taskId}`,
});
const envelope = (type: string, payload: unknown) => ({
  protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
  protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  messageId: "message-1",
  timestamp: "2026-11-06T12:00:00.000Z",
  type,
  executionWorkspaceId: "workspace-a",
  workspaceRuntimeId: "runtime-a",
  payload,
});

describe("tool-call status (reconciliation) v1", () => {
  it("advertises distinct capabilities", () => {
    expect(SERVICE_MCP_TOOL_CALL_STATUS_CAPABILITY).toBe(
      "workspace.mcp_tool_call_status.v1",
    );
    expect(SERVICE_MCP_INVENTORY_CAPABILITY).toBe("workspace.mcp_inventory.v1");
  });

  it("accepts a request that names the logical dispatch identity only", () => {
    const ok = { schemaVersion: 1, ...key("t1") };
    expect(McpToolCallStatusRequestSchema.safeParse(ok).success).toBe(true);
    for (const bad of [
      { ...ok, dispatchKey: "mcp-tool-v1:other" },
      { ...ok, arguments: {} },
      { ...ok, schemaVersion: 2 },
    ])
      expect(McpToolCallStatusRequestSchema.safeParse(bad).success).toBe(false);
  });

  it("accepts the three statuses with consistent fields", () => {
    const base = { schemaVersion: 1, ...key("t1") };
    for (const ok of [
      { ...base, status: "unclaimed" },
      { ...base, status: "claimed_no_outcome" },
      {
        ...base,
        status: "recorded",
        state: "unknown",
        code: "outcome_unknown",
      },
      {
        ...base,
        status: "recorded",
        state: "completed",
        code: "completed",
        result: { content: [] },
      },
    ])
      expect(McpToolCallStatusResultSchema.safeParse(ok).success).toBe(true);
  });

  it("rejects inconsistent or unsafe results", () => {
    const base = { schemaVersion: 1, ...key("t1") };
    for (const bad of [
      { ...base, status: "recorded" },
      { ...base, status: "unclaimed", state: "completed", code: "x" },
      { ...base, status: "claimed_no_outcome", code: "x" },
      { ...base, status: "recorded", state: "unknown", code: "x", result: {} },
      {
        ...base,
        status: "recorded",
        state: "completed",
        code: "x",
        result: { t: "x".repeat(300 * 1024) },
      },
      { ...base, dispatchKey: "mcp-tool-v1:other", status: "unclaimed" },
      { ...base, status: "recorded", state: "ok", code: "x" },
    ])
      expect(McpToolCallStatusResultSchema.safeParse(bad).success).toBe(false);
  });

  it("is validated inside the runtime envelope", () => {
    const request = { schemaVersion: 1, ...key("t1") };
    expect(
      parseWorkspaceRuntimeMessage(
        envelope("mcp.tool_call.status.request", request),
      ).type,
    ).toBe("mcp.tool_call.status.request");
    expect(() =>
      parseWorkspaceRuntimeMessage(
        envelope("mcp.tool_call.status.request", {
          ...request,
          dispatchKey: "x",
        }),
      ),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage(
        envelope("mcp.tool_call.status.result", {
          schemaVersion: 1,
          ...key("t1"),
          status: "recorded",
        }),
      ),
    ).toThrow();
  });
});

describe("mcp.inventory envelope", () => {
  const inventory = {
    schemaVersion: 1,
    revision: 1,
    servers: [
      {
        serverId: "files",
        displayName: "Files",
        transport: "local",
        consented: true,
        enabled: true,
        availability: "unknown",
        tools: [{ name: "read", definitionHash: "a".repeat(64) }],
        boundWorkerTypes: [],
      },
    ],
  };
  it("accepts the sanitized contract and rejects secrets", () => {
    expect(
      parseWorkspaceRuntimeMessage(envelope("mcp.inventory", inventory)).type,
    ).toBe("mcp.inventory");
    expect(() =>
      parseWorkspaceRuntimeMessage(
        envelope("mcp.inventory", {
          ...inventory,
          servers: [{ ...inventory.servers[0], command: "/bin/x" }],
        }),
      ),
    ).toThrow();
  });
});
