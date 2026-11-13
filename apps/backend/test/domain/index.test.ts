import { describe, expect, it } from "./helpers/vitest-compat";
import worker, { routeHandlers } from "../../src/domain/index.js";

const identityDb = {
  prepare() {
    return {
      bind() {
        return this;
      },
      async first() {
        return null;
      },
      async all() {
        return { results: [] };
      },
      async run() {
        return { success: true };
      },
    };
  },
  async batch() {
    return [];
  },
};

const env = {
  SYNTILA_ENVIRONMENT: "development",
  TEST_AUTHENTICATION: async () => ({
    userId: "local-development",
    user: {
      id: "local-development",
      email: "local-development@local",
      displayName: "Developer",
      status: "active",
    },
    workspaceId: "local-development",
    spaceRoles: {},
    sessionId: "session-local-development",
    clientType: "desktop",
  }),
  SYNTILA_DB: identityDb,
} as unknown as Env;

describe("Worker smoke tests", () => {
  it("registers the Work history clear handler", () => {
    expect(typeof routeHandlers.handleClearWorkHistory).toBe("function");
  });

  it("registers authenticated Workspace ownership lifecycle handlers", () => {
    expect(typeof routeHandlers.handleCheckWorkspaceOwnership).toBe("function");
    expect(typeof routeHandlers.handleDisconnectDesktopWorkspace).toBe(
      "function",
    );
    expect(typeof routeHandlers.handleReleaseDesktopWorkspace).toBe("function");
  });

  it("returns a health response", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.test/health"),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      environment: "development",
    });
  });

  it("returns not found for unknown routes", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.test/unknown"),
      env,
    );

    expect(response.status).toBe(404);
  });

  it("serves the SPA asset for browser routes when static assets are bound", async () => {
    const requests: Request[] = [];
    const response = await worker.fetch(
      new Request(
        "https://syntila.test/desktop-auth/approve?intentId=intent-1",
      ),
      {
        ...env,
        ASSETS: {
          fetch: async (request: Request) => {
            requests.push(request);
            return new Response("flutter-index", {
              headers: { "content-type": "text/html" },
            });
          },
        },
      } as unknown as Env,
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("flutter-index");
    expect(requests[0]?.url).toBe(
      "https://syntila.test/desktop-auth/approve?intentId=intent-1",
    );
  });

  it("uses the development sign-in helper only for a real Better Auth flow", async () => {
    const response = await worker.fetch(
      new Request(
        "https://syntila.test/api/dev/sign-in?provider=google&returnTo=/spaces",
      ),
      env,
    );
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://syntila.test/api/auth/sign-in/google?returnTo=%2Fspaces",
    );

    const productionResponse = await worker.fetch(
      new Request("https://syntila.test/api/dev/sign-in"),
      {
        ...env,
        SYNTILA_ENVIRONMENT: "production",
        TEST_AUTHENTICATION: undefined,
      } as unknown as Env,
    );
    expect(productionResponse.status).toBe(404);
  });

  it.each(["github", "google"])(
    "keeps the %s OAuth entry point on the same-origin callback boundary",
    async (provider) => {
      const response = await worker.fetch(
        new Request(
          `https://syntila.test/api/dev/sign-in?provider=${provider}&returnTo=/account`,
        ),
        env,
      );
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe(
        `https://syntila.test/api/auth/sign-in/${provider}?returnTo=%2Faccount`,
      );
    },
  );

  it("fails closed when step-up completion has no passkey ceremony", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.test/api/auth/step-up/passkey/complete", {
        method: "POST",
        headers: { origin: "https://syntila.test" },
        body: "{}",
      }),
      env,
    );
    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({
      error: "No recent strong authentication ceremony is available",
    });
  });

  it("fails closed when production authentication is missing", async () => {
    const productionEnv = {
      ...env,
      SYNTILA_ENVIRONMENT: "production",
      TEST_AUTHENTICATION: undefined,
    } as unknown as Env;
    const response = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        method: "GET",
        headers: {
          "content-type": "application/json",
          "cf-access-authenticated-user-email": "operator@example.com",
          "cf-access-jwt-assertion": "ignored-by-application-auth",
        },
      }),
      productionEnv,
    );
    expect(response.status).toBe(401);
  });

  it("does not expose legacy run or CI evidence routes", async () => {
    const routes = [
      ["GET", "/api/runs/run-1"],
      ["POST", "/api/runs/run-1/events"],
      ["POST", "/api/runs/run-1/ci-evidence"],
    ] as const;
    for (const [method, path] of routes) {
      const response = await worker.fetch(
        new Request(`https://syntila.test${path}`, { method }),
        env,
      );
      expect(response.status, `${method} ${path}`).toBe(404);
    }
  });
});
