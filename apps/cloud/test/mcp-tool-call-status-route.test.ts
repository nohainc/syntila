import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleWorkspaceMcpToolCallStatus } from "../src/routes/mcp-tool-call.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

let store: ReturnType<typeof sqliteD1>;
let lastForwardedBody: unknown;
let gatewayStatus: number;
let gatewayReply: unknown;
let env: SecurityEnv;

const getStatus = (
  user: string,
  workspace: string,
  taskId: string,
  method = "GET",
) =>
  handleWorkspaceMcpToolCallStatus(
    new Request(
      `https://test/api/workspaces/${workspace}/mcp-tool-calls/${taskId}/status`,
      {
        method,
        headers: {
          authorization: user,
        },
      },
    ),
    env,
    workspace,
    taskId,
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
    cloud: { state: "completed", code: "completed" },
    workspace: {
      status: "recorded",
      state: "completed",
      code: "completed",
      result: { ok: true },
    },
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

describe("GET /api/workspaces/:id/mcp-tool-calls/:taskId/status", () => {
  it("rejects non-GET methods with 405", async () => {
    await expect(
      getStatus("owner", "ws-owner", "task-1", "POST"),
    ).rejects.toMatchObject({ status: 405 });
  });

  it("refuses callers who do not own the Workspace with 404", async () => {
    await expect(
      getStatus("other", "ws-owner", "task-1"),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("refuses revoked Workspaces with 404", async () => {
    await expect(getStatus("owner", "ws-gone", "task-1")).rejects.toMatchObject(
      { status: 404 },
    );
  });

  it("rejects empty or overly long taskId with 400", async () => {
    await expect(getStatus("owner", "ws-owner", "")).rejects.toMatchObject({
      status: 400,
    });
    await expect(
      getStatus("owner", "ws-owner", "a".repeat(901)),
    ).rejects.toMatchObject({ status: 400 });
  });

  it("forwards the request to WorkspaceGateway DO and returns the response", async () => {
    const res = await getStatus("owner", "ws-owner", "task-1");
    expect(res.status).toBe(200);
    expect(lastForwardedBody).toEqual({
      schemaVersion: 1,
      taskId: "task-1",
      dispatchKey: "mcp-tool-v1:task-1",
    });
    const body = await res.json();
    expect(body).toEqual(gatewayReply);
  });

  it("propagates 404 or 409 status from the gateway", async () => {
    gatewayStatus = 404;
    gatewayReply = { cloud: null, workspace: null };
    const res = await getStatus("owner", "ws-owner", "task-missing");
    expect(res.status).toBe(404);

    gatewayStatus = 409;
    gatewayReply = { error: "Tool call belongs to another Workspace" };
    const resConflict = await getStatus("owner", "ws-owner", "task-other");
    expect(resConflict.status).toBe(409);
  });
});
