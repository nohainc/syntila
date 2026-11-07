import { beforeEach, expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import type { SecurityEnv } from "../src/routes/http-security.js";
const admission = vi.hoisted(() => vi.fn());
vi.mock("../src/routes/handlers.js", () => ({
  validateWorkflowWorkerEligibility: admission,
}));
import { resolveWorkflowExecutionBindings } from "../src/routes/workflow-execution-configuration.js";
import { requireWorkflowPermission } from "../src/routes/space-permissions.js";

/**
 * Space "space" uses Workspace "space-ws" (owned by "owner"). "member" owns
 * "own-ws" with Worker "mine" and borrows "lent-ws" with Worker "lent".
 */
function fixture(memberRights: Record<string, boolean> | null, kind = "group") {
  const inventory = [
    { workerId: "shared", workspaceId: "space-ws", ownerUserId: "owner" },
    { workerId: "mine", workspaceId: "own-ws", ownerUserId: "member" },
    { workerId: "lent", workspaceId: "lent-ws", ownerUserId: "lender" },
  ];
  const writes: Array<{ sql: string; values: unknown[] }> = [];
  const settings = memberRights
    ? { memberPermissions: { member: memberRights } }
    : {};
  const env = {
    SYNTILA_DB: {
      prepare(sql: string) {
        return {
          sql,
          values: [] as unknown[],
          bind(...values: unknown[]) {
            this.values = values;
            return this;
          },
          async first() {
            if (sql.includes("space_workflow_settings"))
              return { workspaceId: "space-ws" };
            if (sql.includes("space_memberships"))
              return {
                role: "collaborator",
                settingsJson: JSON.stringify(settings),
                kind,
              };
            if (
              sql.includes(
                "SELECT i.workspace_id AS workspaceId FROM workspace_worker_inventory",
              )
            )
              return (
                inventory.find(
                  (worker) =>
                    worker.workerId === this.values[0] &&
                    worker.ownerUserId === this.values[1],
                ) ?? null
              );
            if (sql.includes("FROM workspace_worker_inventory i\n       JOIN"))
              return (
                inventory.find(
                  (worker) =>
                    worker.workerId === this.values[0] &&
                    worker.ownerUserId === this.values[1],
                ) ?? null
              );
            if (sql.includes("FROM workspace_space_grants")) return null;
            if (sql.includes("FROM spaces WHERE id"))
              return { ownerUserId: "owner" };
            if (sql.includes("FROM execution_workspaces WHERE id"))
              return {
                ownerUserId: inventory.find(
                  (worker) => worker.workspaceId === this.values[0],
                )?.ownerUserId,
              };
            return null;
          },
          async all() {
            if (sql.includes("UNION ALL")) return { results: [] };
            return {
              results: inventory.filter(
                (worker) => worker.workspaceId === this.values[0],
              ),
            };
          },
        };
      },
      async batch(statements: Array<{ sql: string; values: unknown[] }>) {
        writes.push(...statements);
        return [];
      },
    },
  } as unknown as SecurityEnv;
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
  return { resolve, writes, env };
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
  const f = fixture(null);
  await expect(f.resolve("mine")).resolves.toEqual({
    chat: { workerId: "mine" },
  });
  const grant = f.writes.find((write) =>
    write.sql.includes("INSERT INTO workspace_space_grants"),
  );
  expect(grant?.sql).toContain("'[\"repository:read\"]'");
  expect(grant?.values.slice(1, 4)).toEqual(["space", "own-ws", "member"]);
});

it("rejects own Workers when the member lacks Chat", async () => {
  const f = fixture({ chat: false, work: true });
  await expect(f.resolve("mine")).rejects.toMatchObject({ status: 403 });
  expect(f.writes).toEqual([]);
});

it("ignores a legacy stored useOwnWorkers: false while Chat is granted", async () => {
  const f = fixture({ chat: true, useOwnWorkers: false });
  await expect(f.resolve("mine")).resolves.toBeDefined();
});

it("never treats a Worker shared with the member as their own", async () => {
  const f = fixture(null);
  await expect(f.resolve("lent")).rejects.toMatchObject({ status: 422 });
  expect(f.writes).toEqual([]);
});

it("requires an owned Worker in a personal Space", async () => {
  const f = fixture(null, "direct");
  await expect(f.resolve("shared")).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve("lent")).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve(undefined)).rejects.toMatchObject({ status: 403 });
  await expect(
    f.resolve("mine", BUILTIN_WORKFLOWS.direct),
  ).rejects.toMatchObject({ status: 403 });
  await expect(f.resolve("mine")).resolves.toBeDefined();
});

it("rejects non-Chat workflow admission in a personal Space", async () => {
  const f = fixture(null, "direct");
  await expect(
    requireWorkflowPermission(f.env, "member", "space", "direct"),
  ).rejects.toMatchObject({ status: 403 });
});
