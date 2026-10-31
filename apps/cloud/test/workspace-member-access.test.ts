import { describe, expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
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
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  validateWorkflowWorkerEligibility: async () => ({
    issues: [],
    primaryWorkspaceId: "workspace",
    workerCatalogRevisions: {},
  }),
}));
import {
  handleWorkspaceMemberAccess,
  memberModeError,
  memberSelectionError,
  parseWorkspaceMemberAccessPolicy,
} from "../src/routes/workspace-member-access.js";
import { resolveWorkflowExecutionBindings } from "../src/routes/workflow-execution-configuration.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','o@test','O','now','now'),('member','m@test','M','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('o','P','owner','owner','now','now'),('m','P','member','collaborator','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','owner','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','owner','Workspace','now','now'),('other','member','Other','now','now');
    INSERT INTO user_workflow_settings VALUES('owner','workspace','now');
    INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at)
      VALUES('worker-a','workspace','owner','chatgpt','enabled','ready',1,1,'now','now','now'),('worker-b','workspace','owner','gemini','enabled','ready',1,1,'now','now','now');
    INSERT INTO user_workflow_configurations(user_id,workspace_id,workflow_id,schema_version,configuration_json,updated_at)
      VALUES('owner','workspace','direct',1,'{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a","model":"fast","effort":"low"},"stepOverrides":{}}','now');`);
  const env = { SYNTILA_DB: db } as SecurityEnv;
  const call = (
    method: string,
    user: string,
    workspaceId: string,
    body?: unknown,
  ) =>
    handleWorkspaceMemberAccess(
      new Request(
        `https://cloud.test/api/workspaces/${workspaceId}/member-access`,
        {
          method,
          headers: { authorization: user },
          ...(body ? { body: JSON.stringify(body) } : {}),
        },
      ),
      env,
      workspaceId,
    );
  const bind = (userId: string, executionSelection?: Record<string, unknown>) =>
    resolveWorkflowExecutionBindings(
      env,
      userId,
      "P",
      "W",
      BUILTIN_WORKFLOW_CATALOG.direct_v2 ??
        Object.values(BUILTIN_WORKFLOW_CATALOG)
          .filter((entry) => entry.id === "direct")
          .sort((a, b) => b.version - a.version)[0]!,
      {},
      [],
      executionSelection,
    );
  return { sqlite, env, call, bind };
}

describe("memberSelectionError", () => {
  const policy = parseWorkspaceMemberAccessPolicy({
    workers: {
      "worker-a": { models: ["fast"], efforts: ["low", "medium"] },
      "worker-c": { models: null, efforts: null },
    },
  });
  it("applies only when a policy exists and requires every restricted dimension", () => {
    expect(memberSelectionError(null, { worker: "any" })).toBeNull();
    expect(memberSelectionError(policy, { worker: "worker-b" })).toMatch(
      /not shared/,
    );
    expect(
      memberSelectionError(policy, {
        worker: "worker-a",
        model: "fast",
        effort: "low",
      }),
    ).toBeNull();
    expect(
      memberSelectionError(policy, { worker: "worker-a", effort: "low" }),
    ).toMatch(/models/);
    expect(
      memberSelectionError(policy, {
        worker: "worker-a",
        model: "fast",
        effort: "high",
      }),
    ).toMatch(/efforts/);
    // Unrestricted lists share everything, including Auto.
    expect(memberSelectionError(policy, { worker: "worker-c" })).toBeNull();

    const modelEffortPolicy = parseWorkspaceMemberAccessPolicy({
      workers: {
        "worker-m": {
          models: ["model-1", "model-2"],
          efforts: null,
          modelEfforts: {
            "model-1": ["low"],
            "model-2": ["high"],
          },
        },
      },
    });
    expect(
      memberSelectionError(modelEffortPolicy, {
        worker: "worker-m",
        model: "model-1",
        effort: "low",
      }),
    ).toBeNull();
    expect(
      memberSelectionError(modelEffortPolicy, {
        worker: "worker-m",
        model: "model-1",
        effort: "high",
      }),
    ).toMatch(/efforts/);
    expect(
      memberSelectionError(modelEffortPolicy, {
        worker: "worker-m",
        model: "model-2",
        effort: "high",
      }),
    ).toBeNull();
    expect(
      memberSelectionError(modelEffortPolicy, {
        worker: "worker-m",
        model: "model-2",
        effort: "low",
      }),
    ).toMatch(/efforts/);
  });
  it("rejects malformed policies", () => {
    expect(() => parseWorkspaceMemberAccessPolicy({})).toThrow();
    expect(() =>
      parseWorkspaceMemberAccessPolicy({ workers: { a: { models: "fast" } } }),
    ).toThrow();
    expect(() =>
      parseWorkspaceMemberAccessPolicy({ workers: { a: { extra: [] } } }),
    ).toThrow();
  });
});

