import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  BUILTIN_WORKFLOWS,
  configuredWorkflowDefinition,
  type BuiltinWorkflowDefinition,
} from "@syntila/core";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
import { pgD1 } from "./helpers/pg-d1";
import { member, space, T0, user, workspace } from "./helpers/seed";
const admission = vi.hoisted(() => vi.fn());
vi.mock("../../src/domain/routes/handlers.js", () => ({
  validateWorkflowWorkerEligibility: admission,
}));
import {
  parseWorkflowExecutionSelection,
  resolveWorkflowExecutionBindings,
} from "../../src/domain/routes/workflow-execution-configuration.js";

it("accepts Auto only for transient model and effort overrides", () => {
  expect(
    parseWorkflowExecutionSelection({
      workerId: "b",
      model: "Auto",
      reasoningEffort: "Auto",
    }),
  ).toEqual({ workerId: "b", model: null, reasoningEffort: null });
  expect(() => parseWorkflowExecutionSelection({ workerId: "Auto" })).toThrow(
    "Worker must be selected explicitly",
  );
  expect(() => parseWorkflowExecutionSelection({ model: "Automatic" })).toThrow(
    "Use Auto for model and effort defaults",
  );
});

const testMultiStepDefinition: BuiltinWorkflowDefinition = {
  id: "plan_implement",
  version: 1,
  name: "Multi-Step Test",
  description: "Test workflow with multiple steps",
  steps: [
    {
      id: "implement",
      kind: "implement",
      order: 0,
      executionMode: "stateless_read",
      executionClass: "workspace_action",
      requiredCapabilities: [],
      readWritePolicy: "read_only",
      timeoutMs: 60000,
      promptProfileVersion: "implement:v1",
      dependsOn: [],
      inputsFrom: [],
      resultSemantics: "thread_changes",
    },
    {
      id: "verify",
      kind: "verify",
      order: 1,
      executionMode: "stateless_read",
      executionClass: "analysis",
      requiredCapabilities: [],
      readWritePolicy: "read_only",
      timeoutMs: 60000,
      promptProfileVersion: "verify:v1",
      dependsOn: [],
      inputsFrom: [],
      resultSemantics: "verification_report",
    },
  ],
};

function fixture(
  defaults: object = {},
  stepOverrides: object = {},
  spaceDefaults?: object,
  workspaceId = (defaults as { worker?: string }).worker === "a"
    ? "first"
    : "second",
) {
  const { db, sqlite } = pgD1();
  const inventory = (worker: string, ws: string) =>
    `INSERT INTO workspace_worker_inventory (
       worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
       local_concurrency_limit, revision, created_at, updated_at, last_seen_at
     ) VALUES ('${worker}', '${ws}', 'user', 'chatgpt-codex', 'enabled', 'ready', 1, 1, '${T0}', '${T0}', '${T0}');`;
  sqlite.exec(
    user("user") +
      user("another-member") +
      space("space", "user") +
      member("space", "user", "owner") +
      member("space", "another-member", "collaborator") +
      workspace("first", "user") +
      workspace("second", "user") +
      inventory("a", "first") +
      inventory("b", "second") +
      `INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at) VALUES ('space', '${workspaceId}', '${T0}');`,
  );
  const configuration = {
    schemaVersion: 1,
    workflowId: "plan_implement",
    enabled: true,
    defaults,
    stepOverrides,
  };
  /**
   * Stores the configuration as the Space owner's own setting for the Space's
   * Workspace; Space defaults, when given, replace it as a Space-wide row.
   * Tests change `configuration` after creation, so it is saved on every resolve.
   */
  const save = () => {
    sqlite.exec(
      "DELETE FROM user_workflow_configurations; DELETE FROM space_workflow_configurations;",
    );
    const insert = (table: string, keys: string, json: object) =>
      sqlite
        .prepare(
          `INSERT INTO ${table} (${keys}, workflow_id, schema_version, configuration_json, updated_at) VALUES (${keys.split(",").map(() => "?").join(",")}, ?, 1, ?, '${T0}')`,
        )
        .run(
          ...(table === "space_workflow_configurations" ? ["space"] : ["user", workspaceId]),
          configuration.workflowId,
          JSON.stringify(json),
        );
    insert("user_workflow_configurations", "user_id,workspace_id", configuration);
    if (spaceDefaults)
      insert("space_workflow_configurations", "space_id", { ...configuration, defaults: spaceDefaults });
  };
  const env = { SYNTILA_DB: db } as unknown as SecurityEnv;
  const resolve = (
    requester = "user",
    threadId = "thread",
    definition = testMultiStepDefinition,
    executionSelection?: unknown,
  ) => {
    save();
    return resolveWorkflowExecutionBindings(
      env,
      requester,
      "space",
      threadId,
      definition,
      {},
      [],
      executionSelection,
    );
  };
  admission.mockImplementation(
    async (_env, _space, _thread, definition, bindings) => {
      const binding = Object.values(bindings)[0] as { workerId: string };
      const supports =
        binding.workerId === "b" || definition.steps[0].kind === "implement";
      return {
        issues: supports ? [] : [{ message: "Unsupported capability" }],
        primaryWorkspaceId: binding.workerId === "b" ? "second" : "first",
        workerProfiles: {},
        workerCatalogRevisions: {},
      };
    },
  );
  return { configuration, resolve };
}
it("uses the explicitly configured Worker across the whole workflow", async () => {
  const f = fixture(
    { worker: "b", model: "model", effort: "medium" },
    { verify: { effort: "high" } },
  );
  expect(await f.resolve()).toEqual({
    implement: { workerId: "b", model: "model", reasoningEffort: "medium" },
    verify: { workerId: "b", model: "model", reasoningEffort: "high" },
  });
});
it("retains an explicit Worker and fails admission without silently choosing another", async () => {
  const f = fixture({ worker: "a" });
  await expect(f.resolve()).rejects.toMatchObject({
    status: 422,
    message: "Unsupported capability",
  });
});
it("rejects a saved Worker missing from current user ownership", async () => {
  const f = fixture({ worker: "foreign" });
  await expect(f.resolve()).rejects.toMatchObject({ status: 422 });
});
it("rejects disabled workflows before admission", async () => {
  const f = fixture();
  f.configuration.enabled = false;
  admission.mockClear();
  await expect(f.resolve()).rejects.toMatchObject({ status: 422 });
  expect(admission).not.toHaveBeenCalled();
});

