import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  handleListWorkspaceWorkerCatalog,
  handleListWorkspaceWorkerInventory,
  handleListWorkerCatalog,
} from "../../src/domain/routes/profiles.js";

describe("Workspace Worker inventory catalog metadata", () => {
  it("returns Cloud metadata separately from local readiness", async () => {
    const row = {
      worker_id: "workspace-worker-dynamic",
      workspace_id: "workspace-1",
      workspace_name: "Vitalii’s MacBook Pro",
      worker_type_id: "dynamic-test-worker",
      activation_state: "enabled",
      readiness_state: "setup_required",
      readiness_issue_code: "provider_tool_missing",
      capabilities_json: '["text"]',
      local_concurrency_limit: 1,
      engine_version: null,
      profile_definition_id: null,
      profile_release_version: null,
      provider_tool_name: null,
      provider_tool_version: null,
      last_seen_at: "2026-10-02T00:00:00.000Z",
      catalog_display_name: "Dynamic Test Worker",
      catalog_description: "Catalog-created acceptance Worker.",
      catalog_lifecycle_state: "active",
      catalog_visibility_state: "visible",
    };
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({ results: [row] })),
    };
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: { prepare: vi.fn(() => statement) },
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;

    const response = await handleListWorkspaceWorkerInventory(
      new Request("https://syntila.test/api/workers"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<{
        status?: string;
        readinessState: string;
        workspaceName: string;
        displayName: string;
        description: string;
        catalogLifecycleState: string;
        catalogVisibilityState: string;
      }>;
    };

    expect(response.status).toBe(200);
    expect(body.workers[0]).toMatchObject({
      workerTypeId: "dynamic-test-worker",
      workspaceName: "Vitalii’s MacBook Pro",
      displayName: "Dynamic Test Worker",
      description: "Catalog-created acceptance Worker.",
      readinessState: "setup_required",
      catalogLifecycleState: "active",
      catalogVisibilityState: "visible",
    });
    expect(body.workers[0]).not.toHaveProperty("descriptor");

    row.catalog_lifecycle_state = "retired";
    const retiredResponse = await handleListWorkspaceWorkerInventory(
      new Request("https://syntila.test/api/workers"),
      env,
    );
    const retiredBody = (await retiredResponse.json()) as {
      workers: Array<{ catalogLifecycleState: string }>;
    };
    expect(retiredBody.workers[0]?.catalogLifecycleState).toBe("retired");
  });

  it("does not invent model choices from an authoring template", async () => {
    const row = {
      worker_id: "workspace-worker-chatgpt",
      workspace_id: "workspace-1",
      workspace_name: "Workspace",
      worker_type_id: "chatgpt",
      activation_state: "enabled",
      readiness_state: "ready",
      readiness_issue_code: null,
      capabilities_json: '["text","thread_read"]',
      local_concurrency_limit: 1,
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 2,
      provider_tool_name: "Codex CLI",
      provider_tool_version: "0.160.0",
      last_seen_at: "2026-10-02T00:00:00.000Z",
      catalog_display_name: "ChatGPT",
      catalog_description: "",
      catalog_lifecycle_state: "active",
      catalog_visibility_state: "visible",
      model_profile_json: JSON.stringify({
        model: {
          supported: true,
          unknownModelPolicy: "profile_allowlist",
          allowlist: ["gpt-test"],
        },
      }),
      starter_profile_json: JSON.stringify({
        model: {
          supported: true,
          catalog: [{ id: "gpt-test", name: "GPT Test" }],
        },
      }),
    };
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({ results: [row] })),
    };
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: { prepare: vi.fn(() => statement) },
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;

    const response = await handleListWorkspaceWorkerInventory(
      new Request("https://syntila.test/api/workers"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<{ modelOptions: { catalog: Array<{ id: string }> } }>;
    };
    expect(body.workers[0]?.modelOptions.catalog).toEqual([]);
  });

  it("discovers a managed Cloud Worker from the current Profile catalog", async () => {
    const queries: string[] = [];
    const db = {
      prepare: vi.fn((sql: string) => {
        queries.push(sql);
        return {
          bind: vi.fn((..._values: unknown[]) => {
            return {
              first: async () =>
                sql.includes("workspace_runtime_identities")
                  ? { workspaceId: "workspace-1" }
                  : null,
              all: async () => ({
                results: [
                  {
                    worker_type_id: "dynamic-test-worker",
                    display_name: "Dynamic Test Worker",
                    description: "Catalog-created acceptance Worker.",
                    lifecycle_state: "active",
                    engine_family: "cli",
                    visibility_state: "visible",
                    sort_order: 30,
                    current_revision: 4,
                    current_digest: "a".repeat(64),
                    current_updated_at: "2026-10-02T00:00:00.000Z",
                  },
                ],
              }),
            };
          }),
          all: async () => ({
            results: [
              {
                worker_type_id: "dynamic-test-worker",
                display_name: "Dynamic Test Worker",
                description: "Catalog-created acceptance Worker.",
                lifecycle_state: "active",
                engine_family: "cli",
                visibility_state: "visible",
                sort_order: 30,
                current_revision: 4,
                current_digest: "a".repeat(64),
                current_updated_at: "2026-10-02T00:00:00.000Z",
              },
            ],
          }),
        };
      }),
    };
    const env = {
      SYNTILA_DB: db,
    } as unknown as Env;

    const response = await handleListWorkspaceWorkerCatalog(
      new Request(
        "https://syntila.test/api/workspace-runtime/workers/catalog?workspaceRuntimeId=runtime-1",
        {
          headers: { authorization: "Bearer runtime-secret" },
        },
      ),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<Record<string, unknown>>;
    };

    expect(response.status).toBe(200);
    expect(body.workers).toContainEqual(
      expect.objectContaining({
        workerTypeId: "dynamic-test-worker",
        displayName: "Dynamic Test Worker",
        currentRevision: 4,
        currentDigest: "a".repeat(64),
      }),
    );
    const catalogQuery = queries.find((sql) =>
      sql.includes("FROM worker_catalog worker"),
    );
    expect(catalogQuery).toContain("worker.visibility_state");
    expect(catalogQuery).toContain("current_profile.revision");
  });

  it("serves the current Worker catalog through the authenticated human API", async () => {
    const queries: string[] = [];
    const db = {
      prepare: vi.fn((sql: string) => {
        queries.push(sql);
        return {
          bind: vi.fn((..._values: unknown[]) => {
            return {
              all: async () => ({
                results: [
                  {
                    worker_type_id: "dynamic-test-worker",
                    display_name: "Dynamic Test Worker",
                    description: "Catalog-created acceptance Worker.",
                    engine_family: "cli",
                    visibility_state: "visible",
                    lifecycle_state: "active",
                    sort_order: 30,
                    current_revision: 4,
                    current_digest: "a".repeat(64),
                    current_updated_at: "2026-10-02T00:00:00.000Z",
                  },
                ],
              }),
            };
          }),
          all: async () => ({
            results: [
              {
                worker_type_id: "dynamic-test-worker",
                display_name: "Dynamic Test Worker",
                description: "Catalog-created acceptance Worker.",
                lifecycle_state: "active",
                engine_family: "cli",
                visibility_state: "visible",
                sort_order: 30,
                current_revision: 4,
                current_digest: "a".repeat(64),
                current_updated_at: "2026-10-02T00:00:00.000Z",
              },
            ],
          }),
        };
      }),
    };
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;

    const response = await handleListWorkerCatalog(
      new Request("https://syntila.test/api/workers/catalog"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<Record<string, unknown>>;
    };

    expect(response.status).toBe(200);
    expect(body.workers).toContainEqual(
      expect.objectContaining({
        workerTypeId: "dynamic-test-worker",
        displayName: "Dynamic Test Worker",
        currentRevision: 4,
        currentDigest: "a".repeat(64),
      }),
    );
    expect(queries[0]).toContain("FROM worker_catalog worker");
  });
});
