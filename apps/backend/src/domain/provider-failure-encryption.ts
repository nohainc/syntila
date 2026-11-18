import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
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
    nonce: nonce.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

export function decryptProviderFailure(
  value: unknown,
  assignmentId: string,
  key: Buffer | null,
): ProviderFailureDetails | null {
  if (!key || !value || typeof value !== "object") return null;
  const envelope = value as Record<string, unknown>;
  if (
    envelope.version !== 1 ||
    typeof envelope.nonce !== "string" ||
    typeof envelope.ciphertext !== "string" ||
    typeof envelope.tag !== "string"
  )
    return null;
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
    return null;
  }
}
