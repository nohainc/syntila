import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

vi.mock("../src/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../src/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId };
  },
}));
import { handleWorkspaceWorkerPreferences } from "../src/routes/workspace-worker-preferences.js";

const preferences = {
  schemaVersion: 1,
  hiddenWorkers: ["worker-a"],
  hiddenModels: { "worker-a": ["model-a"] },
  hiddenEfforts: { "worker-a": { "model-a": ["high"] } },
};
const defaults = {
  schemaVersion: 1,
  hiddenWorkers: [],
  hiddenModels: {},
  hiddenEfforts: {},
};
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(
    readFileSync(
      new URL(
        "../migrations-v8/0114_personal_worker_visibility.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','o@test','O','now','now'),('other','x@test','X','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','owner','Workspace','now','now');
    INSERT INTO workspace_member_access(workspace_id,policy_json,updated_at) VALUES('workspace','{"schemaVersion":1,"workers":{}}','now');
    INSERT INTO workspace_member_overrides(workspace_id,user_id,policy_json,updated_at) VALUES('workspace','other','{"schemaVersion":1,"workers":{}}','now');`);
  const call = (method: string, user: string | null, body?: unknown) =>
    handleWorkspaceWorkerPreferences(
      new Request(
        "https://cloud.test/api/workspaces/workspace/worker-preferences",
        {
          method,
          headers: user ? { authorization: user } : {},
          ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
        },
      ),
      { SYNTILA_DB: db } as SecurityEnv,
      "workspace",
    );
  return { sqlite, call };
}
describe("personal Worker preferences", () => {
  it("persists and resets without changing sharing or member policies", async () => {
    const { sqlite, call } = fixture();
    const before = [
      sqlite.prepare("SELECT * FROM workspace_member_access").all(),
      sqlite.prepare("SELECT * FROM workspace_member_overrides").all(),
    ];
    expect(await (await call("GET", "owner")).json()).toEqual({
      preferences: defaults,
    });
    expect(await (await call("PUT", "owner", preferences)).json()).toEqual({
      preferences,
    });
    expect(await (await call("GET", "owner")).json()).toEqual({ preferences });
    expect([
      sqlite.prepare("SELECT * FROM workspace_member_access").all(),
      sqlite.prepare("SELECT * FROM workspace_member_overrides").all(),
    ]).toEqual(before);
    expect(await (await call("DELETE", "owner")).json()).toEqual({
      preferences: defaults,
    });
    expect(await (await call("GET", "owner")).json()).toEqual({
      preferences: defaults,
    });
  });
  it("rejects other users and unauthenticated requests", async () => {
    const { call } = fixture();
    await call("PUT", "owner", preferences);
    for (const method of ["GET", "PUT", "DELETE"])
      await expect(
        call(method, "other", method === "PUT" ? preferences : undefined),
      ).rejects.toMatchObject({ status: 404 });
    await expect(call("GET", null)).rejects.toThrow("Unauthenticated");
    expect(await (await call("GET", "owner")).json()).toEqual({ preferences });
  });
  it("rejects malformed, unsupported and oversized documents", async () => {
    const { call } = fixture();
    for (const body of [
      { ...preferences, schemaVersion: 2 },
      { ...preferences, hiddenWorkers: [""] },
      { ...preferences, extra: true },
      { ...preferences, hiddenModels: { worker: Array(201).fill("x") } },
    ])
      await expect(call("PUT", "owner", body)).rejects.toMatchObject({
        status: 400,
      });
    await expect(
      call("PUT", "owner", { ...preferences, extra: "x".repeat(70000) }),
    ).rejects.toMatchObject({ status: 413 });
    expect(await (await call("GET", "owner")).json()).toEqual({
      preferences: defaults,
    });
  });
  it("removes preferences when the Workspace is deleted", async () => {
    const { sqlite, call } = fixture();
    await call("PUT", "owner", preferences);
    sqlite
      .prepare("DELETE FROM execution_workspaces WHERE id = ?")
      .run("workspace");
    expect(
      sqlite.prepare("SELECT * FROM workspace_worker_preferences").all(),
    ).toHaveLength(0);
  });
});
