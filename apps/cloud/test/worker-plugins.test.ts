import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../src/auth/identity-service.js";
import {
  PLUGIN_LIBRARY_LIMIT,
  handlePluginLibrary,
  handleWorkspacePluginPin,
} from "../src/routes/worker-plugins.js";
import { pluginManifestDigest } from "../src/plugin-manifest-digest.js";
import { recordWorkspaceWorkerInventory } from "../src/workspace-gateway/inventory.js";
import {
  PluginInventoryExecutorSchema,
  WorkerInventoryPayloadSchema,
  WorkspaceWorkerInventoryEntrySchema,
} from "@syntila/workspace-runtime-protocol";
import type { SecurityEnv } from "../src/routes/http-security.js";

let store: ReturnType<typeof sqliteD1>;
let env: SecurityEnv;

const manifest = (over: Record<string, unknown> = {}) => ({
  schemaVersion: 1,
  kind: "mcp" as const,
  pluginId: "acme-reviewer",
  version: "1.4.2",
  displayName: "Acme Reviewer",
  description: "Reviews code.",
  author: { name: "Acme" },
  protocol: { min: "1.0", max: "1.0" },
  artifacts: {
    "linux-x64": {
      command: "bin/run",
      args: [],
      sha256: "a".repeat(64),
      size: 10,
    },
  },
  capabilities: {},
  access: {
    workRoot: "write",
    network: { mode: "none" },
    subprocess: false,
    env: [],
  },
  ...over,
});

