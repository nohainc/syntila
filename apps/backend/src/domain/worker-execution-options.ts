import { createHash } from "node:crypto";
import { WorkspaceWorkerInventoryEntrySchema } from "@syntila/workspace-runtime-protocol";
import {
  modelSelectionVersionMatches,
  type ToolProfileV1,
} from "@syntila/tool-profile";
import type {
  WorkerExecutionOptions,
  WorkerEffortOptions,
} from "@syntila/core";
/** Expose selection metadata only, never CLI commands or credential configuration. */
export function spaceModelOptions(
  payload: unknown,
  providerVersion?: unknown,
  discoveredCatalog?: unknown,
  profileDigest?: unknown,
  includeUnavailable = false,
) {
  let profile: Record<string, unknown>;
  try {
    profile = JSON.parse(String(payload));
  } catch {
    return null;
  }
  const model = profile?.model as Record<string, unknown> | undefined;
  if (!model || model.supported !== true) return null;
  const efforts = (value: unknown) =>
    Array.isArray(value)
      ? value.filter((item): item is string => typeof item === "string")
      : [];
  const version = (value: unknown) =>
    typeof value === "string" && /^\d+\.\d+\.\d+(?:[-+].*)?$/.test(value)
      ? value.split(/[.+-]/).slice(0, 3).map(Number)
      : null;
  const installed = version(providerVersion);
  const compatible = (entry: Record<string, unknown>) => {
    for (const key of ["minProviderVersion", "maxProviderVersion"] as const) {
      if (entry[key] === undefined) continue;
      const bound = version(entry[key]);
      if (!installed || !bound) return false;
      let comparison = 0;
      for (let i = 0; i < 3; i++) {
        if (installed[i] !== bound[i]) {
          comparison = installed[i]! - bound[i]!;
          break;
        }
      }
      if (
        (key === "minProviderVersion" && comparison < 0) ||
        (key === "maxProviderVersion" && comparison > 0)
      )
        return false;
    }
    return true;
  };
  const allowlist = efforts(model.allowlist);
  // A discovery-backed profile has no fallback catalog. The local
  // Workspace is the authority for the models and effort values available on
  // that installation; until it publishes a matching catalog, no choices are
  // exposed to AX.
  let catalog = model.discovery
    ? []
    : Array.isArray(model.catalog)
      ? model.catalog
      : [];
  if (model.discovery) {
    const spec = model.discovery as { idPrefix?: string };
    let rawCatalog: unknown;
    try {
      rawCatalog =
        typeof discoveredCatalog === "string"
          ? JSON.parse(discoveredCatalog)
          : discoveredCatalog;
    } catch {
      rawCatalog = null;
    }
    const parsedCatalog =
      WorkspaceWorkerInventoryEntrySchema.shape.modelCatalog.safeParse(
        rawCatalog,
      );
    const discovered = parsedCatalog.success ? parsedCatalog.data : null;
    // Local metadata cannot widen an unrelated or retired signed release.
    catalog =
      discovered &&
      discovered.profileDigest === profileDigest &&
      discovered.providerToolVersion === providerVersion &&
      typeof spec.idPrefix === "string"
        ? discovered.models
            .filter(
              (entry) =>
                (spec.idPrefix!.length === 0 ||
                  entry.id.startsWith(spec.idPrefix!) ||
                  (
                    model.selectionMapping as ToolProfileV1["model"]["selectionMapping"]
                  )?.models.some((f) => f.id === entry.id)) &&
                (includeUnavailable || entry.status !== "unavailable"),
            )
            .map((entry) => ({
              id: entry.id,
              name: entry.name,
              status: entry.status,
              selectionMode:
                "selectionMode" in entry
                  ? entry.selectionMode
                  : (model.selectionMode ?? "separate"),
              badge:
                entry.status === "verified"
                  ? "Verified"
                  : entry.status === "unavailable"
                    ? "Unavailable"
                    : "Listed",
              supportedReasoningEfforts:
                "efforts" in entry
                  ? entry.efforts
                  : (entry.supportedReasoningEfforts ?? []),
              defaultReasoningEffort:
                "defaultEffort" in entry
                  ? entry.defaultEffort
                  : entry.defaultReasoningEffort,
            }))
        : [];
  }
  const globalEfforts = efforts(model.supportedReasoningEfforts);
  if (
    new Set(globalEfforts).size !== globalEfforts.length ||
    (model.defaultReasoningEffort != null &&
      !globalEfforts.includes(String(model.defaultReasoningEffort)))
  )
    return null;
  const ids = new Set<string>();
  for (const entry of catalog) {
    if (
      !entry ||
      typeof entry.id !== "string" ||
      ids.has(entry.id) ||
      (Array.isArray(entry.supportedReasoningEfforts) &&
        new Set(entry.supportedReasoningEfforts).size !==
          entry.supportedReasoningEfforts.length) ||
      (entry.defaultReasoningEffort != null &&
        !efforts(
          entry.supportedReasoningEfforts ?? model.supportedReasoningEfforts,
        ).includes(entry.defaultReasoningEffort))
    )
      return null;
    const mapping =
      model.selectionMapping as ToolProfileV1["model"]["selectionMapping"];
    if (mapping) {
      const family = mapping.models.find((f) => f.id === entry.id);
      const choices = efforts(entry.supportedReasoningEfforts);
      const matchesVersion = (
        range: { min: string; maxExclusive: string } | undefined,
      ) => modelSelectionVersionMatches(providerVersion, range);
      if (
        (!family && choices.length > 0) ||
        (family &&
          (choices.some(
            (e) =>
              family.variants.filter(
                (v) => v.effort === e && matchesVersion(v.providerVersion),
              ).length !== 1,
          ) ||
            (entry.defaultReasoningEffort != null &&
              entry.defaultReasoningEffort !== family.defaultEffort)))
      )
        return null;
    }
    ids.add(entry.id);
  }
  return {
    supportedReasoningEfforts: model.discovery
      ? []
      : efforts(model.supportedReasoningEfforts),
    defaultReasoningEffort: model.discovery
      ? null
      : typeof model.defaultReasoningEffort === "string"
        ? model.defaultReasoningEffort
        : null,
    catalog: catalog
      .filter(
        (entry) =>
          entry &&
          typeof entry.id === "string" &&
          compatible(entry) &&
          (model.unknownModelPolicy !== "profile_allowlist" ||
            allowlist.includes(entry.id)),
      )
      .map((entry) => ({
        id: entry.id,
        name: entry.name,
        badge: entry.badge,
        status: entry.status ?? "listed",
        selectionMode: entry.selectionMode ?? model.selectionMode ?? "separate",
        description: entry.description,
        minProviderVersion: entry.minProviderVersion,
        maxProviderVersion: entry.maxProviderVersion,
        defaultReasoningEffort: entry.defaultReasoningEffort,
        supportedReasoningEfforts:
          entry.supportedReasoningEfforts === undefined
            ? efforts(model.supportedReasoningEfforts)
            : efforts(entry.supportedReasoningEfforts),
      })),
  };
}

