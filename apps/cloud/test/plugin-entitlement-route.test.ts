import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handlePluginEntitlementLease } from "../src/routes/plugin-entitlement.js";
import {
  ENTITLEMENT_TRUST_PUBLISHER,
  verifyPluginEntitlementLease,
} from "../src/plugin-entitlement-lease.js";
import { generateEd25519ReleaseKeyPair } from "../src/release-trust.js";
import { WorkspaceRuntimeAuthenticator } from "../src/workspace-gateway/runtime-authenticator.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

const keys = generateEd25519ReleaseKeyPair();
let store: ReturnType<typeof sqliteD1>;
let runtime: { workspaceId: string; installationId: string | null };

const request = (init: RequestInit = { method: "POST" }, query = "r1") =>
  new Request(
    `https://test/api/workspace-runtime/worker-plugins/entitlement?workspaceRuntimeId=${query}`,
    { headers: { authorization: "Bearer token" }, ...init },
  );
const envWith = (extra: Record<string, string> = {}) =>
  ({
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_ENTITLEMENT_SIGNING_KEY: keys.privateKeyBase64,
    ...extra,
  }) as unknown as SecurityEnv;

beforeEach(() => {
  store = sqliteD1();
  store.sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
      ('plus','p@test','Plus','now','now'),('free','f@test','Free','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at)
      VALUES('plus','paid','active','manual',NULL,'now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES
      ('ws-plus','plus','A','online','now','now'),
      ('ws-free','free','B','online','now','now'),
      ('ws-gone','plus','C','revoked','now','now');`);
  runtime = { workspaceId: "ws-plus", installationId: "inst-1" };
  vi.spyOn(
    WorkspaceRuntimeAuthenticator.prototype,
    "authenticateRuntime",
  ).mockImplementation(
    async () =>
      ({
        runtimeId: "r1",
        executionWorkspaceId: runtime.workspaceId,
        installationId: runtime.installationId,
        credentialTokenHash: "h",
      }) as never,
  );
});
afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});

it("issues a lease bound to the owner, Workspace and installation", async () => {
  const response = await handlePluginEntitlementLease(request(), envWith());
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("no-store");
  const verified = await verifyPluginEntitlementLease({
    envelope: await response.json(),
    trustKeysJson: JSON.stringify({
      [ENTITLEMENT_TRUST_PUBLISHER]: { "ent-1": keys.publicKeyBase64 },
    }),
    expected: {
      ownerUserId: "plus",
      workspaceId: "ws-plus",
      installationId: "inst-1",
    },
    now: new Date(),
  });
  expect(verified).toMatchObject({ ok: true });
});

it("refuses a Free owner with the stable paid_plan_required code", async () => {
  runtime = { workspaceId: "ws-free", installationId: "inst-1" };
  await expect(
    handlePluginEntitlementLease(request(), envWith()),
  ).rejects.toMatchObject({ status: 402, code: "paid_plan_required" });
});

it("answers 503 until a signing key is configured", async () => {
  await expect(
    handlePluginEntitlementLease(
      request(),
      envWith({ SYNTILA_ENTITLEMENT_SIGNING_KEY: "" }),
    ),
  ).rejects.toMatchObject({ status: 503 });
});

it("rejects other methods, missing credentials, revoked Workspaces and missing installations", async () => {
  await expect(
    handlePluginEntitlementLease(request({ method: "GET" }), envWith()),
  ).rejects.toMatchObject({ status: 405 });
  await expect(
    handlePluginEntitlementLease(
      new Request("https://test/x?workspaceRuntimeId=r1", { method: "POST" }),
      envWith(),
    ),
  ).rejects.toMatchObject({ status: 401 });
  runtime = { workspaceId: "ws-gone", installationId: "inst-1" };
  await expect(
    handlePluginEntitlementLease(request(), envWith()),
  ).rejects.toMatchObject({ status: 404 });
  runtime = { workspaceId: "ws-plus", installationId: null };
  await expect(
    handlePluginEntitlementLease(request(), envWith()),
  ).rejects.toMatchObject({ status: 409 });
});

it("stops issuing once the plan lapses", async () => {
  store.sqlite.exec(
    "UPDATE account_plans SET status='canceled' WHERE user_id='plus'",
  );
  await expect(
    handlePluginEntitlementLease(request(), envWith()),
  ).rejects.toMatchObject({ status: 402 });
});
