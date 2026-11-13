import { describe, expect, it, vi } from "./helpers/vitest-compat";
import * as security from "../../src/domain/routes/http-security.js";
import { conditionalJson } from "../../src/domain/routes/conditional-read.js";
import { handleGetSpace } from "../../src/domain/routes/spaces.js";
import { handleListSpaceThreads } from "../../src/domain/routes/threads.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

function request(etag?: string) {
  return new Request("https://syntila.test/api/spaces/p", {
    headers: etag ? { "if-none-match": etag } : {},
  });
}
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('u','u@test','User','now','now');
    INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES ('p','u','Space','{}','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES ('m','p','u','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('w','p','Work','active','u','now','now');`);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async () => ({
      userId: "u",
      user: { id: "u", email: "u@test", displayName: "User", status: "active" },
      workspaceId: "",
      spaceRoles: {},
      sessionId: "s",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  return { sqlite, env };
}

describe("stable read revisions v1", () => {
  it("returns an empty 304 with the same private response headers", async () => {
    const first = await conditionalJson(request(), { rows: [1, 2] });
    const etag = first.headers.get("etag")!;
    const unchanged = await conditionalJson(request(etag), { rows: [1, 2] });
    expect(unchanged.status).toBe(304);
    expect(await unchanged.text()).toBe("");
    for (const name of ["etag", "cache-control", "vary"])
      expect(unchanged.headers.get(name)).toBe(first.headers.get(name));
    expect(first.headers.get("cache-control")).toBe("private, no-cache");
  });
  it("supports weak validators, lists and wildcard, and detects changed representations", async () => {
    const etag = (
      await conditionalJson(request(), { rows: [1, 2] })
    ).headers.get("etag")!;
    for (const header of [`W/${etag}`, `"other", W/${etag}`, "*"]) {
      expect(
        (await conditionalJson(request(header), { rows: [1, 2] })).status,
      ).toBe(304);
    }
    for (const data of [
      { rows: [2, 1] },
      { rows: [1, 2], canExecute: false },
      { rows: [] },
    ]) {
      expect((await conditionalJson(request(etag), data)).status).toBe(200);
    }
  });
  it("Space edits with unchanged timestamps change the revision", async () => {
    const { sqlite, env } = fixture();
    try {
      const first = await handleGetSpace(request(), env, "p");
      const etag = first.headers.get("etag")!;
      expect((await handleGetSpace(request(etag), env, "p")).status).toBe(304);
      sqlite.exec("UPDATE spaces SET name = 'Renamed' WHERE id = 'p'");
      const changed = await handleGetSpace(request(etag), env, "p");
      expect(changed.status).toBe(200);
      expect(
        ((await changed.json()) as { space: { name: string } }).space.name,
      ).toBe("Renamed");
    } finally {
      sqlite.close();
    }
  });
  it("Thread creation/deletion and permission changes change collection revisions", async () => {
    const { sqlite, env } = fixture();
    try {
      const first = await handleListSpaceThreads(request(), env, "p");
      const etag = first.headers.get("etag")!;
      expect(
        (await handleListSpaceThreads(request(etag), env, "p")).status,
      ).toBe(304);
      sqlite.exec(
        "UPDATE space_memberships SET role = 'viewer' WHERE id = 'm'",
      );
      expect(
        (await handleListSpaceThreads(request(etag), env, "p")).status,
      ).toBe(200);
      sqlite.exec("DELETE FROM threads WHERE id = 'w'");
      expect(
        (await handleListSpaceThreads(request(etag), env, "p")).status,
      ).toBe(200);
    } finally {
      sqlite.close();
    }
  });
  it("membership revocation is checked before returning 304", async () => {
    const { sqlite, env } = fixture();
    try {
      const etag = (await handleGetSpace(request(), env, "p")).headers.get(
        "etag",
      )!;
      sqlite.exec("DELETE FROM space_memberships WHERE id = 'm'");
      // TEST_AUTHENTICATION intentionally bypasses membership authorization.
      // Simulate its denied outcome at the real authorization boundary.
      const denied = vi
        .spyOn(security, "authorizeRequest")
        .mockRejectedValue(new Error("Resource not found"));
      await expect(handleGetSpace(request(etag), env, "p")).rejects.toThrow();
      await expect(
        handleListSpaceThreads(request("*"), env, "p"),
      ).rejects.toThrow();
      expect(denied).toHaveBeenCalledTimes(2);
      denied.mockRestore();
    } finally {
      vi.restoreAllMocks();
      sqlite.close();
    }
  });
});
