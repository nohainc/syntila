/* eslint-disable @typescript-eslint/no-explicit-any */
import { readFileSync } from "node:fs";
import { parseProfile } from "../../src/domain/tool-profile-validation.js";
import { describe, expect, it } from "./helpers/vitest-compat";
import { spaceModelOptions } from "../../src/domain/routes/profiles.js";
describe("profile selection projection", () => {
  it("accepts the Gemini candidate at the Cloud Draft-sync boundary", () => {
    const candidate = JSON.parse(
      readFileSync(
        new URL(
          "../../../../packages/tool-profile/test/fixtures/gemini-antigravity.v2.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const parsed = parseProfile(candidate);
    expect(parsed.profile.probe.live?.requiredForReadiness).toBe(true);
    expect(parsed.profile.model.discovery?.idPrefix).toBe("");
  });
  it("keeps per-model efforts and filters out non-allowlisted entries", () => {
    const result = spaceModelOptions(
      JSON.stringify({
        credential: "never exposed",
        model: {
          supported: true,
          unknownModelPolicy: "profile_allowlist",
          allowlist: ["a", "b"],
          supportedReasoningEfforts: ["low", "high"],
          catalog: [
            { id: "a", name: "A", supportedReasoningEfforts: ["low"] },
            { id: "b", name: "B", supportedReasoningEfforts: [] },
            { id: "c", name: "C" },
          ],
        },
      }),
    );
    expect(result?.catalog.map((item) => item.id)).toEqual(["a", "b"]);
    expect(result?.catalog[0]?.supportedReasoningEfforts).toEqual(["low"]);
    expect(result?.catalog[1]?.supportedReasoningEfforts).toEqual([]);
    expect(result).not.toHaveProperty("credential");
  });
  it("does not invent a catalog for legacy profiles", () => {
    expect(
      spaceModelOptions(JSON.stringify({ model: { supported: true } }))
        ?.catalog,
    ).toEqual([]);
    expect(spaceModelOptions("invalid")).toBeNull();
  });
});

it("filters profile models against the installed CLI version", () => {
  const payload = JSON.stringify({
    model: {
      supported: true,
      catalog: [
        { id: "new", name: "New", minProviderVersion: "2.0.0" },
        { id: "old", name: "Old", maxProviderVersion: "1.9.0" },
      ],
    },
  });
  expect(
    spaceModelOptions(payload, "1.5.0")?.catalog.map((item) => item.id),
  ).toEqual(["old"]);
  expect(
    spaceModelOptions(payload, "2.0.0")?.catalog.map((item) => item.id),
  ).toEqual(["new"]);
  expect(spaceModelOptions(payload)?.catalog).toEqual([]);
});

it("spaces normalized capabilities without provider instructions or fake Defaults", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const result = spaceWorkerExecutionOptions(
    JSON.stringify({
      session: { supported: true },
      model: {
        supported: true,
        arguments: ["--private-flag"],
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["a", "b"],
        supportedReasoningEfforts: ["brief", "deep"],
        defaultReasoningEffort: "brief",
        executionOptions: {
          schemaVersion: 1,
          discovery: "profile_catalog",
          modelSwitchSupported: false,
          effortSupported: true,
          defaultModelId: "a",
          effortMapping: { deep: "provider-private-value" },
        },
        catalog: [
          { id: "a", name: "A", supportedReasoningEfforts: [] },
          {
            id: "b",
            name: "B",
            supportedReasoningEfforts: ["deep"],
            defaultReasoningEffort: "deep",
          },
        ],
      },
    }),
  );
  expect(result?.schemaVersion).toBe(2);
  expect(result?.modelSwitch.supported).toBe(false);
  expect(result?.models.defaultModelId).toBe("a");
  expect(result?.models.options[0]?.efforts).toEqual([]);
  expect(result?.models.options[0]?.defaultEffort).toBeNull();
  expect(result?.models.options[1]?.defaultEffort).toBe("deep");
  expect(JSON.stringify(result)).not.toContain("private");
});
it("supports fixed-model effort and filters unavailable CLI-version models", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const fixed = spaceWorkerExecutionOptions(
    JSON.stringify({
      model: {
        supported: false,
        supportedReasoningEfforts: ["deep"],
        defaultReasoningEffort: "deep",
      },
    }),
  );
  expect(fixed?.models.supported).toBe(false);
  expect(fixed?.effort.values).toEqual(["deep"]);
  const result = spaceWorkerExecutionOptions(
    JSON.stringify({
      session: { supported: true },
      model: {
        supported: true,
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["new"],
        catalog: [{ id: "new", name: "New", minProviderVersion: "2.0.0" }],
        executionOptions: {
          schemaVersion: 1,
          discovery: "profile_catalog",
          modelSwitchSupported: true,
          effortSupported: false,
          defaultModelId: "new",
        },
      },
    }),
    "1.0.0",
  );
  expect(result?.models.allowedModelIds).toEqual([]);
  expect(result?.models.defaultModelId).toBeNull();
  expect(result?.models.options).toEqual([]);
});

it("uses runtime models only for the exact authorized Profile and CLI version", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const { validateWorkerExecutionSelection } = await import("@syntila/core");
  const payload = JSON.stringify({
    session: { supported: true },
    model: {
      supported: true,
      arguments: ["--model", "{{model}}"],
      unknownModelPolicy: "pass_through",
      discovery: {
        schemaVersion: 1,
        arguments: ["models"],
        timeoutMs: 1000,
        format: "tsv",
        idPrefix: "gemini-",
      },
      executionOptions: {
        schemaVersion: 1,
        discovery: "profile_catalog",
        modelSwitchSupported: true,
        effortSupported: false,
      },
    },
  });
  const digest = "a".repeat(64);
  const catalog = {
    schemaVersion: 1,
    profileDigest: digest,
    providerToolVersion: "1.2.16",
    discoveredAt: "2026-10-11T00:00:00.000Z",
    models: [
      {
        id: "gemini-new-high",
        name: "Gemini New (High)",
        status: "listed",
        supportedReasoningEfforts: ["low", "high"],
        defaultReasoningEffort: "high",
      },
      { id: "gemini-old", name: "Old", status: "unavailable" },
      { id: "claude-other", name: "Other", status: "verified" },
    ],
  };
  const result = spaceWorkerExecutionOptions(
    payload,
    "1.2.16",
    JSON.stringify(catalog),
    digest,
  )!;
  expect(result.models.discovery).toBe("provider_catalog");
  expect(result.models.allowsCustomModel).toBe(false);
  expect(result.models.allowedModelIds).toEqual(["gemini-new-high"]);
  expect(result.models.options[0]?.badge).toBe("Listed");
  expect(result.models.options[0]?.efforts).toEqual([]);
  expect(result.models.options[0]?.defaultEffort).toBeNull();
  expect(result.models.options[1]?.status).toBe("unavailable");
  expect(result.effort.supported).toBe(false);
  expect(result.effort.values).toEqual([]);
  const fallbackPayload = JSON.parse(payload) as Record<string, any>;
  fallbackPayload.model.catalog = [{ id: "fallback", name: "Signed fallback" }];
  expect(
    spaceWorkerExecutionOptions(
      JSON.stringify(fallbackPayload),
      "1.2.16",
      undefined,
      digest,
    )?.models.options,
  ).toEqual([]);
  expect(
    validateWorkerExecutionSelection(result, "gemini-old", null),
  ).toContain("not available");
  expect(
    validateWorkerExecutionSelection(result, "gemini-new-high", "high"),
  ).toContain("effort");
  expect(
    validateWorkerExecutionSelection(result, "gemini-new-high", "medium"),
  ).toContain("effort");
  expect(
    validateWorkerExecutionSelection(result, "gemini-new-high", null),
  ).toBeNull();
  expect(
    spaceWorkerExecutionOptions(payload, "1.2.17", catalog, digest)?.models
      .options,
  ).toEqual([]);
  expect(
    spaceWorkerExecutionOptions(payload, "1.2.16", catalog, "b".repeat(64))
      ?.models.options,
  ).toEqual([]);
  expect(
    spaceWorkerExecutionOptions(payload, "1.2.16", catalog)?.models.options,
  ).toEqual([]);
  expect(
    spaceWorkerExecutionOptions(
      payload,
      "1.2.16",
      {
        ...catalog,
        models: [{ id: "gemini-secret", name: "name\u001b", status: "listed" }],
      },
      digest,
    )?.models.options,
  ).toEqual([]);
  expect(JSON.stringify(result)).not.toContain("arguments");
  expect(JSON.stringify(result)).not.toContain("profileDigest");
});

