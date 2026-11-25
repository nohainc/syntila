/**
 * Feature flags, read from `SYNTILA_FEATURE_FLAGS` (a comma-separated list).
 * Every flag is off unless listed; an unknown name is an error, so a typo
 * cannot silently leave a flag off. The value is process-wide and read at
 * boot; every node of a cluster must receive the same value.
 *
 * This module imports nothing from Bun or the database so it can be used by
 * scripts and tests directly.
 */

/** Flag -> flags that must also be on. */
export const FEATURE_FLAG_REQUIRES = {
  cluster_mode: [], // ADR-039: more than one backend node
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
