import { describe, expect, it } from "vitest";
import { McpInventorySchema } from "../src/mcp-inventory.js";

const server = () => ({
  serverId: "files",
  displayName: "Files",
  transport: "local",
  consented: true,
  enabled: true,
  availability: "unknown",
  tools: [{ name: "read", definitionHash: "a".repeat(64) }],
  boundWorkerTypes: ["chatgpt"],
});
const inventory = (servers: unknown[] = [server()]) => ({
  schemaVersion: 1,
  revision: 3,
  servers,
});

describe("sanitized MCP inventory v1", () => {
  it("accepts the Workspace projection shape", () => {
    expect(McpInventorySchema.safeParse(inventory()).success).toBe(true);
    expect(
      McpInventorySchema.safeParse(
        inventory([
          {
            ...server(),
            availability: "incompatible",
            diagnostic: "profile_unsupported",
          },
        ]),
      ).success,
    ).toBe(true);
  });

  it("rejects, rather than strips, anything that could carry a secret or path", () => {
    for (const extra of [
      { command: "/usr/bin/files" },
      { arguments: ["--root", "/home/me"] },
      { environment: { TOKEN: "secret" } },
      { env: { TOKEN: "secret" } },
      { endpoint: "https://example.com/mcp" },
      { tokenEnv: "API_TOKEN" },
      { commandSha256: "b".repeat(64) },
    ]) {
      expect(
        McpInventorySchema.safeParse(inventory([{ ...server(), ...extra }]))
          .success,
        JSON.stringify(extra),
      ).toBe(false);
    }
    expect(
      McpInventorySchema.safeParse({ ...inventory(), credentials: {} }).success,
    ).toBe(false);
    // Tool descriptions and schemas are not part of the Cloud contract.
    expect(
      McpInventorySchema.safeParse(
        inventory([
          {
            ...server(),
            tools: [
              {
                name: "read",
                definitionHash: "a".repeat(64),
                description: "x",
              },
            ],
          },
        ]),
      ).success,
    ).toBe(false);
  });

  it("limits diagnostics to fixed codes, never server-supplied text", () => {
    expect(
      McpInventorySchema.safeParse(
        inventory([
          { ...server(), diagnostic: "connect failed: /Users/me/bin" },
        ]),
      ).success,
    ).toBe(false);
  });

  it("rejects malformed identities and hashes", () => {
    for (const bad of [
      { serverId: "Has Space" },
      { serverId: "../x" },
      { tools: [{ name: "read", definitionHash: "short" }] },
      { transport: "http" },
      { boundWorkerTypes: ["Bad Type"] },
    ])
      expect(
        McpInventorySchema.safeParse(inventory([{ ...server(), ...bad }]))
          .success,
      ).toBe(false);
  });

  it("rejects duplicate servers, tools and bindings and enforces bounds", () => {
    expect(
      McpInventorySchema.safeParse(inventory([server(), server()])).success,
    ).toBe(false);
    const tool = { name: "read", definitionHash: "a".repeat(64) };
    expect(
      McpInventorySchema.safeParse(
        inventory([{ ...server(), tools: [tool, tool] }]),
      ).success,
    ).toBe(false);
    expect(
      McpInventorySchema.safeParse(
        inventory([{ ...server(), boundWorkerTypes: ["a", "a"] }]),
      ).success,
    ).toBe(false);
    const many = Array.from({ length: 65 }, (_, i) => ({
      ...server(),
      serverId: `s${i}`,
    }));
    expect(McpInventorySchema.safeParse(inventory(many)).success).toBe(false);
  });

  it("requires a schema version and a non-negative integer revision", () => {
    expect(
      McpInventorySchema.safeParse({ ...inventory(), schemaVersion: 2 })
        .success,
    ).toBe(false);
    expect(
      McpInventorySchema.safeParse({ ...inventory(), revision: -1 }).success,
    ).toBe(false);
    expect(
      McpInventorySchema.safeParse({ ...inventory(), revision: 1.5 }).success,
    ).toBe(false);
  });
});
