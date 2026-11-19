/**
 * Worker Agent pairing and session DTOs (ADR-034). The Agent holds an Ed25519
 * key pair: it sends only the public key (raw 32 bytes, base64url, 43 chars)
 * and signs server nonces with the private key (64-byte signature, base64url,
 * 86 chars). Signed messages are domain-separated, see
 * `apps/backend/src/domain/worker-agents.ts`.
 */
import { z } from "zod";

const publicKey = z
  .string({ error: "publicKey is required" })
  .regex(/^[A-Za-z0-9_-]{43}$/, "publicKey must be a raw Ed25519 key (base64url, 43 characters)");
const signature = z
  .string({ error: "signature is required" })
  .regex(/^[A-Za-z0-9_-]{86}$/, "signature must be an Ed25519 signature (base64url, 86 characters)");
const workerId = z.string({ error: "workerId is required" }).min(1).max(128);
const nonceId = z.string({ error: "nonceId is required" }).min(1).max(128);

/** POST /api/worker-agent/claim: the Agent claims a pairing or transfer challenge. */
export const ClaimWorkerPairingRequestSchema = z.strictObject({
  challengeId: z.string({ error: "challengeId is required" }).min(1).max(128),
  secret: z.string({ error: "secret is required" }).min(16).max(256),
  publicKey,
  /** Signature by the new key over `pairingMessage(challengeId, workerId, publicKey)`. */
  signature,
});
export type ClaimWorkerPairingRequest = z.infer<typeof ClaimWorkerPairingRequestSchema>;

/** POST /api/worker-agent/nonce */
export const WorkerNonceRequestSchema = z.strictObject({ workerId });
export type WorkerNonceRequest = z.infer<typeof WorkerNonceRequestSchema>;

/** POST /api/worker-agent/sessions: connect with a signed nonce. */
export const ConnectWorkerSessionRequestSchema = z.strictObject({
  workerId,
  nonceId,
  signature,
  clientVersion: z.string().max(64).optional(),
});
export type ConnectWorkerSessionRequest = z.infer<typeof ConnectWorkerSessionRequestSchema>;

/** POST /api/worker-agent/rotate: replace the key, signed by both keys. */
export const RotateWorkerCredentialRequestSchema = z.strictObject({
  workerId,
  nonceId,
  signature,
  newPublicKey: publicKey,
  newKeySignature: signature,
});
export type RotateWorkerCredentialRequest = z.infer<typeof RotateWorkerCredentialRequestSchema>;

/** What the owner receives when starting a pairing or transfer. The secret is shown once. */
export const WorkerPairingChallengeSchema = z.object({
  challengeId: z.string(),
  secret: z.string(),
  kind: z.enum(["pair", "transfer"]),
  workerId: z.string(),
  expiresAt: z.string(),
});
export type WorkerPairingChallenge = z.infer<typeof WorkerPairingChallengeSchema>;