it("publishes the same v2 contract for separate and combined Profiles without private fields", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const { validateWorkerExecutionSelection } = await import("@syntila/core");
  for (const selectionMode of ["separate", "combined"] as const) {
    const digest = "c".repeat(64);
    const payload = JSON.stringify({
      execution: {
        arguments: [
          {
            ifPresent: "reasoningEffort",
            values: ["--effort", "{{reasoningEffort}}"],
          },
        ],
      },
      model: {
        supported: true,
        selectionMode,
        discovery: { idPrefix: "" },
        arguments: ["--model", "{{model}}"],
      },
    });
    const catalog = {
      schemaVersion: 2,
      catalogRevision: "d".repeat(64),
      profileDigest: digest,
      providerToolVersion: "1.3.3",
      discoveredAt: "2026-10-11T00:00:00.000Z",
      models: [
        {
          id: "logical",
          name: "Logical",
          selectionMode,
          status: "listed",
          efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
          defaultEffort: "low",
        },
        {
          id: "retired",
          name: "Retired",
          selectionMode,
          status: "unavailable",
          efforts: [],
          defaultEffort: null,
        },
      ],
    };
    const result = spaceWorkerExecutionOptions(
      payload,
      "1.3.3",
      catalog,
      digest,
    )!;
    expect(result.schemaVersion).toBe(2);
    expect(result.catalogRevision).toBe(catalog.catalogRevision);
    expect(result.models.options[0]?.selectionMode).toBe(selectionMode);
    expect(result.models.options[0]?.efforts).toHaveLength(6);
    expect(result.models.options[0]?.defaultEffort).toBe("low");
    expect(result.models.allowedModelIds).toEqual(["logical"]);
    expect(result.models.options[1]?.status).toBe("unavailable");
    expect(validateWorkerExecutionSelection(result, "retired", null)).toContain(
      "not available",
    );
    const serialized = JSON.stringify(result);
    for (const privateField of [
      "nativeId",
      "profileDigest",
      "providerToolVersion",
      "arguments",
    ])
      expect(serialized).not.toContain(privateField);
    expect(
      spaceWorkerExecutionOptions(payload, "1.3.4", catalog, digest)?.models
        .options,
    ).toEqual([]);
  }
});
it("keeps legacy catalog revisions stable across refresh time and rejects malformed catalogs", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const digest = "e".repeat(64);
  const payload = JSON.stringify({
    model: { supported: true, discovery: { idPrefix: "" } },
  });
  const catalog = {
    schemaVersion: 1,
    profileDigest: digest,
    providerToolVersion: "1.3.3",
    discoveredAt: "2026-10-11T00:00:00.000Z",
    models: [{ id: "model", name: "Model", status: "listed" }],
  };
  const first = spaceWorkerExecutionOptions(payload, "1.3.3", catalog, digest)!;
  expect(
    spaceWorkerExecutionOptions(
      payload,
      "1.3.3",
      { ...catalog, discoveredAt: "2026-10-11T01:00:00.000Z" },
      digest,
    )?.catalogRevision,
  ).toBe(first.catalogRevision);
  expect(
    spaceWorkerExecutionOptions(
      payload,
      "1.3.3",
      { ...catalog, models: [...catalog.models, ...catalog.models] },
      digest,
    )?.models.options,
  ).toEqual([]);
});

