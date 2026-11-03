import { describe, expect, it } from "vitest";
import type {
  PluginEntitlementLease,
  WorkerPluginManifest,
} from "@syntila/workspace-runtime-protocol";
import {
  ENTITLEMENT_TRUST_PUBLISHER,
  issuePluginEntitlementLease,
  pluginManifestDigest,
  verifyPluginEntitlementLease,
} from "../src/plugin-entitlement-lease.js";
import { generateEd25519ReleaseKeyPair } from "../src/release-trust.js";

const keys = generateEd25519ReleaseKeyPair();
const other = generateEd25519ReleaseKeyPair();
const trust = (publicKeyBase64: string) =>
  JSON.stringify({
    [ENTITLEMENT_TRUST_PUBLISHER]: { "ent-1": publicKeyBase64 },
  });
const expected = { ownerUserId: "u1", workspaceId: "w1", installationId: "i1" };
const now = new Date("2026-11-03T10:00:00.000Z");
const hours = (n: number) => new Date(+now + n * 3_600_000);

const issue = (over: Partial<PluginEntitlementLease> = {}, at = now) =>
  issuePluginEntitlementLease({
    privateKeyBase64OrPem: keys.privateKeyBase64,
    now: at,
    claims: {
      kid: "ent-1",
      ...expected,
      leaseId: "lease-1",
      issuedAt: at.toISOString(),
      planStatus: "active",
      planPeriodEnd: null,
      ...over,
    },
  });
const verify = (
  envelope: unknown,
  extra: { now?: Date; highWaterMark?: Date; trust?: string } = {},
) =>
  verifyPluginEntitlementLease({
    envelope,
    trustKeysJson: extra.trust ?? trust(keys.publicKeyBase64),
    expected,
    now: extra.now ?? hours(1),
    ...(extra.highWaterMark ? { highWaterMark: extra.highWaterMark } : {}),
  });

describe("plugin entitlement lease", () => {
  it("round-trips a valid lease and caps the TTL at 24 hours", async () => {
    const envelope = issue({ expiresAt: hours(72).toISOString() });
    expect(Date.parse(envelope.lease.expiresAt) - +now).toBe(24 * 3_600_000);
    expect(await verify(envelope)).toMatchObject({ ok: true });
  });

  it("never outlives the subscription period", async () => {
    const envelope = issue({ planPeriodEnd: hours(3).toISOString() });
    expect(envelope.lease.expiresAt).toBe(hours(3).toISOString());
    expect(await verify(envelope, { now: hours(4) })).toEqual({
      ok: false,
      reason: "expired",
    });
  });

  it("refuses to issue an already-expired lease", () => {
    expect(() => issue({ planPeriodEnd: hours(-1).toISOString() })).toThrow();
  });

  it("rejects edits, a wrong key and a missing trust root", async () => {
    const envelope = issue();
    const edited = {
      ...envelope,
      lease: { ...envelope.lease, expiresAt: hours(500).toISOString() },
    };
    expect(await verify(edited)).toEqual({
      ok: false,
      reason: "signature_invalid",
    });
    expect(
      await verify(envelope, { trust: trust(other.publicKeyBase64) }),
    ).toEqual({ ok: false, reason: "signature_invalid" });
    expect(
      await verifyPluginEntitlementLease({
        envelope,
        trustKeysJson: undefined,
        expected,
        now: hours(1),
      }),
    ).toEqual({ ok: false, reason: "signature_invalid" });
  });

  it("is bound to owner, Workspace and installation", async () => {
    for (const field of Object.keys(expected)) {
      const result = await verifyPluginEntitlementLease({
        envelope: issue({
          [field]: "someone-else",
        } as Partial<PluginEntitlementLease>),
        trustKeysJson: trust(keys.publicKeyBase64),
        expected,
        now: hours(1),
      });
      expect(result).toEqual({ ok: false, reason: "binding_mismatch" });
    }
  });

  it("expires at expiresAt with no extra grace", async () => {
    const envelope = issue();
    expect(await verify(envelope, { now: hours(23.9) })).toMatchObject({
      ok: true,
    });
    expect(await verify(envelope, { now: hours(24) })).toEqual({
      ok: false,
      reason: "expired",
    });
  });

  it("detects a rolled-back clock using the high-water mark", async () => {
    const envelope = issue();
    expect(
      await verify(envelope, { now: hours(1), highWaterMark: hours(10) }),
    ).toEqual({ ok: false, reason: "entitlement_clock_invalid" });
    expect(
      await verify(envelope, {
        now: hours(10),
        highWaterMark: new Date(+hours(10) + 60_000),
      }),
    ).toMatchObject({ ok: true });
  });

  it("rejects malformed envelopes", async () => {
    expect(await verify({ lease: {}, signature: "x" })).toEqual({
      ok: false,
      reason: "malformed",
    });
    expect(await verify(null)).toEqual({ ok: false, reason: "malformed" });
  });
});

describe("plugin manifest digest", () => {
  const manifest = {
    schemaVersion: 1,
    pluginId: "acme-reviewer",
    version: "1.0.0",
    displayName: "A",
    description: "",
    author: { name: "A" },
    protocol: { min: "1.0", max: "1.0" },
    artifacts: {
      any: { command: "run", args: [], sha256: "b".repeat(64), size: 1 },
    },
    capabilities: {},
    access: {
      workRoot: "none",
      network: { mode: "none" },
      subprocess: false,
      env: [],
    },
  } as unknown as WorkerPluginManifest;

  it("is stable under key order and changes with any executable byte hash", async () => {
    const reordered = Object.fromEntries(
      Object.entries(manifest).reverse(),
    ) as unknown as WorkerPluginManifest;
    expect(await pluginManifestDigest(reordered)).toBe(
      await pluginManifestDigest(manifest),
    );
    expect(await pluginManifestDigest(manifest)).toMatch(/^[0-9a-f]{64}$/);
    const changed = {
      ...manifest,
      artifacts: {
        any: { ...manifest.artifacts.any!, sha256: "c".repeat(64) },
      },
    };
    expect(await pluginManifestDigest(changed)).not.toBe(
      await pluginManifestDigest(manifest),
    );
  });
});
