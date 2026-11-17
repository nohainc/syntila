import { pgD1 } from "./helpers/pg-d1";
import { member, T0, user, workspace } from "./helpers/seed";
import { beforeEach, expect, it, vi } from "./helpers/vitest-compat";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
const admission = vi.hoisted(() => vi.fn());
vi.mock("../../src/domain/routes/handlers.js", () => ({
  validateWorkflowWorkerEligibility: admission,
}));
import { resolveWorkflowExecutionBindings } from "../../src/domain/routes/workflow-execution-configuration.js";
import { requireWorkflowPermission } from "../../src/domain/routes/space-permissions.js";

/**
 * Space "space" uses Workspace "space-ws" (owned by "owner"). "member" owns
 * "own-ws" with Worker "mine" and borrows "lent-ws" with Worker "lent".
 */
async function fixture(memberRights: Record<string, boolean> | null, kind = "group") {
  const { db, sqlite } = await pgD1();
  const settings = memberRights
    ? { memberPermissions: { member: memberRights } }
    : {};
  const inventory = (worker: string, ws: string, owner: string) =>
    `INSERT INTO workspace_worker_inventory (
       worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
       local_concurrency_limit, revision, created_at, updated_at, last_seen_at
     ) VALUES ('${worker}', '${ws}', '${owner}', 'chatgpt-codex', 'enabled', 'ready', 1, 1, '${T0}', '${T0}', '${T0}');`;
  await sqlite.exec(
    user("owner") +
      user("member") +
      user("lender") +
      `INSERT INTO spaces(id,owner_user_id,name,settings_json,kind,created_at,updated_at)
         VALUES ('space','owner','space','${JSON.stringify(settings)}','${kind}','${T0}','${T0}');` +
      member("space", "owner") +
      member("space", "member", "collaborator") +
      workspace("space-ws", "owner") +
      workspace("own-ws", "member") +
      workspace("lent-ws", "lender") +
      inventory("shared", "space-ws", "owner") +
      inventory("mine", "own-ws", "member") +
      inventory("lent", "lent-ws", "lender") +
      `INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at) VALUES ('space', 'space-ws', '${T0}');`,
  );
  const env = { SYNTILA_DB: db } as unknown as SecurityEnv;
  const resolve = (
    workerId: string | undefined,
    workflow = BUILTIN_WORKFLOWS.chat,
  ) =>
    resolveWorkflowExecutionBindings(
      env,
      "member",
      "space",
      "thread",
      workflow,
      {},
      [],
      { workerId },
    );
  const grants = async () =>
    (await sqlite
      .prepare(
        `SELECT workspace_id AS "workspaceId", granted_by_user_id AS "grantedBy", allowed_permissions_json AS permissions
           FROM workspace_space_grants WHERE space_id = 'space'`,
      )
      .all()) as { workspaceId: string; grantedBy: string; permissions: string }[];
  const audits = async () =>
    (await sqlite.prepare("SELECT action FROM space_audit_log WHERE space_id = 'space'").all()) as { action: string }[];
  return { resolve, grants, audits, env };
}

beforeEach(() => {
  admission.mockReset();
  admission.mockResolvedValue({
    issues: [],
    primaryWorkspaceId: "own-ws",
    workerProfiles: {},
    workerCatalogRevisions: {},
  });
});

it("admits the member's own Worker for Chat through a read-only grant", async () => {
  const f = await fixture(null);
  await expect(f.resolve("mine")).resolves.toEqual({
    chat: { workerId: "mine" },
  });
  const grants = await f.grants();
  expect(grants).toHaveLength(1);
  expect(grants[0]).toMatchObject({ workspaceId: "own-ws", grantedBy: "member" });
  expect(JSON.parse(grants[0]!.permissions)).toEqual(["repository:read"]);
  expect((await f.audits()).map((a) => a.action)).toEqual(["chat.own_workspace.authorized"]);
});

it("rejects own Workers when the member lacks Chat", async () => {
  const f = await fixture({ chat: false, work: true });
  await expect(f.resolve("mine")).rejects.toMatchObject({ status: 403 });
  expect(await f.grants()).toEqual([]);
});

it("ignores a legacy stored useOwnWorkers: false while Chat is granted", async () => {
  const f = await fixture({ chat: true, useOwnWorkers: false });
  await expect(f.resolve("mine")).resolves.toBeDefined();
});

it("never treats a Worker shared with the member as their own", async () => {
  const f = await fixture(null);
  await expect(f.resolve("lent")).rejects.toMatchObject({ status: 422 });
  expect(await f.grants()).toEqual([]);
});

it("requires an owned Worker in a personal Space", async () => {
  const f = await fixture(null, "direct");
  await expect(f.resolve("shared")).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve("lent")).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve(undefined)).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve("mine", BUILTIN_WORKFLOWS.direct),).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve("mine")).resolves.toBeDefined();
});

it("rejects non-Chat workflow admission in a personal Space", async () => {
  const f = await fixture(null, "direct");
  await expect(
    requireWorkflowPermission(f.env, "member", "space", "direct"),
  ).rejects.toMatchObject({ status: 403 });
});