it("does not expose discovered efforts without a Profile invocation mapping", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const digest = "a".repeat(64);
  const payload = JSON.stringify({
    model: { supported: true, discovery: { idPrefix: "" } },
  });
  const catalog = {
    schemaVersion: 1,
    profileDigest: digest,
    providerToolVersion: "1.3.3",
    discoveredAt: "2026-10-11T00:00:00.000Z",
    models: [
      {
        id: "model",
        name: "Model",
        status: "listed",
        supportedReasoningEfforts: ["high"],
        defaultReasoningEffort: "high",
      },
    ],
  };
  const result = spaceWorkerExecutionOptions(
    payload,
    "1.3.3",
    catalog,
    digest,
  )!;
  expect(result.models.options[0]?.efforts).toEqual([]);
  expect(result.models.options[0]?.defaultEffort).toBeNull();
});

it("validates the additive signed selection mode and current authoring candidate", () => {
  const candidate = JSON.parse(
    readFileSync(
      new URL("../../../profile_lab/assets/profiles/gemini.json", import.meta.url),
      "utf8",
    ),
  );
  expect(parseProfile(candidate).profile.model.selectionMode).toBe("combined");
  candidate.model.selectionMode = "separate";
  expect(() => parseProfile(candidate)).toThrow();
  candidate.model.selectionMode = "infer_from_suffix";
  expect(() => parseProfile(candidate)).toThrow();
});

