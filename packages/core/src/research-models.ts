import { RESEARCH_RESEARCHER_LIMITS } from "./thread.js";

/**
 * Model-diversity rules for Research v2 researchers.
 *
 * Diversity is decided on the *resolved* model identity, never on Worker,
 * provider, effort or display name: two researchers on the same model with
 * different effort, different Workers, or an alias of each other do not count
 * as distinct. Providers may differ but need not.
 */
export interface ResearchRoleSelection {
  /** Execution role label used in messages, e.g. "Researcher 1". */
  readonly role: string;
  readonly workerId?: string | null;
  /** Explicit model ID. Missing/empty means Auto (provider default). */
  readonly model?: string | null;
  readonly reasoningEffort?: string | null;
}

/**
 * Authoritative identity metadata for one Worker's models, from its catalog or
 * Tool Profile: canonical IDs and the aliases that resolve to them.
 */
export interface ModelIdentityCatalog {
  /** Canonical model IDs this Worker offers. */
  readonly models: readonly string[];
  /** Alias -> canonical model ID (e.g. "latest" or a dated snapshot name). */
  readonly aliases?: Readonly<Record<string, string>>;
  /** Whether the Worker accepts model IDs outside its catalog. */
  readonly allowsCustomModels?: boolean;
}

export type ResearchModelIssueCode =
  | "insufficient_researchers"
  | "too_many_researchers"
  | "worker_unavailable"
  | "model_unresolved"
  | "model_unavailable"
  | "duplicate_model";

export interface ResearchModelIssue {
  readonly code: ResearchModelIssueCode;
  readonly role: string;
  readonly message: string;
}

const key = (value: string) => value.trim().toLowerCase();

/**
 * Canonical identity of `model` on a Worker, or null when it cannot be
 * established. Aliases resolve through the catalog; a catalog ID resolves to
 * itself; a custom ID (only where the Worker allows custom models) is its own
 * identity, compared case-insensitively. A custom ID that is really an alias
 * of a catalog model cannot be detected and is documented as such (ADR-026).
 */
export function normalizeModelIdentity(
  model: string | null | undefined,
  catalog: ModelIdentityCatalog | undefined,
): string | null {
  if (!model || !model.trim() || !catalog) return null;
  const wanted = key(model);
  const aliases = Object.entries(catalog.aliases ?? {});
  const alias = aliases.find(([name]) => key(name) === wanted);
  if (alias) return key(alias[1]);
  const listed = catalog.models.find((id) => key(id) === wanted);
  if (listed) return key(listed);
  return catalog.allowsCustomModels ? wanted : null;
}

/**
 * Validates researcher selections before acceptance. Returns every issue so
 * the composer can show them all; an empty list means the selections may be
 * frozen into the snapshot. Nothing is substituted or deduplicated silently.
 */
export function validateResearchModelDiversity(
  researchers: readonly ResearchRoleSelection[],
  catalogFor: (workerId: string) => ModelIdentityCatalog | undefined,
): ResearchModelIssue[] {
  const issues: ResearchModelIssue[] = [];
  if (researchers.length < RESEARCH_RESEARCHER_LIMITS.min)
    issues.push({
      code: "insufficient_researchers",
      role: "Research",
      message: `Research needs at least ${RESEARCH_RESEARCHER_LIMITS.min} researchers on different models.`,
    });
  if (researchers.length > RESEARCH_RESEARCHER_LIMITS.max)
    issues.push({
      code: "too_many_researchers",
      role: "Research",
      message: `Research supports at most ${RESEARCH_RESEARCHER_LIMITS.max} researchers.`,
    });
  const seen = new Map<string, string>();
  for (const selection of researchers) {
    const workerId = selection.workerId?.trim();
    const catalog = workerId ? catalogFor(workerId) : undefined;
    if (!workerId || !catalog) {
      issues.push({
        code: "worker_unavailable",
        role: selection.role,
        message: `${selection.role}: choose an available Worker.`,
      });
      continue;
    }
    if (!selection.model || !selection.model.trim()) {
      issues.push({
        code: "model_unresolved",
        role: selection.role,
        message: `${selection.role}: choose a specific model. Auto cannot prove the researchers use different models.`,
      });
      continue;
    }
    const identity = normalizeModelIdentity(selection.model, catalog);
    if (!identity) {
      issues.push({
        code: "model_unavailable",
        role: selection.role,
        message: `${selection.role}: model "${selection.model}" is not offered by the selected Worker.`,
      });
      continue;
    }
    const earlier = seen.get(identity);
    if (earlier) {
      issues.push({
        code: "duplicate_model",
        role: selection.role,
        message: `${selection.role} uses the same model as ${earlier}. Each researcher needs a different model; a different effort or Worker does not count.`,
      });
      continue;
    }
    seen.set(identity, selection.role);
  }
  return issues;
}
