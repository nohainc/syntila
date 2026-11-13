import { readFileSync } from "node:fs";
import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { recordWorkspaceWorkerInventory } from "../../src/domain/workspace-gateway/inventory.js";

it("binds catalog ingestion to the current V9 Profile revision and tool version", async () => {
  const { sqlite, db } = sqliteD1();
  try {
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('u','u@test','U','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('ws','u','Workspace','online','now','now');
      INSERT INTO worker_catalog(worker_type_id,display_name,created_at,updated_at) VALUES ('provider','Provider','now','now');`);
    const digest = "a".repeat(64);
    sqlite
      .prepare(
        `INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES ('provider',1,'{"schemaVersion":1}',1,?,'now')`,
      )
      .run(digest);
    const worker = {
      workerId: "worker",
      workerTypeId: "provider",
      activationState: "enabled",
      readinessState: "ready",
      localConcurrencyLimit: 1,
      profileDefinitionId: "profile",
      profileReleaseVersion: 1,
      providerToolVersion: "1.0.0",
    };
    const catalog = {
      schemaVersion: 2,
      profileDigest: digest,
      providerToolVersion: "1.0.0",
      catalogRevision: "b".repeat(64),
      discoveredAt: "2026-10-11T00:00:00.000Z",
      models: [
        {
          id: "model",
          name: "Model",
          status: "listed",
          selectionMode: "separate",
          efforts: ["deep"],
          defaultEffort: null,
        },
      ],
    };
    const publish = (revision: number, modelCatalog: unknown) =>
      recordWorkspaceWorkerInventory({ SYNTILA_DB: db } as never, "ws", {
        workers: [{ ...worker, revision, modelCatalog }],
      });
    const stored = () =>
      sqlite
        .prepare(
          "SELECT model_catalog_json AS catalog FROM workspace_worker_inventory WHERE worker_id = 'worker'",
        )
        .get() as { catalog: string | null };
    await publish(1, catalog);
    expect(JSON.parse(stored().catalog!)).toEqual(catalog);
    await publish(2, { ...catalog, profileDigest: "c".repeat(64) });
    expect(stored().catalog).toBeNull();
    await publish(3, catalog);
    const { catalogRevision: _, ...legacy } = catalog;
    await publish(4, {
      ...legacy,
      schemaVersion: 1,
      models: [{ id: "model", name: "Model", status: "listed" }],
    });
    expect(JSON.parse(stored().catalog!)).toMatchObject({
      schemaVersion: 2,
      stale: true,
      catalogRevision: catalog.catalogRevision,
    });
    await publish(5, { ...catalog, providerToolVersion: "2.0.0" });
    expect(stored().catalog).toBeNull();
    await publish(6, catalog);
    await recordWorkspaceWorkerInventory({ SYNTILA_DB: db } as never, "ws", {
      fullSnapshot: true,
      workers: [
        { ...worker, revision: 7 },
        { ...worker, revision: 8 },
      ],
    });
    expect(JSON.parse(stored().catalog!)).toEqual(catalog);
    sqlite.exec(
      "DELETE FROM worker_profiles WHERE worker_type_id = 'provider'",
    );
    await publish(9, catalog);
    expect(stored().catalog).toBeNull();
  } finally {
    sqlite.close();
  }
});
