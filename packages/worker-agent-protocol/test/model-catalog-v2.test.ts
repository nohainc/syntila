import { expect, it } from "vitest";
import { DiscoveredModelCatalogSchema } from "../src/index.js";
const catalog = {
  schemaVersion: 2,
  catalogRevision: "a".repeat(64),
  profileDigest: "b".repeat(64),
  providerToolVersion: "1.3.3",
  discoveredAt: "2026-10-11T00:00:00Z",
  models: [
    { id: "model", name: "Model", selectionMode: "combined", status: "listed" },
  ],
};
it("defaults missing effort metadata without inventing choices", () => {
  const parsed = DiscoveredModelCatalogSchema.parse(catalog);
  expect(parsed.schemaVersion).toBe(2);
  if (parsed.schemaVersion !== 2) throw new Error("wrong version");
  expect(parsed.models[0]?.efforts).toEqual([]);
  expect(parsed.models[0]?.defaultEffort).toBeNull();
});
it("rejects duplicates, invalid defaults and private execution fields", () => {
  for (const models of [
    [...catalog.models, ...catalog.models],
    [{ ...catalog.models[0], efforts: ["high", "high"] }],
    [{ ...catalog.models[0], defaultEffort: "high" }],
    [{ ...catalog.models[0], nativeId: "private-provider-id" }],
  ])
    expect(
      DiscoveredModelCatalogSchema.safeParse({ ...catalog, models }).success,
    ).toBe(false);
});
it("keeps explicit v1 decoding during the reader-first migration", () => {
  expect(
    DiscoveredModelCatalogSchema.parse({
      schemaVersion: 1,
      profileDigest: catalog.profileDigest,
      providerToolVersion: catalog.providerToolVersion,
      discoveredAt: catalog.discoveredAt,
      models: [{ id: "old", name: "Old", status: "listed" }],
    }).schemaVersion,
  ).toBe(1);
});

it("accepts a bounded stale flag without changing the opaque catalog revision", () => {
  const fresh = DiscoveredModelCatalogSchema.parse(catalog);
  const stale = DiscoveredModelCatalogSchema.parse({ ...catalog, stale: true });
  expect(stale.schemaVersion === 2 && stale.stale).toBe(true);
  expect(
    stale.schemaVersion === 2 &&
      fresh.schemaVersion === 2 &&
      stale.catalogRevision === fresh.catalogRevision,
  ).toBe(true);
  expect(
    DiscoveredModelCatalogSchema.safeParse({ ...catalog, stale: "true" })
      .success,
  ).toBe(false);
});
