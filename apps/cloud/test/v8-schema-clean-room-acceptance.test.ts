import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  fileURLToPath(
    new URL("../migrations-v8/0001_syntila_v8.sql", import.meta.url),
  ),
  "utf8",
);

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${migration}\n${readFileSync(new URL("../migrations-v8/0006_chat_workflow_admission.sql", import.meta.url), "utf8")}\n${sql}`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

describe("v8 clean D1 schema acceptance", () => {
  it("stores Chat alongside historical Direct requests without rewriting snapshots", () => {
    expect(
      apply(`
      PRAGMA foreign_keys = OFF;
      INSERT INTO work_requests (id, thread_id, requested_by_user_id, mode,
        workflow_id, workflow_version, workflow_snapshot_json, status, created_at, updated_at)
      VALUES ('old', 'stream', 'user', 'stateful', 'direct', 1, '{"name":"Direct"}', 'completed', 'now', 'now'),
        ('chat', 'stream', 'user', 'stateless', 'chat', 1, '{"name":"Chat"}', 'queued', 'now', 'now');
      INSERT INTO workflow_tasks (id, work_request_id, step_kind, execution_mode,
        timeout_ms, prompt_profile_version, status, created_at, updated_at)
      VALUES ('chat-step', 'chat', 'chat', 'stateless_read', 900000, 'chat:v1', 'queued', 'now', 'now');
      SELECT workflow_id, workflow_version, workflow_snapshot_json FROM work_requests ORDER BY id;
    `),
    ).toEqual([
      {
        workflow_id: "chat",
        workflow_version: 1,
        workflow_snapshot_json: '{"name":"Chat"}',
      },
      {
        workflow_id: "direct",
        workflow_version: 1,
        workflow_snapshot_json: '{"name":"Direct"}',
      },
    ]);
  });
  it("applies as one migration and includes current Workspace, Work, and Profile tables", () => {
    const tables = apply(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;",
    ) as { name: string }[];
    const tableNames = tables.map(({ name }) => name);
    expect(tableNames).toEqual(
      expect.arrayContaining([
        "users",
        "spaces",
        "space_memberships",
        "execution_workspaces",
        "workspace_space_grants",
        "workspace_releases",
        "worker_scheduling",
        "worker_scheduling_audit",
        "threads",
        "work_requests",
        "worker_assignments",
        "worker_catalog",
        "tool_profile_definitions",
        "tool_profile_releases",
        "tool_profile_channel_pointers",
      ]),
    );
    expect(tableNames).not.toContain("worker_releases");
    expect(tableNames).not.toContain("worker_versions");
    expect(tableNames).not.toContain("credential_profiles");
    expect(tableNames).not.toContain("host_releases");
    expect(tableNames).not.toContain("v7_worker_scheduling");
    expect(tableNames).not.toContain("v7_worker_scheduling_audit");
    expect(tableNames).not.toContain("v7_adapter_releases");
    expect(tableNames).not.toContain("ai_accounts");
    expect(tableNames).not.toContain("host_workspace_bindings");
    expect(tableNames).not.toContain("space_account_grants");
    expect(tableNames).not.toContain("chat_thread_migrations");
    expect(tableNames).not.toContain("workspace_worker_installations");
    expect(tableNames).not.toContain("thread_memberships");
    expect(tableNames).not.toContain("worker_attribution_audit_archive");
    expect(tableNames).not.toContain("run_external_executions");
    expect(tableNames).not.toContain("thread_execution_leases");
    expect(tableNames).not.toContain("thread_integrations");
    expect(tableNames).not.toContain("thread_audit_log");
    expect(tableNames).not.toContain("thread_observability_metrics");
    const grantColumns = apply(
      "PRAGMA table_info(workspace_space_grants);",
    ) as {
      name: string;
    }[];
    expect(grantColumns.map(({ name }) => name)).not.toContain("budget_json");
    expect(grantColumns.map(({ name }) => name)).not.toEqual(
      expect.arrayContaining([
        "scope",
        "repository_mappings_json",
        "path_mappings_json",
        "requires_step_up",
      ]),
    );
    const runtimeIdentityColumns = apply(
      "PRAGMA table_info(workspace_runtime_identities);",
    ) as { name: string; notnull: number }[];
    expect(runtimeIdentityColumns.map(({ name }) => name)).not.toContain(
      "credential_key_ref",
    );
    expect(
      runtimeIdentityColumns.find(
        ({ name }) => name === "credential_token_hash",
      )?.notnull,
    ).toBe(1);
    const policyColumns = apply(
      "PRAGMA table_info(thread_execution_policies);",
    ) as {
      name: string;
    }[];
    expect(policyColumns.map(({ name }) => name)).not.toContain("budget_json");
    expect(policyColumns.map(({ name }) => name)).not.toContain(
      "max_concurrent_work_requests",
    );
    expect(policyColumns.map(({ name }) => name)).not.toContain(
      "allowed_providers_json",
    );
    const assignmentColumns = apply(
      "PRAGMA table_info(worker_assignments);",
    ) as { name: string }[];
    expect(assignmentColumns.map(({ name }) => name)).toContain(
      "worker_type_id",
    );
    expect(assignmentColumns.map(({ name }) => name)).not.toContain(
      "worker_id",
    );
    const runColumns = apply("PRAGMA table_info(runs);") as { name: string }[];
    expect(runColumns.map(({ name }) => name)).not.toContain(
      "execution_lease_id",
    );
    expect(
      apply(
        "SELECT worker_type_id FROM worker_catalog ORDER BY worker_type_id;",
      ),
    ).toEqual([{ worker_type_id: "chatgpt" }, { worker_type_id: "gemini" }]);
  });

  it("enforces Workspace Grant status transitions in the database", () => {
    const activeToSuspended = apply(`
      INSERT INTO workspace_space_grants
        (id, space_id, workspace_id, granted_by_user_id, created_at, updated_at)
      VALUES ('grant-transition', 'space', 'workspace', 'owner', 'now', 'now');
      UPDATE workspace_space_grants SET status = 'suspended'
        WHERE id = 'grant-transition';
      UPDATE workspace_space_grants SET status = 'active'
        WHERE id = 'grant-transition';
      UPDATE workspace_space_grants SET status = 'revoked'
        WHERE id = 'grant-transition';
      SELECT status FROM workspace_space_grants WHERE id = 'grant-transition';
    `) as { status: string }[];
    expect(activeToSuspended).toEqual([{ status: "revoked" }]);
    expect(() =>
      apply(`
        INSERT INTO workspace_space_grants
          (id, space_id, workspace_id, granted_by_user_id, created_at, updated_at)
        VALUES ('grant-terminal', 'space', 'workspace', 'owner', 'now', 'now');
        UPDATE workspace_space_grants SET status = 'revoked'
          WHERE id = 'grant-terminal';
        UPDATE workspace_space_grants SET status = 'active'
          WHERE id = 'grant-terminal';
      `),
    ).toThrow();
  });

  it("keeps the regular development seed to official logical identities", () => {
    const seed = readFileSync(
      fileURLToPath(new URL("../seed/development.sql", import.meta.url)),
      "utf8",
    );
    expect(
      apply(`${seed}
        SELECT (SELECT COUNT(*) FROM worker_catalog) AS workers,
               (SELECT COUNT(*) FROM tool_profile_definitions) AS profiles,
               (SELECT COUNT(*) FROM tool_profile_releases) AS releases,
               (SELECT COUNT(*) FROM execution_workspaces) AS workspaces,
               (SELECT COUNT(*) FROM work_requests) AS work_requests;`),
    ).toEqual([
      { workers: 2, profiles: 2, releases: 0, workspaces: 0, work_requests: 0 },
    ]);
  });

  it("keeps the fixture CLI Worker in a separate development-only seed", () => {
    const seed = readFileSync(
      fileURLToPath(
        new URL("../seed/development-fixtures.sql", import.meta.url),
      ),
      "utf8",
    );
    expect(
      apply(`${seed}
        SELECT worker.worker_type_id, worker.release_stage,
               definition.profile_definition_id, definition.provider_tool_name
          FROM worker_catalog worker
          JOIN tool_profile_definitions definition
            ON definition.worker_type_id = worker.worker_type_id
         WHERE worker.worker_type_id = 'fixture-worker';`),
    ).toEqual([
      {
        worker_type_id: "fixture-worker",
        release_stage: "testing",
        profile_definition_id: "fixture-cli",
        provider_tool_name: "Fixture CLI",
      },
    ]);
    expect(migration).not.toContain("fixture-worker");
  });

  it("accepts a new application-unknown Worker through catalog data", () => {
    expect(
      apply(`
        INSERT INTO worker_catalog (
          worker_type_id, display_name, description, created_at, updated_at,
          engine_family, visibility_state, release_stage, sort_order
        ) VALUES (
          'dynamic-test-worker', 'Dynamic Test Worker',
          'Catalog-created acceptance Worker.', 'now', 'now', 'cli',
          'visible', 'stable', 100
        );
        INSERT INTO tool_profile_definitions (
          profile_definition_id, worker_type_id, display_name,
          provider_tool_name, engine_family, schema_version,
          lifecycle_state, created_at, updated_at
        ) VALUES (
          'dynamic-test-cli', 'dynamic-test-worker', 'Dynamic Test CLI',
          'Fixture CLI', 'cli', 1, 'active', 'now', 'now'
        );
        SELECT worker.worker_type_id, worker.display_name,
               definition.profile_definition_id
          FROM worker_catalog worker
          JOIN tool_profile_definitions definition
            ON definition.worker_type_id = worker.worker_type_id
         WHERE worker.worker_type_id = 'dynamic-test-worker';
      `),
    ).toEqual([
      {
        worker_type_id: "dynamic-test-worker",
        display_name: "Dynamic Test Worker",
        profile_definition_id: "dynamic-test-cli",
      },
    ]);
  });

  it("does not include retired Workspace token pairing tables", () => {
    const tables = apply(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;",
    ) as { name: string }[];
    expect(tables.map(({ name }) => name)).not.toContain(
      "workspace_pairing_intents",
    );
    expect(tables.map(({ name }) => name)).not.toContain(
      "workspace_enrollments",
    );
  });

  it("preserves the synchronized v8 Engine and Profile evidence columns", () => {
    const columns = apply("PRAGMA table_info(workspace_worker_inventory);") as {
      name: string;
    }[];
    const names = columns.map(({ name }) => name);
    expect(names).toEqual(
      expect.arrayContaining([
        "activation_state",
        "readiness_state",
        "engine_version",
        "profile_definition_id",
        "profile_release_version",
        "provider_tool_name",
        "provider_tool_version",
      ]),
    );
    expect(names).not.toContain("worker_runtime_version");
    expect(names).not.toContain("adapter_version");
    expect(names).not.toContain("provider_tool_path");
    expect(names).not.toContain("account_id");
    const workerForeignKey = apply(
      "PRAGMA foreign_key_list(worker_assignments);",
    ) as { from: string; table: string; to: string }[];
    expect(
      workerForeignKey.find(({ from }) => from === "worker_type_id"),
    ).toMatchObject({ table: "worker_catalog", to: "worker_type_id" });
  });
});
