import { readFileSync } from "node:fs";
import { expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleWorkflowConfigurations } from "../../src/domain/routes/workflow-configurations.js";
import { handleWorkflowDefault } from "../../src/domain/routes/workflow-default.js";
import { handleWorkflowWorkspace } from "../../src/domain/routes/workflow-workspace.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
vi.mock("../../src/domain/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId };
  },
}));
vi.mock("../../src/domain/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () =>
    Response.json({
      workers: [
        { id: "worker-a", workspaceId: "A", executionOptions: null },
        { id: "worker-b", workspaceId: "B", executionOptions: null },
      ],
    }),
}));

const configuration = (workflowId: string, worker: string) => ({
  schemaVersion: 1,
  workflowId,
  enabled: true,
  defaults: { worker },
  stepOverrides: {},
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(
    `INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('U','u@test','U','now','now'),('V','v@test','V','now','now');
     INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('A','U','First','now','now'),('B','U','Second','now','now'),('F','V','Foreign','now','now');
     INSERT INTO user_workflow_settings VALUES('U','A','now');`,
  );
  const env = { SYNTILA_DB: db } as SecurityEnv;
  const url = (path: string, workspaceId?: string) =>
    `https://cloud.test/api/user/${path}${workspaceId ? `?workspaceId=${workspaceId}` : ""}`;
  const send = (
    method: string,
    path: string,
    workspaceId?: string,
    body?: unknown,
  ) =>
    new Request(url(path, workspaceId), {
      method,
      headers: { authorization: "U" },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  const configs = async (workspaceId?: string) =>
    (await (
      await handleWorkflowConfigurations(
        send("GET", "workflow-configurations", workspaceId),
        env,
      )
    ).json()) as {
      workspaceId: string | null;
      defaultWorkflowId: string;
      configurations: { workflowId: string }[];
    };
  return { sqlite, db, env, send, configs };
}

it("stores workflow configuration per Workspace and rejects foreign or cross-Workspace choices", async () => {
  const { sqlite, env, send, configs } = fixture();
  try {
    await handleWorkflowConfigurations(
      send(
        "PUT",
        "workflow-configurations/chat",
        "B",
        configuration("chat", "worker-b"),
      ),
      env,
      "chat",
    );
    // The selected Workspace A is untouched; B holds the configuration.
    expect(await configs()).toMatchObject({
      workspaceId: "A",
      configurations: [],
    });
    expect(await configs("B")).toMatchObject({
      workspaceId: "B",
      configurations: [configuration("chat", "worker-b")],
    });
    expect(
      sqlite
        .prepare("SELECT workspace_id FROM user_workflow_configurations")
        .all(),
    ).toEqual([{ workspace_id: "B" }]);
    // A Worker of another Workspace cannot be used.
    await expect(
      handleWorkflowConfigurations(
        send(
          "PUT",
          "workflow-configurations/chat",
          "B",
          configuration("chat", "worker-a"),
        ),
        env,
        "chat",
      ),
    ).rejects.toThrow("outside the selected Workspace");
    // Foreign Workspaces are not addressable.
    await expect(
      handleWorkflowConfigurations(
        send("GET", "workflow-configurations", "F"),
        env,
      ),
    ).rejects.toMatchObject({ status: 404 });
    // Reset only clears the addressed Workspace.
    await handleWorkflowConfigurations(
      send(
        "PUT",
        "workflow-configurations/chat",
        "A",
        configuration("chat", "worker-a"),
      ),
      env,
      "chat",
    );
    await handleWorkflowConfigurations(
      send("DELETE", "workflow-configurations/chat", "B"),
      env,
      "chat",
    );
    expect((await configs("A")).configurations).toHaveLength(1);
    expect((await configs("B")).configurations).toHaveLength(0);
  } finally {
    sqlite.close();
  }
});

it("keeps a default workflow per Workspace and preserves configuration when the selected Workspace changes", async () => {
  const { sqlite, env, send, configs } = fixture();
  try {
    await handleWorkflowConfigurations(
      send(
        "PUT",
        "workflow-configurations/direct",
        "B",
        configuration("direct", "worker-b"),
      ),
      env,
      "direct",
    );
    await handleWorkflowDefault(
      send("PUT", "workflow-default", "B", { defaultWorkflowId: "direct" }),
      env,
    );
    expect((await configs("B")).defaultWorkflowId).toBe("direct");
    expect((await configs("A")).defaultWorkflowId).toBe("chat");
    // Selecting B as the global Workspace is not destructive.
    await handleWorkflowWorkspace(
      send("PUT", "workflow-workspace", undefined, { workspaceId: "B" }),
      env,
    );
    expect(await configs()).toMatchObject({
      workspaceId: "B",
      defaultWorkflowId: "direct",
      configurations: [configuration("direct", "worker-b")],
    });
    // Disabling the default workflow resets only that Workspace's default.
    await handleWorkflowConfigurations(
      send("PUT", "workflow-configurations/direct", "B", {
        ...configuration("direct", "worker-b"),
        enabled: false,
      }),
      env,
      "direct",
    );
    expect((await configs("B")).defaultWorkflowId).toBe("chat");
  } finally {
    sqlite.close();
  }
});
