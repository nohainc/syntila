import { readFileSync } from "node:fs";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { hashToken } from "@syntila/security";
import { canonicalJson } from "../src/canonical-json.js";
import { handleGetWorkspaceV9WorkerProfile } from "../src/routes/profile-admin.js";
import { validateWorkerProfileCandidate } from "../src/worker-profile-registry.js";

describe("Workspace Profile download before Worker configuration", () => {
  let sqlite: DatabaseSync;
  let env: Env;
  let digest: string;

  beforeEach(async () => {
    sqlite = new DatabaseSync(":memory:");
    // Only the read boundary's tables are needed. In particular, inventory
    // exists but stays empty, as on a newly connected Workspace.
    sqlite.exec(`
      CREATE TABLE execution_workspaces (id TEXT PRIMARY KEY, status TEXT);
      CREATE TABLE workspace_runtime_identities (
        id TEXT PRIMARY KEY, workspace_id TEXT, installation_id TEXT,
        credential_token_hash TEXT, revoked_at TEXT
      );
      CREATE TABLE workspace_worker_inventory (workspace_id TEXT, worker_type_id TEXT, worker_id TEXT);
      CREATE TABLE worker_catalog (worker_type_id TEXT PRIMARY KEY, origin TEXT NOT NULL DEFAULT 'official');
      CREATE TABLE worker_profiles (
        worker_type_id TEXT PRIMARY KEY, schema_version INTEGER,
        profile_json TEXT, revision INTEGER, digest TEXT,
        updated_by_user_id TEXT, updated_at TEXT
      );
      INSERT INTO execution_workspaces VALUES ('workspace', 'online');
      INSERT INTO worker_catalog (worker_type_id) VALUES ('fixture-worker');
    `);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities VALUES (?, ?, ?, ?, NULL)",
      )
      .run(
        "runtime",
        "workspace",
        "installation",
        await hashToken("credential"),
      );
    const profile = JSON.parse(
      readFileSync(
        new URL(
          "../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    profile.logicalWorkerTypeId = "fixture-worker";
    const validated = await validateWorkerProfileCandidate(
      "fixture-worker",
      profile,
    );
    digest = validated.digest;
    sqlite
      .prepare("INSERT INTO worker_profiles VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run(
        "fixture-worker",
        1,
        canonicalJson(validated.profile),
        1,
        digest,
        null,
        "2026-10-23T00:00:00Z",
      );
    const db = {
      prepare(sql: string) {
        return {
          bind(...values: SQLInputValue[]) {
            return {
              first: async () => sqlite.prepare(sql).get(...values) ?? null,
            };
          },
        };
      },
    };
    env = { SYNTILA_DB: db } as unknown as Env;
  });

  afterEach(() => sqlite.close());

  function download({
    token = "credential",
    runtimeId = "runtime",
    workerTypeId = "fixture-worker",
  } = {}) {
    return handleGetWorkspaceV9WorkerProfile(
      new Request(
        `https://syntila.test/api/workers/${workerTypeId}/profile?workspaceRuntimeId=${runtimeId}`,
        {
          headers: token ? { authorization: `Bearer ${token}` } : {},
        },
      ),
      env,
      workerTypeId,
    );
  }

  it("downloads a published Profile with no configured Worker or inventory row", async () => {
    const response = await download();
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      workerTypeId: "fixture-worker",
      revision: 1,
      digest,
    });
    expect(
      sqlite
        .prepare("SELECT count(*) AS count FROM workspace_worker_inventory")
        .get()?.count,
    ).toBe(0);
  });

  it.each([
    { token: "" },
    { token: "wrong" },
    { runtimeId: "unknown" },
    { runtimeId: "" },
  ])("rejects missing or invalid runtime credentials: %j", async (options) => {
    await expect(download(options)).rejects.toMatchObject({ status: 401 });
  });

  it.each(["runtime", "workspace"])("rejects a revoked %s", async (kind) => {
    sqlite.exec(
      kind === "runtime"
        ? "UPDATE workspace_runtime_identities SET revoked_at = 'now'"
        : "UPDATE execution_workspaces SET status = 'revoked'",
    );
    await expect(download()).rejects.toMatchObject({ status: 401 });
  });

  it("still rejects unknown Workers and unpublished Profiles", async () => {
    await expect(download({ workerTypeId: "unknown" })).rejects.toMatchObject({
      status: 404,
    });
    sqlite.exec("DELETE FROM worker_profiles");
    await expect(download()).rejects.toMatchObject({
      status: 404,
      message: "The Worker does not have a published Profile",
    });
  });

  it("still rejects a corrupt published Profile", async () => {
    sqlite.exec(`UPDATE worker_profiles SET digest = '${"0".repeat(64)}'`);
    await expect(download()).rejects.toMatchObject({ status: 409 });
  });
});
