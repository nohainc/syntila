import type { FixtureDb } from "./helpers/fixture-db";
import { pgD1 } from "./helpers/pg-d1";
import { readFileSync } from "node:fs";
import { beforeEach, afterEach, describe, expect, it } from "./helpers/vitest-compat";
import { recordWorkspaceWorkerInventory } from "../../src/domain/workspace-gateway/inventory.js";

describe("inventory scheduling for Workers configured after Workspace selection", () => {
  let sqlite: FixtureDb;
  let env: Parameters<typeof recordWorkspaceWorkerInventory>[0];
  beforeEach(async () => {
    const handle = await pgD1();
    sqlite = handle.sqlite as unknown as FixtureDb;
    await sqlite.exec("PRAGMA foreign_keys = ON");
    for (const migration of [
      "0001_syntila_v8.sql",
      "0018_user_workflow_configurations.sql",
      "0020_space_workflow_configurations.sql",
      "0022_workflow_workspace_selection.sql",
      "0029_worker_model_discovery.sql",
      "0101_worker_plugins.sql",
    ]) {
      await sqlite.exec(
        "" /* D1 migration: schema is final in PostgreSQL */,
      );
    }
    await sqlite.exec(`
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('owner','owner@test','Owner','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('workspace','owner','Workspace','online','now','now'), ('other','owner','Other','online','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('space','owner','Space','now','now');
    `);
    env = {
      SYNTILA_DB: handle.db,
    } as unknown as typeof env;
  });
  afterEach(() => sqlite.close());
  const worker = {
    workerId: "copilot-local",
    workerTypeId: "copilot",
    activationState: "enabled",
    readinessState: "ready",
    localConcurrencyLimit: 1,
    revision: 1,
  };
  const report = (entry = worker) =>
    recordWorkspaceWorkerInventory(env, "workspace", { workers: [entry] });
  const state = async () =>
    (await sqlite
      .prepare(
        "SELECT state FROM worker_scheduling WHERE worker_id='copilot-local'",
      )
      .get())?.state;
  async function select(scope: "user" | "space", workspace = "workspace") {
    await sqlite
      .prepare(
        scope === "user"
          ? "INSERT INTO user_workflow_settings VALUES ('owner', ?, 'now')"
          : "INSERT INTO space_workflow_settings VALUES ('space', ?, 'now')",
      )
      .run(workspace);
  }

  it("enables a newly ready Worker in the Workspace a Space selected", async () => {
    await select("space");
    await report();
    expect(await state()).toBe("enabled");
  });
  it("does not enable Workers from the account-level selection alone", async () => {
    // Only a Space's explicit choice attaches a Workspace.
    await select("user");
    await report();
    expect(await state()).toBe("disabled");
  });
  it("enables a Worker that becomes ready after setup", async () => {
    await select("space");
    await report({ ...worker, readinessState: "setup_required" });
    expect(await state()).toBe("disabled");
    await report({ ...worker, revision: 2 });
    expect(await state()).toBe("enabled");
  });
  it("repairs an existing disabled Worker on an unchanged inventory report", async () => {
    await report();
    expect(await state()).toBe("disabled");
    await select("space");
    await report();
    expect(await state()).toBe("enabled");
  });
  it("does not enable Workers when a different Workspace is selected", async () => {
    await select("space", "other");
    await report();
    expect(await state()).toBe("disabled");
  });
  it("does not enable Workers without a Workspace selection", async () => {
    await report();
    expect(await state()).toBe("disabled");
  });
  it("does not enable a locally disabled Worker", async () => {
    await select("space");
    await report({ ...worker, activationState: "disabled" });
    expect(await state()).toBe("disabled");
  });
  it("preserves draining and Cloud concurrency limits", async () => {
    await select("space");
    await report();
    await sqlite.exec(
      "UPDATE worker_scheduling SET state='draining', cloud_concurrency_limit=2",
    );
    await report({ ...worker, revision: 2 });
    expect(
      await sqlite
        .prepare("SELECT state,cloud_concurrency_limit FROM worker_scheduling")
        .get(),
    ).toEqual({ state: "draining", cloud_concurrency_limit: 2 });
  });
  it("does not trust an older report claiming the Worker is ready", async () => {
    await select("space");
    await report({ ...worker, readinessState: "setup_required", revision: 2 });
    await report();
    expect(await state()).toBe("disabled");
  });
});