it("normalizes retained installed Codex and AGY evidence into the same public contract", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const evidenceRoot = new URL(
    "../../../../docs/acceptance/real-provider/2026-10-11/",
    import.meta.url,
  );
  const codex = JSON.parse(
    readFileSync(
      new URL("model-effort-audit-codex.json", evidenceRoot),
      "utf8",
    ),
  );
  const agy = readFileSync(
    new URL("model-effort-audit-agy.tsv", evidenceRoot),
    "utf8",
  )
    .trim()
    .split("\n")
    .map((line) => {
      const [id, name] = line.split("\t");
      return { id, name, status: "listed" };
    });
  const digest = "f".repeat(64);
  for (const [candidate, version, models, expected] of [
    [
      "chatgpt-codex",
      "0.160.0",
      codex.models.map((model: any) => ({
        id: model.id,
        name: model.displayName,
        status: "listed",
        supportedReasoningEfforts: model.supportedReasoningEfforts.map(
          (entry: any) => entry.reasoningEffort,
        ),
        defaultReasoningEffort: model.defaultReasoningEffort,
      })),
      7,
    ],
    ["gemini-antigravity", "1.3.3", agy, 18],
  ] as const) {
    const payload = readFileSync(
      new URL(
        `../../../profile_lab/assets/profiles/${candidate === "chatgpt-codex" ? "chatgpt" : "gemini"}.json`,
        import.meta.url,
      ),
      "utf8",
    );
    const result = spaceWorkerExecutionOptions(
      payload,
      version,
      {
        schemaVersion: 1,
        profileDigest: digest,
        providerToolVersion: version,
        discoveredAt: "2026-10-11T00:00:00.000Z",
        models,
      },
      digest,
    )!;
    expect(result.schemaVersion).toBe(2);
    expect(result.models.options).toHaveLength(expected);
    for (const model of result.models.options)
      expect(Object.keys(model).sort()).toEqual(
        [
          "id",
          "name",
          "badge",
          "efforts",
          "defaultEffort",
          "selectionMode",
          "status",
        ].sort(),
      );
    if (candidate === "gemini-antigravity") {
      expect(
        result.models.options.every(
          (model) =>
            model.selectionMode === "combined" &&
            model.efforts.length === 0 &&
            model.defaultEffort === null,
        ),
      ).toBe(true);
    } else {
      expect(
        result.models.options.reduce(
          (total, model) => total + model.efforts.length,
          0,
        ),
      ).toBe(40);
    }
  }
});

it("publishes AGY families derived from the CLI catalog without a signed model list", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const candidate = JSON.parse(
    readFileSync(
      new URL("../../../profile_lab/assets/profiles/gemini.json", import.meta.url),
      "utf8",
    ),
  );
  expect(candidate.model.selectionMapping).toBeUndefined();
  expect(candidate.model.discovery.effortVariants).toEqual({
    source: "label_parenthesized_suffix",
    separator: "-",
  });
  const digest = "c".repeat(64);
  const families: Record<string, string[]> = {
    "gemini-4-argon": ["low", "medium", "high"],
    "gemini-3.8-flash": ["low", "medium", "high"],
    "claude-opus-5-5": ["low", "medium", "high"],
    "claude-sonnet-5-5": ["low", "medium", "high"],
    "gpt-oss-120b": ["medium"],
  };
  const models = Object.entries(families).map(([id, efforts]) => ({
    id,
    name: id,
    status: "listed",
    selectionMode: "combined",
    efforts,
    defaultEffort: null,
  }));
  const catalog = {
    schemaVersion: 2,
    catalogRevision: "a".repeat(64),
    profileDigest: digest,
    providerToolVersion: "1.4.0",
    discoveredAt: "2026-10-16T00:00:00.000Z",
    models,
  };
  const result = spaceWorkerExecutionOptions(
    JSON.stringify(candidate),
    "1.4.0",
    catalog,
    digest,
  )!;
  expect(result.models.options.map((m) => m.id)).toEqual(Object.keys(families));
  expect(
    result.models.options.reduce((sum, m) => sum + m.efforts.length, 0),
  ).toBe(13);
  expect(JSON.stringify(result)).not.toContain("nativeId");
  const stale = spaceWorkerExecutionOptions(
    JSON.stringify(candidate),
    "1.4.0",
    { ...catalog, stale: true },
    digest,
  )!;
  expect(stale.catalogStale).toBe(true);
  expect(stale.catalogRevision).toBe(result.catalogRevision);
  const mapped = structuredClone(candidate);
  mapped.model.selectionMapping = {
    schemaVersion: 1,
    models: [
      {
        id: "x",
        name: "X",
        variants: [{ nativeId: "x-low", effort: "low" }],
      },
    ],
  };
  expect(() => parseProfile(mapped)).toThrow();
  const outdated = structuredClone(candidate);
  outdated.engineCompatibility.min = "1.2.0";
  expect(() => parseProfile(outdated)).toThrow();
  const badRule = structuredClone(candidate);
  badRule.model.discovery.effortVariants.separator = "--";
  expect(() => parseProfile(badRule)).toThrow();
});

