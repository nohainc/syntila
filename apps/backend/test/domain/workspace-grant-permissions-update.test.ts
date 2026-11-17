vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { T0, user, space, workspace } from "./helpers/seed";

const state = vi.hoisted(() => ({ status: "active", owner: true }));
vi.mock("../../src/domain/routes/handlers.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../src/domain/routes/handlers.js")>()),
  securityContext: async () => ({ userId: "owner-1" }),
  loadWorkspaceSpaceGrant: async () => ({
    id: "grant-1",
    workspace_id: "workspace-1",
    space_id: "space-1",
    status: state.status,
    allowed_permissions_json: "[]",
    expires_at: null,
  }),
  recordAudit: async () => {},
}));
vi.mock("@syntila/security", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@syntila/security")>()),
  authorizeWorkspaceOwner: async () => {
    if (!state.owner)
      throw Object.assign(new Error("Owner required"), { status: 403 });
  },
}));
import { handleUpdateWorkspaceSpaceGrant } from "../../src/domain/routes/workspaces-grants.js";

describe("Workspace grant access editing", () => {
  const stored = async (f: Awaited<ReturnType<typeof pgD1>>) =>
    (await f.sqlite.prepare("SELECT allowed_permissions_json AS p FROM workspace_space_grants WHERE id = 'grant-1'").get() as { p: string }).p;
  async function fixture() {
    const f = await pgD1();
    await f.sqlite.exec(`${user("owner-1")}${space("space-1", "owner-1")}${workspace("workspace-1", "owner-1")}
      INSERT INTO workspace_space_grants(id, space_id, workspace_id, granted_by_user_id, created_at, updated_at)
        VALUES ('grant-1', 'space-1', 'workspace-1', 'owner-1', '${T0}', '${T0}');`);
    const update = (permissions: unknown) =>
      handleUpdateWorkspaceSpaceGrant(
        new Request("https://cloud.test/api/workspace-space-grants/grant-1", {
          method: "PATCH",
          body: JSON.stringify({ allowedPermissions: permissions }),
        }),
        { SYNTILA_DB: f.db } as never,
        "grant-1",
      );
    return { f, update };
  }
  it("stores explicitly confirmed Direct permissions", async () => {
    state.status = "active";
    state.owner = true;
    const { f, update } = await fixture();
    try {
      expect((await update(["repository:read", "repository:write"])).status).toBe(200);
      expect(await stored(f)).toBe('["repository:read","repository:write"]');
    } finally {
      await f.sqlite.close();
    }
  });
  it("rejects invalid permissions without a write", async () => {
    state.status = "active";
    state.owner = true;
    const { f, update } = await fixture();
    try {
      await expect(update(["full_access"])).rejects.toMatchObject({ status: 400 });
      expect(await stored(f)).toBe("[]");
    } finally {
      await f.sqlite.close();
    }
  });
  it("requires Workspace ownership", async () => {
    state.status = "active";
    state.owner = false;
    const { f, update } = await fixture();
    try {
      await expect(update(["repository:write"])).rejects.toMatchObject({ status: 403 });
      expect(await stored(f)).toBe("[]");
    } finally {
      state.owner = true;
      await f.sqlite.close();
    }
  });
  it("cannot widen a revoked grant", async () => {
    state.status = "revoked";
    state.owner = true;
    const { f, update } = await fixture();
    try {
      await expect(update(["repository:read", "repository:write"])).rejects.toMatchObject({ status: 409 });
      expect(await stored(f)).toBe("[]");
    } finally {
      state.status = "active";
      await f.sqlite.close();
    }
  });
});