/** Normalized, versioned public execution options; provider mappings remain signed/local. */
export function spaceWorkerExecutionOptions(
  payload: unknown,
  providerVersion?: unknown,
  discoveredCatalog?: unknown,
  profileDigest?: unknown,
): Extract<WorkerExecutionOptions, { schemaVersion: 2 }> | null {
  let profile: Partial<ToolProfileV1>;
  try {
    profile = JSON.parse(String(payload));
  } catch {
    return null;
  }
  const model = profile?.model;
  if (!model || typeof model.supported !== "boolean") return null;
  if (
    model.selectionMode !== undefined &&
    !["separate", "combined"].includes(model.selectionMode)
  )
    return null;
  const declared = model.executionOptions;
  if (
    declared &&
    (declared.schemaVersion !== 1 || declared.discovery !== "profile_catalog")
  )
    return null;
  const projection = spaceModelOptions(
    payload,
    providerVersion,
    discoveredCatalog,
    profileDigest,
    true,
  );
  if (model.supported && !projection) return null;
  const hasEffortInvocation = JSON.stringify([
    profile.execution,
    model.arguments,
  ]).includes("{{reasoningEffort}}");
  const normalizeEffort = (
    values: unknown,
    defaultValue: unknown,
  ): WorkerEffortOptions => {
    const choices =
      (!runtimeRevision && declared?.effortSupported === false) ||
      (!runtimeRevision &&
        model.discovery &&
        !hasEffortInvocation &&
        !model.selectionMapping &&
        !(model.discovery as { effortVariants?: unknown }).effortVariants) ||
      !Array.isArray(values)
        ? []
        : [
            ...new Set(
              values.filter(
                (value): value is string => typeof value === "string",
              ),
            ),
          ];
    return {
      supported: choices.length > 0,
      values: choices,
      defaultValue:
        typeof defaultValue === "string" && choices.includes(defaultValue)
          ? defaultValue
          : null,
    };
  };
  let runtimeRevision: string | undefined;
  let catalogStale = false;
  let catalogAvailable = false;
  try {
    const parsed =
      WorkspaceWorkerInventoryEntrySchema.shape.modelCatalog.safeParse(
        typeof discoveredCatalog === "string"
          ? JSON.parse(discoveredCatalog)
          : discoveredCatalog,
      );
    if (
      model.discovery &&
      parsed.success &&
      parsed.data?.schemaVersion === 2 &&
      parsed.data.profileDigest === profileDigest &&
      parsed.data.providerToolVersion === providerVersion
    ) {
      catalogAvailable = true;
      runtimeRevision = parsed.data.catalogRevision;
      catalogStale = parsed.data.stale === true;
    }
  } catch {
    /* Invalid inventory cannot supply a catalog identity. */
  }
  const catalog = projection?.catalog ?? [];
  const selectable = catalog.filter((entry) => entry.status !== "unavailable");
  const defaultModel =
    typeof declared?.defaultModelId === "string" &&
    selectable.some((entry) => entry.id === declared.defaultModelId)
      ? declared.defaultModelId
      : null;
  return {
    schemaVersion: 2,
    ...(catalogStale ? { catalogStale: true } : {}),
    catalogRevision:
      runtimeRevision ??
      createHash("sha256")
        .update(
          JSON.stringify({
            profileDigest:
              typeof profileDigest === "string" ? profileDigest : null,
            providerToolVersion:
              typeof providerVersion === "string" ? providerVersion : null,
            models: [...catalog].sort((a, b) => a.id.localeCompare(b.id)),
            declaration: declared ?? null,
          }),
        )
        .digest("hex"),
    models: {
      supported: model.supported,
      discovery: model.discovery ? "provider_catalog" : "profile_catalog",
      ...(model.discovery ? { catalogAvailable } : {}),
      allowsCustomModel:
        model.supported &&
        !model.discovery &&
        model.unknownModelPolicy === "pass_through",
      allowedModelIds: model.supported
        ? model.discovery
          ? selectable.map((entry) => entry.id)
          : model.unknownModelPolicy === "profile_allowlist"
            ? Array.isArray(model.allowlist)
              ? model.allowlist.filter(
                  (id) =>
                    typeof id === "string" &&
                    (!Array.isArray(model.catalog) ||
                      !model.catalog.some((entry) => entry.id === id) ||
                      catalog.some((entry) => entry.id === id)),
                )
              : []
            : selectable.map((entry) => entry.id)
        : [],
      defaultModelId: defaultModel,
      options: catalog.map((entry) => ({
        id: entry.id,
        name: entry.name,
        ...(typeof entry.badge === "string" ? { badge: entry.badge } : {}),
        ...(typeof entry.description === "string"
          ? { description: entry.description }
          : {}),
        status: entry.status as "listed" | "verified" | "unavailable",
        selectionMode: entry.selectionMode as "separate" | "combined",
        efforts: normalizeEffort(
          entry.supportedReasoningEfforts,
          entry.defaultReasoningEffort ?? projection?.defaultReasoningEffort,
        ).values,
        defaultEffort: normalizeEffort(
          entry.supportedReasoningEfforts,
          entry.defaultReasoningEffort ?? projection?.defaultReasoningEffort,
        ).defaultValue,
      })),
    },
    modelSwitch: {
      supported:
        model.supported &&
        profile.session?.supported === true &&
        declared?.modelSwitchSupported !== false,
    },
    effort: normalizeEffort(
      model.supportedReasoningEfforts,
      model.defaultReasoningEffort,
    ),
  };
}

