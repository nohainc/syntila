import { pgD1 } from "./helpers/pg-d1";
import { T0, user, workspace } from "./helpers/seed";
import { beforeEach, describe, expect, it } from "./helpers/vitest-compat";
import { hashToken } from "@syntila/security";
import {
  handleListWorkspaceWorkerCatalog,
  handleListWorkspaceWorkerInventory,
  handleListWorkerCatalog,
} from "../../src/domain/routes/profiles.js";

const LAST_SEEN = "2026-10-02T00:00:00.000Z";
const DIGEST = "a".repeat(64);

describe("Workspace Worker inventory catalog metadata", () => {
  let handle: Awaited<ReturnType<typeof pgD1>>;
  let env: Env;

  const inventory = (o: {
    id: string;
    type: string;
    readiness: string;
    issue?: string;
    profile?: { definition: string; release: number; tool: string; version: string };
    engineVersion?: string;
  }) =>
    handle.sqlite
      .prepare(
        `INSERT INTO workspace_worker_inventory (
           worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
           readiness_issue_code, local_concurrency_limit, engine_version, profile_definition_id,
           profile_release_version, provider_tool_name, provider_tool_version,
           revision, created_at, updated_at, last_seen_at
         ) VALUES (?, 'workspace-1', 'user-1', ?, 'enabled', ?, ?, 1, ?, ?, ?, ?, ?, 1, ?, ?, ?)`,
      )
      .run(
        o.id,
        o.type,
        o.readiness,
        o.issue ?? null,
        o.engineVersion ?? null,
        o.profile?.definition ?? null,
        o.profile?.release ?? null,
        o.profile?.tool ?? null,
        o.profile?.version ?? null,
        T0,
        T0,
        LAST_SEEN,
      );

  const dynamicWorker = (revision: number) =>
    handle.sqlite.exec(
      `INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, sort_order, created_at, updated_at)
         VALUES ('dynamic-test-worker', 'Dynamic Test Worker', 'Catalog-created acceptance Worker.', 'active', 30, '${T0}', '${T0}');
       INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at)
         VALUES ('dynamic-test-worker', 1, '{"schemaVersion":1}', ${revision}, '${DIGEST}', '${LAST_SEEN}');`,
    );

  beforeEach(async () => {
    handle = await pgD1();
    await handle.sqlite.exec(
      user("user-1") + workspace("workspace-1", "user-1", "Vitalii’s MacBook Pro"),
    );
    env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: handle.db,
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;
  });

  it("returns Cloud metadata separately from local readiness", async () => {
    await handle.sqlite.exec(
      `INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at)
       VALUES ('dynamic-test-worker', 'Dynamic Test Worker', 'Catalog-created acceptance Worker.', 'active', '${T0}', '${T0}');`,
    );
    await inventory({
      id: "workspace-worker-dynamic",
      type: "dynamic-test-worker",
      readiness: "setup_required",
      issue: "provider_tool_missing",
    });

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

    await handle.sqlite.exec(
      "UPDATE worker_catalog SET lifecycle_state = 'retired' WHERE worker_type_id = 'dynamic-test-worker'",
    );
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
    // The stored Profile allows one model but lists no catalog of choices.
    const profile = JSON.stringify({
      schemaVersion: 1,
      model: {
        supported: true,
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["gpt-test"],
      },
    });
    await handle.sqlite
      .prepare(
        `INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at)
         VALUES ('chatgpt', 1, ?, 2, ?, ?)
         ON CONFLICT (worker_type_id) DO UPDATE
           SET profile_json = excluded.profile_json, revision = 2, digest = excluded.digest`,
      )
      .run(profile, DIGEST, LAST_SEEN);
    await inventory({
      id: "workspace-worker-chatgpt",
      type: "chatgpt",
      readiness: "ready",
      engineVersion: "1.0.0",
      profile: { definition: "chatgpt-codex", release: 2, tool: "Codex CLI", version: "0.160.0" },
    });

    const response = await handleListWorkspaceWorkerInventory(
      new Request("https://syntila.test/api/workers"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<{ modelOptions: { catalog: Array<{ id: string }> } }>;
    };
    expect(response.status).toBe(200);
    expect(body.workers[0]?.modelOptions.catalog).toEqual([]);
  });

  it("discovers a managed Cloud Worker from the current Profile catalog", async () => {
    await dynamicWorker(4);
    await handle.sqlite
      .prepare(
        `INSERT INTO workspace_runtime_identities (id, workspace_id, installation_id, credential_token_hash, created_at)
         VALUES ('runtime-1', 'workspace-1', 'installation-1', ?, now())`,
      )
      .run(await hashToken("runtime-secret"));

    const response = await handleListWorkspaceWorkerCatalog(
      new Request(
        "https://syntila.test/api/workspace-runtime/workers/catalog?workspaceRuntimeId=runtime-1",
        { headers: { authorization: "Bearer runtime-secret" } },
      ),
      { SYNTILA_DB: handle.db } as unknown as Env,
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
        currentDigest: DIGEST,
      }),
    );

    // The same route refuses a wrong credential.
    await expect(
      handleListWorkspaceWorkerCatalog(
        new Request(
          "https://syntila.test/api/workspace-runtime/workers/catalog?workspaceRuntimeId=runtime-1",
          { headers: { authorization: "Bearer wrong" } },
        ),
        { SYNTILA_DB: handle.db } as unknown as Env,
      ),
    ).rejects.toMatchObject({ status: 401 });
  });

  it("serves the current Worker catalog through the authenticated human API", async () => {
    await dynamicWorker(4);

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
        currentDigest: DIGEST,
      }),
    );
  });
});
