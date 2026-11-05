import { describe, expect, it } from "vitest";
import { pluginExecutionOptions } from "../src/worker-execution-options.js";

describe("plugin model discovery projection", () => {
  const digest = "a".repeat(64);
  const catalog = {
    schemaVersion: 2,
    profileDigest: digest,
    providerToolVersion: "1.1.0",
    discoveredAt: "2026-11-05T00:00:00.000Z",
    catalogRevision: "b".repeat(64),
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
  it("exposes choices only from the pinned package and installed version", () => {
    const options = pluginExecutionOptions(digest, catalog, "1.1.0");
    expect(options.models.allowedModelIds).toEqual(["local:8b"]);
    expect(options.catalogRevision).toBe(catalog.catalogRevision);
    expect(options.models.allowsCustomModel).toBe(false);
    expect(
      pluginExecutionOptions("c".repeat(64), catalog, "1.1.0").models.supported,
    ).toBe(false);
    expect(
      pluginExecutionOptions(digest, catalog, "2.0.0").models.supported,
    ).toBe(false);
  });
  it("preserves stale metadata and removes unavailable choices from admission", () => {
    const options = pluginExecutionOptions(
      digest,
      {
        ...catalog,
        stale: true,
        models: [{ ...catalog.models[0], status: "unavailable" }],
      },
      "1.1.0",
    );
    expect(options.catalogStale).toBe(true);
    expect(options.models.allowedModelIds).toEqual([]);
    expect(options.models.options[0]?.status).toBe("unavailable");
  });
  it("retains unsupported selection for legacy plugins and malformed catalogs", () => {
    expect(pluginExecutionOptions(digest).models.supported).toBe(false);
    expect(pluginExecutionOptions(digest, "{", "1.1.0").models.supported).toBe(
      false,
    );
  });
});