it("lets only the Workspace owner manage member access and validates Workers", async () => {
  const { sqlite, call } = fixture();
  try {
    expect(await (await call("GET", "owner", "workspace")).json()).toEqual({
      restricted: false,
      policy: null,
    });
    await expect(call("GET", "member", "workspace")).rejects.toMatchObject({
      status: 404,
    });
    await expect(
      call("PUT", "member", "workspace", { restricted: false }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      call("PUT", "owner", "workspace", {
        restricted: true,
        workers: { stranger: { models: null, efforts: null } },
      }),
    ).rejects.toMatchObject({ status: 400 });
    await call("PUT", "owner", "workspace", {
      restricted: true,
      workers: { "worker-a": { models: ["fast"], efforts: null } },
    });
    expect(await (await call("GET", "owner", "workspace")).json()).toEqual({
      restricted: true,
      policy: {
        schemaVersion: 1,
        workers: { "worker-a": { models: ["fast"], efforts: null } },
      },
    });
    await call("PUT", "owner", "workspace", { restricted: false });
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM workspace_member_access").get(),
    ).toEqual({ n: 0 });
  } finally {
    sqlite.close();
  }
});

it("restricts members, not the owner, when Work resolves its Worker, model and effort", async () => {
  const { sqlite, call, bind } = fixture();
  try {
    // No policy: members use the configured selection.
    expect((await bind("member")).direct).toMatchObject({
      workerId: "worker-a",
    });
    await call("PUT", "owner", "workspace", {
      restricted: true,
      workers: { "worker-a": { models: ["fast"], efforts: ["low"] } },
    });
    // Configured selection is shared, so it still works for both.
    expect((await bind("member")).direct).toMatchObject({
      workerId: "worker-a",
      model: "fast",
      reasoningEffort: "low",
    });
    // A Worker, model or effort outside the share is rejected for members...
    await expect(
      bind("member", { workerId: "worker-b" }),
    ).rejects.toMatchObject({ status: 403 });
    await expect(bind("member", { model: "slow" })).rejects.toMatchObject({
      status: 403,
    });
    await expect(
      bind("member", { reasoningEffort: "high" }),
    ).rejects.toMatchObject({ status: 403 });
    // ...but never for the Workspace owner.
    expect(
      (await bind("owner", { workerId: "worker-b", model: "slow" })).direct,
    ).toMatchObject({ workerId: "worker-b", model: "slow" });
  } finally {
    sqlite.close();
  }
});

