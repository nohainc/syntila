import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { handleListWorkspaces } from "../../src/domain/routes/workspaces-management.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
import { pgD1 } from "./helpers/pg-d1";

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
    ('owner','owner@test','Owner','now','now'), ('other','other@test','Other','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES
    ('mine','owner','Mine','now','now'), ('empty','owner','Empty','now','now'),
    ('private','other','Private','now','now');`);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async () => ({
      userId: "owner",
      user: {
        id: "owner",
        email: "owner@test",
        displayName: "Owner",
        status: "active",
      },
      workspaceId: "",
      spaceRoles: {},
      sessionId: "session",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  async function space(id: string, archived = false) {
    await sqlite
      .prepare(
        "INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES (?,'other',?,?, 'now','now')",
      )
      .run(id, id, JSON.stringify({ archived }));
  }
  async function grant(
    id: string,
    spaceId: string,
    status = "active",
    expiry: string | null = null,
    workspace = "mine",
  ) {
    await sqlite
      .prepare(
        "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,expires_at,created_at,updated_at) VALUES (?,?,?,?,?,?,'now','now')",
      )
      .run(
        id,
        spaceId,
        workspace,
        workspace === "private" ? "other" : "owner",
        status,
        expiry,
      );
  }
  const list = async () => {
    const response = await handleListWorkspaces(
      new Request("https://cloud.test/api/workspaces"),
      env,
    );
    return (await response.json()) as {
      workspaces: { id: string; activeSpaceGrantCount: number }[];
    };
  };
  return { sqlite, db, env, space, grant, list };
}

describe("Workspace aggregate", () => {
  it("does not expose Space access counts", async () => {
    const f = await fixture();
    try {
      for (const id of [
        "active",
        "suspended",
        "revoked",
        "expired",
        "timed-out",
        "future",
        "private",
      ])
        await f.space(id);
      await f.space("archived", true);
      await f.grant("g1", "active");
      // A second live grant for the same Space is impossible (unique index).
      await f.grant("g2", "suspended", "suspended");
      await f.grant("g3", "revoked", "revoked");
      await f.grant("g4", "expired", "expired");
      await f.grant("g5", "timed-out", "active", "2000-01-01T00:00:00.000Z");
      await f.grant("g6", "future", "active", "2999-01-01T00:00:00.000Z");
      await f.grant("g7", "archived");
      await f.grant("g8", "private", "active", null, "private");
      const { workspaces } = await f.list();
      expect(workspaces.map((w) => w.id).sort()).toEqual(["empty", "mine"]);
      expect(workspaces.find((w) => w.id === "mine")).not.toHaveProperty(
        "activeSpaceGrantCount",
      );
    } finally {
      await f.sqlite.close();
    }
  });
  it("uses one aggregate database read without a grant-count query", async () => {
    const f = await fixture();
    try {
      for (let i = 0; i < 30; i++) {
        await f.space(`p${i}`);
        await f.grant(`g${i}`, `p${i}`);
      }
      // Count the statements the handler sends through the data layer.
      const statements: string[] = [];
      const real = (f.db as any).sql;
      const counted: any = new Proxy(real, {
        apply(target, thisArg, args) {
          if (Array.isArray(args[0])) statements.push((args[0] as string[]).join("?"));
          return Reflect.apply(target, thisArg, args);
        },
      });
      (f.env as any).SYNTILA_DB = Object.create(f.db, { sql: { value: counted } });
      await f.list();
      // Besides the account provisioning of the signed-in user, the list is one read.
      const reads = statements.filter((text) => text.includes("FROM execution_workspaces"));
      expect(reads).toHaveLength(1);
      expect(statements.join("\n")).not.toContain("COUNT(DISTINCT g.space_id)");
    } finally {
      await f.sqlite.close();
    }
  });
});
