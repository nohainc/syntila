import { describe, expect, it } from "vitest";
import {
  PluginEntitlementLeaseSchema,
  PluginIdSchema,
  PluginManifestSchema,
  PluginRefSchema,
} from "../src/index.js";

const sha = "a".repeat(64);
const manifest = () => ({
  schemaVersion: 1,
  pluginId: "acme-reviewer",
  version: "1.4.2",
  displayName: "Acme Reviewer",
  description: "Reviews code.",
  author: { name: "Acme" },
  protocol: { min: "1.0", max: "1.0" },
  artifacts: {
    "linux-x64": {
      command: "bin/reviewer",
      args: ["--syntila"],
      sha256: sha,
      size: 1024,
    },
  },
  capabilities: { progress: true, readOnly: "never" },
  access: {
    workRoot: "write",
    network: { mode: "declared", hosts: ["api.acme.example"] },
    subprocess: false,
    env: ["ACME_ENDPOINT"],
  },
});

describe("worker plugin manifest", () => {
  it("accepts the documented example shape", () => {
    expect(PluginManifestSchema.safeParse(manifest()).success).toBe(true);
  });

  it("rejects unknown keys so typos cannot hide an access declaration", () => {
    expect(
      PluginManifestSchema.safeParse({ ...manifest(), accesss: {} })
        .success,
    ).toBe(false);
    const m = manifest();
    expect(
      PluginManifestSchema.safeParse({
        ...m,
        access: { ...m.access, filesystem: "all" },
      }).success,
    ).toBe(false);
  });

  it.each([
    ["traversal", "../evil"],
    ["absolute", "/bin/sh"],
    ["drive", "C:\\x.exe"],
    ["empty segment", "bin//x"],
    ["backslash traversal", "bin\\..\\x"],
  ])("rejects an unsafe artifact command (%s)", (_name, command) => {
    const m = manifest();
    const bad = {
      ...m,
      artifacts: { "linux-x64": { ...m.artifacts["linux-x64"], command } },
    };
    expect(PluginManifestSchema.safeParse(bad).success).toBe(false);
  });

  it("requires a platform artifact, a valid digest and a bounded size", () => {
    const m = manifest();
    expect(
      PluginManifestSchema.safeParse({ ...m, artifacts: {} }).success,
    ).toBe(false);
    const art = m.artifacts["linux-x64"];
    for (const patch of [
      { sha256: "A".repeat(64) },
      { sha256: "abc" },
      { size: 0 },
      { size: 256 * 1024 * 1024 + 1 },
    ])
      expect(
        PluginManifestSchema.safeParse({
          ...m,
          artifacts: { "linux-x64": { ...art, ...patch } },
        }).success,
      ).toBe(false);
  });

  it("rejects reserved env names, bad versions and inverted protocol ranges", () => {
    const m = manifest();
    expect(
      PluginManifestSchema.safeParse({
        ...m,
        access: { ...m.access, env: ["SYNTILA_TOKEN"] },
      }).success,
    ).toBe(false);
    expect(
      PluginManifestSchema.safeParse({ ...m, version: "1.4" }).success,
    ).toBe(false);
    expect(
      PluginManifestSchema.safeParse({
        ...m,
        protocol: { min: "1.2", max: "1.1" },
      }).success,
    ).toBe(false);
    expect(
      PluginManifestSchema.safeParse({
        ...m,
        protocol: { min: "2.0", max: "2.0" },
      }).success,
    ).toBe(false);
  });

  it("keeps plugin identities distinct from official Worker type IDs", () => {
    expect(PluginIdSchema.safeParse("acme-reviewer").success).toBe(true);
    expect(PluginIdSchema.safeParse("Acme").success).toBe(false);
    expect(PluginIdSchema.safeParse("a".repeat(49)).success).toBe(false);
    expect(PluginRefSchema.safeParse("plugin-3fa91c04b2d7").success).toBe(
      true,
    );
    expect(PluginRefSchema.safeParse("chatgpt").success).toBe(false);
    expect(PluginRefSchema.safeParse("plugin-xyz").success).toBe(false);
  });

  it("only allows a paid-tier lease for the plugin feature", () => {
    const lease = {
      v: 1,
      kid: "ent-1",
      feature: "workers.custom_plugins",
      ownerUserId: "u",
      workspaceId: "w",
      installationId: "i",
      leaseId: "l",
      issuedAt: "2026-11-03T10:00:00.000Z",
      expiresAt: "2026-11-04T10:00:00.000Z",
      planStatus: "active",
      planPeriodEnd: null,
    };
    expect(PluginEntitlementLeaseSchema.safeParse(lease).success).toBe(true);
    expect(
      PluginEntitlementLeaseSchema.safeParse({
        ...lease,
        planStatus: "canceled",
      }).success,
    ).toBe(false);
    expect(
      PluginEntitlementLeaseSchema.safeParse({ ...lease, feature: "x" })
        .success,
    ).toBe(false);
  });
});
