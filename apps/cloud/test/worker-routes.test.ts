import { describe, expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOW_CATALOG, workflowCatalogEntry } from "@syntila/core";
import { handleGetReleaseTrustState } from "../src/routes/releases.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "../src/routes/router.js";

class TestRouteError extends Error {
  constructor(...args: unknown[]) {
    super(String(args[0] ?? ""));
  }
}

const dependencies: WorkerRouteDependencies = {
  json: (data, init) =>
    new Response(JSON.stringify(data), {
      ...init,
      headers: { "content-type": "application/json", ...init?.headers },
    }),
  requireSameOriginForCookieMutation: () => undefined,
  errorMessage: (error) => String(error),
  HttpError: TestRouteError,
};

function request(path: string, method = "GET"): Request {
  return new Request(`https://syntila.test${path}`, { method });
}

describe("Worker API routes", () => {
  it("routes Input Delivery reports to their handlers, never the runtime transport", async () => {
    const file = "wrf-11111111-2222-3333-4444-555555555555";
    const sameOrigin = vi.fn();
    const handlers = {
      handleWorkspaceRuntimeTransport: vi.fn(async () => new Response("{}")),
      handleListRuntimeInputs: vi.fn(async () => new Response("{}")),
      handleDownloadRuntimeInput: vi.fn(async () => new Response("{}")),
      handleConfirmRuntimeInput: vi.fn(async () => new Response("{}")),
      handleReportRuntimeInputAttempt: vi.fn(async () => new Response("{}")),
    };
    const env = {} as Env;
    for (const [path, method, handler] of [
      ["/api/workspace-runtime/inputs", "GET", "handleListRuntimeInputs"],
      [
        `/api/workspace-runtime/inputs/${file}/content`,
        "GET",
        "handleDownloadRuntimeInput",
      ],
      [
        `/api/workspace-runtime/inputs/${file}/delivered`,
        "POST",
        "handleConfirmRuntimeInput",
      ],
      [
        `/api/workspace-runtime/inputs/${file}/attempt`,
        "POST",
        "handleReportRuntimeInputAttempt",
      ],
    ] as const) {
      await routeWorkerRequest(
        request(`${path}?workspaceRuntimeId=r`, method),
        env,
        undefined,
        handlers,
        { ...dependencies, requireSameOriginForCookieMutation: sameOrigin },
      );
      expect(handlers[handler]).toHaveBeenCalledTimes(1);
    }
    expect(handlers.handleWorkspaceRuntimeTransport).not.toHaveBeenCalled();
    // Bearer-authenticated runtime reports skip the cookie same-origin check.
    expect(sameOrigin).not.toHaveBeenCalled();
  });
  it("routes canonical history reads to the Conversation-scoped handler", async () => {
    const handler = vi.fn(async () => new Response("{}"));
    const req = request("/api/threads/W/conversations/C/history");
    const env = {} as Env;
    await routeWorkerRequest(
      req,
      env,
      undefined,
      { handleListConversationHistory: handler },
      dependencies,
    );
    expect(handler).toHaveBeenCalledWith(req, env, "W", "C", undefined);
  });
  it("routes Conversation reads through scoped authorization", async () => {
    const handler = vi.fn(async () => new Response("{}"));
    const req = request("/api/threads/W/conversations");
    const env = {} as Env;
    await routeWorkerRequest(
      req,
      env,
      undefined,
      { handleListConversations: handler },
      dependencies,
    );
    expect(handler).toHaveBeenCalledWith(req, env, "W", undefined);
  });
  it("serves the shared core Workflow catalog to AX", async () => {
    const response = await routeWorkerRequest(
      request("/api/workflows/catalog"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {} as WorkerRouteHandlers,
      dependencies,
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      // Tool-call workflows need a request-supplied target and are not listed.
      workflows: Object.values(BUILTIN_WORKFLOW_CATALOG)
        .filter((definition) =>
          definition.steps.every((step) => step.kind !== "tool_call"),
        )
        .map(workflowCatalogEntry),
    });
  });

  it("returns zero catalog payload bytes when the revision is unchanged", async () => {
    const first = await routeWorkerRequest(
      request("/api/workflows/catalog"),
      {} as Env,
      undefined,
      {},
      dependencies,
    );
    expect((await first.text()).length).toBeGreaterThan(0);
    const next = await routeWorkerRequest(
      new Request("https://syntila.test/api/workflows/catalog", {
        headers: { "if-none-match": first.headers.get("etag")! },
      }),
      {} as Env,
      undefined,
      {},
      dependencies,
    );
    expect(next.status).toBe(304);
    expect((await next.arrayBuffer()).byteLength).toBe(0);
  });

  it("serves the logical Worker inventory at its current product route", async () => {
    const handler = vi.fn(
      async () => new Response("inventory", { status: 200 }),
    );
    const response = await routeWorkerRequest(
      request("/api/workers?workspaceId=workspace-1"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {
        handleListWorkspaceWorkerInventory: handler,
      } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("serves the Cloud Worker catalog through the human product API", async () => {
    const handler = vi.fn(async () => new Response("catalog", { status: 200 }));
    const response = await routeWorkerRequest(
      request("/api/workers/catalog"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {
        handleListWorkerCatalog: handler,
      } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("keeps the channel-scoped catalog behind the Workspace runtime API", async () => {
    const handler = vi.fn(
      async () => new Response("runtime catalog", { status: 200 }),
    );
    const response = await routeWorkerRequest(
      request("/api/workspace-runtime/workers/catalog"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {
        handleListWorkspaceWorkerCatalog: handler,
      } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("serves Workspace releases only at the versionless release routes", async () => {
    const routes = [
      [
        "GET",
        "/api/workspace-releases/latest",
        "handleGetLatestWorkspaceRelease",
      ],
      [
        "POST",
        "/api/workspace-releases/publish",
        "handlePublishWorkspaceRelease",
      ],
      ["GET", "/api/workspace-releases/1.2.3", "handleGetWorkspaceRelease"],
      [
        "GET",
        "/api/workspace-releases/1.2.3/download",
        "handleDownloadWorkspaceRelease",
      ],
      [
        "POST",
        "/api/workspace-releases/1.2.3/revoke",
        "handleRevokeWorkspaceRelease",
      ],
    ] as const;

    for (const [method, path, handlerName] of routes) {
      const handler = vi.fn(
        async () => new Response("release", { status: 200 }),
      );
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        { [handlerName]: handler } as unknown as WorkerRouteHandlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(200);
      expect(handler).toHaveBeenCalledOnce();
    }
  });

  it("serves shared release trust", async () => {
    const handlers = {
      handleGetReleaseTrustState: vi.fn(async () => new Response("trust")),
    } as unknown as WorkerRouteHandlers;

    const trust = await routeWorkerRequest(
      request("/api/release-trust"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    expect(trust.status).toBe(200);
    expect(handlers.handleGetReleaseTrustState).toHaveBeenCalledOnce();
  });

  it("passes database environment to the actual release trust handler", async () => {
    const prepare = vi.fn(() => ({ all: async () => ({ results: [] }) }));
    const response = await routeWorkerRequest(
      request("/api/release-trust"),
      { SYNTILA_DB: { prepare } } as unknown as Parameters<
        typeof routeWorkerRequest
      >[1],
      undefined,
      { handleGetReleaseTrustState } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      revokedKeyIds: [],
      revokedWorkspaceReleases: [],
    });
    expect(prepare).toHaveBeenCalledTimes(2);
  });

  it("routes the V9 admin Worker Profile catalog", async () => {
    const handler = vi.fn(async () => new Response("preflight"));
    const response = await routeWorkerRequest(
      request("/api/admin/workers"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {
        handleListV9WorkerProfiles: handler,
      } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("keeps the removed V8 Profile lifecycle routes unavailable", async () => {
    const handlers = {
      handleListWorkerCatalog: vi.fn(async () => new Response("human catalog")),
      handleResolveToolProfileChannels: vi.fn(
        async () => new Response("resolved"),
      ),
      handleListWorkspaceWorkerCatalog: vi.fn(
        async () => new Response("catalog"),
      ),
      handleSetWorkspaceToolProfileChannel: vi.fn(
        async () => new Response("channel"),
      ),
      handleCreateToolProfileDefinition: vi.fn(
        async () => new Response("definition"),
      ),
      handleCreateApprovedLogicalWorker: vi.fn(
        async () => new Response("worker"),
      ),
      handleCreateDraftToolProfileRelease: vi.fn(
        async () => new Response("draft"),
      ),
      handlePublishDraftToolProfileRelease: vi.fn(
        async () => new Response("published"),
      ),
      handlePromoteToolProfileRelease: vi.fn(
        async () => new Response("promoted"),
      ),
      handleChangeToolProfileReleaseLifecycle: vi.fn(
        async () => new Response("revoked"),
      ),
      handleListToolProfileReleaseAudit: vi.fn(
        async () => new Response("audit"),
      ),
      handleListAdminWorkerCatalog: vi.fn(
        async () => new Response("admin catalog"),
      ),
      handleListToolProfileDefinitions: vi.fn(
        async () => new Response("definitions"),
      ),
      handleGetToolProfileDefinition: vi.fn(
        async () => new Response("definition detail"),
      ),
      handleGetToolProfileRelease: vi.fn(
        async () => new Response("release detail"),
      ),
      handleListAllToolProfileChannels: vi.fn(
        async () => new Response("all channels"),
      ),
      handleListToolProfileChannels: vi.fn(
        async () => new Response("definition channels"),
      ),
      handleRollbackToolProfileChannel: vi.fn(
        async () => new Response("rollback"),
      ),
      handleListToolProfileReleaseEvidence: vi.fn(
        async () => new Response("list evidence"),
      ),
      handleSubmitToolProfileReleaseEvidence: vi.fn(
        async () => new Response("submit evidence"),
      ),
      handleSubmitToolProfileLocalQualification: vi.fn(
        async () => new Response("submit qualification"),
      ),
      handleListToolProfileDefinitionAudit: vi.fn(
        async () => new Response("definition audit"),
      ),
      handleListGlobalToolProfileAudit: vi.fn(
        async () => new Response("global audit"),
      ),
    } as unknown as WorkerRouteHandlers;
    const routes = [
      [
        "/api/tool-profiles?workerTypeId=chatgpt&workspaceRuntimeId=runtime-1",
        "GET",
      ],
      ["/api/workspaces/workspace-1/tool-profile-channel", "PATCH"],
      ["/api/admin/tool-profiles/definitions", "POST"],
      ["/api/admin/tool-profiles/definitions", "GET"],
      ["/api/admin/tool-profiles/definitions/chatgpt-codex", "GET"],
      ["/api/admin/workers/catalog", "POST"],
      ["/api/admin/workers/catalog", "GET"],
      ["/api/admin/tool-profiles/channels", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/channels", "GET"],
      [
        "/api/admin/tool-profiles/chatgpt-codex/channels/stable/rollback",
        "POST",
      ],
      ["/api/admin/tool-profiles/audit", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/audit", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/2/publish", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/2/promote", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/revoke", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/audit", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/evidence", "GET"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/evidence", "POST"],
      [
        "/api/admin/tool-profiles/chatgpt-codex/releases/1/qualification",
        "POST",
      ],
    ] as const;
    for (const [path, method] of routes) {
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        handlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(404);
    }
  });

  it("exports every handler invoked by the router in routeHandlers", async () => {
    const fs = await import("node:fs");
    const path = await import("node:path");
    const routerSource = fs.readFileSync(
      path.resolve(__dirname, "../src/routes/router.ts"),
      "utf8",
    );
    const { routeHandlers } = await import("../src/index.js");

    const routerHandlerNames = new Set<string>();
    for (const match of routerSource.matchAll(/handlers\.([a-zA-Z0-9_]+)!/g)) {
      if (match[1]) {
        routerHandlerNames.add(match[1]);
      }
    }

    const exportedHandlerNames = new Set(Object.keys(routeHandlers));
    const missing: string[] = [];
    for (const name of routerHandlerNames) {
      if (!exportedHandlerNames.has(name)) {
        missing.push(name);
      }
    }

    expect(
      missing,
      `Missing handlers in routeHandlers: ${missing.join(", ")}`,
    ).toEqual([]);
  });
});
