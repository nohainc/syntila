import { z } from "zod";

export const PROVIDER_FAILURE_SCHEMA_VERSION = 1 as const;

export const PROVIDER_FAILURE_SOURCES = [
  "structured_error",
  "result_message",
  "stderr",
  "stdout",
  "plugin",
  "agent",
] as const;

export const PROVIDER_FAILURE_OMITTABLE_FIELDS = [
  "nativeErrorCode",
  "providerErrorText",
  "failedRunResponse",
] as const;

export const PROVIDER_FAILURE_LIMITS = {
  maxNativeErrorCodeBytes: 128,
  maxProviderErrorTextBytes: 4_096,
  maxFailedRunResponseBytes: 32_768,
  maxTotalBytes: 40_960,
} as const;

export type ProviderFailureSource = (typeof PROVIDER_FAILURE_SOURCES)[number];
export type ProviderFailureOmittableField =
  (typeof PROVIDER_FAILURE_OMITTABLE_FIELDS)[number];

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: false });

export function utf8ByteLength(value: string): number {
  return textEncoder.encode(value).byteLength;
}

/**
 * Truncates `value` to at most `maxBytes` UTF-8 bytes without splitting a
 * multi-byte UTF-8 codepoint or leaving a lone UTF-16 surrogate.
 */
export function truncateUtf8ToBytes(
  value: string,
  maxBytes: number,
): { value: string; truncated: boolean } {
  if (maxBytes <= 0) {
    return { value: "", truncated: value.length > 0 };
  }
  const encoded = textEncoder.encode(value);
  if (encoded.byteLength <= maxBytes) {
    return { value, truncated: false };
  }
  let end = maxBytes;
  // Back up past any UTF-8 continuation bytes (10xxxxxx).
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) {
    end--;
  }
  // If `end` points to a multi-byte leading byte whose sequence was cut short,
  // back up before that leading byte as well.
  if (end > 0 && end < encoded.byteLength) {
    const lead = encoded[end]!;
    let expectedLen = 1;
    if ((lead & 0xe0) === 0xc0) expectedLen = 2;
    else if ((lead & 0xf0) === 0xe0) expectedLen = 3;
    else if ((lead & 0xf8) === 0xf0) expectedLen = 4;
    if (end + expectedLen > maxBytes) {
      // Wait: `end` is the start of the next character if `encoded[maxBytes]`
      // was a leading byte, which is fine; only back up if `end` was inside
      // the slice `0..maxBytes`.
    }
  }
  // Safe approach: if the byte at `end - 1` is a leading byte or incomplete
  // multi-byte sequence, step back to the start of that sequence.
  let safeEnd = maxBytes;
  while (safeEnd > 0 && (encoded[safeEnd - 1]! & 0xc0) === 0x80) {
    safeEnd--;
  }
  if (safeEnd > 0) {
    const lead = encoded[safeEnd - 1]!;
    let seqLen = 1;
    if ((lead & 0xe0) === 0xc0) seqLen = 2;
    else if ((lead & 0xf0) === 0xe0) seqLen = 3;
    else if ((lead & 0xf8) === 0xf0) seqLen = 4;
    if (safeEnd - 1 + seqLen > maxBytes) {
      safeEnd--;
    } else {
      safeEnd = maxBytes;
    }
  }
  return {
    value: textDecoder.decode(encoded.subarray(0, safeEnd)),
    truncated: true,
  };
}

/**
 * Strips ANSI/VT escape sequences and C0/C1 control characters.
 * When `multiline` is true, normalizes `\r\n` to `\n` and preserves `\n` and `\t`.
 */
export function stripTerminalControlChars(
  value: string,
  options: { multiline: boolean },
): string {
  // eslint-disable-next-line no-control-regex
  const withoutAnsi = value.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "");
  if (options.multiline) {
    const normalized = withoutAnsi.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    // eslint-disable-next-line no-control-regex
    return normalized.replace(
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g,
      "",
    );
  }
  // eslint-disable-next-line no-control-regex
  return withoutAnsi.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim();
}

