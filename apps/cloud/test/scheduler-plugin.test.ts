import { recordWorkspaceWorkerInventory } from "../src/workspace-gateway/inventory.js";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
import { selectSpaceExecutionTarget } from "../src/scheduler.js";
import { validateWorkflowWorkerEligibility } from "../src/routes/thread-policy.js";
import { listWorkerProfiles } from "../src/worker-profile-registry.js";
import { handleListWorkspaceWorkerInventory } from "../src/routes/profiles.js";
import { identityService } from "../src/auth/identity-service.js";
import { vi } from "vitest";

/**
 * Runs the real scheduler SQL against SQLite. The query swallows database
 * errors into "no candidates", so every case here also proves the new joins
 * execute: a typo would turn the happy path into a null result.
 */
let store: ReturnType<typeof sqliteD1>;

const REF = "plugin-3fa91c04b2d7";
const DIGEST = "a".repeat(64);
const executor = (over: Record<string, unknown> = {}) =>
  JSON.stringify({
    kind: "plugin",
    pluginId: "acme-reviewer",
    version: "1.4.2",
    manifestDigest: DIGEST,
    artifactDigest: "b".repeat(64),
    pluginProtocol: "1.0",
    isolation: { tier: "none", readOnlyEnforced: false },
    sessionResume: "none",
    shareable: false,
    ...over,
  });

