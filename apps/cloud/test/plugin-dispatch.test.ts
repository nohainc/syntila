import { afterEach, expect, it, vi } from "vitest";
import { dispatchTaskAssignment } from "../src/assignment-dispatcher.js";
import { conversationFixture } from "./helpers/conversation.js";

const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../src/scheduler.js", () => scheduler);

const REF = "plugin-3fa91c04b2d7";
const DIGEST = "a".repeat(64);
const open: Array<{ close(): void }> = [];
afterEach(() => {
  for (const sqlite of open.splice(0)) sqlite.close();
});

const executor = {
  schemaVersion: 1,
  kind: "plugin",
  pluginRef: REF,
  pluginId: "acme-reviewer",
  version: "1.4.2",
  manifestDigest: DIGEST,
  artifactDigest: "b".repeat(64),
  pluginProtocol: "1.0",
  isolation: { tier: "none", readOnlyEnforced: false },
};

async function fixture() {
  const f = await conversationFixture();
  open.push(f.sqlite);
  f.sqlite.exec(`
    INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES('U','paid','active','manual',NULL,'now','now');
    INSERT INTO worker_catalog(worker_type_id,display_name,description,lifecycle_state,created_at,updated_at,engine_family,visibility_state,release_stage,sort_order,origin,owner_user_id)
      VALUES ('${REF}','Acme Reviewer','','active','now','now','cli','visible','stable',1000,'plugin','U');`);
  scheduler.selectSpaceExecutionTarget.mockResolvedValue({
    spaceId: "P",
    workspaceId: "WS",
    workspaceRuntimeIdentityId: "RT",
    workspaceSpaceGrantId: null,
    workerId: "plugin-worker",
    workerTypeId: REF,
    engineVersion: "1.4.0",
    profileDefinitionId: REF,
    profileReleaseVersion: 1,
    providerToolName: "acme-reviewer",
    providerToolVersion: "1.4.2",
    model: null,
    reasoningEffort: null,
    maxConcurrentAssignments: 1,
    effectivePermissions: ["repository:read", "repository:write"],
    permissionSnapshot: {
      permissions: ["repository:read", "repository:write"],
      profileDefinitionId: REF,
      profileReleaseVersion: 1,
      workerDisplayName: "Acme Reviewer",
      executionSelection: {
        schemaVersion: 1,
        workerTypeId: REF,
        workerDisplayName: "Acme Reviewer",
        profileReleaseVersion: 1,
        catalogSource: "profile_catalog",
        modelId: null,
        modelName: null,
        effort: null,
        catalogRevision: DIGEST,
        modelSource: "provider_default",
        effortSource: "provider_default",
        executor,
      },
    },
    selectionExplanation: {},
    executionClass: "stateless_read",
    readOnly: false,
  });
  const fetch = vi.fn(async (_url: string, _init?: RequestInit) =>
    Response.json({}),
  );
  const dispatch = () =>
    dispatchTaskAssignment(
      {
        SYNTILA_DB: f.db,
        SYNTILA_WORKSPACE_GATEWAY: {
          idFromName: () => "WS",
          get: () => ({ fetch }),
        } as unknown as DurableObjectNamespace,
      },
      {
        workspaceId: "WS",
        runId: "RUN",
        taskId: "T",
        task: {
          id: "T",
          spaceId: "P",
          requestedByUserId: "U",
          role: "collaborator",
          objective: "test",
          workRequestId: "R",
          sessionPolicy: "stateless",
        },
      },
    );
  return { ...f, fetch, dispatch };
}

it("admits an entitled plugin assignment and delivers the frozen executor", async () => {
  const f = await fixture();
  const result = await f.dispatch();
  expect(result.accepted).toBe(true);
  const stored = f.sqlite
    .prepare(
      "SELECT worker_type_id AS t, permission_snapshot_json AS s FROM worker_assignments",
    )
    .get() as { t: string; s: string };
  expect(stored.t).toBe(REF);
  expect(JSON.parse(stored.s).executionSelection.executor).toEqual(executor);
  // The same digest travels in the command so the Service can compare.
  const sent = JSON.parse(String(f.fetch.mock.calls[0]?.[1]?.body));
  expect(JSON.stringify(sent)).toContain(DIGEST);
});

it("admits nothing when the plan lapsed after scheduling (atomic with the write)", async () => {
  const f = await fixture();
  // The scheduler already chose the plugin; the plan expires before the INSERT.
  f.sqlite.exec("UPDATE account_plans SET status='canceled' WHERE user_id='U'");
  const result = await f.dispatch();
  expect(result.accepted).toBe(false);
  expect(result.error).toMatch(/Syntila Plus/);
  expect(
    f.sqlite.prepare("SELECT COUNT(*) AS n FROM worker_assignments").get(),
  ).toEqual({ n: 0 });
  expect(f.fetch).not.toHaveBeenCalled();
});

it("does not affect official Workers: they dispatch without any plan row", async () => {
  const f = await fixture();
  f.sqlite.exec("DELETE FROM account_plans WHERE user_id='U'");
  scheduler.selectSpaceExecutionTarget.mockResolvedValue({
    ...(await scheduler.selectSpaceExecutionTarget()),
    workerTypeId: "chatgpt",
    permissionSnapshot: {
      permissions: ["repository:read"],
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
    },
  });
  const result = await f.dispatch();
  expect(result.accepted).toBe(true);
});