const CREDENTIAL_PATTERNS: readonly RegExp[] = [
  /\bsk-[A-Za-z0-9_-]{16,}\b/,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bAIza[0-9A-Za-z_-]{35}\b/,
  /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
  /\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*["']?[^\s,;"']+/i,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b/i,
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
];

export function containsDetectedCredential(value: string): boolean {
  return CREDENTIAL_PATTERNS.some((pattern) => pattern.test(value));
}

function utf8BoundedString(maxBytes: number, fieldName: string) {
  return z.string().superRefine((val, ctx) => {
    if (utf8ByteLength(val) > maxBytes) {
      ctx.addIssue({
        code: "custom",
        message: `${fieldName} exceeds ${maxBytes} UTF-8 bytes`,
      });
    }
  });
}

export const ProviderFailureDetailsSchema = z
  .object({
    schemaVersion: z.literal(PROVIDER_FAILURE_SCHEMA_VERSION),
    nativeErrorCode: utf8BoundedString(
      PROVIDER_FAILURE_LIMITS.maxNativeErrorCodeBytes,
      "nativeErrorCode",
    )
      .min(1)
      .optional(),
    providerErrorText: utf8BoundedString(
      PROVIDER_FAILURE_LIMITS.maxProviderErrorTextBytes,
      "providerErrorText",
    )
      .min(1)
      .optional(),
    failedRunResponse: utf8BoundedString(
      PROVIDER_FAILURE_LIMITS.maxFailedRunResponseBytes,
      "failedRunResponse",
    )
      .min(1)
      .optional(),
    source: z.enum(PROVIDER_FAILURE_SOURCES),
    truncated: z.boolean().optional(),
    omitted: z.boolean().optional(),
    omittedFields: z
      .array(z.enum(PROVIDER_FAILURE_OMITTABLE_FIELDS))
      .max(PROVIDER_FAILURE_OMITTABLE_FIELDS.length)
      .optional(),
  })
  .strict()
  .superRefine((val, ctx) => {
    const totalBytes =
      (val.nativeErrorCode ? utf8ByteLength(val.nativeErrorCode) : 0) +
      (val.providerErrorText ? utf8ByteLength(val.providerErrorText) : 0) +
      (val.failedRunResponse ? utf8ByteLength(val.failedRunResponse) : 0);
    if (totalBytes > PROVIDER_FAILURE_LIMITS.maxTotalBytes) {
      ctx.addIssue({
        code: "custom",
        message: `providerFailure total UTF-8 bytes (${totalBytes}) exceeds ${PROVIDER_FAILURE_LIMITS.maxTotalBytes}`,
      });
    }
    if (
      val.omittedFields &&
      val.omittedFields.length > 0 &&
      val.omitted !== true
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["omitted"],
        message: "omitted must be true when omittedFields is non-empty",
      });
    }
  });

export type ProviderFailureDetails = z.infer<
  typeof ProviderFailureDetailsSchema
>;

export function sanitizeProviderFailureDetails(input: {
  nativeErrorCode?: string;
  providerErrorText?: string;
  failedRunResponse?: string;
  source: ProviderFailureSource;
}): ProviderFailureDetails {
  let truncated = false;
  const omittedFields: ProviderFailureOmittableField[] = [];

  const processField = (
    raw: string | undefined,
    field: ProviderFailureOmittableField,
    maxBytes: number,
    multiline: boolean,
  ): string | undefined => {
    if (raw === undefined) return undefined;
    const cleaned = stripTerminalControlChars(raw, { multiline });
    if (cleaned.length === 0) return undefined;
    if (containsDetectedCredential(cleaned)) {
      omittedFields.push(field);
      return undefined;
    }
    const bounded = truncateUtf8ToBytes(cleaned, maxBytes);
    if (bounded.truncated) truncated = true;
    return bounded.value.length > 0 ? bounded.value : undefined;
  };

  const nativeErrorCode = processField(
    input.nativeErrorCode,
    "nativeErrorCode",
    PROVIDER_FAILURE_LIMITS.maxNativeErrorCodeBytes,
    false,
  );
  const providerErrorText = processField(
    input.providerErrorText,
    "providerErrorText",
    PROVIDER_FAILURE_LIMITS.maxProviderErrorTextBytes,
    true,
  );
  const failedRunResponse = processField(
    input.failedRunResponse,
    "failedRunResponse",
    PROVIDER_FAILURE_LIMITS.maxFailedRunResponseBytes,
    true,
  );

  return {
    schemaVersion: PROVIDER_FAILURE_SCHEMA_VERSION,
    ...(nativeErrorCode !== undefined ? { nativeErrorCode } : {}),
    ...(providerErrorText !== undefined ? { providerErrorText } : {}),
    ...(failedRunResponse !== undefined ? { failedRunResponse } : {}),
    source: input.source,
    ...(truncated ? { truncated: true } : {}),
    ...(omittedFields.length > 0 ? { omitted: true, omittedFields } : {}),
  };
}
