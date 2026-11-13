import { afterEach, beforeEach, describe, expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../../src/domain/auth/identity-service.js";
import { handleWorkspaceMcpAction } from "../../src/domain/routes/mcp-action.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

let store: ReturnType<typeof sqliteD1>;
let lastForwardedBody: unknown;
let gatewayStatus: number;
let gatewayReply: unknown;
let env: SecurityEnv;

const postAction = (
  user: string,
  workspace: string,
  body?: unknown,
  method = "POST",
) =>
  handleWorkspaceMcpAction(
    new Request(`https://test/api/workspaces/${workspace}/mcp-action`, {
      method,
      headers: {
        authorization: user,
        ...(body !== undefined ? { "content-type": "application/json" } : {}),
      },
      ...(body !== undefined && method !== "GET" && method !== "HEAD"
        ? { body: JSON.stringify(body) }
        : {}),
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
  lastForwardedBody = null;
  gatewayStatus = 200;
  gatewayReply = {
    actionId: "act-1",
    ok: true,
    action: "enable",
    serverId: "fetch-srv",
    result: { enabled: true },
  };
  env = {
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_WORKSPACE_GATEWAY: {
      getByName: () => ({
        fetch: async (req: Request | string, init?: RequestInit) => {
          if (typeof req !== "string") {
            lastForwardedBody = await req.json();
          } else if (init?.body) {
            lastForwardedBody = JSON.parse(init.body as string);
          }
          return new Response(JSON.stringify(gatewayReply), {
            status: gatewayStatus,
            headers: { "content-type": "application/json" },
          });
        },
      }),
    } as unknown as DurableObjectNamespace,
  } as unknown as SecurityEnv;
});

afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});

describe("POST /api/workspaces/:id/mcp-action", () => {
  it("rejects non-POST methods with 405", async () => {
    await expect(
      postAction("owner", "ws-owner", undefined, "GET"),
    ).rejects.toMatchObject({ status: 405 });
  });

  it("refuses callers who do not own the Workspace with 404", async () => {
    await expect(
      postAction("other", "ws-owner", {
        actionId: "1",
        action: "enable",
        serverId: "srv",
      }),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("refuses revoked Workspaces with 404", async () => {
    await expect(
      postAction("owner", "ws-gone", {
        actionId: "1",
        action: "enable",
        serverId: "srv",
      }),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("forwards the action to the Workspace Gateway and returns the outcome", async () => {
    const actionPayload = {
      actionId: "act-1",
      action: "enable",
      serverId: "fetch-srv",
    };
    const response = await postAction("owner", "ws-owner", actionPayload);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.ok).toBe(true);
    expect(body.action).toBe("enable");
    expect(lastForwardedBody).toEqual(actionPayload);
  });

  it("preserves gateway status codes on errors", async () => {
    gatewayStatus = 503;
    gatewayReply = { error: "Workspace is offline", code: "workspace_offline" };
    const response = await postAction("owner", "ws-owner", {
      actionId: "act-2",
      action: "test",
      serverId: "srv",
    });
    expect(response.status).toBe(503);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.code).toBe("workspace_offline");
  });
});