it("lets a per-person override replace the default and enforces the mode ceiling", async () => {
  const { sqlite, env, call, bind } = fixture();
  const person = (method: string, user: string, id: string, body?: unknown) =>
    handleWorkspaceMemberAccess(
      new Request(
        `https://cloud.test/api/workspaces/workspace/member-access/people/${id}`,
        {
          method,
          headers: { authorization: user },
          ...(body ? { body: JSON.stringify(body) } : {}),
        },
      ),
      env,
      "workspace",
      undefined,
      id,
    );
  try {
    const all = { models: null, efforts: null };
    // Default policy: chat only. On the owner's own Workspace, Space Work
    // permission takes precedence, so the default mode does not cap Work.
    await call("PUT", "owner", "workspace", {
      restricted: true,
      mode: "chat",
      workers: { "worker-a": all },
    });
    expect((await bind("member")).direct).toMatchObject({
      workerId: "worker-a",
    });
    // Only the owner manages overrides.
    await expect(
      person("PUT", "member", "member", { mode: "work", workers: {} }),
    ).rejects.toMatchObject({ status: 404 });
    // A per-person override enforces the mode ceiling.
    await person("PUT", "owner", "member", {
      mode: "chat",
      workers: { "worker-a": all },
    });
    await expect(bind("member")).rejects.toMatchObject({ status: 403 });
    // An override replaces the default (no merge) and lifts the ceiling.
    await person("PUT", "owner", "member", {
      mode: "work",
      workers: { "worker-a": all },
    });
    expect((await bind("member")).direct).toMatchObject({
      workerId: "worker-a",
    });
    expect(await (await person("GET", "owner", "member")).json()).toMatchObject(
      { custom: true, policy: { mode: "work" } },
    );
    // An override that drops the Worker blocks it even though the default lists it.
    await person("PUT", "owner", "member", {
      mode: "work",
      workers: { "worker-b": all },
    });
    await expect(bind("member")).rejects.toMatchObject({ status: 403 });
    // Reset returns the person to the default (where default mode does not cap Work).
    expect(
      await (await person("DELETE", "owner", "member")).json(),
    ).toMatchObject({ custom: false, policy: { mode: "chat" } });
    expect((await bind("member")).direct).toMatchObject({
      workerId: "worker-a",
    });
    // Invalid input and unknown people are rejected; the owner is never restricted.
    await expect(
      person("PUT", "owner", "member", { mode: "root", workers: {} }),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      person("PUT", "owner", "ghost", { workers: {} }),
    ).rejects.toMatchObject({ status: 404 });
    expect((await bind("owner")).direct).toBeDefined();
  } finally {
    sqlite.close();
  }
});

it("blocks commands in work mode but allows them in work+shell", () => {
  const policy = (mode?: "chat" | "work" | "work+shell") =>
    parseWorkspaceMemberAccessPolicy({ workers: {}, mode });
  expect(memberModeError(null, ["test_execution"])).toBeNull();
  expect(memberModeError(policy(), ["test_execution"])).toBeNull();
  expect(memberModeError(policy("chat"), ["thread_write"])).toMatch(/chat/);
  expect(memberModeError(policy("chat"), ["read"])).toBeNull();
  expect(memberModeError(policy("work"), ["thread_write"])).toBeNull();
  expect(memberModeError(policy("work"), ["test_execution"])).toMatch(
    /commands/,
  );
  expect(memberModeError(policy("work+shell"), ["test_execution"])).toBeNull();
});

