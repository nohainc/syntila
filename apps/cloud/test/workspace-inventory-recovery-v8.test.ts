import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { WorkspaceGateway } from "../src/workspace-gateway.js";

class LocalD1Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}

  bind(...values: unknown[]): LocalD1Statement {
    return new LocalD1Statement(this.db, this.sql, values);
  }

  async first<T>(): Promise<T | null> {
    return (
      (this.db.prepare(this.sql).get(...(this.values as SQLInputValue[])) as
        T | undefined) ?? null
    );
  }

  async run(): Promise<{ success: true }> {
    this.db.prepare(this.sql).run(...(this.values as SQLInputValue[]));
    return { success: true };
  }

  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }
}

class LocalD1 {
  constructor(private readonly db: DatabaseSync) {}

  prepare(sql: string): LocalD1Statement {
    return new LocalD1Statement(this.db, sql);
  }
}

describe("v8 Workspace inventory recovery", () => {
  it("reconciles duplicate snapshots, omissions, reconnects, and foreign Worker IDs", async () => {
    const database = new DatabaseSync(":memory:");
    database.exec("PRAGMA foreign_keys = ON");
    database.exec(
      readFileSync(
        fileURLToPath(
          new URL("../migrations-v8/0001_syntila_v8.sql", import.meta.url),
        ),
        "utf8",
      ),
    );
    for (const migration of [
      "0018_user_workflow_configurations.sql",
      "0020_space_workflow_configurations.sql",
      "0022_workflow_workspace_selection.sql",
    ]) {
      database.exec(
        readFileSync(
          new URL(`../migrations-v8/${migration}`, import.meta.url),
          "utf8",
        ),
      );
    }
    database.exec(
      readFileSync(
        fileURLToPath(
          new URL(
            "../migrations-v8/0029_worker_model_discovery.sql",
            import.meta.url,
          ),
        ),
        "utf8",
      ),
    );
    // Inventory ingestion now also writes the plugin executor column.
    database.exec(
      readFileSync(
        new URL("../migrations-v8/0101_worker_plugins.sql", import.meta.url),
        "utf8",
      ),
    );
    database.exec(`
      INSERT INTO users (id, email, display_name, created_at, updated_at)
        VALUES ('owner-a', 'a@example.test', 'Owner A', '2026-01-01', '2026-01-01');
      INSERT INTO users (id, email, display_name, created_at, updated_at)
        VALUES ('owner-b', 'b@example.test', 'Owner B', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-a', 'owner-a', 'Workspace A', 'online', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-b', 'owner-b', 'Workspace B', 'online', '2026-01-01', '2026-01-01');
    `);

    const gateway = new WorkspaceGateway(
      {} as never,
      { SYNTILA_DB: new LocalD1(database) } as never,
    );
    const internal = gateway as unknown as {
      executionWorkspaceId: string;
      recordWorkerInventory(payload: unknown): Promise<void>;
    };
    internal.executionWorkspaceId = "workspace-a";

    const worker = {
      workerId: "worker-shared-id",
      workerTypeId: "chatgpt",
      activationState: "enabled",
      readinessState: "ready",
      revision: 1,
      localConcurrencyLimit: 1,
      engineVersion: "1.0.0",
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
      providerToolName: "Codex CLI",
      providerToolVersion: "1.0.0",
      capabilities: ["code"],
      createdAt: "2026-01-01T00:00:00.000Z",
      lastSeenAt: "2026-01-01T00:00:00.000Z",
    };

    const fullSnapshot = (workers: unknown[]) =>
      internal.recordWorkerInventory({ fullSnapshot: true, workers });
    await fullSnapshot([worker]);
    await fullSnapshot([worker]);
    expect(
      database
        .prepare(
          `SELECT workspace_id, activation_state, readiness_state,
                  engine_version, profile_definition_id, profile_release_version,
                  provider_tool_name, provider_tool_version, capabilities_json, revision
             FROM workspace_worker_inventory WHERE worker_id = ?`,
        )
        .get(worker.workerId),
    ).toMatchObject({
      workspace_id: "workspace-a",
      activation_state: "enabled",
      readiness_state: "ready",
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 3,
      provider_tool_name: "Codex CLI",
      provider_tool_version: "1.0.0",
      // Legacy Worker capability metadata is ignored by inventory writes.
      capabilities_json: "[]",
      revision: 1,
    });

    await internal.recordWorkerInventory({
      fullSnapshot: false,
      workers: [
        {
          ...worker,
          workerId: "worker-needs-setup",
          readinessState: "setup_required",
          readinessIssueCode: "setup_required",
        },
      ],
    });
    expect(
      database
        .prepare(
          `SELECT activation_state, readiness_state, readiness_issue_code
             FROM workspace_worker_inventory WHERE worker_id = ?`,
        )
        .get("worker-needs-setup"),
    ).toMatchObject({
      activation_state: "enabled",
      readiness_state: "setup_required",
      readiness_issue_code: "setup_required",
    });
    database
      .prepare(
        `INSERT INTO worker_scheduling_audit
           (id, worker_id, action, requested_at)
         VALUES ('audit-unready', 'worker-needs-setup', 'disabled', '2026-01-01')`,
      )
      .run();

    await fullSnapshot([worker]);
    await fullSnapshot([worker]);
    expect(
      database
        .prepare("SELECT COUNT(*) AS count FROM workspace_worker_inventory")
        .get(),
    ).toMatchObject({ count: 1 });
    expect(
      database
        .prepare("SELECT COUNT(*) AS count FROM worker_scheduling_audit")
        .get(),
    ).toMatchObject({ count: 0 });

    // Reconnecting recreates a deleted slot with Cloud scheduling disabled.
    await fullSnapshot([]);
    expect(
      database
        .prepare("SELECT COUNT(*) AS count FROM workspace_worker_inventory")
        .get(),
    ).toMatchObject({ count: 0 });
    await fullSnapshot([worker]);
    expect(
      database
        .prepare(
          `SELECT activation_state, revision FROM workspace_worker_inventory
            WHERE worker_id = ?`,
        )
        .get(worker.workerId),
    ).toMatchObject({ activation_state: "enabled", revision: 1 });
    expect(
      database
        .prepare("SELECT state FROM worker_scheduling WHERE worker_id = ?")
        .get(worker.workerId),
    ).toMatchObject({ state: "disabled" });

    // A different Workspace cannot claim an existing logical Worker ID.
    internal.executionWorkspaceId = "workspace-b";
    await fullSnapshot([{ ...worker, revision: 99 }]);
    expect(
      database
        .prepare(
          `SELECT workspace_id, revision FROM workspace_worker_inventory
            WHERE worker_id = ?`,
        )
        .get(worker.workerId),
    ).toMatchObject({ workspace_id: "workspace-a", revision: 1 });

    internal.executionWorkspaceId = "workspace-a";
    await fullSnapshot([{ ...worker, revision: Number.NaN }]);
    expect(
      database
        .prepare(
          "SELECT worker_id FROM workspace_worker_inventory WHERE worker_id = ?",
        )
        .get(worker.workerId),
    ).toBeUndefined();
    database.close();
  });
  it("stores the Workspace-wide parallel slot total and ignores invalid values", async () => {
    const database = new DatabaseSync(":memory:");
    database.exec("PRAGMA foreign_keys = ON");
    for (const migration of [
      "0001_syntila_v8.sql",
      "0018_user_workflow_configurations.sql",
      "0020_space_workflow_configurations.sql",
      "0022_workflow_workspace_selection.sql",
      "0029_worker_model_discovery.sql",
      "0070_workspace_parallel_slots.sql",
      "0071_assignment_engine_liveness.sql",
      "0101_worker_plugins.sql",
    ]) {
      database.exec(
        readFileSync(
          fileURLToPath(
            new URL(`../migrations-v8/${migration}`, import.meta.url),
          ),
          "utf8",
        ),
      );
    }
    database.exec(`
      INSERT INTO users (id, email, display_name, created_at, updated_at)
        VALUES ('owner-a', 'a@example.test', 'Owner A', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-a', 'owner-a', 'Workspace A', 'online', '2026-01-01', '2026-01-01');
    `);
    const gateway = new WorkspaceGateway(
      {} as never,
      { SYNTILA_DB: new LocalD1(database) } as never,
    );
    const internal = gateway as unknown as {
      executionWorkspaceId: string;
      recordWorkerInventory(payload: unknown): Promise<void>;
    };
    internal.executionWorkspaceId = "workspace-a";
    const slots = () =>
      (
        database
          .prepare(
            "SELECT parallel_slots FROM execution_workspaces WHERE id = 'workspace-a'",
          )
          .get() as { parallel_slots: number | null }
      ).parallel_slots;

    // An older Service omits the field: Cloud keeps the per-Worker fallback.
    await internal.recordWorkerInventory({ fullSnapshot: true, workers: [] });
    expect(slots()).toBeNull();
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      parallelSlots: 5,
      workers: [],
    });
    expect(slots()).toBe(5);
    // Cloud owns slots once set (the web Workspaces page): a Service's
    // reported value only seeds an unset Workspace and never overrides it.
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      parallelSlots: 3,
      workers: [],
    });
    expect(slots()).toBe(5);
    for (const invalid of [0, 1025, 2.5, "7", null]) {
      await internal.recordWorkerInventory({
        fullSnapshot: true,
        parallelSlots: invalid,
        workers: [],
      });
      expect(slots()).toBe(5);
    }
    database.close();
  });
});
