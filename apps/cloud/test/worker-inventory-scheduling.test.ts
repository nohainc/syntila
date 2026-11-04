import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";
import { beforeEach, afterEach, describe, expect, it } from "vitest";
import { recordWorkspaceWorkerInventory } from "../src/workspace-gateway/inventory.js";

describe("inventory scheduling for Workers configured after Workspace selection", () => {
  let sqlite: DatabaseSync;
  let env: Parameters<typeof recordWorkspaceWorkerInventory>[0];
  beforeEach(() => {
    sqlite = new DatabaseSync(":memory:");
    sqlite.exec("PRAGMA foreign_keys = ON");
    for (const migration of [
      "0001_syntila_v8.sql",
      "0018_user_workflow_configurations.sql",
      "0020_space_workflow_configurations.sql",
      "0022_workflow_workspace_selection.sql",
      "0029_worker_model_discovery.sql",
      "0101_worker_plugins.sql",
    ]) {
      sqlite.exec(
        readFileSync(
          new URL(`../migrations-v8/${migration}`, import.meta.url),
          "utf8",
        ),
      );
    }
    sqlite.exec(`
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('owner','owner@test','Owner','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('workspace','owner','Workspace','online','now','now'), ('other','owner','Other','online','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('space','owner','Space','now','now');
    `);
    const statement = (sql: string, values: SQLInputValue[] = []) => ({
      bind: (...bound: SQLInputValue[]) => statement(sql, bound),
      first: async () => sqlite.prepare(sql).get(...values) ?? null,
      run: async () => {
        sqlite.prepare(sql).run(...values);
        return { success: true };
      },
      all: async () => ({ results: sqlite.prepare(sql).all(...values) }),
    });
    env = {
      SYNTILA_DB: { prepare: (sql: string) => statement(sql) },
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
  const state = () =>
    sqlite
      .prepare(
        "SELECT state FROM worker_scheduling WHERE worker_id='copilot-local'",
      )
      .get()?.state;
  function select(scope: "user" | "space", workspace = "workspace") {
    sqlite
      .prepare(
        scope === "user"
          ? "INSERT INTO user_workflow_settings VALUES ('owner', ?, 'now')"
          : "INSERT INTO space_workflow_settings VALUES ('space', ?, 'now')",
      )
      .run(workspace);
  }

  it.each(["user", "space"] as const)(
    "enables a newly ready Worker in the already selected %s Workspace",
    async (scope) => {
      select(scope);
      await report();
      expect(state()).toBe("enabled");
    },
  );
  it("enables a Worker that becomes ready after setup", async () => {
    select("user");
    await report({ ...worker, readinessState: "setup_required" });
    expect(state()).toBe("disabled");
    await report({ ...worker, revision: 2 });
    expect(state()).toBe("enabled");
  });
  it("repairs an existing disabled Worker on an unchanged inventory report", async () => {
    await report();
    expect(state()).toBe("disabled");
    select("user");
    await report();
    expect(state()).toBe("enabled");
  });
  it("does not enable Workers when a different Workspace is selected", async () => {
    select("user", "other");
    await report();
    expect(state()).toBe("disabled");
  });
  it("does not enable Workers without a Workspace selection", async () => {
    await report();
    expect(state()).toBe("disabled");
  });
  it("does not enable a locally disabled Worker", async () => {
    select("user");
    await report({ ...worker, activationState: "disabled" });
    expect(state()).toBe("disabled");
  });
  it("preserves draining and Cloud concurrency limits", async () => {
    select("space");
    await report();
    sqlite.exec(
      "UPDATE worker_scheduling SET state='draining', cloud_concurrency_limit=2",
    );
    await report({ ...worker, revision: 2 });
    expect(
      sqlite
        .prepare("SELECT state,cloud_concurrency_limit FROM worker_scheduling")
        .get(),
    ).toEqual({ state: "draining", cloud_concurrency_limit: 2 });
  });
  it("does not trust an older report claiming the Worker is ready", async () => {
    select("user");
    await report({ ...worker, readinessState: "setup_required", revision: 2 });
    await report();
    expect(state()).toBe("disabled");
  });
});
