import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
} from "../../src/domain/routes/router.js";

function dependencies(
  requireSameOriginForCookieMutation: (request: Request) => void,
): WorkerRouteDependencies {
  return {
    json: (data: unknown, init?: ResponseInit) => Response.json(data, init),
    requireSameOriginForCookieMutation,
    errorMessage: (error: unknown) => String(error),
    HttpError: Error,
  } as unknown as WorkerRouteDependencies;
}

describe("Workspace runtime lifecycle routes", () => {
  it.each([
    ["token redemption", "POST", "/api/workspace-runtime/enroll"],
    ["token listing", "GET", "/api/workspaces/workspace-1/enrollments"],
    ["token creation", "POST", "/api/workspaces/workspace-1/enrollments"],
  ])("does not expose %s", async (_label, method, path) => {
    const response = await routeWorkerRequest(
      new Request(`https://syntila.app${path}`, { method }),
      {} as Env,
      undefined,
      {},
      dependencies(vi.fn()),
    );
    expect(response.status).toBe(404);
  });

  it("routes authenticated desktop registration without cookie CSRF", async () => {
    const sameOrigin = vi.fn();
    const register = vi.fn(async () =>
      Response.json({ workspaceRuntimeId: "runtime-1" }, { status: 201 }),
    );
    const response = await routeWorkerRequest(
      new Request("https://syntila.app/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: "Bearer desktop-human-token",
          "content-type": "application/json",
        },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleRegisterWorkspaceFromDesktop: register },
      dependencies(sameOrigin),
    );
    expect(response.status).toBe(201);
    expect(register).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("routes ownership checks and release with desktop bearer authentication", async () => {
    const sameOrigin = vi.fn();
    const ownership = vi.fn(async () =>
      Response.json({ ownerUserId: "user-a" }),
    );
    const release = vi.fn(async () => Response.json({ released: true }));
    const checkResponse = await routeWorkerRequest(
      new Request("https://syntila.app/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer desktop-human-token",
          "content-type": "application/json",
        },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleCheckWorkspaceOwnership: ownership },
      dependencies(sameOrigin),
    );
    const releaseResponse = await routeWorkerRequest(
      new Request("https://syntila.app/api/workspace-runtime/release", {
        method: "POST",
        headers: {
          authorization: "Bearer fresh-desktop-human-token",
          "content-type": "application/json",
        },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleReleaseDesktopWorkspace: release },
      dependencies(sameOrigin),
    );

    expect(checkResponse.status).toBe(200);
    expect(releaseResponse.status).toBe(200);
    expect(ownership).toHaveBeenCalledOnce();
    expect(release).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("routes explicit desktop-human disconnect without cookie CSRF", async () => {
    const sameOrigin = vi.fn();
    const disconnect = vi.fn(async () => Response.json({ disconnected: true }));
    const response = await routeWorkerRequest(
      new Request("https://syntila.app/api/workspace-runtime/disconnect", {
        method: "POST",
        headers: {
          authorization: "Bearer desktop-human-token",
          "content-type": "application/json",
        },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleDisconnectDesktopWorkspace: disconnect },
      dependencies(sameOrigin),
    );
    expect(response.status).toBe(200);
    expect(disconnect).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("requires same-origin protection for browser-cookie desktop approval", async () => {
    const sameOrigin = vi.fn();
    const approve = vi.fn(async () => Response.json({ approved: true }));
    const response = await routeWorkerRequest(
      new Request(
        "https://syntila.app/api/desktop-auth/intents/intent-1/approve",
        {
          method: "POST",
          headers: {
            cookie: "better-auth-session=opaque",
            origin: "https://syntila.app",
            "content-type": "application/json",
          },
          body: "{}",
        },
      ),
      {} as Env,
      undefined,
      { handleApproveDesktopAuthIntent: approve },
      dependencies(sameOrigin),
    );

    expect(response.status).toBe(200);
    expect(approve).toHaveBeenCalledOnce();
    expect(sameOrigin).toHaveBeenCalledOnce();
  });

  it("routes poller cancellation without cookie same-origin requirements", async () => {
    const sameOrigin = vi.fn();
    const cancel = vi.fn(async () => Response.json({ cancelled: true }));
    const response = await routeWorkerRequest(
      new Request(
        "https://syntila.app/api/desktop-auth/intents/intent-1/cancel",
        {
          method: "POST",
          headers: {
            authorization: "Bearer poll-secret",
            "content-type": "application/json",
          },
          body: "{}",
        },
      ),
      {} as Env,
      undefined,
      { handleCancelDesktopAuthIntent: cancel },
      dependencies(sameOrigin),
    );

    expect(response.status).toBe(200);
    expect(cancel).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });
});
