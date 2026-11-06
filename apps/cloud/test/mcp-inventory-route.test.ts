import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleWorkspaceMcpInventory } from "../src/routes/mcp-inventory.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

let store: ReturnType<typeof sqliteD1>;
let gatewayReplies: Record<string, unknown>;
let env: SecurityEnv;

const inventory = {
  schemaVersion: 1,
  revision: 7,
  servers: [
    {
      serverId: "files",
      displayName: "Files",
      transport: "local",
      consented: true,
      enabled: true,
      availability: "unknown",
      tools: [{ name: "read", definitionHash: "a".repeat(64) }],
      boundWorkerTypes: ["chatgpt"],
    },
  ],
};

const get = (user: string, workspace: string, method = "GET") =>
  handleWorkspaceMcpInventory(
    new Request(`https://test/api/workspaces/${workspace}/mcp-inventory`, {
      method,
      headers: { authorization: user },
    }),
    env,
    workspace,
  );

beforeEach(() => {
  store = sqliteD1();
  store.sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
      ('owner','o@test','Owner','now','now'),
      ('other','x@test','Other','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES
      ('ws-owner','owner','A','online','now','now'),
      ('ws-gone','owner','B','revoked','now','now');`);
  vi.spyOn(identityService, "resolve").mockImplementation(async (req) => {
    const id = req.headers.get("authorization");
    return id
      ? { userId: id, email: `${id}@test`, name: id, sessionId: "t" }
      : null;
  });
  gatewayReplies = {
    "/status": { online: true },
    "/mcp-inventory": {
      inventory,
      receivedAt: new Date(Date.now() - 30_000).toISOString(),
      workspaceRuntimeId: "runtime-secret",
    },
  };
  env = {
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_WORKSPACE_GATEWAY: {
      getByName: () => ({
        fetch: async (url: string) =>
          Response.json(gatewayReplies[new URL(url).pathname] ?? null),
      }),
    },
  } as unknown as SecurityEnv;
});
afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});

describe("GET /api/workspaces/:id/mcp-inventory", () => {
  it("returns the sanitized snapshot with online state and age", async () => {
    const body = (await (await get("owner", "ws-owner")).json()) as Record<
      string,
      unknown
    >;
    expect(body).toMatchObject({
      schemaVersion: 1,
      online: true,
      inventory: { revision: 7 },
    });
    expect(body.ageSeconds as number).toBeGreaterThanOrEqual(29);
    // Internal identifiers of the gateway never reach the client.
    expect(JSON.stringify(body)).not.toContain("runtime-secret");
  });

  it("marks a disconnected Workspace and keeps the last snapshot", async () => {
    gatewayReplies["/status"] = { online: false };
    const body = (await (await get("owner", "ws-owner")).json()) as {
      online: boolean;
      inventory: { revision: number };
    };
    expect(body.online).toBe(false);
    expect(body.inventory.revision).toBe(7);
  });

  it("says nothing is published rather than inventing an empty list", async () => {
    gatewayReplies["/mcp-inventory"] = null;
    const body = (await (await get("owner", "ws-owner")).json()) as Record<
      string,
      unknown
    >;
    expect(body.inventory).toBeNull();
    expect(body.receivedAt).toBeNull();
    expect(body.ageSeconds).toBeNull();
  });

  it("drops a stored snapshot that no longer matches the contract", async () => {
    gatewayReplies["/mcp-inventory"] = {
      inventory: {
        ...inventory,
        servers: [{ ...inventory.servers[0], command: "/bin/x" }],
      },
      receivedAt: new Date().toISOString(),
    };
    const body = (await (await get("owner", "ws-owner")).json()) as {
      inventory: unknown;
    };
    expect(body.inventory).toBeNull();
  });

  it("reports an unknown online state when the gateway cannot say", async () => {
    gatewayReplies["/status"] = null;
    const body = (await (await get("owner", "ws-owner")).json()) as {
      online: unknown;
    };
    expect(body.online).toBeNull();
  });

  it("is owner-only, hides revoked Workspaces and refuses other methods", async () => {
    await expect(get("other", "ws-owner")).rejects.toMatchObject({
      status: 404,
    });
    await expect(get("owner", "ws-gone")).rejects.toMatchObject({
      status: 404,
    });
    await expect(get("owner", "ws-missing")).rejects.toMatchObject({
      status: 404,
    });
    await expect(get("owner", "ws-owner", "POST")).rejects.toMatchObject({
      status: 405,
    });
  });
});
