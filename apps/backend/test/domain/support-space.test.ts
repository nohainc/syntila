import { describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../../src/domain/index.js";
import {
  loadSpacePermissions,
  requireWorkflowPermission,
} from "../../src/domain/routes/space-permissions.js";

function setup(support: string | null = "support@syntila.test") {
  const { sqlite, db } = sqliteD1();
  const now = new Date().toISOString();
  sqlite.exec(`
    INSERT INTO users (id, email, display_name, avatar_url, status, created_at, updated_at) VALUES
      ('user-alice', 'alice@test.com', 'Alice', NULL, 'active', '${now}', '${now}'),
      ('user-bob', 'bob@test.com', 'Bob', NULL, 'active', '${now}', '${now}'),
      ('user-support', 'Support@Syntila.test', 'Support', NULL, 'active', '${now}', '${now}');
  `);
  const users: Record<
    string,
    {
      id: string;
      email: string;
      displayName: string;
      avatarUrl: null;
      status: string;
    }
  > = {
    alice: {
      id: "user-alice",
      email: "alice@test.com",
      displayName: "Alice",
      avatarUrl: null,
      status: "active",
    },
    bob: {
      id: "user-bob",
      email: "bob@test.com",
      displayName: "Bob",
      avatarUrl: null,
      status: "active",
    },
    support: {
      id: "user-support",
      email: "support@syntila.test",
      displayName: "Support",
      avatarUrl: null,
      status: "active",
    },
  };
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    ...(support ? { SYNTILA_SUPPORT_ACCOUNT_EMAIL: support } : {}),
    TEST_AUTHENTICATION: async (req: Request) => {
      const user =
        users[req.headers.get("authorization")?.replace("Bearer ", "") ?? ""] ??
        users.alice!;
      return {
        userId: user.id,
        user,
        workspaceId: "",
        spaceRoles: {},
        sessionId: `sess-${user.id}`,
        clientType: "web",
      };
    },
  };
  const call = (who: string) =>
    worker.fetch(
      new Request("https://syntila.test/api/people/support", {
        method: "POST",
        headers: { authorization: `Bearer ${who}` },
      }),
      env as never,
    );
  return { sqlite, env, call };
}

