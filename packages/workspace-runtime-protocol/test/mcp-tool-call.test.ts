import { describe, expect, it } from "vitest";
import { McpToolCallRequestSchema } from "../src/mcp-tool-call.js";

const request = () => ({
  schemaVersion: 1,
  taskId: "task-one",
  dispatchKey: "mcp-tool-v1:task-one",
  serverId: "echo",
  tool: "echo",
  toolDefinitionHash: "a".repeat(64),
  arguments: { text: "hello" },
  timeoutMs: 30000,
});

describe("internal MCP tool-call v1", () => {
  it("accepts a complete frozen call", () => {
    expect(McpToolCallRequestSchema.safeParse(request()).success).toBe(true);
  });
  it("rejects mismatched keys, invalid identities and unexpected fields", () => {
    for (const bad of [
      { ...request(), dispatchKey: "mcp-tool-v1:other" },
      { ...request(), serverId: "../outside" },
      { ...request(), toolDefinitionHash: "A".repeat(64) },
      { ...request(), timeoutMs: 0 },
      { ...request(), extra: true },
    ])
      expect(McpToolCallRequestSchema.safeParse(bad).success).toBe(false);
  });
  it("counts encoded UTF-8 bytes rather than characters", () => {
    expect(
      McpToolCallRequestSchema.safeParse({
        ...request(),
        arguments: { text: "é".repeat(33_000) },
      }).success,
    ).toBe(false);
  });
});
