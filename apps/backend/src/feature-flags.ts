/**
 * Feature flags for the Worker-first migration (ADR-032 to ADR-039,
 * docs/roadmaps/WORKER_FIRST_IMPLEMENTATION_PHASES.md).
 *
 * Flags are read from one environment variable, `SYNTILA_FEATURE_FLAGS`, a
 * comma-separated list of flag names. Every flag is off unless listed.
 * Rules:
 *  - An unknown name is an error, so a typo cannot silently leave a flag off.
 *  - A flag may only be on when the flags it depends on are on (the phase
 *    graph: a later phase cannot run without the earlier one).
 *  - The value is process-wide and read at boot. Every node of a cluster must
 *    receive the same value: a flag is configuration, never per-node state
 *    (ADR-033 multi-server rules, ADR-039 `cluster_mode` gate).
 *
 * This module imports nothing from Bun or the database so it can be used by
 * scripts and tests directly.
 */

/** Flag -> flags that must also be on. Order follows the phase order. */
export const FEATURE_FLAG_REQUIRES = {
  worker_identity: [], // P1, ADR-032
  worker_agent_connect: ["worker_identity"], // P3-P4, ADR-034
  worker_target_dispatch: ["worker_agent_connect"], // P5, ADR-035
  workers_ux: ["worker_target_dispatch"], // P6, ADR-035
  canonical_timeline: ["worker_target_dispatch"], // P7, ADR-036
  artifact_handoff: ["worker_agent_connect"], // P8, ADR-037
  unified_gateway: ["worker_agent_connect"], // P9, ADR-038
  cluster_mode: ["unified_gateway"], // P12, ADR-039
} as const satisfies Record<string, readonly string[]>;

export type FeatureFlag = keyof typeof FEATURE_FLAG_REQUIRES;

export const FEATURE_FLAGS = Object.keys(FEATURE_FLAG_REQUIRES) as FeatureFlag[];

export const FEATURE_FLAGS_ENV = "SYNTILA_FEATURE_FLAGS";

function isFlag(name: string): name is FeatureFlag {
  return Object.hasOwn(FEATURE_FLAG_REQUIRES, name);
}

/** The enabled flags for a raw `SYNTILA_FEATURE_FLAGS` value. Throws on an unknown name or a missing dependency. */
export function parseFeatureFlags(raw: string | undefined): ReadonlySet<FeatureFlag> {
  const enabled = new Set<FeatureFlag>();
  for (const name of (raw ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    if (!isFlag(name)) {
      throw new Error(`Unknown feature flag "${name}" in ${FEATURE_FLAGS_ENV}. Known: ${FEATURE_FLAGS.join(", ")}`);
    }
    enabled.add(name);
  }
  for (const flag of enabled) {
    for (const needed of FEATURE_FLAG_REQUIRES[flag]) {
      if (!enabled.has(needed)) {
        throw new Error(`Feature flag "${flag}" requires "${needed}" in ${FEATURE_FLAGS_ENV}`);
      }
    }
  }
  return enabled;
}

/** True when `flag` is on in `env` (default: the process environment). */
export function isFeatureEnabled(
  flag: FeatureFlag,
  env: Record<string, string | undefined> = process.env,
): boolean {
  return parseFeatureFlags(env[FEATURE_FLAGS_ENV]).has(flag);
}
