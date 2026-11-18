import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { sanitizeProviderFailureDetails } from "../src/index.js";

// Shared with packages/dart/protocol/test/provider_failure_parity_test.dart.
// Both sanitizers must produce identical output for every case.
const cases = JSON.parse(
  readFileSync(
    new URL("./fixtures/provider-failure-sanitize-cases.json", import.meta.url),
    "utf8",
  ),
);
const value = (v: unknown) =>
  typeof v === "object" && v !== null
    ? (v as { repeat: string; count: number }).repeat.repeat(
        (v as { count: number }).count,
      )
    : v;

describe("sanitizer parity fixtures", () => {
  for (const c of cases) {
    it(c.name, () => {
      const input: Record<string, unknown> = { source: c.input.source };
      for (const k of ["nativeErrorCode", "providerErrorText", "failedRunResponse"])
        if (k in c.input) input[k] = value(c.input[k]);
      expect(
        JSON.parse(JSON.stringify(sanitizeProviderFailureDetails(input as never))),
      ).toEqual(c.expected);
    });
  }
});
