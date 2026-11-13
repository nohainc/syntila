import { afterEach, beforeEach, describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleChangeSpaceMemberRole,
  handleListSpaceMembers,
  handleGetSpace,
  handleCreateSpaceInvitation,
  handleAcceptSpaceInvitation,
  handleUpdateSpace,
  handleListSpaceThreads,
  handleCreateThread,
  handleUpdateThread,
  handleValidateWorkRequest,
  handleCreateWorkspaceSpaceGrant,
  handleRevokeWorkspaceSpaceGrant,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";
import {
  defaultSpaceMemberPermissions,
  authorizeSpaceMembership,
} from "@syntila/security";
import { requireWorkflowPermission } from "../../src/domain/routes/space-permissions.js";

const all = defaultSpaceMemberPermissions("owner");
const none = defaultSpaceMemberPermissions("viewer");
let store: ReturnType<typeof sqliteD1>;
let env: SecurityEnv;
const req = (user: string, body: unknown = {}, method = "POST") =>
  new Request("https://test/api", {
    method,
    headers: { "test-user": user, "content-type": "application/json" },
    ...(method === "GET" ? {} : { body: JSON.stringify(body) }),
  });
const context = (id: string) => ({
  userId: id,
  user: {
    id,
    email: `${id}@example.test`,
    displayName: id,
    status: "active" as const,
  },
  spaceRoles: {
    S: (id === "owner" ? "owner" : "collaborator") as "owner" | "collaborator",
  },
  sessionId: "test",
  clientType: "web" as const,
});
async function rights(id: string, permissions: typeof all) {
  await handleChangeSpaceMemberRole(
    req("owner", { permissions }, "PATCH"),
    env,
    "S",
    id,
  );
}

beforeEach(() => {
  store = sqliteD1();
  for (const id of ["owner", "member", "other", "recipient"])
    store.sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@example.test`, id);
  store.sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','owner','Space','now','now')",
  );
  for (const id of ["owner", "member", "other"])
    store.sqlite
      .prepare(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'S',?,?,'now','now')",
      )
      .run("m-" + id, id, id === "owner" ? "owner" : "collaborator");
  store.sqlite.exec(
    "INSERT INTO threads(id,space_id,name,status,access_policy_json,lead_user_id,created_at,updated_at) VALUES('T','S','Member thread','active','{\"allowedUserIds\":[],\"allowedSpaceRoles\":[],\"allowedPermissions\":[\"view\",\"discuss\",\"execute\"]}','member','now','now')",
  );
  env = {
    SYNTILA_DB: store.db,
    SYNTILA_ENVIRONMENT: "development",
    TEST_AUTHENTICATION: async (request: Request) =>
      context(request.headers.get("test-user")!),
  } as unknown as SecurityEnv;
});
afterEach(() => store.sqlite.close());

describe("Space member permissions contract v1", () => {
  it("preserves existing role defaults and projects non-owner creator emails", async () => {
    const data = (await (
      await handleListSpaceMembers(req("owner", {}, "GET"), env, "S")
    ).json()) as {
      members: Array<{ userId: string; permissions: typeof all }>;
    };
    expect(
      data.members.find((m) => m.userId === "member")?.permissions,
    ).toEqual(defaultSpaceMemberPermissions("collaborator"));
    const { threads } = (await (
      await handleListSpaceThreads(req("owner", {}, "GET"), env, "S")
    ).json()) as { threads: Array<Record<string, unknown>> };
    expect(threads[0]).toMatchObject({
      creatorEmail: "member@example.test",
      creatorIsOwner: false,
    });
  });
  it("only lets owners edit rights and never lets them disable their own owner rights", async () => {
    await expect(
      handleChangeSpaceMemberRole(
        req("member", { permissions: none }, "PATCH"),
        env,
        "S",
        "other",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await expect(rights("owner", none)).rejects.toMatchObject({ status: 403 });
    await expect(
      handleChangeSpaceMemberRole(
        req("owner", { permissions: { ...none, work: "yes" } }, "PATCH"),
        env,
        "S",
        "member",
      ),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      handleChangeSpaceMemberRole(
        req(
          "owner",
          {
            permissions: {
              ...none,
              attachWorkspace: true,
            },
          },
          "PATCH",
        ),
        env,
        "S",
        "member",
      ),
    ).rejects.toMatchObject({ status: 400 });
  });
  it("disables own Workers whenever Chat is denied", async () => {
    await rights("member", { ...none, useOwnWorkers: true });
    const response = await handleListSpaceMembers(
      req("owner", {}, "GET"),
      env,
      "S",
    );
    const members = (
      (await response.json()) as {
        members: Array<{ userId: string; permissions: typeof all }>;
      }
    ).members;
    expect(
      members.find((member) => member.userId === "member")?.permissions,
    ).toMatchObject({ chat: false, useOwnWorkers: false });
    await rights("member", { ...none, chat: true, useOwnWorkers: true });
    const allowed = (
      (await (
        await handleListSpaceMembers(req("owner", {}, "GET"), env, "S")
      ).json()) as {
        members: Array<{ userId: string; permissions: typeof all }>;
      }
    ).members;
    expect(
      allowed.find((member) => member.userId === "member")?.permissions,
    ).toMatchObject({ chat: true, useOwnWorkers: true });
  });
  it("separates Chat, Work and own-thread management even for a member who created the thread", async () => {
    await rights("member", { ...none, chat: true });
    await expect(
      requireWorkflowPermission(env, "member", "S", "chat"),
    ).resolves.toMatchObject({ rights: { chat: true } });
    await expect(
      requireWorkflowPermission(env, "member", "S", "direct"),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      handleValidateWorkRequest(
        req("member", { workflowId: "direct" }),
        env,
        "T",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      handleCreateThread(req("member", { name: "Denied" }), env, "S"),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      handleUpdateThread(req("member", { name: "Denied" }, "PATCH"), env, "T"),
    ).rejects.toMatchObject({ status: 403 });
    await rights("member", { ...none, manageOwnThreads: true });
    await expect(
      handleUpdateThread(req("member", { name: "Renamed" }, "PATCH"), env, "T"),
    ).resolves.toMatchObject({ status: 200 });
    await expect(
      handleUpdateThread(req("other", { name: "Denied" }, "PATCH"), env, "T"),
    ).rejects.toMatchObject({ status: 403 });
  });
  it("enforces current rights at the security boundary and keeps reading available", async () => {
    await rights("member", none);
    await expect(
      authorizeSpaceMembership(store.db, context("member"), "S", "run.start"),
    ).rejects.toThrow();
    await expect(
      authorizeSpaceMembership(store.db, context("member"), "S", "spaces:read"),
    ).resolves.toBeDefined();
  });
  it("workflow enablement preserves member rights and history, and retired Space-wide settings are rejected", async () => {
    await rights("member", { ...none, chat: true, work: true });
    const publicRead = (await (
      await handleGetSpace(req("member", {}, "GET"), env, "S")
    ).json()) as {
      space: { settings: Record<string, unknown>; permissions: typeof all };
    };
    expect(publicRead.space.permissions).toMatchObject({
      chat: true,
      work: true,
    });
    expect(publicRead.space.settings).not.toHaveProperty("memberPermissions");
    expect(publicRead.space.settings).not.toHaveProperty(
      "invitationPermissions",
    );

    await expect(
      handleUpdateSpace(
        req("owner", { settings: { allowWork: false } }, "PATCH"),
        env,
        "S",
      ),
    ).rejects.toMatchObject({ status: 400 });
    store.sqlite
      .prepare(
        "INSERT INTO space_workflow_configurations VALUES('S','direct',1,?,'now')",
      )
      .run(
        JSON.stringify({
          schemaVersion: 1,
          workflowId: "direct",
          enabled: false,
          defaults: {},
          stepOverrides: {},
        }),
      );
    await expect(
      requireWorkflowPermission(env, "owner", "S", "direct"),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      requireWorkflowPermission(env, "member", "S", "chat"),
    ).resolves.toBeDefined();
    expect(
      store.sqlite.prepare("SELECT COUNT(*) AS count FROM threads").get(),
    ).toEqual({ count: 1 });
    await handleUpdateSpace(
      req("owner", { instructions: "Updated" }, "PATCH"),
      env,
      "S",
    );
    const stored = JSON.parse(
      (
        store.sqlite
          .prepare("SELECT settings_json FROM spaces WHERE id='S'")
          .get() as { settings_json: string }
      ).settings_json,
    ) as {
      memberPermissions: { member: { work: boolean } };
    };
    expect(stored.memberPermissions.member.work).toBe(true);
    expect(stored).not.toHaveProperty("allowWork");
    await expect(
      handleUpdateSpace(
        req(
          "owner",
          { settings: { memberPermissions: { member: all } } },
          "PATCH",
        ),
        env,
        "S",
      ),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      handleUpdateSpace(
        req("owner", { settings: { allowWork: true } }, "PATCH"),
        env,
        "S",
      ),
    ).rejects.toMatchObject({ status: 400 });
    store.sqlite.exec(
      "DELETE FROM space_workflow_configurations WHERE space_id='S'",
    );
    await expect(
      requireWorkflowPermission(env, "member", "S", "direct"),
    ).resolves.toBeDefined();
  });
  it("keeps Workspace grants independent from member permission snapshots", async () => {
    store.sqlite.exec(
      "INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES('W','other','Other workspace','online','now','now')",
    );
    await expect(
      handleCreateWorkspaceSpaceGrant(
        req("member", { workspaceId: "W", confirmContribution: true }),
        env,
        "W",
        "S",
      ),
    ).rejects.toMatchObject({ status: 403 });
  });
  it("allows an authorized member to contribute their own Workspace and lets the Space owner revoke it", async () => {
    store.sqlite.exec(
      "INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES('W','member','Member workspace','online','now','now')",
    );
    await expect(
      handleCreateWorkspaceSpaceGrant(
        req("member", { workspaceId: "W" }),
        env,
        "W",
        "S",
      ),
    ).rejects.toMatchObject({ status: 400 });
    const response = await handleCreateWorkspaceSpaceGrant(
      req("member", {
        workspaceId: "W",
        confirmContribution: true,
        allowedPermissions: [
          "repository:read",
          "repository:write",
          "shell:execute",
        ],
      }),
      env,
      "W",
      "S",
    );
    expect(response.status).toBe(201);
    const grant = store.sqlite
      .prepare(
        "SELECT id, status FROM workspace_space_grants WHERE space_id='S' AND workspace_id='W'",
      )
      .get() as { id: string; status: string };
    expect(grant.status).toBe("active");
    await handleRevokeWorkspaceSpaceGrant(
      req("owner", {}, "DELETE"),
      env,
      grant.id,
    );
    expect(
      store.sqlite
        .prepare("SELECT status FROM workspace_space_grants WHERE id=?")
        .get(grant.id),
    ).toEqual({ status: "revoked" });
    expect(
      store.sqlite
        .prepare("SELECT owner_user_id FROM execution_workspaces WHERE id='W'")
        .get(),
    ).toEqual({ owner_user_id: "member" });
  });
  it("allows invitations only for the Space owner", async () => {
    await rights("member", { ...none, chat: true, work: true });
    await expect(
      handleCreateSpaceInvitation(
        req("member", {
          email: "recipient@example.test",
          role: "collaborator",
          permissions: all,
        }),
        env,
        "S",
      ),
    ).rejects.toMatchObject({ status: 403 });
    const response = await handleCreateSpaceInvitation(
      req("owner", {
        email: "recipient@example.test",
        role: "collaborator",
        permissions: { ...none, chat: true, work: true },
      }),
      env,
      "S",
    );
    const { invitation } = (await response.json()) as {
      invitation: { id: string };
    };
    await handleAcceptSpaceInvitation(req("recipient"), env, invitation.id);
    await expect(
      requireWorkflowPermission(env, "recipient", "S", "chat"),
    ).resolves.toBeDefined();
    await expect(
      requireWorkflowPermission(env, "recipient", "S", "direct"),
    ).resolves.toBeDefined();
    expect(
      store.sqlite
        .prepare("SELECT role FROM space_memberships WHERE user_id='recipient'")
        .get(),
    ).toEqual({ role: "collaborator" });
  });
});