beforeEach(() => {
  store = sqliteD1();
  for (const migration of [
    "0029_worker_model_discovery.sql",
    "0043_worker_profiles_v9.sql",
    "0047_remove_worker_profile_signatures.sql",
  ]) {
    store.sqlite.exec(
      readFileSync(
        new URL(`../migrations-v8/${migration}`, import.meta.url),
        "utf8",
      ),
    );
  }
  store.sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
      ('U','u@test','Owner','now','now'),
      ('V','v@test','Visitor','now','now'),
      ('X','x@test','Other','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('P','U','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES
      ('m1','P','U','owner','now','now'),('m2','P','V','collaborator','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('WS','U','Workspace','online','now','now');
    INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES ('RT','WS','h','inst','now');
    INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,allowed_permissions_json,created_at,updated_at)
      VALUES ('G','P','WS','U','active','["repository:read","repository:write"]','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES ('U','paid','active','manual',NULL,'now','now');
    INSERT INTO account_worker_plugins(plugin_ref,owner_user_id,plugin_id,display_name,created_at,updated_at) VALUES ('${REF}','U','acme-reviewer','Acme Reviewer','now','now');
    INSERT INTO account_worker_plugin_versions(plugin_ref,version,manifest_digest,manifest_json,origin_json,created_at) VALUES ('${REF}','1.4.2','${DIGEST}','{}','{}','now');
    INSERT INTO worker_catalog(worker_type_id,display_name,description,lifecycle_state,created_at,updated_at,engine_family,visibility_state,release_stage,sort_order,origin,owner_user_id)
      VALUES ('${REF}','Acme Reviewer','','active','now','now','cli','visible','stable',1000,'plugin','U');
    INSERT INTO workspace_worker_plugin_enablements(workspace_id,plugin_ref,version,manifest_digest,consent_hash,intent,shareable,updated_at)
      VALUES ('WS','${REF}','1.4.2','${DIGEST}','${"c".repeat(64)}','enabled',0,'now');
    INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,provider_tool_name,provider_tool_version,local_concurrency_limit,revision,created_at,updated_at,last_seen_at,engine_version,executor_json)
      VALUES ('pw','WS','U','${REF}','enabled','ready','acme-reviewer','1.4.2',2,1,'now','now','now','1.4.0','${executor()}');
    INSERT INTO worker_scheduling(worker_id,state,updated_at) VALUES ('pw','enabled','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('T','P','Work','active','U','now','now');
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,primary_workspace_id,input_json,snapshot_json,created_at,updated_at)
      VALUES ('R','T','U','stateful','direct',2,'{}','running','WS','{}','{"resolvedBindings":{"direct":{"workerId":"pw"}},"stepExecutionConfigs":{"implement":{"schemaVersion":1,"workerId":"pw","profileId":"${REF}","profileReleaseVersion":1,"modelId":null,"effort":null,"workflowId":"direct","workflowVersion":2}}}','now','now');
    INSERT INTO thread_runtime_leases(id,thread_id,work_request_id,workspace_id,fencing_token,status,acquired_at,expires_at)
      VALUES ('L','T','R','WS',1,'active','now','2999-01-01T00:00:00Z');`);
});
afterEach(() => store.sqlite.close());

/** Work: a writable, stateful request bound to the frozen step configuration. */
const work = (over: Record<string, unknown> = {}) =>
  selectSpaceExecutionTarget(
    store.db as unknown as D1Database,
    {
      spaceId: "P",
      requesterUserId: "U",
      role: "implement",
      capabilities: ["repository", "thread_write"],
      executionClass: "stateful_thread",
      threadId: "T",
      workRequestId: "R",
      workBindingId: "direct",
      ...over,
    } as never,
  );

/** Chat / read-only analysis: a stateless request. */
const readOnly = (over: Record<string, unknown> = {}) =>
  selectSpaceExecutionTarget(
    store.db as unknown as D1Database,
    {
      spaceId: "P",
      requesterUserId: "U",
      role: "collaborator",
      capabilities: ["repository"],
      executionClass: "stateless_read",
      ...over,
    } as never,
  );

const run = (sql: string) => store.sqlite.exec(sql);
const enforced = executor({
  isolation: { tier: "enforced", readOnlyEnforced: true },
});

/** The baseline schedules; breaking one rule refuses it; repairing restores it. */
async function expectRefusedThenRestored(
  break_: string,
  restore: string,
  request: () => Promise<unknown> = () => work(),
) {
  expect(await request(), "baseline must schedule").not.toBeNull();
  run(break_);
  expect(await request(), `refused after: ${break_}`).toBeNull();
  run(restore);
  expect(await request(), "restored").not.toBeNull();
}

describe("plugin Worker scheduling (real SQL)", () => {
  it("schedules the owner's entitled, pinned plugin for Work and freezes its identity", async () => {
    const target = await work();
    expect(target).not.toBeNull();
    expect(target!.workerTypeId).toBe(REF);
    expect(target!.executionClass).toBe("stateful_thread");
    expect(target!.readOnly).toBe(false);
    expect(target!.effectivePermissions).toContain("repository:write");
    // A plugin has no Profile; its ref and revision 1 are the stable identity,
    // and the frozen turn configuration must agree with it.
    expect(target!.profileDefinitionId).toBe(REF);
    expect(target!.profileReleaseVersion).toBe(1);
    const selection = target!.permissionSnapshot.executionSelection as Record<
      string,
      unknown
    >;
    expect(selection.executor).toEqual({
      schemaVersion: 1,
      kind: "plugin",
      pluginRef: REF,
      pluginId: "acme-reviewer",
      version: "1.4.2",
      manifestDigest: DIGEST,
      artifactDigest: "b".repeat(64),
      pluginProtocol: "1.0",
      isolation: { tier: "none", readOnlyEnforced: false },
    });
    expect(selection.modelId).toBeNull();
    expect(selection.effort).toBeNull();
    expect(selection.workerDisplayName).toBe("Acme Reviewer");
  });

  it("ingests a pin-bound plugin catalog and schedules only an advertised selected model", async () => {
    const catalog = {
      schemaVersion: 2,
      profileDigest: DIGEST,
      providerToolVersion: "1.4.2",
      discoveredAt: "2026-11-05T00:00:00Z",
      catalogRevision: "e".repeat(64),
      stale: false,
      models: [
        {
          id: "local:8b",
          name: "Local 8B",
          status: "listed",
          selectionMode: "separate",
          efforts: [],
        },
      ],
    };
    const publish = (revision: number, modelCatalog: unknown) =>
      recordWorkspaceWorkerInventory({ SYNTILA_DB: store.db } as never, "WS", {
        workers: [
          {
            workerId: "pw",
            workerTypeId: REF,
            activationState: "enabled",
            readinessState: "ready",
            localConcurrencyLimit: 2,
            revision,
            engineVersion: "1.4.0",
            providerToolVersion: "1.4.2",
            executor: JSON.parse(executor()),
            modelCatalog,
          },
        ],
      });
    await publish(2, catalog);
    const stored = store.sqlite
      .prepare(
        "SELECT model_catalog_json FROM workspace_worker_inventory WHERE worker_id='pw'",
      )
      .get() as { model_catalog_json: string };
    expect(JSON.parse(stored.model_catalog_json).models[0].id).toBe("local:8b");
    run(`UPDATE workspace_worker_inventory SET executor_json='${enforced}'`);
    expect((await readOnly({ model: "local:8b" }))?.model).toBe("local:8b");
    expect(await readOnly({ model: "removed:8b" })).toBeNull();
    await publish(3, { ...catalog, profileDigest: "f".repeat(64) });
    const rejected = store.sqlite
      .prepare(
        "SELECT model_catalog_json FROM workspace_worker_inventory WHERE worker_id='pw'",
      )
      .get() as { model_catalog_json: string | null };
    expect(rejected.model_catalog_json).toBeNull();
  });

  it("stops when the owner's plan lapses, with no event needed", async () => {
    await expectRefusedThenRestored(
      "UPDATE account_plans SET status='canceled' WHERE user_id='U'",
      "UPDATE account_plans SET status='active' WHERE user_id='U'",
    );
    await expectRefusedThenRestored(
      "UPDATE account_plans SET current_period_end='2020-01-01T00:00:00Z' WHERE user_id='U'",
      "UPDATE account_plans SET current_period_end=NULL WHERE user_id='U'",
    );
  });

  it("requires an enabled pin", async () => {
    await expectRefusedThenRestored(
      "UPDATE workspace_worker_plugin_enablements SET intent='disabled'",
      "UPDATE workspace_worker_plugin_enablements SET intent='enabled'",
    );
  });

  it("requires the Service's reported digest and version to equal the pin", async () => {
    await expectRefusedThenRestored(
      `UPDATE workspace_worker_plugin_enablements SET manifest_digest='${"d".repeat(64)}'`,
      `UPDATE workspace_worker_plugin_enablements SET manifest_digest='${DIGEST}'`,
    );
    await expectRefusedThenRestored(
      `UPDATE workspace_worker_inventory SET executor_json='${executor({ version: "9.9.9" })}'`,
      `UPDATE workspace_worker_inventory SET executor_json='${executor()}'`,
    );
    await expectRefusedThenRestored(
      "UPDATE workspace_worker_inventory SET executor_json=NULL",
      `UPDATE workspace_worker_inventory SET executor_json='${executor()}'`,
    );
  });

  it("never runs on an older Engine", async () => {
    await expectRefusedThenRestored(
      "UPDATE workspace_worker_inventory SET engine_version='1.3.1'",
      "UPDATE workspace_worker_inventory SET engine_version='1.4.0'",
    );
  });

  it("refuses a catalog row that does not belong to the Workspace owner", async () => {
    await expectRefusedThenRestored(
      `UPDATE worker_catalog SET owner_user_id='X' WHERE worker_type_id='${REF}'`,
      `UPDATE worker_catalog SET owner_user_id='U' WHERE worker_type_id='${REF}'`,
    );
  });

  it("requires a frozen step configuration that names this plugin identity", async () => {
    // Accepted snapshots are immutable (a trigger enforces it), so a second
    // request carries the mismatched configuration.
    const snapshot = (profileId: string) =>
      JSON.stringify({
        resolvedBindings: { direct: { workerId: "pw" } },
        stepExecutionConfigs: {
          implement: {
            schemaVersion: 1,
            workerId: "pw",
            profileId,
            profileReleaseVersion: 1,
            modelId: null,
            effort: null,
          },
        },
      }).replaceAll("'", "''");
    run(`
      INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('T2','P','Work 2','active','U','now','now');
      INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,primary_workspace_id,input_json,snapshot_json,created_at,updated_at)
        VALUES ('R2','T2','U','stateful','direct',2,'{}','running','WS','{}','${snapshot("plugin-ffffffffffff")}','now','now');
      INSERT INTO thread_runtime_leases(id,thread_id,work_request_id,workspace_id,fencing_token,status,acquired_at,expires_at)
        VALUES ('L2','T2','R2','WS',1,'active','now','2999-01-01T00:00:00Z');`);
    expect(await work()).not.toBeNull();
    expect(await work({ threadId: "T2", workRequestId: "R2" })).toBeNull();
  });

  it("is skipped when not ready or locally disabled, like any Worker", async () => {
    await expectRefusedThenRestored(
      "UPDATE workspace_worker_inventory SET readiness_state='sign_in_required'",
      "UPDATE workspace_worker_inventory SET readiness_state='ready'",
    );
    await expectRefusedThenRestored(
      "UPDATE workspace_worker_inventory SET activation_state='disabled'",
      "UPDATE workspace_worker_inventory SET activation_state='enabled'",
    );
  });

  describe("read-only requests (Chat, Research, Plan, Test, Verify)", () => {
    it("are refused while no isolation tier proved read-only", async () => {
      expect(await readOnly()).toBeNull();
      expect(await readOnly({ readOnly: true })).toBeNull();
    });

    it("are allowed once the host proves read-only enforcement", async () => {
      run(`UPDATE workspace_worker_inventory SET executor_json='${enforced}'`);
      expect(await readOnly()).not.toBeNull();
    });
  });

  it("needs the owner's opt-in before anyone else's request can use it", async () => {
    run(`UPDATE workspace_worker_inventory SET executor_json='${enforced}'`);
    const visitor = () =>
      readOnly({ requesterUserId: "V", role: "collaborator" });
    expect(await readOnly()).not.toBeNull();
    expect(await visitor()).toBeNull();
    run("UPDATE workspace_worker_plugin_enablements SET shareable=1");
    expect(await visitor()).not.toBeNull();
  });
});

describe("workflow eligibility (acceptance) for a plugin Worker", () => {
  const check = () =>
    validateWorkflowWorkerEligibility(
      { SYNTILA_DB: store.db } as never,
      "P",
      "T",
      BUILTIN_WORKFLOW_CATALOG["direct:v2"]!,
      { direct: { workerId: "pw" } } as never,
    );
  const codes = async () => (await check()).issues.map((issue) => issue.code);

  it("accepts a pinned, entitled plugin and freezes its stable identity", async () => {
    const result = await check();
    expect(result.issues).toEqual([]);
    expect(result.workerProfiles.direct).toEqual({
      profileId: REF,
      profileReleaseVersion: 1,
    });
    expect(result.primaryWorkspaceId).toBe("WS");
  });

  it("reports why a plugin cannot be chosen, in plain terms", async () => {
    run("UPDATE account_plans SET status='canceled' WHERE user_id='U'");
    expect(await codes()).toContain("plugin_entitlement_required");
    run("UPDATE account_plans SET status='active' WHERE user_id='U'");
    run("UPDATE workspace_worker_plugin_enablements SET intent='disabled'");
    expect(await codes()).toContain("plugin_not_enabled");
    run("UPDATE workspace_worker_plugin_enablements SET intent='enabled'");
    run(
      `UPDATE workspace_worker_inventory SET executor_json='${executor({ manifestDigest: "d".repeat(64) })}'`,
    );
    expect(await codes()).toContain("plugin_digest_not_pinned");
    run(
      `UPDATE workspace_worker_inventory SET executor_json='${executor()}', engine_version='1.3.1'`,
    );
    expect(await codes()).toContain("worker_engine_update_required");
    run("UPDATE workspace_worker_inventory SET engine_version='1.4.0'");
    expect(await codes()).toEqual([]);
  });
});

describe("plugins stay out of every shared list", () => {
  it("never appears in the shared catalog or Profile administration", async () => {
    const { workers } = await listWorkerProfiles(
      store.db as unknown as D1Database,
    );
    expect(workers.map((worker) => worker.workerTypeId)).not.toContain(REF);
    expect(
      workers.every((worker) => !worker.workerTypeId.startsWith("plugin-")),
    ).toBe(true);
  });

  describe("AX Workers list", () => {
    beforeEach(() => {
      vi.spyOn(identityService, "resolve").mockImplementation(
        async (request) => {
          const id = request.headers.get("authorization");
          return id
            ? { userId: id, email: `${id}@test`, name: id, sessionId: "t" }
            : null;
        },
      );
    });
    afterEach(() => vi.restoreAllMocks());
    const list = async (user: string, query = "") => {
      const response = await handleListWorkspaceWorkerInventory(
        new Request(`https://test/api/workers${query}`, {
          headers: { authorization: user },
        }),
        {
          SYNTILA_DB: store.db,
          BETTER_AUTH_SECRET: "t",
          SYNTILA_ENVIRONMENT: "development",
        } as never,
      );
      return ((await response.json()) as { workers: Record<string, unknown>[] })
        .workers;
    };

    it("shows the owner their plugin Worker with plugin options and an origin badge", async () => {
      const workers = await list("U");
      const plugin = workers.find((worker) => worker.workerTypeId === REF)!;
      expect(plugin.origin).toBe("plugin");
      expect(plugin.displayName).toBe("Acme Reviewer");
      expect(
        (plugin.executionOptions as { models: { supported: boolean } }).models
          .supported,
      ).toBe(false);
    });

    it("shows nobody else's account the plugin", async () => {
      expect(
        (await list("X")).map((worker) => worker.workerTypeId),
      ).not.toContain(REF);
      expect(
        (await list("X", "?includeShared=true")).map(
          (worker) => worker.workerTypeId,
        ),
      ).not.toContain(REF);
    });

    it("shows a Space member the plugin only when its owner opted in to sharing", async () => {
      // The Space runs on the owner's Workspace, so members see its Workers.
      run(
        "INSERT INTO space_workflow_settings(space_id,workspace_id,updated_at) VALUES ('P','WS','now')",
      );
      const member = () => list("V", "?includeShared=true");
      const types = async () =>
        (await member()).map((worker) => worker.workerTypeId);
      expect(await types()).not.toContain(REF);
      run("UPDATE workspace_worker_plugin_enablements SET shareable=1");
      expect(await types()).toContain(REF);
      // Shared views are masked: no machine or provider details.
      const seen = (await member()).find(
        (worker) => worker.workerTypeId === REF,
      )!;
      expect(seen.providerToolName).toBeNull();
      expect(seen.engineVersion).toBeNull();
      expect(seen.shared).toBe(true);
    });
  });
});
