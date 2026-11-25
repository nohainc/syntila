import { describe, expect, test } from "bun:test";
import {
  FEATURE_FLAGS,
  FEATURE_FLAGS_ENV,
  FEATURE_FLAG_REQUIRES,
  isFeatureEnabled,
  parseFeatureFlags,
} from "../src/feature-flags";

describe("worker-first feature flags", () => {
  test("every flag is off by default", () => {
    expect(parseFeatureFlags(undefined).size).toBe(0);
    expect(parseFeatureFlags("").size).toBe(0);
    for (const flag of FEATURE_FLAGS) expect(isFeatureEnabled(flag, {})).toBe(false);
  });

  test("the flags exist", () => {
    expect([...FEATURE_FLAGS].sort()).toEqual(["cluster_mode"]);
  });

  test("a listed flag is on, with whitespace and empty entries ignored", () => {
    const env = { [FEATURE_FLAGS_ENV]: " , cluster_mode , " };
    expect(isFeatureEnabled("cluster_mode", env)).toBe(true);
  });

  test("an unknown flag name fails instead of being ignored", () => {
    expect(() => parseFeatureFlags("cluster_mode,worker_idenity")).toThrow(/Unknown feature flag "worker_idenity"/);
  });

  test("the full chain is accepted in any order", () => {
    const all = [...FEATURE_FLAGS].reverse().join(",");
    expect(parseFeatureFlags(all).size).toBe(FEATURE_FLAGS.length);
  });

  test("dependencies only name known flags and never form a cycle", () => {
    for (const [flag, needs] of Object.entries(FEATURE_FLAG_REQUIRES)) {
      for (const needed of needs) expect(FEATURE_FLAGS as string[]).toContain(needed);
      const seen = new Set<string>();
      const stack: string[] = [...needs];
      while (stack.length) {
        const next = stack.pop()!;
        expect(next).not.toBe(flag);
        if (seen.has(next)) continue;
        seen.add(next);
        stack.push(...(FEATURE_FLAG_REQUIRES as Record<string, readonly string[]>)[next]!);
      }
    }
  });
});
