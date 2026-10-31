import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashToken } from "../../../packages/security/src/index.js";
import { identityService } from "../src/auth/index.js";
import * as authModule from "../src/auth/index.js";
import {
  handleApproveDesktopAuthIntent,
  handleClaimDesktopAuthIntent,
  handleCreateDesktopAuthIntent,
  handleDesktopPasswordSignIn,
  handleDesktopAuthIntentStatus,
  handleDesktopAuthIntentBrowserStatus,
  handleCancelDesktopAuthIntent,
  handleDenyDesktopAuthIntent,
  handleGetDesktopHumanSession,
  handleCheckWorkspaceOwnership,
  handleReconcileWorkspaceOwnership,
  handleDisconnectDesktopWorkspace,
  handleReleaseDesktopWorkspace,
  handleRegisterWorkspaceFromDesktop,
  handleRevokeDesktopHumanSession,
  handleRotateDesktopHumanSession,
  authorizeToolProfileAdmin,
} from "../src/routes/handlers.js";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations-v8/", import.meta.url),
);

class Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}
  bind(...values: unknown[]): Statement {
    return new Statement(this.db, this.sql, values);
  }
  async first<T>(): Promise<T | null> {
    return (
      (this.db.prepare(this.sql).get(...(this.values as SQLInputValue[])) as
        T | undefined) ?? null
    );
  }
  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }
  async run(): Promise<{ meta: { changes: number } }> {
    const result = this.db
      .prepare(this.sql)
      .run(...(this.values as SQLInputValue[]));
    return { meta: { changes: Number(result.changes) } };
  }
}
class TestD1 {
  constructor(readonly sqlite: DatabaseSync) {}
  prepare(sql: string): Statement {
    return new Statement(this.sqlite, sql);
  }
  async batch(statements: readonly Statement[]): Promise<unknown[]> {
    this.sqlite.exec("BEGIN");
    try {
      const results = [];
      for (const statement of statements) results.push(await statement.run());
      this.sqlite.exec("COMMIT");
      return results;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }
}

function seedWorkspaceInstallation(
  sqlite: DatabaseSync,
  installationId: string,
  ownerUserId: string,
  workspaceId: string,
  status: "active" | "released" = "active",
  now = new Date().toISOString(),
): void {
  sqlite
    .prepare(
      `INSERT INTO workspace_installations
        (installation_id, owner_user_id, workspace_id, status, created_at, updated_at, released_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      installationId,
      ownerUserId,
      workspaceId,
      status,
      now,
      now,
      status === "released" ? now : null,
    );
}

describe("desktop human authentication", () => {
  const databases: DatabaseSync[] = [];
  afterEach(() => {
    vi.restoreAllMocks();
    for (const database of databases.splice(0)) database.close();
  });

  async function setup() {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec("PRAGMA foreign_keys = ON");
    databases.push(sqlite);
    for (const filename of fs.readdirSync(migrationsDirectory).sort()) {
      if (filename.endsWith(".sql"))
        sqlite.exec(
          fs.readFileSync(path.join(migrationsDirectory, filename), "utf8"),
        );
    }
    const db = new TestD1(sqlite);
    const env = {
      SYNTILA_DB: db,
      SYNTILA_WORKSPACE_GATEWAY: {
        getByName: () => ({
          fetch: async () => Response.json({ online: false }),
        }),
      },
    } as never;
    vi.spyOn(identityService, "resolve").mockResolvedValue({
      userId: "human-1",
      email: "person@example.test",
      name: "Person",
      sessionId: "browser-session-1",
    });
    return { db, env, sqlite };
  }

  it("headless password login uses Better Auth and returns only a desktop session", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
      )
      .run("human-1", "person@example.test", "Person", now, now);
    const verifier = vi
      .spyOn(authModule, "handleBetterAuthRequest")
      .mockImplementation(async (request) => {
        if (new URL(request.url).pathname.endsWith("/sign-out"))
          return Response.json({ success: true });
        expect(new URL(request.url).pathname).toBe("/api/auth/sign-in/email");
        expect(request.headers.get("cookie")).toBeNull();
        expect(await request.json()).toEqual({
          email: "person@example.test",
          password: "private-password",
          rememberMe: false,
        });
        return Response.json(
          { user: { id: "human-1" } },
          {
            headers: {
              "Set-Cookie": "session=private-cookie; HttpOnly; Secure",
            },
          },
        );
      });
    const response = await handleDesktopPasswordSignIn(
      new Request("https://app.syntila.test/api/desktop-auth/password", {
        method: "POST",
        body: JSON.stringify({
          email: "person@example.test",
          password: "private-password",
        }),
      }),
      env,
    );
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const text = await response.text();
    expect(text).not.toContain("private-password");
    expect(text).not.toContain("private-cookie");
    const session = JSON.parse(text);
    expect(session.audience).toBe("syntila.desktop.management");
    expect(session.user.userId).toBe("human-1");
    expect(verifier).toHaveBeenCalledTimes(2);
    expect(
      sqlite.prepare("SELECT token_hash FROM desktop_human_sessions").get()
        ?.token_hash,
    ).toBe(await hashToken(session.credential));
  });

  it("headless password login rejects invalid passwords, rate limits and MFA", async () => {
    const { env } = await setup();
    const verifier = vi.spyOn(authModule, "handleBetterAuthRequest");
    const request = () =>
      new Request("https://app.syntila.test/api/desktop-auth/password", {
        method: "POST",
        body: JSON.stringify({
          email: "person@example.test",
          password: "private-password",
        }),
      });
    verifier.mockResolvedValue(
      Response.json({ error: "private-error" }, { status: 401 }),
    );
    await expect(handleDesktopPasswordSignIn(request(), env)).rejects.toThrow(
      "sign-in failed",
    );
    verifier.mockResolvedValue(Response.json({}, { status: 429 }));
    await expect(handleDesktopPasswordSignIn(request(), env)).rejects.toThrow(
      "Too many",
    );
    verifier.mockResolvedValue(Response.json({ twoFactorRedirect: true }));
    await expect(handleDesktopPasswordSignIn(request(), env)).rejects.toThrow(
      "additional verification",
    );
  });

  for (const [email, verified, allowed] of [
    ["vitalii@nohainc.com", 1, true],
    ["vitalii@nohainc.com", 0, true],
    ["someone@example.test", 1, false],
    ["someone@example.test", 0, false],
  ] as const) {
    it(`Profile Lab browser approval requires the configured owner: ${email}, verified=${verified}`, async () => {
      const { env: baseEnv, sqlite } = await setup();
      const env = Object.assign(baseEnv, {
        SYNTILA_PROFILE_LAB_OWNER_EMAIL: "vitalii@nohainc.com",
      });
      vi.mocked(identityService.resolve).mockResolvedValue({
        userId: "human-1",
        email,
        name: "Person",
        sessionId: "browser-session-1",
      });
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, status, created_at, updated_at, email_verified) VALUES (?, ?, ?, 'active', ?, ?, ?)",
        )
        .run(
          "human-1",
          email,
          "Person",
          new Date().toISOString(),
          new Date().toISOString(),
          verified,
        );
      const response = await handleCreateDesktopAuthIntent(
        new Request("https://app.syntila.test/api/desktop-auth/intents", {
          method: "POST",
          body: JSON.stringify({
            clientName: "Syntila Profile Lab",
            contractVersion: "1.1",
            audience: "syntila.profile-lab.management",
          }),
        }),
        env,
      );
      const intent = (await response.json()) as {
        intentId: string;
        pollToken: string;
      };
      const approve = () =>
        handleApproveDesktopAuthIntent(
          new Request("https://app.syntila.test/approve", { method: "POST" }),
          env,
          intent.intentId,
        );
      if (!allowed) {
        await expect(approve()).rejects.toMatchObject({ status: 403 });
        expect(
          sqlite
            .prepare(
              "SELECT approved_at FROM desktop_auth_intents WHERE id = ?",
            )
            .get(intent.intentId)?.approved_at,
        ).toBeNull();
      } else {
        expect((await approve()).status).toBe(200);
        const claimRequest = () =>
          new Request("https://app.syntila.test/claim", {
            method: "POST",
            body: JSON.stringify({ pollToken: intent.pollToken }),
          });
        const claimed = await handleClaimDesktopAuthIntent(
          claimRequest(),
          env,
          intent.intentId,
        );
        expect(claimed.status).toBe(200);
        const session = (await claimed.json()) as { credential: string };
        const sessionRequest = () =>
          new Request("https://app.syntila.test/api/desktop-auth/session", {
            headers: { authorization: `Bearer ${session.credential}` },
          });
        expect(
          (await handleGetDesktopHumanSession(sessionRequest(), env)).status,
        ).toBe(200);
        await authorizeToolProfileAdmin(sessionRequest(), env);
        sqlite
          .prepare(
            "UPDATE users SET email = 'someone@example.test' WHERE id = ?",
          )
          .run("human-1");
        await expect(
          handleGetDesktopHumanSession(sessionRequest(), env),
        ).rejects.toMatchObject({ status: 403 });
        await expect(
          authorizeToolProfileAdmin(sessionRequest(), env),
        ).rejects.toMatchObject({ status: 403 });
      }
    });
  }

  it("exchanges a browser-approved 1.1 intent without a comparison code for an independently revocable desktop session", async () => {
    const { env, sqlite } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    expect(create.status).toBe(201);
    const intent = (await create.json()) as {
      intentId: string;
      pollToken: string;
      verificationUrl: string;
    };
    expect(new URL(intent.verificationUrl).pathname).toBe(
      "/desktop-auth/approve",
    );
    const pending = await handleDesktopAuthIntentStatus(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${intent.intentId}`,
        {
          headers: { authorization: `Bearer ${intent.pollToken}` },
        },
      ),
      env,
      intent.intentId,
    );
    expect(((await pending.json()) as { status: string }).status).toBe(
      "pending",
    );

