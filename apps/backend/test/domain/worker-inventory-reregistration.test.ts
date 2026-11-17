import { readFileSync } from "node:fs";
import { expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { recordWorkspaceWorkerInventory } from "../../src/domain/workspace-gateway/inventory.js";
import { atomically } from "../../src/platform/data.js";
import { releasedWorkspaceCleanup } from "../../src/domain/workspace-gateway/release-cleanup.js";

it("deletes a released Workspace's Workers; Worker IDs never change Workspace", async () => {
  const { sqlite, db } = pgD1();
  try {
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('u','u@test','U','now','now'),('o','o@test','O','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES
        ('old','u','Old','online','now','now'),
        ('new','u','New','online','now','now'),
        ('other','o','Other','online','now','now');
      INSERT INTO worker_catalog(worker_type_id,display_name,created_at,updated_at) VALUES ('provider','Provider','now','now');`);
    const worker = {
      workerId: "worker",
      workerTypeId: "provider",
      activationState: "enabled",
      readinessState: "ready",
      localConcurrencyLimit: 1,
      revision: 5,
    };
    const env = { SYNTILA_DB: db } as never;
    const publish = (ws: string) =>
      recordWorkspaceWorkerInventory(env, ws, { workers: [worker] });
    const owner = () =>
      (
        sqlite
          .prepare(
            "SELECT workspace_id AS w FROM workspace_worker_inventory WHERE worker_id = 'worker'",
          )
          .get() as { w: string }
      ).w;
    await publish("old");
    expect(owner()).toBe("old");
    // Worker IDs stay with the Workspace that first synced them.
    await publish("new");
    expect(owner()).toBe("old");
    await publish("other");
    expect(owner()).toBe("old");
    // Releasing deletes the Workspace's Workers.
    await atomically(db, "test.cleanup", (q) => releasedWorkspaceCleanup(q, "old"));
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM workspace_worker_inventory")
        .get(),
    ).toEqual({ n: 0 });
  } finally {
    sqlite.close();
  }
});