describe("support Space provisioning", () => {
  it("creates one authorized Space and is idempotent", async () => {
    const { sqlite, call } = setup(" SUPPORT@syntila.test ");
    const first = await call("alice");
    expect(first.status).toBe(201);
    const { spaceId } = (await first.json()) as { spaceId: string };
    const second = await call("alice");
    expect(second.status).toBe(200);
    expect(((await second.json()) as { spaceId: string }).spaceId).toBe(
      spaceId,
    );
    const members = sqlite
      .prepare(
        "SELECT user_id FROM space_memberships WHERE space_id=? ORDER BY user_id",
      )
      .all(spaceId);
    expect(members).toEqual([
      { user_id: "user-alice" },
      { user_id: "user-support" },
    ]);
    expect(
      sqlite.prepare("SELECT COUNT(*) c FROM support_spaces").get(),
    ).toEqual({ c: 1 });
    expect(
      sqlite.prepare("SELECT COUNT(*) c FROM person_connections").get(),
    ).toEqual({ c: 0 });
  });

  it("excludes the configured support account from People while retaining other people", async () => {
    const { sqlite, env } = setup(" SUPPORT@syntila.test ");
    sqlite.exec(
      `INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES ('user-alice', 'user-support', '2026-01-01'), ('user-alice', 'user-bob', '2026-01-01')`,
    );
    const res = await worker.fetch(
      new Request("https://syntila.test/api/people", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const body = (await res.json()) as { people: { userId: string }[] };
    expect(body.people.map((p) => p.userId)).toEqual(["user-bob"]);
  });

  it("recreates support after deletion", async () => {
    const { env, call } = setup();
    const { spaceId } = (await (await call("alice")).json()) as {
      spaceId: string;
    };
    const deleted = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${spaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleted.status).toBe(200);
    const next = await call("alice");
    expect(next.status).toBe(201);
    expect(((await next.json()) as { spaceId: string }).spaceId).not.toBe(
      spaceId,
    );
  });

  it("converges under concurrent requests", async () => {
    const { sqlite, call } = setup();
    const res = await Promise.all([
      call("alice"),
      call("alice"),
      call("alice"),
    ]);
    expect(res.every((r) => r.ok)).toBe(true);
    const ids = new Set(
      await Promise.all(
        res.map(async (r) => ((await r.json()) as { spaceId: string }).spaceId),
      ),
    );
    expect(ids.size).toBe(1);
    expect(
      sqlite.prepare("SELECT COUNT(*) c FROM direct_spaces").get(),
    ).toEqual({ c: 1 });
    expect(
      sqlite.prepare("SELECT COUNT(*) c FROM spaces WHERE kind='direct'").get(),
    ).toEqual({ c: 1 });
  });

  it("adopts an existing Direct Space and keeps its history", async () => {
    const { sqlite, call } = setup();
    const first = await call("alice");
    const { spaceId } = (await first.json()) as { spaceId: string };
    sqlite.exec("DELETE FROM support_spaces");
    const again = await call("alice");
    expect(again.status).toBe(200);
    expect(((await again.json()) as { spaceId: string }).spaceId).toBe(spaceId);
    expect(
      sqlite.prepare("SELECT COUNT(*) c FROM support_spaces").get(),
    ).toEqual({ c: 1 });
  });

  it("gives each user a separate Space", async () => {
    const { call } = setup();
    const a = (await (await call("alice")).json()) as { spaceId: string };
    const b = (await (await call("bob")).json()) as { spaceId: string };
    expect(a.spaceId).not.toBe(b.spaceId);
  });

  it("fails safely on missing/unknown config, self, and blocks", async () => {
    expect((await setup(null).call("alice")).status).toBe(503);
    expect((await setup("nobody@syntila.test").call("alice")).status).toBe(503);
    expect((await setup().call("support")).status).toBe(409);
    const s = setup();
    s.sqlite.exec(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES ('user-support','user-alice','2024-01-01T00:00:00Z')",
    );
    expect((await s.call("alice")).status).toBe(403);
    const inactive = setup();
    inactive.sqlite.exec(
      "UPDATE users SET status='suspended' WHERE id='user-support'",
    );
    expect((await inactive.call("alice")).status).toBe(503);
  });
});

describe("support Space state endpoint", () => {
  it("reports no Space and hidden before provisioning, then the stored state", async () => {
    const { env } = setup();
    const get = () =>
      worker.fetch(
        new Request("https://syntila.test/api/people/support", {
          headers: { authorization: "Bearer alice" },
        }),
        env as never,
      );
    expect(await (await get()).json()).toEqual({ spaceId: null, hidden: true });
    const post = await worker.fetch(
      new Request("https://syntila.test/api/people/support", {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const { spaceId } = (await post.json()) as { spaceId: string };
    expect(await (await get()).json()).toEqual({ spaceId, hidden: true });
  });
});

describe("support Space is human messaging only", () => {
  it("denies Chat, Work and own Workers to both participants and flags the Space", async () => {
    const { env, call } = setup();
    const { spaceId } = (await (await call("alice")).json()) as {
      spaceId: string;
    };
    for (const userId of ["user-alice", "user-support"]) {
      const policy = await loadSpacePermissions(env as never, userId, spaceId);
      expect(policy.isSupport).toBe(true);
      expect(policy.rights).toMatchObject({
        chat: false,
        work: false,
        useOwnWorkers: false,
      });
      for (const workflowId of ["chat", "direct"]) {
        await expect(
          requireWorkflowPermission(env as never, userId, spaceId, workflowId, {
            entitlement: false,
          }),
        ).rejects.toMatchObject({ status: 403 });
      }
    }
    const res = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${spaceId}`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(
      ((await res.json()) as { space: { isSupport: boolean } }).space.isSupport,
    ).toBe(true);
  });

  it("leaves ordinary Direct Spaces unchanged", async () => {
    const { sqlite, env } = setup();
    const now = new Date().toISOString();
    sqlite.exec(`
      INSERT INTO spaces (id, owner_user_id, name, kind, settings_json, created_at, updated_at) VALUES ('space-d', 'user-alice', 'D', 'direct', '{}', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES ('pm-1','space-d','user-alice','owner','${now}','${now}');
    `);
    const policy = await loadSpacePermissions(
      env as never,
      "user-alice",
      "space-d",
    );
    expect(policy.isSupport).toBe(false);
    expect(policy.rights.chat).toBe(true);
    await expect(
      requireWorkflowPermission(env as never, "user-alice", "space-d", "chat", {
        entitlement: false,
      }),
    ).resolves.toBeDefined();
  });
});