    const approval = await handleApproveDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/approve", {
        method: "POST",
        headers: {
          cookie: "better-auth-session=opaque",
          "content-type": "application/json",
        },
        body: JSON.stringify({}),
      }),
      env,
      intent.intentId,
    );
    expect(approval.status).toBe(200);

    const claim = await handleClaimDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/claim", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ pollToken: intent.pollToken }),
      }),
      env,
      intent.intentId,
    );
    const session = (await claim.json()) as {
      credential: string;
      sessionId: string;
      audience: string;
      user: { email: string };
    };
    expect(session.audience).toBe("syntila.desktop.management");
    expect(session.user.email).toBe("person@example.test");
    expect(session.credential).toMatch(/^syntila_dhs_/);
    const savedHash = sqlite
      .prepare("SELECT token_hash FROM desktop_human_sessions")
      .get() as { token_hash: string };
    expect(savedHash.token_hash).toBe(await hashToken(session.credential));

    const duplicateClaim = await handleClaimDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/claim", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ pollToken: intent.pollToken }),
      }),
      env,
      intent.intentId,
    ).then(
      () => null,
      (error: Error) => error,
    );
    expect(duplicateClaim?.message).toMatch(/already claimed/);

    const humanSession = await handleGetDesktopHumanSession(
      new Request("https://app.syntila.test/api/desktop-auth/session", {
        headers: { authorization: `Bearer ${session.credential}` },
      }),
      env,
    );
    expect(
      ((await humanSession.json()) as { user: { userId: string } }).user.userId,
    ).toBe("human-1");

    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.syntila.test/api/desktop-auth/session", {
          headers: { authorization: "Bearer syntila_workspace_tok_runtime" },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);

    const revoked = await handleRevokeDesktopHumanSession(
      new Request(
        `https://app.syntila.test/api/desktop-auth/sessions/${session.sessionId}/revoke`,
        {
          method: "POST",
          headers: { authorization: `Bearer ${session.credential}` },
        },
      ),
      env,
      session.sessionId,
    );
    expect(((await revoked.json()) as { revoked: boolean }).revoked).toBe(true);
    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.syntila.test/api/desktop-auth/session", {
          headers: { authorization: `Bearer ${session.credential}` },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);
  });

  it("a new sign-in on the same device revokes that device's earlier sessions", async () => {
    const { env, sqlite } = await setup();
    async function signIn(deviceId?: string) {
      const create = await handleCreateDesktopAuthIntent(
        new Request("https://app.syntila.test/api/desktop-auth/intents", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            clientName: "Syntila Workspace",
            contractVersion: "1.1",
          }),
        }),
        env,
      );
      const intent = (await create.json()) as {
        intentId: string;
        pollToken: string;
      };
      await handleApproveDesktopAuthIntent(
        new Request("https://app.syntila.test/api/desktop-auth/approve", {
          method: "POST",
          headers: {
            cookie: "better-auth-session=opaque",
            "content-type": "application/json",
          },
          body: JSON.stringify({}),
        }),
        env,
        intent.intentId,
      );
      const claim = await handleClaimDesktopAuthIntent(
        new Request("https://app.syntila.test/api/desktop-auth/claim", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ pollToken: intent.pollToken, deviceId }),
        }),
        env,
        intent.intentId,
      );
      return ((await claim.json()) as { sessionId: string }).sessionId;
    }
    const revoked = (id: string) =>
      (
        sqlite
          .prepare("SELECT revoked_at FROM desktop_human_sessions WHERE id = ?")
          .get(id) as { revoked_at: string | null }
      ).revoked_at;

    const legacy = await signIn();
    const first = await signIn("device-aaaaaaaa");
    const otherDevice = await signIn("device-bbbbbbbb");
    const second = await signIn("device-aaaaaaaa");

    expect(revoked(first)).not.toBeNull();
    expect(revoked(second)).toBeNull();
    expect(revoked(otherDevice)).toBeNull();
    expect(revoked(legacy)).toBeNull();
    await expect(signIn("bad id")).rejects.toThrow(/device identifier/);
  });

  it("uses the configured browser application origin for desktop approval", async () => {
    const { env } = await setup();
    (env as Record<string, unknown>).SYNTILA_APP_URL = "http://localhost:3000/";
    const response = await handleCreateDesktopAuthIntent(
      new Request("http://localhost:8787/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );

    expect(response.status).toBe(201);
    const body = (await response.json()) as { verificationUrl: string };
    expect(body.verificationUrl).toMatch(
      /^http:\/\/localhost:3000\/desktop-auth\/approve\?intentId=/,
    );
  });

  it("lets only the intent poll credential cancel and expose terminal browser status", async () => {
    const { env } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await create.json()) as {
      intentId: string;
      pollToken: string;
    };
    await expect(
      handleCancelDesktopAuthIntent(
        new Request("https://app.syntila.test/cancel", { method: "POST" }),
        env,
        intent.intentId,
      ),
    ).rejects.toThrow(/credential required/);

    const canceled = await handleCancelDesktopAuthIntent(
      new Request("https://app.syntila.test/cancel", {
        method: "POST",
        headers: { authorization: `Bearer ${intent.pollToken}` },
      }),
      env,
      intent.intentId,
    );
    expect(canceled.status).toBe(200);
    const status = await handleDesktopAuthIntentBrowserStatus(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${intent.intentId}/browser-status`,
      ),
      env,
      intent.intentId,
    );
    expect(((await status.json()) as { status: string }).status).toBe("denied");
  });

  it("allows an authenticated browser user to cancel a pending intent", async () => {
    const { env } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await create.json()) as { intentId: string };
    const response = await handleDenyDesktopAuthIntent(
      new Request("https://app.syntila.test/cancel", {
        method: "POST",
        headers: { cookie: "better-auth-session=opaque" },
      }),
      env,
      intent.intentId,
    );
    expect(response.status).toBe(200);
    const status = await handleDesktopAuthIntentBrowserStatus(
      new Request("https://app.syntila.test/status"),
      env,
      intent.intentId,
    );
    expect(((await status.json()) as { status: string }).status).toBe("denied");
  });

  it("keeps runtime credentials out of human management APIs", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, 'install_11111111-1111-4111-8111-111111111111', ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-only-secret"),
        now,
      );

    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.syntila.test/api/desktop-auth/session", {
          headers: { authorization: "Bearer runtime-only-secret" },
        }),
        env,
      ),
    ).rejects.toMatchObject({
      status: 401,
      message: "Desktop human session is invalid, expired, or revoked",
    });
  });

  it("allows ownership transition only after explicit release", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const accounts = [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ] as const;
    for (const [id, email] of accounts) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          `session-${id}`,
          id,
          await hashToken(`${id}-secret`),
          "syntila.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    }
    const registrationBody = {
      contractVersion: "1.0",
      installationId,
      proposedWorkspaceName: "Test computer",
      hostname: "test-computer",
      platform: "macos",
      architecture: "arm64",
      appVersion: "1.0.0",
      runtimeCapabilities: {
        os: "macos",
        arch: "arm64",
        appVersion: "1.0.0",
        supportedRuntimes: ["dart"],
        maxConcurrentWorkers: 2,
      },
    };
    const register = (userId: string, extra: Record<string, unknown> = {}) =>
      handleRegisterWorkspaceFromDesktop(
        new Request("https://app.syntila.test/api/workspace-runtime/register", {
          method: "POST",
          headers: {
            authorization: `Bearer ${userId}-secret`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ ...registrationBody, ...extra }),
        }),
        env,
      );
    const checkOwnership = (
      userId: string,
      workspaceId?: string,
      runtimeId?: string,
    ) =>
      handleCheckWorkspaceOwnership(
        new Request(
          "https://app.syntila.test/api/workspace-runtime/ownership",
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${userId}-secret`,
              "content-type": "application/json",
            },
            body: JSON.stringify({
              contractVersion: "1.0",
              installationId,
              ...(workspaceId ? { workspaceId } : {}),
              ...(runtimeId ? { runtimeId } : {}),
            }),
          },
        ),
        env,
      );

    const connected = await register("human-a");
    expect(connected.status).toBe(201);
    const firstRuntime = (await connected.json()) as {
      workspaceId: string;
      workspaceRuntimeId: string;
    };
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, workspace_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({
      owner_user_id: "human-a",
      workspace_id: firstRuntime.workspaceId,
      status: "active",
    });
    const initialOwnership = await checkOwnership(
      "human-a",
      firstRuntime.workspaceId,
      firstRuntime.workspaceRuntimeId,
    );
    expect(await initialOwnership.json()).toMatchObject({
      state: "owned_by_current_user",
      ownerMatchesCurrentSession: true,
      workspaceId: firstRuntime.workspaceId,
    });

    const disconnected = await handleDisconnectDesktopWorkspace(
      new Request("https://app.syntila.test/api/workspace-runtime/disconnect", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: firstRuntime.workspaceId,
          runtimeId: firstRuntime.workspaceRuntimeId,
        }),
      }),
      env,
    );
    expect(disconnected.status).toBe(200);
    expect(await disconnected.json()).toMatchObject({ disconnected: true });
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, workspace_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({
      owner_user_id: "human-a",
      workspace_id: firstRuntime.workspaceId,
      status: "active",
    });
    const sameOwnerAfterDisconnect = await checkOwnership(
      "human-a",
      firstRuntime.workspaceId,
      firstRuntime.workspaceRuntimeId,
    );
    expect(await sameOwnerAfterDisconnect.json()).toMatchObject({
      state: "local_registration_stale",
      ownerMatchesCurrentSession: true,
      workspaceId: firstRuntime.workspaceId,
      runtimeState: "offline",
    });
    const otherOwnerAfterDisconnect = await checkOwnership("human-b");
    expect(await otherOwnerAfterDisconnect.json()).toEqual({
      state: "owned_by_other_user",
    });

    const recovered = await register("human-a");
    expect(recovered.status).toBe(201);
    const recoveredRuntime = (await recovered.json()) as {
      outcome: string;
      workspaceId: string;
      workspaceRuntimeId: string;
    };
    expect(recoveredRuntime).toMatchObject({
      outcome: "recovered",
      workspaceId: firstRuntime.workspaceId,
    });
    const reconnectedOwnership = await checkOwnership(
      "human-a",
      recoveredRuntime.workspaceId,
      recoveredRuntime.workspaceRuntimeId,
    );
    expect(await reconnectedOwnership.json()).toMatchObject({
      state: "owned_by_current_user",
      ownerMatchesCurrentSession: true,
      workspaceId: firstRuntime.workspaceId,
    });

    const accountSwitchDenied = await register("human-b");
    expect(accountSwitchDenied.status).toBe(409);
    expect(await accountSwitchDenied.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });

    const released = await handleReleaseDesktopWorkspace(
      new Request("https://app.syntila.test/api/workspace-runtime/release", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: recoveredRuntime.workspaceId,
          runtimeId: recoveredRuntime.workspaceRuntimeId,
        }),
      }),
      env,
    );
    expect(released.status).toBe(200);
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, workspace_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({
      owner_user_id: "human-a",
      workspace_id: firstRuntime.workspaceId,
      status: "released",
    });
    const otherOwnerAfterRelease = await checkOwnership("human-b");
    expect(await otherOwnerAfterRelease.json()).toEqual({ state: "released" });
    const transferred = await register("human-b");
    expect(transferred.status).toBe(201);
    expect(await transferred.json()).toMatchObject({
      outcome: "created",
      ownerUserId: "human-b",
    });
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ owner_user_id: "human-b", status: "active" });
  });

  it("matches the Workspace ownership-state acceptance matrix", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const users = [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ] as const;
    for (const [id, email] of users) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
    }
    const addSession = async (
      userId: string,
      credential: string,
      sessionId = `session-${userId}`,
    ) =>
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          sessionId,
          userId,
          await hashToken(credential),
          "syntila.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    await addSession("human-a", "human-a-secret");
    await addSession("human-b", "human-b-secret");

    const registrationBody = (installationId: string) => ({
      contractVersion: "1.0",
      installationId,
      proposedWorkspaceName: "Acceptance Mac",
      hostname: "acceptance-mac",
      platform: "macos",
      architecture: "arm64",
      appVersion: "1.0.0",
      runtimeCapabilities: {
        os: "macos",
        arch: "arm64",
        appVersion: "1.0.0",
        supportedRuntimes: ["dart"],
        maxConcurrentWorkers: 2,
      },
    });
    const register = (userId: string, installationId: string) =>
      handleRegisterWorkspaceFromDesktop(
        new Request("https://app.syntila.test/api/workspace-runtime/register", {
          method: "POST",
          headers: {
            authorization: `Bearer ${userId}-secret`,
            "content-type": "application/json",
          },
          body: JSON.stringify(registrationBody(installationId)),
        }),
        env,
      );
    const checked = (
      userId: string,
      installationId: string,
      workspaceId?: string,
      runtimeId?: string,
    ) =>
      handleCheckWorkspaceOwnership(
        new Request(
          "https://app.syntila.test/api/workspace-runtime/ownership",
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${userId}-secret`,
              "content-type": "application/json",
            },
            body: JSON.stringify({
              contractVersion: "1.0",
              installationId,
              ...(workspaceId ? { workspaceId } : {}),
              ...(runtimeId ? { runtimeId } : {}),
            }),
          },
        ),
        env,
      );
    const disconnect = (
      installationId: string,
      workspaceId: string,
      runtimeId: string,
    ) =>
      handleDisconnectDesktopWorkspace(
        new Request(
          "https://app.syntila.test/api/workspace-runtime/disconnect",
          {
            method: "POST",
            headers: {
              authorization: "Bearer human-a-secret",
              "content-type": "application/json",
            },
            body: JSON.stringify({ installationId, workspaceId, runtimeId }),
          },
        ),
        env,
      );
    const release = (
      installationId: string,
      workspaceId: string,
      runtimeId: string,
    ) =>
      handleReleaseDesktopWorkspace(
        new Request("https://app.syntila.test/api/workspace-runtime/release", {
          method: "POST",
          headers: {
            authorization: "Bearer human-a-secret",
            "content-type": "application/json",
          },
          body: JSON.stringify({ installationId, workspaceId, runtimeId }),
        }),
        env,
      );
    const requireRegistration = async (
      response: Response,
      expectedOutcome: string,
      expectedOwner: string,
    ) => {
      expect(response.status).toBe(201);
      const value = (await response.json()) as {
        outcome: string;
        workspaceId: string;
        workspaceRuntimeId: string;
        ownerUserId: string;
      };
      expect(value).toMatchObject({
        outcome: expectedOutcome,
        ownerUserId: expectedOwner,
      });
      return value;
    };

    const sameOwnerInstall = `install_${crypto.randomUUID()}`;
    const created = await requireRegistration(
      await register("human-a", sameOwnerInstall),
      "created",
      "human-a",
    );
    const existingSameOwner = await requireRegistration(
      await register("human-a", sameOwnerInstall),
      "recovered",
      "human-a",
    );
    expect(existingSameOwner.workspaceId).toBe(created.workspaceId);
    expect(
      sqlite
        .prepare(
          "SELECT revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get(created.workspaceRuntimeId),
    ).toMatchObject({ revoked_at: expect.any(String) });

    const staleRuntimeOwnership = await checked(
      "human-a",
      sameOwnerInstall,
      existingSameOwner.workspaceId,
      "runtime-missing-from-cloud",
    );
    expect(await staleRuntimeOwnership.json()).toMatchObject({
      state: "local_registration_stale",
      workspaceId: existingSameOwner.workspaceId,
      workspaceRuntimeId: existingSameOwner.workspaceRuntimeId,
      ownerMatchesCurrentSession: true,
    });
    const recoveredStaleRuntime = await requireRegistration(
      await register("human-a", sameOwnerInstall),
      "recovered",
      "human-a",
    );
    expect(recoveredStaleRuntime.workspaceId).toBe(created.workspaceId);
    const currentOwnerWithRevokedHistory = await checked(
      "human-a",
      sameOwnerInstall,
      recoveredStaleRuntime.workspaceId,
      recoveredStaleRuntime.workspaceRuntimeId,
    );
    expect(await currentOwnerWithRevokedHistory.json()).toMatchObject({
      state: "owned_by_current_user",
      ownerMatchesCurrentSession: true,
      workspaceId: created.workspaceId,
      workspaceRuntimeId: recoveredStaleRuntime.workspaceRuntimeId,
    });
    const revokedRuntimeCount = sqlite
      .prepare(
        `SELECT COUNT(*) AS count FROM workspace_runtime_identities
          WHERE workspace_id = ? AND revoked_at IS NOT NULL`,
      )
      .get(created.workspaceId) as { count: number };
    expect(revokedRuntimeCount.count).toBeGreaterThan(0);

    const activeForeignState = await checked("human-b", sameOwnerInstall);
    expect(await activeForeignState.json()).toEqual({
      state: "owned_by_other_user",
    });
    const activeForeignRegistration = await register(
      "human-b",
      sameOwnerInstall,
    );
    expect(activeForeignRegistration.status).toBe(409);
    expect(await activeForeignRegistration.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });

    const disconnectedInstall = `install_${crypto.randomUUID()}`;
    const disconnectedInitial = await requireRegistration(
      await register("human-a", disconnectedInstall),
      "created",
      "human-a",
    );
    const disconnectResponse = await disconnect(
      disconnectedInstall,
      disconnectedInitial.workspaceId,
      disconnectedInitial.workspaceRuntimeId,
    );
    expect(disconnectResponse.status).toBe(200);
    const disconnectedOwnerState = await checked(
      "human-a",
      disconnectedInstall,
      disconnectedInitial.workspaceId,
      disconnectedInitial.workspaceRuntimeId,
    );
    expect(await disconnectedOwnerState.json()).toMatchObject({
      state: "local_registration_stale",
      ownerMatchesCurrentSession: true,
      runtimeState: "offline",
    });
    const disconnectedForeignState = await checked(
      "human-b",
      disconnectedInstall,
    );
    expect(await disconnectedForeignState.json()).toEqual({
      state: "owned_by_other_user",
    });
    const disconnectedForeignRegistration = await register(
      "human-b",
      disconnectedInstall,
    );
    expect(disconnectedForeignRegistration.status).toBe(409);
    expect(await disconnectedForeignRegistration.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });
    const reconnected = await requireRegistration(
      await register("human-a", disconnectedInstall),
      "recovered",
      "human-a",
    );
    expect(reconnected.workspaceId).toBe(disconnectedInitial.workspaceId);

    const releasedInstall = `install_${crypto.randomUUID()}`;
    const releasedInitial = await requireRegistration(
      await register("human-a", releasedInstall),
      "created",
      "human-a",
    );
    expect(
      (
        await disconnect(
          releasedInstall,
          releasedInitial.workspaceId,
          releasedInitial.workspaceRuntimeId,
        )
      ).status,
    ).toBe(200);
    expect(
      (
        await release(
          releasedInstall,
          releasedInitial.workspaceId,
          releasedInitial.workspaceRuntimeId,
        )
      ).status,
    ).toBe(200);
    expect(await (await checked("human-b", releasedInstall)).json()).toEqual({
      state: "released",
    });
    const claimedAfterRelease = await requireRegistration(
      await register("human-b", releasedInstall),
      "created",
      "human-b",
    );
    expect(claimedAfterRelease.workspaceId).not.toBe(
      releasedInitial.workspaceId,
    );

    const missingLocalInstall = `install_${crypto.randomUUID()}`;
    const cloudOwner = await requireRegistration(
      await register("human-a", missingLocalInstall),
      "created",
      "human-a",
    );
    const missingLocalWorkspace = await checked(
      "human-a",
      missingLocalInstall,
      "workspace-no-longer-present",
      "runtime-no-longer-present",
    );
    expect(await missingLocalWorkspace.json()).toMatchObject({
      state: "local_registration_stale",
      workspaceId: cloudOwner.workspaceId,
      workspaceRuntimeId: cloudOwner.workspaceRuntimeId,
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
    });
    const recoveredMissingLocalWorkspace = await requireRegistration(
      await register("human-a", missingLocalInstall),
      "recovered",
      "human-a",
    );
    expect(recoveredMissingLocalWorkspace.workspaceId).toBe(
      cloudOwner.workspaceId,
    );

    const ambiguousInstall = `install_${crypto.randomUUID()}`;
    const ambiguousInitial = await requireRegistration(
      await register("human-a", ambiguousInstall),
      "created",
      "human-a",
    );
    sqlite.exec("DROP INDEX idx_runtime_installation_active");
    sqlite.exec("DROP INDEX idx_workspace_runtime_identities_active_workspace");
    sqlite
      .prepare(
        `INSERT INTO workspace_runtime_identities
          (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, NULL)`,
      )
      .run(
        "runtime-ambiguous-active",
        ambiguousInitial.workspaceId,
        await hashToken("runtime-ambiguous-secret"),
        ambiguousInstall,
        new Date(Date.now() + 1).toISOString(),
      );
    const corruptOwnerState = await checked("human-a", ambiguousInstall);
    expect(await corruptOwnerState.json()).toEqual({
      state: "corrupt_or_ambiguous",
    });
    const corruptOwnerRegistration = await register(
      "human-a",
      ambiguousInstall,
    );
    expect(corruptOwnerRegistration.status).toBe(409);
    const corruptOwnerError = (await corruptOwnerRegistration.json()) as {
      code: string;
    };
    expect(corruptOwnerError.code).toBe("installation_binding_ambiguous");
    expect(corruptOwnerError.code).not.toBe("workspace_owned_by_other_account");
  });

  it("returns precise registration errors for ambiguous bindings and revoked Workspaces", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-b", "b@example.test", "B", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    const registration = (name = "A's Workspace") =>
      handleRegisterWorkspaceFromDesktop(
        new Request("https://app.syntila.test/api/workspace-runtime/register", {
          method: "POST",
          headers: {
            authorization: "Bearer human-a-secret",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            contractVersion: "1.0",
            installationId,
            proposedWorkspaceName: name,
            hostname: "a-machine",
            platform: "macos",
            architecture: "arm64",
            appVersion: "1.0.0",
            runtimeCapabilities: {
              os: "macos",
              arch: "arm64",
              appVersion: "1.0.0",
              supportedRuntimes: ["dart"],
              maxConcurrentWorkers: 2,
            },
          }),
        }),
        env,
      );
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "Workspace A", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-old",
        "workspace-a",
        await hashToken("secret-a"),
        installationId,
        now,
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "active",
      now,
    );

    const recovered = await registration();
    expect(recovered.status).toBe(201);
    expect(await recovered.json()).toMatchObject({
      outcome: "recovered",
      workspaceId: "workspace-a",
    });

    sqlite
      .prepare(
        "UPDATE execution_workspaces SET status = 'revoked' WHERE id = ?",
      )
      .run("workspace-a");
    const revoked = await registration();
    expect(revoked.status).toBe(409);
    expect(await revoked.json()).toMatchObject({ code: "release_required" });
  });

  it("uses released current ownership instead of foreign runtime history during registration", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    for (const [id, email] of [
      ["former-owner", "former@example.test"],
      ["current-owner", "current@example.test"],
    ] as const) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
    }
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-current-owner",
        "current-owner",
        await hashToken("current-owner-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'revoked', ?, ?)",
      )
      .run("former-workspace", "former-owner", "Former Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_installations (installation_id, owner_user_id, workspace_id, status, created_at, updated_at, released_at) VALUES (?, ?, ?, 'released', ?, ?, ?)",
      )
      .run(installationId, "former-owner", "former-workspace", now, now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "former-runtime",
        "former-workspace",
        await hashToken("former-runtime-secret"),
        installationId,
        now,
        now,
      );

    const response = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: "Bearer current-owner-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          proposedWorkspaceName: "Current Owner's Workspace",
          hostname: "current-machine",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );

    expect(response.status).toBe(201);
    const registration = (await response.json()) as {
      outcome: string;
      ownerUserId: string;
      workspaceId: string;
    };
    expect(registration).toMatchObject({
      outcome: "created",
      ownerUserId: "current-owner",
    });
    expect(registration.workspaceId).not.toBe("former-workspace");
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, workspace_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({
      owner_user_id: "current-owner",
      workspace_id: registration.workspaceId,
      status: "active",
    });
    expect(
      sqlite
        .prepare(
          `SELECT wi.owner_user_id AS currentOwner, old.owner_user_id AS historicalOwner
             FROM workspace_installations wi
             JOIN workspace_runtime_identities i ON i.installation_id = wi.installation_id
             JOIN execution_workspaces old ON old.id = i.workspace_id
            WHERE wi.installation_id = ? AND i.id = 'former-runtime'`,
        )
        .get(installationId),
    ).toMatchObject({
      currentOwner: "current-owner",
      historicalOwner: "former-owner",
    });
  });

  it("distinguishes a missing runtime from mismatched local identity on lifecycle operations", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const otherInstallationId = "install_abcdefab-cdef-4abc-8def-abcdefabcdef";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    const lifecycleRequest = (
      path: "disconnect" | "release",
      requestInstallationId: string,
      runtimeId: string,
    ) =>
      new Request(`https://app.syntila.test/api/workspace-runtime/${path}`, {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId: requestInstallationId,
          workspaceId: "workspace-a",
          runtimeId,
        }),
      });

    const identityMismatch = await handleDisconnectDesktopWorkspace(
      lifecycleRequest("disconnect", otherInstallationId, "runtime-a"),
      env,
    );
    expect(identityMismatch.status).toBe(409);
    expect(await identityMismatch.json()).toMatchObject({
      code: "workspace_identity_mismatch",
    });

    const missingRuntime = await handleReleaseDesktopWorkspace(
      lifecycleRequest("release", installationId, "runtime-missing"),
      env,
    );
    expect(missingRuntime.status).toBe(404);
    expect(await missingRuntime.json()).toMatchObject({
      code: "workspace_runtime_missing",
    });
  });

  it("hashes the short-lived poll token at rest", async () => {
    const { env, sqlite } = await setup();
    const response = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await response.json()) as {
      intentId: string;
      pollToken: string;
    };
    const stored = sqlite
      .prepare("SELECT poll_token_hash FROM desktop_auth_intents WHERE id = ?")
      .get(intent.intentId) as {
      poll_token_hash: string;
    };
    expect(stored.poll_token_hash).toBe(await hashToken(intent.pollToken));
    expect(stored.poll_token_hash).not.toBe(intent.pollToken);
  });

  it("does not let another signed-in User claim an owned installation", async () => {
    const { env, sqlite } = await setup();
    const humanCredential = "syntila_dhs_user-b";
    const runtimeCredential = "syntila_workspace_tok_user-a";
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-b", "b@example.test", "B", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken(runtimeCredential),
        installationId,
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "active",
      now,
    );
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-b",
        "human-b",
        await hashToken(humanCredential),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          proposedWorkspaceName: "B's computer",
          hostname: "b-computer",
          platform: "linux",
          architecture: "x64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "linux",
            arch: "x64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) AS count FROM workspace_runtime_identities WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ count: 1 });
  });

  it("blocks a different owner and preserves an existing runtime installation binding", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const testUsers: Array<[string, string]> = [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ];
    for (const [id, email] of testUsers) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
    }
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a-history",
        "workspace-a",
        await hashToken("old-runtime-secret"),
        installationId,
        new Date(Date.now() - 1000).toISOString(),
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "active",
      now,
    );
    const addSession = async (
      id: string,
      userId: string,
      credential: string,
    ) => {
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          id,
          userId,
          await hashToken(credential),
          "syntila.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    };
    await addSession("session-b", "human-b", "human-b-secret");
    await addSession("session-a", "human-a", "human-a-secret");
    const request = (credential: string) =>
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: `Bearer ${credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      });

    const denied = await handleCheckWorkspaceOwnership(
      request("human-b-secret"),
      env,
    );
    expect(denied.status).toBe(200);
    expect(await denied.json()).toEqual({ state: "owned_by_other_user" });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId });

    const connectDenied = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: "Bearer human-b-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          proposedWorkspaceName: "B's computer",
          hostname: "b-computer",
          platform: "linux",
          architecture: "x64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "linux",
            arch: "x64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );
    expect(connectDenied.status).toBe(409);
    expect(await connectDenied.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM workspace_runtime_identities")
        .get(),
    ).toMatchObject({ count: 2 });
    expect(
      sqlite
        .prepare(
          "SELECT credential_token_hash AS tokenHash FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ tokenHash: await hashToken("runtime-secret") });

    const verified = await handleCheckWorkspaceOwnership(
      request("human-a-secret"),
      env,
    );
    expect(verified.status).toBe(200);
    expect(await verified.json()).toMatchObject({
      state: "owned_by_current_user",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
      runtimeState: "offline",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId });

    const mismatchedInstallation = await handleCheckWorkspaceOwnership(
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_abcdefab-cdef-4abc-8def-abcdefabcdef",
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      }),
      env,
    );
    expect(mismatchedInstallation.status).toBe(200);
    expect(await mismatchedInstallation.json()).toMatchObject({
      state: "installation_conflict",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerMatchesCurrentSession: true,
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId });

    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-other", "human-a", "Other Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-other",
        "workspace-other",
        await hashToken("other-runtime-secret"),
        "install_abcdefab-cdef-4abc-8def-abcdefabcdef",
        now,
      );
    sqlite
      .prepare("UPDATE execution_workspaces SET owner_user_id = ? WHERE id = ?")
      .run("human-b", "workspace-other");
    const mismatchedWorkspace = await handleCheckWorkspaceOwnership(
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "workspace-other",
          runtimeId: "runtime-other",
        }),
      }),
      env,
    );
    expect(mismatchedWorkspace.status).toBe(200);
    expect(await mismatchedWorkspace.json()).toMatchObject({
      state: "local_registration_stale",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-other"),
    ).toMatchObject({
      installation_id: "install_abcdefab-cdef-4abc-8def-abcdefabcdef",
    });

    const staleLocalRegistration = await handleCheckWorkspaceOwnership(
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "stale-workspace",
          runtimeId: "stale-runtime",
        }),
      }),
      env,
    );
    expect(await staleLocalRegistration.json()).toMatchObject({
      state: "local_registration_stale",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerMatchesCurrentSession: true,
    });

    sqlite
      .prepare(
        "UPDATE workspace_runtime_identities SET revoked_at = ? WHERE id = ?",
      )
      .run(now, "runtime-a");
    const staleRegistrationWithoutRuntime = await handleCheckWorkspaceOwnership(
      request("human-a-secret"),
      env,
    );
    const staleRegistrationBody =
      (await staleRegistrationWithoutRuntime.json()) as Record<string, unknown>;
    expect(staleRegistrationBody).toMatchObject({
      state: "local_registration_stale",
      workspaceId: "workspace-a",
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
      runtimeState: "offline",
    });
    expect(staleRegistrationBody.workspaceRuntimeId).toBeUndefined();
    sqlite
      .prepare(
        "UPDATE workspace_runtime_identities SET revoked_at = NULL WHERE id = ?",
      )
      .run("runtime-a");

    const canonicalWithoutLocalIds = await handleCheckWorkspaceOwnership(
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({ contractVersion: "1.0", installationId }),
      }),
      env,
    );
    expect(await canonicalWithoutLocalIds.json()).toMatchObject({
      state: "owned_by_current_user",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerMatchesCurrentSession: true,
    });

    // Simulate corrupted data that the production partial unique index blocks.
    sqlite.exec("DROP INDEX idx_runtime_installation_active");
    sqlite.exec("DROP INDEX idx_workspace_runtime_identities_active_workspace");
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-duplicate",
        "workspace-a",
        await hashToken("duplicate-runtime-secret"),
        installationId,
        now,
      );
    const ambiguous = await handleCheckWorkspaceOwnership(
      request("human-a-secret"),
      env,
    );
    expect(await ambiguous.json()).toEqual({
      state: "corrupt_or_ambiguous",
    });
  });

  it("distinguishes unbound and released installations without exposing owner data", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    const request = () =>
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({ contractVersion: "1.0", installationId }),
      });

    const unbound = await handleCheckWorkspaceOwnership(request(), env);
    expect(await unbound.json()).toEqual({
      state: "unbound",
      ownerUserId: "human-a",
    });

    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'revoked', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?, ?, ?, NULL, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        now,
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "released",
      now,
    );
    sqlite
      .prepare(
        "INSERT INTO workspace_audit_log (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?, ?, 'user', ?, 'workspace.ownership.released', 'workspace_runtime', ?, ?, ?)",
      )
      .run(
        "audit-release",
        "workspace-a",
        "human-a",
        "runtime-a",
        JSON.stringify({ installationId }),
        now,
      );
    const releasedWithLocalIds = await handleCheckWorkspaceOwnership(
      new Request("https://app.syntila.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      }),
      env,
    );
    expect(await releasedWithLocalIds.json()).toMatchObject({
      state: "released",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerMatchesCurrentSession: true,
      runtimeState: "revoked",
    });

    const releasedWithoutLocalIds = await handleCheckWorkspaceOwnership(
      request(),
      env,
    );
    expect(await releasedWithoutLocalIds.json()).toMatchObject({
      state: "released",
      workspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
      runtimeState: "revoked",
    });
  });

  it("reconciles only a fresh same-owner legacy binding and audits the repair", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?, ?, ?, NULL, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        now,
        now,
      );
    sqlite
      .prepare(
        "INSERT INTO workspace_audit_log (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?, ?, 'user', ?, 'workspace.registered', 'workspace_runtime', ?, ?, ?)",
      )
      .run(
        "audit-register",
        "workspace-a",
        "human-a",
        "runtime-a",
        JSON.stringify({ installationId }),
        now,
      );
    const reconcile = () =>
      handleReconcileWorkspaceOwnership(
        new Request(
          "https://app.syntila.test/api/workspace-runtime/ownership/reconcile",
          {
            method: "POST",
            headers: {
              authorization: "Bearer human-a-secret",
              "content-type": "application/json",
            },
            body: JSON.stringify({
              contractVersion: "1.0",
              installationId,
              workspaceId: "workspace-a",
              runtimeId: "runtime-a",
            }),
          },
        ),
        env,
      );

    const result = await reconcile();
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({
      state: "local_registration_stale",
      workspaceId: "workspace-a",
      ownerUserId: "human-a",
      ownerMatchesCurrentSession: true,
    });
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id, workspace_id, status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toEqual({
      owner_user_id: "human-a",
      workspace_id: "workspace-a",
      status: "active",
    });
    expect(
      sqlite
        .prepare(
          "SELECT actor_id, action, target_id, details_json FROM workspace_audit_log WHERE action = 'workspace.ownership.reconciled'",
        )
        .get(),
    ).toMatchObject({
      actor_id: "human-a",
      action: "workspace.ownership.reconciled",
      target_id: installationId,
      details_json: JSON.stringify({
        source: "legacy_runtime_identity",
        runtimeId: "runtime-a",
      }),
    });
  });

  it("does not reconcile stale sessions or an active foreign owner", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    for (const [id, email] of [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ] as const) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
    }
    const staleCreatedAt = new Date(Date.now() - 10 * 60_000).toISOString();
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        staleCreatedAt,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-b", "human-b", "B's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-b",
        "workspace-b",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    const request = () =>
      new Request(
        "https://app.syntila.test/api/workspace-runtime/ownership/reconcile",
        {
          method: "POST",
          headers: {
            authorization: "Bearer human-a-secret",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            contractVersion: "1.0",
            installationId,
            workspaceId: "workspace-b",
            runtimeId: "runtime-b",
          }),
        },
      );
    const result = await handleReconcileWorkspaceOwnership(request(), env);
    expect(result.status).toBe(403);
    expect(await result.json()).toMatchObject({ code: "fresh_auth_required" });

    sqlite
      .prepare("UPDATE desktop_human_sessions SET created_at = ? WHERE id = ?")
      .run(now, "session-a");
    const legacyForeignResult = await handleReconcileWorkspaceOwnership(
      request(),
      env,
    );
    expect(legacyForeignResult.status).toBe(200);
    expect(await legacyForeignResult.json()).toEqual({
      state: "owned_by_other_user",
    });
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-b",
      "workspace-b",
      "active",
      now,
    );
    const freshResult = await handleReconcileWorkspaceOwnership(request(), env);
    expect(freshResult.status).toBe(200);
    expect(await freshResult.json()).toEqual({ state: "owned_by_other_user" });
    expect(
      sqlite
        .prepare(
          "SELECT owner_user_id FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ owner_user_id: "human-b" });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) AS count FROM workspace_audit_log WHERE action = 'workspace.ownership.reconciled'",
        )
        .get(),
    ).toMatchObject({ count: 0 });
  });

  it("allows only a fresh Workspace owner session to release the installation binding", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-b", "b@example.test", "B", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "active",
      now,
    );
    const addSession = async (
      id: string,
      userId: string,
      credential: string,
    ) => {
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          id,
          userId,
          await hashToken(credential),
          "syntila.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    };
    await addSession("session-a", "human-a", "human-a-secret");
    await addSession("session-b", "human-b", "human-b-secret");
    const request = (credential: string) =>
      new Request("https://app.syntila.test/api/workspace-runtime/release", {
        method: "POST",
        headers: {
          authorization: `Bearer ${credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      });

    const denied = await handleReleaseDesktopWorkspace(
      request("human-b-secret"),
      env,
    );
    expect(denied.status).toBe(409);
    expect(await denied.json()).toMatchObject({
      code: "workspace_owned_by_other_account",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId, revoked_at: null });

    sqlite.exec("PRAGMA foreign_keys = OFF");
    sqlite
      .prepare(
        "INSERT INTO worker_assignments (id, space_id, execution_workspace_id, runtime_identity_id, worker_type_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'running', ?, ?)",
      )
      .run(
        "assignment-active",
        "space-x",
        "workspace-a",
        "runtime-a",
        "worker-x",
        now,
        now,
      );
    const activeWorkDenied = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(activeWorkDenied.status).toBe(409);
    expect(await activeWorkDenied.json()).toMatchObject({
      code: "active_work",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId, revoked_at: null });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "offline" });
    sqlite
      .prepare("DELETE FROM worker_assignments WHERE id = ?")
      .run("assignment-active");

    sqlite
      .prepare("UPDATE execution_workspaces SET status = 'online' WHERE id = ?")
      .run("workspace-a");
    const connectedReleaseDenied = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(connectedReleaseDenied.status).toBe(409);
    expect(await connectedReleaseDenied.json()).toMatchObject({
      code: "runtime_connected",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId });
    sqlite
      .prepare(
        "UPDATE execution_workspaces SET status = 'offline' WHERE id = ?",
      )
      .run("workspace-a");

    const released = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(released.status).toBe(200);
    expect(await released.json()).toMatchObject({
      released: true,
      installationId,
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: null });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "revoked" });
    expect(
      sqlite
        .prepare(
          "SELECT status, released_at FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ status: "released", released_at: expect.any(String) });
  });

  it("disconnects through the owner human session and retains installation ownership", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'online', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    seedWorkspaceInstallation(
      sqlite,
      installationId,
      "human-a",
      "workspace-a",
      "active",
      now,
    );
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    const gatewayFetch = vi.fn(async (request: RequestInfo | URL) => {
      const requestUrl =
        request instanceof Request ? request.url : String(request);
      expect(new URL(requestUrl).pathname).toBe("/disconnect-runtime");
      return Response.json({ disconnected: true });
    });
    (
      env as unknown as { SYNTILA_WORKSPACE_GATEWAY: unknown }
    ).SYNTILA_WORKSPACE_GATEWAY = {
      getByName: () => ({ fetch: gatewayFetch }),
    };
    const response = await handleDisconnectDesktopWorkspace(
      new Request("https://app.syntila.test/api/workspace-runtime/disconnect", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      }),
      env,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      disconnected: true,
      gatewayDisconnected: true,
    });
    expect(gatewayFetch).toHaveBeenCalledOnce();
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({
      installation_id: installationId,
      revoked_at: expect.any(String),
    });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "offline" });
    expect(
      sqlite
        .prepare(
          "SELECT status FROM workspace_installations WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ status: "active" });
    expect(
      sqlite
        .prepare(
          "SELECT action FROM workspace_audit_log WHERE workspace_id = ?",
        )
        .get("workspace-a"),
    ).toMatchObject({ action: "workspace.disconnected" });
  });

  it("rotates a valid desktop session without changing its owner or session ID", async () => {
    const { env, sqlite } = await setup();
    const oldCredential = "syntila_dhs_before_rotation";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken(oldCredential),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRotateDesktopHumanSession(
      new Request(
        "https://app.syntila.test/api/desktop-auth/sessions/session-a/rotate",
        {
          method: "POST",
          headers: { authorization: `Bearer ${oldCredential}` },
        },
      ),
      env,
      "session-a",
    );
    expect(response.status).toBe(200);
    const rotated = (await response.json()) as {
      credential: string;
      sessionId: string;
      audience: string;
      user: { userId: string };
      expiresAt: string;
    };
    expect(rotated.credential).not.toBe(oldCredential);
    expect(rotated.sessionId).toBe("session-a");
    expect(rotated.audience).toBe("syntila.desktop.management");
    expect(rotated.user.userId).toBe("human-a");
    expect(Date.parse(rotated.expiresAt)).toBeGreaterThan(Date.now());
    expect(
      sqlite
        .prepare("SELECT token_hash FROM desktop_human_sessions WHERE id = ?")
        .get("session-a"),
    ).toMatchObject({ token_hash: await hashToken(rotated.credential) });
    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.syntila.test/api/desktop-auth/session", {
          headers: { authorization: `Bearer ${oldCredential}` },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);
  });

  it("returns the authenticated owner with a new Workspace registration", async () => {
    const { env, sqlite } = await setup();
    const humanCredential = "syntila_dhs_user-a";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken(humanCredential),
        "syntila.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          proposedWorkspaceName: "A's computer",
          hostname: "a-computer",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      outcome: "created",
      ownerUserId: "human-a",
      workspaceName: "A's computer",
    });

    const updateResponse = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          proposedWorkspaceName: "Updated Workspace Name",
          hostname: "a-computer",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );

    expect(updateResponse.status).toBe(201);
    expect(await updateResponse.json()).toMatchObject({
      outcome: "recovered",
      ownerUserId: "human-a",
      workspaceName: "Updated Workspace Name",
    });

    const workspaceRecord = sqlite
      .prepare("SELECT name FROM execution_workspaces LIMIT 1")
      .get() as { name: string };
    expect(workspaceRecord.name).toBe("Updated Workspace Name");
  });

  it("authenticates Profile Lab with dedicated audience and enforces mutual exclusion with Workspace operations", async () => {
    const { env } = await setup();
    // Configure Profile admin user
    (env as Record<string, unknown>).SYNTILA_PROFILE_ADMIN_USER_IDS = "human-1";
    (env as Record<string, unknown>).SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS =
      "human-1";

    // 1. Create Profile Lab auth intent
    const createRes = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Profile Lab",
          contractVersion: "1.1",
          audience: "syntila.profile-lab.management",
        }),
      }),
      env,
    );
    expect(createRes.status).toBe(201);
    const intentData = (await createRes.json()) as {
      intentId: string;
      pollToken: string;
      verificationUrl: string;
      audience: string;
    };
    expect(intentData.audience).toBe("syntila.profile-lab.management");

    // 2. Check browser status reflects the Profile Lab audience
    const browserStatusRes = await handleDesktopAuthIntentBrowserStatus(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${intentData.intentId}/browser-status`,
      ),
      env,
      intentData.intentId,
    );
    expect(browserStatusRes.status).toBe(200);
    const browserStatus = (await browserStatusRes.json()) as {
      audience: string;
      clientName: string;
      status: string;
    };
    expect(browserStatus.audience).toBe("syntila.profile-lab.management");
    expect(browserStatus.clientName).toBe("Syntila Profile Lab");
    expect(browserStatus.status).toBe("pending");

    // 3. Approve intent
    const approveRes = await handleApproveDesktopAuthIntent(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${intentData.intentId}/approve`,
        { method: "POST" },
      ),
      env,
      intentData.intentId,
    );
    expect(approveRes.status).toBe(200);

    // 4. Claim intent and verify session audience
    const claimRes = await handleClaimDesktopAuthIntent(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${intentData.intentId}/claim`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ pollToken: intentData.pollToken }),
        },
      ),
      env,
      intentData.intentId,
    );
    expect(claimRes.status).toBe(200);
    const profileLabSession = (await claimRes.json()) as {
      credential: string;
      audience: string;
      sessionId: string;
      user: { userId: string };
    };
    expect(profileLabSession.audience).toBe("syntila.profile-lab.management");
    expect(profileLabSession.user.userId).toBe("human-1");

    // 5. Verify Profile Lab session CAN access profile admin routes
    const adminReq = new Request(
      "https://app.syntila.test/api/profile-admin/profiles",
      {
        headers: {
          authorization: `Bearer ${profileLabSession.credential}`,
        },
      },
    );
    const authContext = await authorizeToolProfileAdmin(adminReq, env);
    expect(authContext.userId).toBe("human-1");
    expect(authContext.clientType).toBe("desktop");
    expect(authContext.audience).toBe("syntila.profile-lab.management");

    // 6. Verify Profile Lab session CANNOT register or manipulate workspaces (mutual exclusion)
    const wsRegisterRes = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.syntila.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${profileLabSession.credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          proposedWorkspaceName: "Unauthorized Lab Workspace",
          hostname: "lab-computer",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    ).catch((err: { status?: number; message?: string }) => err);
    // In our implementation, findDesktopHumanSession throws HttpError(403) when audience doesn't match
    expect(wsRegisterRes).toMatchObject({
      status: 403,
    });

    // 7. Create a normal Workspace session (syntila.desktop.management)
    const wsIntentRes = await handleCreateDesktopAuthIntent(
      new Request("https://app.syntila.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Syntila Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const wsIntent = (await wsIntentRes.json()) as {
      intentId: string;
      pollToken: string;
      audience: string;
    };
    expect(wsIntent.audience).toBe("syntila.desktop.management");
    await handleApproveDesktopAuthIntent(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${wsIntent.intentId}/approve`,
        { method: "POST" },
      ),
      env,
      wsIntent.intentId,
    );
    const wsClaimRes = await handleClaimDesktopAuthIntent(
      new Request(
        `https://app.syntila.test/api/desktop-auth/intents/${wsIntent.intentId}/claim`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ pollToken: wsIntent.pollToken }),
        },
      ),
      env,
      wsIntent.intentId,
    );
    const wsSession = (await wsClaimRes.json()) as { credential: string };

    // 8. Verify Workspace session CANNOT access profile admin routes (mutual exclusion)
    const wsAdminReq = new Request(
      "https://app.syntila.test/api/profile-admin/profiles",
      {
        headers: {
          authorization: `Bearer ${wsSession.credential}`,
        },
      },
    );
    await expect(
      authorizeToolProfileAdmin(wsAdminReq, env),
    ).rejects.toMatchObject({
      status: 403,
      message: "The profiles:admin permission is required",
    });
  });
});
