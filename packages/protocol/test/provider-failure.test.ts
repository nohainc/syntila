import { describe, expect, it } from "vitest";
import {
  PROVIDER_FAILURE_LIMITS,
  PROVIDER_FAILURE_SCHEMA_VERSION,
  ProviderFailureDetailsSchema,
  sanitizeProviderFailureDetails,
  truncateUtf8ToBytes,
  utf8ByteLength,
} from "../src/index.js";

describe("ProviderFailureDetails contract", () => {
  it("accepts valid providerFailure with both error and response", () => {
    const parsed = ProviderFailureDetailsSchema.parse({
      schemaVersion: PROVIDER_FAILURE_SCHEMA_VERSION,
      nativeErrorCode: "MODEL_CAPACITY_EXHAUSTED",
      providerErrorText: "The model is currently overloaded.",
      failedRunResponse: "Partial answer before failure.",
      source: "structured_error",
    });
    expect(parsed.nativeErrorCode).toBe("MODEL_CAPACITY_EXHAUSTED");
    expect(parsed.failedRunResponse).toBe("Partial answer before failure.");
  });

  it("rejects unknown keys, invalid source, and oversized UTF-8 fields", () => {
    expect(() =>
      ProviderFailureDetailsSchema.parse({
        schemaVersion: 1,
        source: "unknown_source",
      }),
    ).toThrow();

    expect(() =>
      ProviderFailureDetailsSchema.parse({
        schemaVersion: 1,
        source: "stderr",
        extraField: "nope",
      }),
    ).toThrow();

    expect(() =>
      ProviderFailureDetailsSchema.parse({
        schemaVersion: 1,
        source: "stderr",
        nativeErrorCode: "a".repeat(
          PROVIDER_FAILURE_LIMITS.maxNativeErrorCodeBytes + 1,
        ),
      }),
    ).toThrow();

    expect(() =>
      ProviderFailureDetailsSchema.parse({
        schemaVersion: 1,
        source: "stderr",
        omittedFields: ["providerErrorText"],
      }),
    ).toThrow();
  });

  it("truncates multi-byte Unicode text on exact UTF-8 codepoint boundaries", () => {
    // Each '🎉' is 4 UTF-8 bytes. 10 bytes should fit 2 emojis (8 bytes), not 2.5.
    const result = truncateUtf8ToBytes("🎉🎉🎉", 10);
    expect(result.truncated).toBe(true);
    expect(result.value).toBe("🎉🎉");
    expect(utf8ByteLength(result.value)).toBe(8);
  });

  it("strips ANSI/control characters and omits detected credentials explicitly", () => {
    const sanitized = sanitizeProviderFailureDetails({
      nativeErrorCode: "ERR\u001b[31m_AUTH\u001b[0m\n",
      providerErrorText: "Failed with key sk-1234567890abcdef123456",
      failedRunResponse: "Line 1\r\nLine 2\u0007",
      source: "structured_error",
    });

    expect(sanitized.nativeErrorCode).toBe("ERR_AUTH");
    expect(sanitized.providerErrorText).toBeUndefined();
    expect(sanitized.failedRunResponse).toBe("Line 1\nLine 2");
    expect(sanitized.omitted).toBe(true);
    expect(sanitized.omittedFields).toEqual(["providerErrorText"]);
  });

  it("omits common credential assignments and Google keys", () => {
    for (const text of ["password=hunter2", `key AIza${"A".repeat(35)}`]) {
      const result = sanitizeProviderFailureDetails({
        source: "stderr",
        providerErrorText: text,
      });
      expect(result.providerErrorText).toBeUndefined();
      expect(result.omittedFields).toEqual(["providerErrorText"]);
    }
  });
});