it("uses shared Space defaults for every requester and Thread rather than each requester's globals", async () => {
  const f = fixture(
    { model: "global-model" },
    {},
    { worker: "b", model: "space-model", effort: "high" },
  );
  const owner = await f.resolve();
  expect(owner).toEqual({
    implement: { workerId: "b", model: "space-model", reasoningEffort: "high" },
    verify: { workerId: "b", model: "space-model", reasoningEffort: "high" },
  });
  expect(await f.resolve("another-member", "another-thread")).toEqual(owner);
  f.configuration.defaults = { model: "changed-global-model" };
  expect(await f.resolve("another-member", "another-thread")).toEqual(owner);
});

it("requires an explicit Worker and does not fall back to another Workspace", async () => {
  await expect(
    fixture({}, {}, undefined, "first").resolve(),
  ).rejects.toMatchObject({
    status: 422,
    message: expect.stringContaining("Select a Worker"),
  });
  await expect(
    fixture({ worker: "b" }, {}, undefined, "first").resolve(),
  ).rejects.toMatchObject({ status: 422 });
});

it("accepts observed catalog revisions on transient selections", () => {
  expect(
    parseWorkflowExecutionSelection({
      workerId: "worker",
      catalogRevision: "a".repeat(64),
    }),
  ).toEqual({ workerId: "worker", catalogRevision: "a".repeat(64) });
  expect(() =>
    parseWorkflowExecutionSelection({ catalogRevision: "Auto" }),
  ).toThrow("catalogRevision is invalid");
});

it("revalidates inherited preferences and pins current revisions without rewriting settings", async () => {
  const oldRevision = "a".repeat(64);
  const currentRevision = "b".repeat(64);
  const f = fixture(
    {
      worker: "b",
      model: "model",
      effort: "medium",
      catalogRevision: oldRevision,
    },
    { verify: { effort: "high", catalogRevision: oldRevision } },
  );
  admission.mockImplementation(
    async (_env, _space, _thread, _definition, bindings) => {
      const binding = Object.values(bindings)[0] as {
        catalogRevision?: string;
      };
      expect(binding.catalogRevision).toBeUndefined();
      return {
        issues: [],
        primaryWorkspaceId: "second",
        workerProfiles: {},
        workerCatalogRevisions: {
          implement: currentRevision,
          verify: currentRevision,
        },
      };
    },
  );
  expect(await f.resolve()).toEqual({
    implement: {
      workerId: "b",
      model: "model",
      reasoningEffort: "medium",
      catalogRevision: currentRevision,
    },
    verify: {
      workerId: "b",
      model: "model",
      reasoningEffort: "high",
      catalogRevision: currentRevision,
    },
  });
  expect(f.configuration.defaults).toHaveProperty(
    "catalogRevision",
    oldRevision,
  );
  expect(f.configuration.stepOverrides).toHaveProperty(
    "verify.catalogRevision",
    oldRevision,
  );
});