describe("shared Worker inventory", () => {
  async function inventory(
    f: ReturnType<typeof fixture>,
    user: string,
    shared = true,
  ) {
    const { handleListWorkspaceWorkerInventory } =
      await import("../src/routes/profiles.js");
    const response = await handleListWorkspaceWorkerInventory(
      new Request(
        `https://cloud.test/api/workers${shared ? "?includeShared=true" : ""}`,
        { headers: { authorization: user } },
      ),
      f.env,
    );
    return (
      (await response.json()) as {
        workers: { id: string; providerToolName: string | null }[];
      }
    ).workers;
  }
  const ids = (workers: { id: string }[]) => workers.map((w) => w.id).sort();

  it("shows members the Workers their Space's Workspace shares, filtered and masked", async () => {
    const f = fixture();
    try {
      // The shared test schema omits the Profile tables the inventory joins.
      f.sqlite
        .exec(`CREATE TABLE worker_profiles(worker_type_id TEXT, revision INTEGER, profile_json TEXT, digest TEXT);
        CREATE TABLE worker_profile_history(worker_type_id TEXT, revision INTEGER, profile_json TEXT, digest TEXT);
        ALTER TABLE workspace_worker_inventory ADD COLUMN model_catalog_json TEXT;
        UPDATE workspace_worker_inventory SET provider_tool_name='codex';`);
      // Only clients that ask for shared Workers receive them.
      expect(ids(await inventory(f, "member", false))).toEqual([]);
      // No policy: every Worker of the Workspace is available to members.
      const open = await inventory(f, "member");
      expect(ids(open)).toEqual(["worker-a", "worker-b"]);
      expect(open.every((worker) => worker.providerToolName === null)).toBe(
        true,
      );
      // The owner still sees their own Workers unmasked.
      const own = await inventory(f, "owner");
      expect(ids(own)).toEqual(["worker-a", "worker-b"]);
      expect(own[0]!.providerToolName).toBe("codex");
      // A restricted Workspace shares only the Workers it lists.
      await f.call("PUT", "owner", "workspace", {
        restricted: true,
        workers: { "worker-a": { models: null, efforts: null } },
      });
      expect(ids(await inventory(f, "member"))).toEqual(["worker-a"]);
      expect(ids(await inventory(f, "owner"))).toEqual([
        "worker-a",
        "worker-b",
      ]);
      // People outside the Space see nothing.
      f.sqlite.exec(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('stranger','s@test','S','now','now')",
      );
      expect(ids(await inventory(f, "stranger"))).toEqual([]);
      // A Space with its own Workspace shares that one instead.
      f.sqlite.exec(
        "INSERT INTO space_workflow_settings VALUES('P','other','now')",
      );
      expect(ids(await inventory(f, "member"))).toEqual([]);
    } finally {
      f.sqlite.close();
    }
  });

  it("limits visible models and efforts to the shared ones", async () => {
    const { restrictExecutionOptions } =
      await import("../src/routes/workspace-member-access.js");
    const options = {
      schemaVersion: 2,
      catalogRevision: "r",
      modelSwitch: { supported: true },
      effort: { supported: true, values: ["low", "high"], defaultValue: "low" },
      models: {
        supported: true,
        discovery: "profile_catalog",
        allowsCustomModel: true,
        allowedModelIds: ["fast", "slow"],
        defaultModelId: "slow",
        options: [
          {
            id: "fast",
            name: "Fast",
            efforts: ["low", "high"],
            defaultEffort: "high",
            selectionMode: "separate",
            status: "listed",
          },
          {
            id: "slow",
            name: "Slow",
            efforts: ["high"],
            defaultEffort: "high",
            selectionMode: "separate",
            status: "listed",
          },
        ],
      },
    };
    const restricted = restrictExecutionOptions(options, {
      models: ["fast"],
      efforts: ["low"],
    });
    expect(restricted.models.options).toEqual([
      expect.objectContaining({
        id: "fast",
        efforts: ["low"],
        defaultEffort: null,
      }),
    ]);
    expect(restricted.models.allowedModelIds).toEqual(["fast"]);
    expect(restricted.models.defaultModelId).toBeNull();
    expect(restricted.models.allowsCustomModel).toBe(false);
    expect(restricted.effort.values).toEqual(["low"]);

    const restrictedByModelEfforts = restrictExecutionOptions(options, {
      models: ["fast", "slow"],
      efforts: null,
      modelEfforts: {
        fast: ["low"],
        slow: ["high"],
      },
    });
    expect(restrictedByModelEfforts.models.options).toEqual([
      expect.objectContaining({
        id: "fast",
        efforts: ["low"],
      }),
      expect.objectContaining({
        id: "slow",
        efforts: ["high"],
      }),
    ]);

    // Sharing everything leaves the options as they were.
    const all = restrictExecutionOptions(options, {
      models: null,
      efforts: null,
    });
    expect(all.models.options).toEqual(options.models.options);
    expect(all.models.allowsCustomModel).toBe(true);
    expect(
      restrictExecutionOptions(null, { models: null, efforts: null }),
    ).toBe(null);
  });
});
