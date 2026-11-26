import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import {
  ProviderFailureDetailsSchema,
  type ProviderFailureDetails,
} from "@syntila/protocol";

/** One externally managed, stable 256-bit key; no plaintext is stored in tables. */
export function providerFailureKey(value: string | undefined): Buffer | null {
  return value && /^[0-9a-f]{64}$/i.test(value)
    ? Buffer.from(value, "hex")
    : null;
}

/** Non-secret identifier of a key (first 8 bytes of its SHA-256, hex). */
export function providerFailureKeyId(key: Buffer): string {
  return createHash("sha256").update(key).digest("hex").slice(0, 16);
}

/**
 * Decrypt-only keys kept during rotation: a comma/whitespace separated list of
 * 64-hex keys. Invalid entries are ignored.
 */
export function previousProviderFailureKeys(value: string | undefined): Buffer[] {
  return (value ?? "")
    .split(/[\s,]+/)
    .map((entry) => providerFailureKey(entry))
    .filter((key): key is Buffer => key !== null);
}

export function encryptProviderFailure(
  details: ProviderFailureDetails,
  assignmentId: string,
  key: Buffer,
) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(assignmentId, "utf8"));
  const ciphertext = Buffer.concat([
    cipher.update(JSON.stringify(details), "utf8"),
    cipher.final(),
  ]);
  return {
    version: 1,
    keyId: providerFailureKeyId(key),
    nonce: nonce.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

export function decryptProviderFailure(
  value: unknown,
  assignmentId: string,
  keys: Buffer | readonly Buffer[] | null,
): ProviderFailureDetails | null {
  const candidates = keys === null ? [] : Array.isArray(keys) ? keys : [keys as Buffer];
  if (candidates.length === 0 || !value || typeof value !== "object") return null;
  const envelope = value as Record<string, unknown>;
  if (
    envelope.version !== 1 ||
    typeof envelope.nonce !== "string" ||
    typeof envelope.ciphertext !== "string" ||
    typeof envelope.tag !== "string"
  )
    return null;
  // Envelopes name their key; older envelopes without a keyId try every key.
  const matching = typeof envelope.keyId === "string"
    ? candidates.filter((key) => providerFailureKeyId(key) === envelope.keyId)
    : candidates;
  for (const key of matching) {
    try {
      const decipher = createDecipheriv(
        "aes-256-gcm",
        key,
        Buffer.from(envelope.nonce, "base64"),
      );
      decipher.setAAD(Buffer.from(assignmentId, "utf8"));
      decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
      const plaintext = Buffer.concat([
        decipher.update(Buffer.from(envelope.ciphertext, "base64")),
        decipher.final(),
      ]);
      const parsed = ProviderFailureDetailsSchema.safeParse(
        JSON.parse(plaintext.toString("utf8")),
      );
      return parsed.success ? parsed.data : null;
    } catch {
      // Try the next candidate key.
    }
  }
  return null;
}

/** Decrypt only for an already-authorized response; never persist the result. */
export function extractProviderFailure(
  assignmentError: Record<string, unknown>,
  assignmentId: unknown,
  env: { SYNTILA_PROVIDER_FAILURE_KEY?: string; SYNTILA_PROVIDER_FAILURE_PREVIOUS_KEYS?: string },
): { providerFailure: ProviderFailureDetails | null; providerFailureUnavailable?: boolean } {
  const encrypted = assignmentError.providerFailureEncrypted;
  if (!encrypted) return { providerFailure: null, ...(assignmentError.providerFailureUnavailable === true ? { providerFailureUnavailable: true } : {}) };
  const value = typeof assignmentId === "string"
    ? decryptProviderFailure(encrypted, assignmentId, [
        ...[providerFailureKey(env.SYNTILA_PROVIDER_FAILURE_KEY)].filter((key): key is Buffer => key !== null),
        ...previousProviderFailureKeys(env.SYNTILA_PROVIDER_FAILURE_PREVIOUS_KEYS),
      ]) : null;
  return { providerFailure: value, ...(!value ? { providerFailureUnavailable: true } : {}) };
}