const call = (user: string, path: string, method: string, body?: unknown) =>
  new Request(`https://test${path}`, {
    method,
    headers: { authorization: user, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });

async function register(user: string, m: Record<string, unknown> = manifest()) {
  const digest = await pluginManifestDigest(m as never);
  return handlePluginLibrary(
    call(user, "/api/me/worker-plugins", "POST", {
      manifest: m,
      manifestDigest: digest,
      origin: { kind: "local_path", locator: "pkg" },
    }),
    env,
  );
}

const enable = (
  user: string,
  workspace: string,
  ref: string,
  body: Record<string, unknown>,
) =>
  handleWorkspacePluginPin(
    call(
      user,
      `/api/workspaces/${workspace}/worker-plugins/${ref}`,
      "PUT",
      body,
    ),
    env,
    workspace,
    ref,
  );

beforeEach(() => {
  store = sqliteD1();
  store.sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
      ('plus','p@test','Plus','now','now'),
      ('plus2','p2@test','Plus2','now','now'),
      ('free','f@test','Free','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES
      ('plus','paid','active','manual',NULL,'now','now'),
      ('plus2','paid','active','manual',NULL,'now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES
      ('ws-plus','plus','A','online','now','now'),
      ('ws-plus2','plus2','B','online','now','now'),
      ('ws-free','free','C','online','now','now');`);
  vi.spyOn(identityService, "resolve").mockImplementation(async (req) => {
    const id = req.headers.get("authorization");
    return id
      ? { userId: id, email: `${id}@test`, name: id, sessionId: "t" }
      : null;
  });
  env = {
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
  } as SecurityEnv;
});
afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});

const vectorPath = (name: string) =>
  fileURLToPath(
    new URL(
      `../../../docs/specifications/worker-plugin-vectors/${name}`,
      import.meta.url,
    ),
  );

const mcpVector = () =>
  JSON.parse(readFileSync(vectorPath("manifest-mcp.json"), "utf8")) as Record<
    string,
    unknown
  >;

describe("MCP Workers (manifest kind)", () => {
  it("computes the digest the Workspace computes, and kind is part of it", async () => {
    const expected = readFileSync(
      vectorPath("manifest-mcp.sha256"),
      "utf8",
    ).trim();
    const withKind = mcpVector();
    expect(await pluginManifestDigest(withKind as never)).toBe(expected);
    const { kind: _kind, ...plain } = withKind;
    const plainDigest = await pluginManifestDigest(plain as never);
    // The NDJSON vector pinned in the Dart SDK tests.
    expect(plainDigest).toBe(
      "1bb61d4147ad05e39110b86209fdb9f54dce582f6ffb0d92bbc913a928d49a8d",
    );
    expect(plainDigest).not.toBe(expected);
  });

  it("registers a kind=mcp manifest through the real route", async () => {
    const m = manifest({ kind: "mcp" });
    const response = await register("plus", m);
    expect(response.status).toBe(201);
    const result = (await response.json()) as Record<string, string>;
    expect(result.pluginRef).toMatch(/^plugin-[0-9a-f]{12}$/);
    expect(result.manifestDigest).toBe(await pluginManifestDigest(m as never));
    const { kind: _k, ...withoutKind } = m;
    expect(result.manifestDigest).not.toBe(
      await pluginManifestDigest(withoutKind as never),
    );
  });

  it("rejects any other kind or absent kind", async () => {
    const { kind: _k, ...withoutKind } = manifest();
    await expect(register("plus", withoutKind)).rejects.toMatchObject({
      code: "plugin_manifest_invalid",
    });
    for (const kind of ["ndjson", "MCP", "", 1, null, true]) {
      await expect(register("plus", manifest({ kind }))).rejects.toMatchObject({
        code: "plugin_manifest_invalid",
      });
    }
  });
});

describe("library", () => {
  it("registers a version, allocates an opaque ref and a private catalog row", async () => {
    const response = await register("plus");
    expect(response.status).toBe(201);
    const result = (await response.json()) as Record<string, string>;
    expect(result.pluginRef).toMatch(/^plugin-[0-9a-f]{12}$/);
    expect(result.manifestDigest).toBe(
      await pluginManifestDigest(manifest() as never),
    );
    const catalog = store.sqlite
      .prepare(
        "SELECT origin, owner_user_id, visibility_state FROM worker_catalog WHERE worker_type_id = ?",
      )
      .get(result.pluginRef!) as Record<string, string>;
    expect(catalog).toEqual({
      origin: "plugin",
      owner_user_id: "plus",
      visibility_state: "visible",
    });
  });

  it("is idempotent for the same contents and conflicts for different ones", async () => {
    const first = (await (await register("plus")).json()) as Record<
      string,
      string
    >;
    const again = await register("plus");
    expect(again.status).toBe(200);
    expect(((await again.json()) as Record<string, string>).pluginRef).toBe(
      first.pluginRef,
    );
    await expect(
      register("plus", manifest({ description: "Changed." })),
    ).rejects.toMatchObject({
      status: 409,
      code: "plugin_version_conflict",
    });
  });

  it("recomputes the digest and never trusts the client's", async () => {
    await expect(
      handlePluginLibrary(
        call("plus", "/api/me/worker-plugins", "POST", {
          manifest: manifest(),
          manifestDigest: "f".repeat(64),
          origin: { kind: "local_path", locator: "pkg" },
        }),
        env,
      ),
    ).rejects.toMatchObject({ status: 400, code: "plugin_digest_mismatch" });
  });

  it("rejects invalid manifests, path origins and unknown fields", async () => {
    await expect(
      register("plus", manifest({ extra: 1 })),
    ).rejects.toMatchObject({
      code: "plugin_manifest_invalid",
    });
    const digest = await pluginManifestDigest(manifest() as never);
    for (const origin of [
      { kind: "local_path", locator: "/Users/me/pkg" },
      { kind: "url", locator: "x" },
      { kind: "local_path", locator: "x", path: "/y" },
    ]) {
      await expect(
        handlePluginLibrary(
          call("plus", "/api/me/worker-plugins", "POST", {
            manifest: manifest(),
            manifestDigest: digest,
            origin,
          }),
          env,
        ),
      ).rejects.toMatchObject({ status: 400 });
    }
    await expect(
      handlePluginLibrary(
        call("plus", "/api/me/worker-plugins", "POST", {
          manifest: manifest(),
          manifestDigest: digest,
          origin: { kind: "local_path", locator: "x" },
          extra: true,
        }),
        env,
      ),
    ).rejects.toMatchObject({ status: 400 });
  });

  it("lets a Free account register; Plus is enforced only when used", async () => {
    const response = await register("free");
    expect(response.status).toBe(201);
  });

  it("keeps accounts apart: same plugin ID, different refs, no cross visibility", async () => {
    const a = (await (await register("plus")).json()) as Record<string, string>;
    const b = (await (await register("plus2")).json()) as Record<
      string,
      string
    >;
    expect(a.pluginRef).not.toBe(b.pluginRef);
    const listA = (await (
      await handlePluginLibrary(
        call("plus", "/api/me/worker-plugins", "GET"),
        env,
      )
    ).json()) as { plugins: { pluginRef: string }[] };
    expect(listA.plugins.map((p) => p.pluginRef)).toEqual([a.pluginRef]);
    await expect(
      handlePluginLibrary(
        call("plus2", `/api/me/worker-plugins/${a.pluginRef}`, "DELETE"),
        env,
        a.pluginRef,
      ),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("limits the library size", async () => {
    for (let i = 0; i < PLUGIN_LIBRARY_LIMIT; i += 1) {
      expect(
        (
          await register(
            "plus",
            manifest({
              pluginId: `plugin${i}`.replace(
                /\d/g,
                (d) => "abcdefghij"[Number(d)]!,
              ),
            }),
          )
        ).status,
      ).toBe(201);
    }
    await expect(
      register("plus", manifest({ pluginId: "one-too-many" })),
    ).rejects.toMatchObject({
      status: 409,
      code: "plugin_quota_exceeded",
    });
  });
});

describe("catalog invariants", () => {
  const insert = (id: string, origin: string, owner: string | null) =>
    store.sqlite
      .prepare(
        `INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, origin, owner_user_id)
         VALUES (?, 'X', '', 'active', 'now', 'now', 'cli', 'visible', 'stable', 1, ?, ?)`,
      )
      .run(id, origin, owner);

  it("official rows cannot use the reserved prefix or have an owner", () => {
    expect(() => insert("plugin-abcdef012345", "official", null)).toThrow(
      /invalid worker_catalog origin/,
    );
    expect(() => insert("newofficial", "official", "plus")).toThrow(
      /invalid worker_catalog origin/,
    );
    insert("newofficial", "official", null);
  });

  it("plugin rows need an owner and a plugin-shaped ID", () => {
    expect(() => insert("plugin-abcdef012345", "plugin", null)).toThrow();
    expect(() => insert("plugin-xyz", "plugin", "plus")).toThrow();
    expect(() => insert("chatgpt2", "plugin", "plus")).toThrow();
    insert("plugin-abcdef012345", "plugin", "plus");
  });
});

describe("enablement", () => {
  let ref: string;
  let digest: string;
  beforeEach(async () => {
    ref = ((await (await register("plus")).json()) as Record<string, string>)
      .pluginRef!;
    digest = await pluginManifestDigest(manifest() as never);
  });
  const body = (over: Record<string, unknown> = {}) => ({
    version: "1.4.2",
    manifestDigest: digest,
    consentHash: "c".repeat(64),
    enabled: true,
    shareable: false,
    ...over,
  });

  it("pins a version on the owner's Workspace", async () => {
    const response = await enable("plus", "ws-plus", ref, body());
    expect(response.status).toBe(200);
    const row = store.sqlite
      .prepare(
        "SELECT version, intent, shareable FROM workspace_worker_plugin_enablements WHERE plugin_ref = ?",
      )
      .get(ref!);
    expect(row).toEqual({ version: "1.4.2", intent: "enabled", shareable: 0 });
  });

  it("refuses another account's Workspace and a foreign plugin", async () => {
    await expect(enable("plus2", "ws-plus", ref, body())).rejects.toMatchObject(
      { status: 404 },
    );
    await expect(
      enable("plus2", "ws-plus2", ref, body()),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("binds to the registered digest and version", async () => {
    await expect(
      enable("plus", "ws-plus", ref, body({ manifestDigest: "d".repeat(64) })),
    ).rejects.toMatchObject({ status: 409, code: "plugin_digest_mismatch" });
    await expect(
      enable("plus", "ws-plus", ref, body({ version: "9.9.9" })),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      enable("plus", "ws-plus", ref, { ...body(), extra: 1 }),
    ).rejects.toMatchObject({ status: 400 });
  });

  it("enabling and disabling work on any plan; Plus gates use", async () => {
    await enable("plus", "ws-plus", ref, body());
    store.sqlite.exec(
      "UPDATE account_plans SET status='canceled' WHERE user_id='plus'",
    );
    const on = await enable("plus", "ws-plus", ref, body());
    expect(on.status).toBe(200);
    const off = await enable("plus", "ws-plus", ref, body({ enabled: false }));
    expect(off.status).toBe(200);
    const row = store.sqlite
      .prepare(
        "SELECT intent FROM workspace_worker_plugin_enablements WHERE plugin_ref = ?",
      )
      .get(ref!);
    expect(row).toEqual({ intent: "disabled" });
  });

  it("removal waits for every Workspace to disable it, then retires the catalog row", async () => {
    await enable("plus", "ws-plus", ref, body());
    const remove = () =>
      handlePluginLibrary(
        call("plus", `/api/me/worker-plugins/${ref}`, "DELETE"),
        env,
        ref,
      );
    await expect(remove()).rejects.toMatchObject({
      status: 409,
      code: "plugin_in_use",
    });
    await enable("plus", "ws-plus", ref, body({ enabled: false }));
    expect((await remove()).status).toBe(200);
    expect(
      store.sqlite
        .prepare("SELECT COUNT(*) AS n FROM account_worker_plugins")
        .get(),
    ).toEqual({ n: 0 });
    expect(
      store.sqlite
        .prepare(
          "SELECT lifecycle_state, visibility_state FROM worker_catalog WHERE worker_type_id = ?",
        )
        .get(ref),
    ).toEqual({ lifecycle_state: "retired", visibility_state: "hidden" });
    // The same plugin ID can be registered again and gets a fresh reference.
    const again = (
      (await (await register("plus")).json()) as Record<string, string>
    ).pluginRef;
    expect(again).not.toBe(ref);
  });

  it("removing works for a lapsed owner (free operation)", async () => {
    store.sqlite.exec(
      "UPDATE account_plans SET status='canceled' WHERE user_id='plus'",
    );
    const response = await handlePluginLibrary(
      call("plus", `/api/me/worker-plugins/${ref}`, "DELETE"),
      env,
      ref,
    );
    expect(response.status).toBe(200);
  });
});

describe("inventory ingestion", () => {
  beforeEach(() => {
    // The shared test schema omits the model-catalog column ingestion writes.
    store.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0029_worker_model_discovery.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
  });

  const executor = (over: Record<string, unknown> = {}) => ({
    kind: "plugin",
    pluginId: "acme-reviewer",
    version: "1.4.2",
    manifestDigest: "a".repeat(64),
    artifactDigest: "b".repeat(64),
    pluginProtocol: "1.0",
    isolation: { tier: "none", readOnlyEnforced: false },
    sessionResume: "none",
    shareable: false,
    ...over,
  });
  const entry = (type: string, over: Record<string, unknown> = {}) => ({
    workerId: `w-${type}`,
    workerTypeId: type,
    activationState: "enabled",
    readinessState: "ready",
    engineVersion: "1.4.0",
    profileDefinitionId: null,
    profileReleaseVersion: null,
    providerToolName: "acme-reviewer",
    providerToolVersion: "1.4.2",
    localConcurrencyLimit: 2,
    revision: 1,
    createdAt: "2026-11-03T00:00:00.000Z",
    updatedAt: "2026-11-03T00:00:00.000Z",
    lastSeenAt: "2026-11-03T00:00:00.000Z",
    ...over,
  });
  const record = (workers: unknown[], workspace = "ws-plus") =>
    recordWorkspaceWorkerInventory(env as never, workspace, {
      workers,
      fullSnapshot: true,
    });
  const stored = () =>
    store.sqlite
      .prepare(
        "SELECT worker_type_id AS t, executor_json AS e FROM workspace_worker_inventory ORDER BY worker_id",
      )
      .all() as { t: string; e: string | null }[];

  it("stores a plugin Worker only for the Workspace owner's own plugin", async () => {
    const ref = (
      (await (await register("plus")).json()) as Record<string, string>
    ).pluginRef!;
    await record([entry(ref, { executor: executor() })]);
    expect(stored()).toHaveLength(1);
    expect(JSON.parse(stored()[0]!.e!)).toMatchObject({
      kind: "plugin",
      manifestDigest: "a".repeat(64),
    });
  });

  it("ignores another account's plugin, a ref without an executor, and an official type with one", async () => {
    const ref = (
      (await (await register("plus")).json()) as Record<string, string>
    ).pluginRef!;
    // plus2 owns ws-plus2 and tries to report plus's plugin.
    await record([entry(ref, { executor: executor() })], "ws-plus2");
    expect(stored()).toHaveLength(0);
    // Plugin-shaped type without an executor is not accepted.
    await record([entry(ref)]);
    expect(stored()).toHaveLength(0);
    // An official type may not carry an executor.
    await record([entry("chatgpt", { executor: executor() })]);
    expect(stored()).toHaveLength(0);
  });

  it("rejects a malformed executor", async () => {
    const ref = (
      (await (await register("plus")).json()) as Record<string, string>
    ).pluginRef!;
    await record([entry(ref, { executor: executor({ extra: 1 }) })]);
    await record([
      entry(ref, { executor: executor({ manifestDigest: "xyz" }) }),
    ]);
    expect(stored()).toHaveLength(0);
  });
});

describe("protocol schema", () => {
  it("accepts an executor on a strict inventory entry and rejects unknown keys", () => {
    const base = {
      workerId: "w1",
      workerTypeId: "plugin-3fa91c04b2d7",
      activationState: "enabled",
      readinessState: "ready",
      engineVersion: "1.4.0",
      profileDefinitionId: null,
      profileReleaseVersion: null,
      providerToolName: "acme-reviewer",
      providerToolVersion: "1.4.2",
      localConcurrencyLimit: 1,
      revision: 1,
      createdAt: "2026-11-03T00:00:00.000Z",
      updatedAt: "2026-11-03T00:00:00.000Z",
      lastSeenAt: "2026-11-03T00:00:00.000Z",
    };
    const executor = {
      kind: "plugin",
      pluginId: "acme-reviewer",
      version: "1.4.2",
      manifestDigest: "a".repeat(64),
      artifactDigest: null,
      pluginProtocol: "1.0",
      isolation: { tier: "none", readOnlyEnforced: false },
      sessionResume: "tested",
      shareable: true,
    };
    expect(
      WorkspaceWorkerInventoryEntrySchema.safeParse({ ...base, executor })
        .success,
    ).toBe(true);
    expect(
      PluginInventoryExecutorSchema.safeParse({ ...executor, extra: 1 })
        .success,
    ).toBe(false);
    expect(
      WorkerInventoryPayloadSchema.safeParse({
        workers: [{ ...base, executor }],
        fullSnapshot: true,
      }).success,
    ).toBe(true);
    expect(
      WorkspaceWorkerInventoryEntrySchema.safeParse({ ...base, unknown: true })
        .success,
    ).toBe(false);
  });
});
