import { describe, expect, it } from "vitest";
import {
  McpActionRequestSchema,
  McpActionResultSchema,
  SERVICE_MCP_ACTION_CAPABILITY,
  workspaceRuntimeEnvelopeSchema,
} from "../src/index.js";

describe("mcp-action protocol", () => {
  it("advertises a stable capability", () => {
    expect(SERVICE_MCP_ACTION_CAPABILITY).toBe("workspace.mcp_action.v1");
  });

  it("accepts valid action requests", () => {
    const valid = [
      {
        actionId: "act-1",
        action: "enable",
        serverId: "fetch-server",
      },
      {
        actionId: "act-2",
        action: "disable",
        serverId: "fetch-server",
      },
      {
        actionId: "act-3",
        action: "remove",
        serverId: "fetch-server",
      },
      {
        actionId: "act-4",
        action: "bind",
        serverId: "fetch-server",
        workerTypeId: "codex",
      },
      {
        actionId: "act-5",
        action: "unbind",
        serverId: "fetch-server",
        workerTypeId: "codex",
      },
      {
        actionId: "act-6",
        action: "consent",
        serverId: "fetch-server",
        acceptHash:
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      },
      {
        actionId: "act-7",
        action: "test",
        serverId: "fetch-server",
      },
      {
        actionId: "act-8",
        action: "addRemote",
        serverId: "remote-mcp",
        displayName: "Remote MCP",
        endpoint: "https://example.com/sse",
        tokenEnv: "MCP_TOKEN",
        insecureLoopback: false,
      },
    ];

    for (const req of valid) {
      expect(McpActionRequestSchema.safeParse(req).success).toBe(true);
    }
  });

  it("rejects unknown actions or missing fields", () => {
    expect(
      McpActionRequestSchema.safeParse({
        actionId: "act-1",
        action: "reboot",
        serverId: "fetch",
      }).success,
    ).toBe(false);

    expect(
      McpActionRequestSchema.safeParse({
        actionId: "act-1",
        action: "enable",
        serverId: "INVALID SERVER ID WITH SPACES",
      }).success,
    ).toBe(false);
  });

  it("validates action results", () => {
    const successResult = {
      actionId: "act-1",
      ok: true,
      action: "enable",
      serverId: "fetch-server",
      result: { enabled: true },
    };
    expect(McpActionResultSchema.safeParse(successResult).success).toBe(true);

    const errorResult = {
      actionId: "act-1",
      ok: false,
      action: "consent",
      serverId: "fetch-server",
      error: {
        code: "mcp_consent_mismatch",
        message: "Server tools have changed since review.",
      },
    };
    expect(McpActionResultSchema.safeParse(errorResult).success).toBe(true);
  });

  it("enforces envelope validation", () => {
    const validEnvelope = {
      protocol: "syntila.workspace-runtime-protocol",
      protocolVersion: "5.1",
      messageId: "msg-1",
      timestamp: new Date().toISOString(),
      type: "mcp.action.request",
      payload: {
        actionId: "act-1",
        action: "test",
        serverId: "fetch",
      },
    };
    expect(workspaceRuntimeEnvelopeSchema.safeParse(validEnvelope).success).toBe(
      true,
    );
  });
});