/**
 * Execution options for a plugin Worker (ADR-027): model choices come from
 * the manifest/version-bound local catalog. Native invocation details remain
 * inside the plugin. Effort selection is not supported by this contract.
 */
export function pluginExecutionOptions(
  manifestDigest: string,
  discoveredCatalog?: unknown,
  pluginVersion?: unknown,
): Extract<WorkerExecutionOptions, { schemaVersion: 2 }> {
  let catalog: unknown;
  try {
    catalog =
      typeof discoveredCatalog === "string"
        ? JSON.parse(discoveredCatalog)
        : discoveredCatalog;
  } catch {
    catalog = null;
  }
  const parsed =
    WorkspaceWorkerInventoryEntrySchema.shape.modelCatalog.safeParse(catalog);
  const discovered =
    parsed.success &&
    parsed.data?.profileDigest === manifestDigest &&
    parsed.data.providerToolVersion === pluginVersion
      ? parsed.data
      : null;
  const models = discovered?.models ?? [];
  return {
    schemaVersion: 2,
    catalogRevision:
      discovered?.schemaVersion === 2
        ? discovered.catalogRevision
        : manifestDigest,
    ...(discovered?.schemaVersion === 2 && discovered.stale
      ? { catalogStale: true }
      : {}),
    modelSwitch: { supported: false },
    effort: { supported: false, values: [], defaultValue: null },
    models: {
      supported: discovered != null,
      discovery: "profile_catalog",
      allowsCustomModel: false,
      allowedModelIds: models
        .filter((m) => m.status !== "unavailable")
        .map((m) => m.id),
      defaultModelId: null,
      options: models.map((m) => ({
        id: m.id,
        name: m.name,
        status: m.status,
        selectionMode: "separate",
        efforts: [],
        defaultEffort: null,
      })),
    },
  };
}
