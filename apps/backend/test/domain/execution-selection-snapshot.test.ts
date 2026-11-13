import { describe, expect, it } from "./helpers/vitest-compat";
import type { WorkerExecutionOptions } from "@syntila/core";
import {
  resolveExecutionSelectionSnapshot,
  supportsExecutionCatalogPin,
} from "../../src/domain/execution-selection-snapshot.js";
const worker = {
  workerTypeId: "gemini",
  workerDisplayName: "Gemini",
  profileReleaseVersion: 2,
};
function options(
  combined = false,
): Extract<WorkerExecutionOptions, { schemaVersion: 2 }> {
  return {
    schemaVersion: 2,
    catalogRevision: "a".repeat(64),
    modelSwitch: { supported: false },
    effort: { supported: false, values: [], defaultValue: null },
    models: {
      supported: true,
      discovery: "provider_catalog",
      allowsCustomModel: false,
      allowedModelIds: ["family"],
      defaultModelId: "family",
      options: [
        {
          id: "family",
          name: "Original Family",
          efforts: ["low", "high"],
          defaultEffort: combined ? null : "low",
          selectionMode: combined ? "combined" : "separate",
          status: "listed",
        },
      ],
    },
  };
}
describe("immutable public execution selection", () => {
  it("resolves only declared defaults and freezes their original labels", () => {
    const catalog = options();
    const value = resolveExecutionSelectionSnapshot(
      catalog,
      { modelId: null, effort: null },
      worker,
    );
    expect(value).toMatchObject({
      modelId: "family",
      modelName: "Original Family",
      effort: "low",
      modelSource: "catalog_default",
      effortSource: "catalog_default",
    });
    expect(Object.isFrozen(value)).toBe(true);
    const revised = { ...catalog, models: { ...catalog.models, options: [] } };
    expect(revised.models.options).toEqual([]);
    expect(value.modelName).toBe("Original Family");
    expect(value).not.toHaveProperty("resolvedNativeModelId");
  });
  it("preserves explicit overrides without substituting another effort", () => {
    const value = resolveExecutionSelectionSnapshot(
      options(true),
      { modelId: "family", effort: "high", catalogRevision: "a".repeat(64) },
      worker,
    );
    expect(value).toMatchObject({
      modelId: "family",
      effort: "high",
      effortSource: "explicit",
    });
    for (const selection of [
      { modelId: "family", effort: "unknown" },
      { modelId: "family", effort: null },
      { modelId: "family", effort: "high", catalogRevision: "b".repeat(64) },
    ]) {
      expect(() =>
        resolveExecutionSelectionSnapshot(options(true), selection, worker),
      ).toThrow();
    }
  });
  it("retains unknown provider defaults as unknown and rejects stale catalogs", () => {
    const base = options();
    const catalog = {
      ...base,
      models: { ...base.models, defaultModelId: null },
    };
    expect(
      resolveExecutionSelectionSnapshot(
        catalog,
        { modelId: null, effort: null },
        worker,
      ),
    ).toMatchObject({
      modelId: null,
      effort: null,
      modelSource: "provider_default",
      effortSource: "provider_default",
    });
    expect(() =>
      resolveExecutionSelectionSnapshot(
        { ...catalog, catalogStale: true },
        { modelId: null, effort: null },
        worker,
      ),
    ).toThrow();
  });
});

it("does not silently discard catalog pins for older or unknown Engines", () => {
  for (const version of [undefined, "dev", "1.2.0", "1.3.0-preview", "invalid"])
    expect(supportsExecutionCatalogPin(version)).toBe(false);
  for (const version of ["1.3.0", "1.4.1", "2.0.0"])
    expect(supportsExecutionCatalogPin(version)).toBe(true);
});