it("publishes the v2 catalog effort matrix without reconstructing provider support", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const digest = "a".repeat(64);
  const catalog = {
    schemaVersion: 2,
    profileDigest: digest,
    providerToolVersion: "1.0.0",
    catalogRevision: "b".repeat(64),
    discoveredAt: "2026-10-11T00:00:00.000Z",
    models: [
      {
        id: "native",
        name: "Native",
        efforts: ["provider-specific"],
        defaultEffort: "provider-specific",
        status: "verified",
        selectionMode: "separate",
      },
    ],
  };
  const profile = JSON.stringify({
    model: {
      supported: true,
      discovery: { idPrefix: "" },
    },
  });
  const result = spaceWorkerExecutionOptions(profile, "1.0.0", catalog, digest);
  expect(result?.models.options[0]).toMatchObject({
    efforts: ["provider-specific"],
    defaultEffort: "provider-specific",
    selectionMode: "separate",
    status: "verified",
  });
  expect(result).toHaveProperty("catalogRevision", catalog.catalogRevision);
  expect(
    spaceWorkerExecutionOptions(profile, "2.0.0", catalog, digest)?.models
      .options,
  ).toEqual([]);
  expect(
    spaceWorkerExecutionOptions(profile, "1.0.0", catalog, "c".repeat(64))
      ?.models.options,
  ).toEqual([]);
});

it("allows provider Auto with a matching empty catalog but rejects missing or mismatched discovery", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const { validateWorkerExecutionSelection } = await import("@syntila/core");
  const payload = JSON.stringify({
    model: {
      supported: true,
      unknownModelPolicy: "pass_through",
      discovery: { idPrefix: "" },
    },
  });
  const digest = "a".repeat(64);
  const catalog = {
    schemaVersion: 2,
    profileDigest: digest,
    providerToolVersion: "1.0.0",
    discoveredAt: "2026-10-23T00:00:00.000Z",
    catalogRevision: "b".repeat(64),
    models: [],
  };
  const options = (value: unknown) =>
    spaceWorkerExecutionOptions(payload, "1.0.0", value, digest)!;
  expect(
    validateWorkerExecutionSelection(options(catalog), null, null),
  ).toBeNull();
  expect(
    validateWorkerExecutionSelection(options(catalog), "invented", null),
  ).toContain("not available");
  expect(
    validateWorkerExecutionSelection(options(catalog), null, "high"),
  ).toContain("not available");
  for (const invalid of [
    undefined,
    {},
    { ...catalog, profileDigest: "c".repeat(64) },
    { ...catalog, providerToolVersion: "2.0.0" },
  ]) {
    expect(
      validateWorkerExecutionSelection(options(invalid), null, null),
    ).toContain("capabilities are unavailable");
  }
  expect(
    validateWorkerExecutionSelection(
      options({ ...catalog, stale: true }),
      null,
      null,
    ),
  ).toContain("stale");
});

it("offers each discovered Grok model only the efforts its CLI listed", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../../src/domain/worker-execution-options.js");
  const digest = "d".repeat(64);
  const profile = readFileSync(
    new URL("../../../profile_lab/assets/profiles/grok.json", import.meta.url),
    "utf8",
  );
  // The signed Grok Profile declares no model or effort list.
  expect(JSON.parse(profile).model).not.toHaveProperty(
    "supportedReasoningEfforts",
  );
  expect(JSON.parse(profile).model).not.toHaveProperty("catalog");
  const result = spaceWorkerExecutionOptions(
    profile,
    "1.0.67",
    {
      schemaVersion: 2,
      profileDigest: digest,
      providerToolVersion: "1.0.67",
      catalogRevision: "e".repeat(64),
      discoveredAt: "2026-10-24T00:00:00.000Z",
      models: [
        {
          id: "grok-4.7",
          name: "Grok 4.7",
          efforts: ["low", "medium", "high", "xhigh"],
          status: "listed",
          selectionMode: "separate",
        },
        {
          id: "grok-mini",
          name: "Grok Mini",
          efforts: [],
          status: "listed",
          selectionMode: "separate",
        },
      ],
    },
    digest,
  );
  expect(
    result?.models.options.map((option) => [option.id, option.efforts]),
  ).toEqual([
    ["grok-4.7", ["low", "medium", "high", "xhigh"]],
    ["grok-mini", []],
  ]);
});