it("revalidates restored composer choices against current capabilities", async () => {
  const f = fixture({ worker: "b" });
  f.configuration.workflowId = "chat";
  admission.mockImplementation(
    async (_env, _space, _thread, _definition, bindings) => {
      expect(bindings.chat).toEqual({
        workerId: "b",
        model: "model",
        reasoningEffort: "high",
      });
      return {
        issues: [],
        primaryWorkspaceId: "second",
        workerProfiles: {},
        workerCatalogRevisions: { chat: "b".repeat(64) },
      };
    },
  );
  expect(
    await f.resolve("user", "thread", BUILTIN_WORKFLOWS.chat, {
      workerId: "b",
      model: "model",
      reasoningEffort: "high",
      catalogRevision: "a".repeat(64),
    }),
  ).toEqual({
    chat: {
      workerId: "b",
      model: "model",
      reasoningEffort: "high",
      catalogRevision: "b".repeat(64),
    },
  });
});

describe("Research v2 role configuration at acceptance", () => {
  function researchFixture(
    defaults: object,
    stepOverrides: object,
    researcherCount = 2,
  ) {
    const f = fixture(defaults, stepOverrides);
    Object.assign(f.configuration, {
      schemaVersion: 2,
      workflowId: "research",
      researcherCount,
    });
    // Each Worker reports its catalog; "b" offers two models.
    admission.mockImplementation(
      async (_env, _space, _thread, _definition, bindings) => {
        const [id, binding] = Object.entries(bindings)[0] as [
          string,
          { workerId: string },
        ];
        return {
          issues: [],
          primaryWorkspaceId: "second",
          workerProfiles: {},
          workerCatalogRevisions: {},
          workerModelCatalogs:
            binding.workerId === "b"
              ? { [id]: { models: ["model-a", "model-b", "model-c"] } }
              : {},
        };
      },
    );
    const definition = configuredWorkflowDefinition(
      BUILTIN_WORKFLOWS.research,
      f.configuration,
    );
    return { ...f, definition };
  }

  it("freezes a Worker, model and effort per role, inheriting Space defaults", async () => {
    const f = researchFixture(
      { worker: "b", effort: "medium" },
      {
        "research-1": { model: "model-a" },
        "research-2": { model: "model-b", effort: "high" },
        synthesis: { model: "model-a" },
      },
    );
    expect(f.definition.steps.map((s) => s.id)).toEqual([
      "research-1",
      "research-2",
      "synthesis",
    ]);
    expect(await f.resolve("user", "thread", f.definition)).toEqual({
      "research-1": {
        workerId: "b",
        model: "model-a",
        reasoningEffort: "medium",
      },
      "research-2": {
        workerId: "b",
        model: "model-b",
        reasoningEffort: "high",
      },
      // Synthesis may reuse a researcher's model (it runs in its own session).
      synthesis: { workerId: "b", model: "model-a", reasoningEffort: "medium" },
    });
  });

  it("uses the configured researcher count", async () => {
    const f = researchFixture(
      { worker: "b" },
      {
        "research-1": { model: "model-a" },
        "research-2": { model: "model-b" },
        "research-3": { model: "model-c" },
      },
      3,
    );
    expect(
      Object.keys(await f.resolve("user", "thread", f.definition)),
    ).toEqual(["research-1", "research-2", "research-3", "synthesis"]);
  });

  it.each([
    [
      "the same model",
      {
        "research-1": { model: "model-a" },
        "research-2": { model: "MODEL-A", effort: "high" },
      },
      /same model as Researcher 1/,
    ],
    ["Auto", { "research-1": { model: "model-a" } }, /Auto cannot prove/],
    [
      "an unavailable model",
      { "research-1": { model: "model-a" }, "research-2": { model: "gone" } },
      /not offered by the selected Worker/,
    ],
  ])(
    "rejects %s before acceptance, without substituting",
    async (_case, overrides, message) => {
      const f = researchFixture({ worker: "b" }, overrides);
      await expect(
        f.resolve("user", "thread", f.definition),
      ).rejects.toMatchObject({
        status: 422,
        code: "research_configuration_invalid",
        message: expect.stringMatching(message),
      });
    },
  );
});
