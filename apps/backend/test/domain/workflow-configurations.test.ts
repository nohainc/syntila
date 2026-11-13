import { expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleWorkflowConfigurations } from "../../src/domain/routes/workflow-configurations.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
vi.mock("../../src/domain/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId };
  },
}));
const inventory = vi.hoisted(() => ({
  workers: [{ id: "offline", workspaceId: "ws", executionOptions: null }] as {
    id: string;
    workspaceId: string;
    executionOptions: import("@syntila/core").WorkerExecutionOptions | null;
  }[],
}));
vi.mock("../../src/domain/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () => Response.json(inventory),
}));
it("persists only user overrides, isolates users, retains offline choices, resets and rejects foreign writes", async () => {
  const { sqlite, db } = sqliteD1();
  try {
    sqlite.exec(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('U','u@test','U','now','now'),('V','v@test','V','now','now')",
    );
    sqlite.exec(
      "INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('ws','U','Workspace','now','now'); INSERT INTO user_workflow_settings VALUES('U','ws','now');",
    );
    const env = { SYNTILA_DB: db } as SecurityEnv;
    const configuration = {
      schemaVersion: 1,
      workflowId: "chat",
      enabled: true,
      defaults: { worker: "offline" },
      stepOverrides: {},
    };
    const request = (method: string, user = "U", body?: unknown) =>
      new Request("https://cloud.test/api/user/workflow-configurations/chat", {
        method,
        headers: user ? { authorization: user } : {},
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
    await expect(
      handleWorkflowConfigurations(request("GET", ""), env),
    ).rejects.toThrow("Unauthenticated");
    await handleWorkflowConfigurations(
      request("PUT", "U", configuration),
      env,
      "chat",
    );
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([configuration]);
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET", "V"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([]);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "foreign" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("not owned");
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "offline", model: "invented" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("execution options");
    await handleWorkflowConfigurations(
      request("PUT", "U", { ...configuration, enabled: true }),
      env,
      "chat",
    );
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE", "V"), env, "chat");
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE"), env, "chat");
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(0);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          enabled: true,
          defaults: { worker: "Auto" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("Worker must be selected explicitly");
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(0);
    inventory.workers.push({
      id: "elsewhere",
      workspaceId: "other",
      executionOptions: null,
    });
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "elsewhere" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("outside the selected Workspace");
    inventory.workers.push({
      id: "capable",
      workspaceId: "ws",
      executionOptions: {
        schemaVersion: 1,
        models: {
          supported: true,
          discovery: "profile_catalog",
          allowsCustomModel: false,
          allowedModelIds: ["m"],
          defaultModelId: null,
          options: [
            {
              id: "m",
              name: "Model",
              effort: { supported: true, values: ["low"], defaultValue: null },
            },
          ],
        },
        modelSwitch: { supported: true },
        effort: { supported: false, values: [], defaultValue: null },
      },
    });
    inventory.workers.push({
      ...inventory.workers.find((w) => w.id === "capable")!,
      id: "elsewhere-capable",
      workspaceId: "other",
      executionOptions: {
        ...inventory.workers.find((w) => w.id === "capable")!.executionOptions!,
        schemaVersion: 1,
        models: {
          ...inventory.workers.find((w) => w.id === "capable")!
            .executionOptions!.models,
          allowedModelIds: ["elsewhere-model"],
          options: [
            {
              id: "elsewhere-model",
              name: "Elsewhere model",
              effort: {
                supported: true,
                values: ["elsewhere-effort"],
                defaultValue: null,
              },
            },
          ],
        },
      },
    });
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: {
            worker: "capable",
            model: "elsewhere-model",
            effort: "elsewhere-effort",
          },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected model is not available");
    const choices = {
      ...configuration,
      defaults: { worker: "capable", model: "m", effort: "low" },
    };
    await handleWorkflowConfigurations(
      request("PUT", "U", choices),
      env,
      "chat",
    );
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...choices,
          defaults: { ...choices.defaults, effort: "high" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected effort");
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...choices,
          defaults: { ...choices.defaults, model: "invented" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected model");
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...choices,
        defaults: { worker: "capable", model: "m", effort: "low" },
      }),
      env,
      "chat",
    );
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        defaults: { worker: "capable", model: "m" },
        stepOverrides: { chat: { effort: "low" } },
      }),
      env,
      "chat",
    );
    // Existing global/Space preferences may carry a previously observed revision.
    const capable = inventory.workers.find(
      (worker) => worker.id === "capable",
    )!;
    capable.executionOptions = {
      ...capable.executionOptions!,
      schemaVersion: 2,
      catalogRevision: "b".repeat(64),
      models: {
        ...capable.executionOptions!.models,
        options: [
          {
            id: "m",
            name: "Renamed model",
            selectionMode: "separate",
            status: "verified",
            efforts: ["low", "high"],
            defaultEffort: "low",
          },
        ],
      },
    };
    const observed = {
      ...configuration,
      defaults: {
        worker: "capable",
        model: "m",
        catalogRevision: "a".repeat(64),
      },
      stepOverrides: { chat: { effort: "low" } },
    };
    const saved = await handleWorkflowConfigurations(
      request("PUT", "U", observed),
      env,
      "chat",
    );
    expect(await saved.json()).toEqual({ configuration: observed });
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...observed,
          stepOverrides: { chat: { effort: "removed" } },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected effort");
    capable.executionOptions = {
      ...capable.executionOptions,
      catalogStale: true,
    };
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...observed,
          stepOverrides: { chat: { effort: "high" } },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("stale");
    // Restore the unchanged-unavailable fixture below.
    await handleWorkflowConfigurations(
      request("PUT", "U", observed),
      env,
      "chat",
    );
    capable.executionOptions = {
      ...capable.executionOptions,
      catalogStale: false,
    };
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        defaults: { worker: "capable", model: "m" },
        stepOverrides: { chat: { effort: "low" } },
      }),
      env,
      "chat",
    );
    inventory.workers.find(
      (worker) => worker.id === "capable",
    )!.executionOptions = null;
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        defaults: { worker: "capable", model: "m" },
        stepOverrides: {},
      }),
      env,
      "chat",
    );
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "capable", model: "invented" },
          stepOverrides: {},
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("execution options");
    await handleWorkflowConfigurations(request("DELETE"), env, "chat");
  } finally {
    sqlite.close();
  }
});
