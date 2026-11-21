import { notifyWorkerAgent, publishWorkerChanged } from "./worker-events.js";
import { hashToken, timingSafeEqual } from "@syntila/security";
import { dataOf, type Query, type Row } from "../platform/data.js";
import { HttpError } from "./routes/http-security.js";
import type { AgentSessionFence } from "./agent-session-fence.js";

/**
 * Worker pairing, credentials and session fencing (ADR-034, phase P3).
 *
 * Trust model:
 *  - The owner asks for a pairing challenge (single use, expiring). Its secret
 *    goes to the Agent out of band; only its digest is stored.
 *  - The Agent generates an Ed25519 key pair and sends the PUBLIC key plus a
 *    signature over the claim. The private key never leaves the host.
 *  - Every later request proves possession of the key by signing a server nonce.
 *    Nonces are consumed in their own statement, so a replay is refused even
 *    when the first attempt failed.
 *  - Connecting increments the Worker's session epoch in one statement (see
 *    `connectSession`); `agent-session-fence.ts` rejects writes of older sessions.
 *
 * Nothing here stores or logs a long-lived secret: the session token is shown
 * once and kept as a digest.
 */

export const PAIRING_TTL_SECONDS = 600;
export const NONCE_TTL_SECONDS = 60;
export const MAX_OPEN_NONCES = 8;
/** A session that is not renewed for this long is closed by the sweep. */
export const SESSION_LEASE_SECONDS = 300;
/** Lease renewals are written at most this often per session (a third of the lease). */
export const LEASE_RENEW_MIN_MS = (SESSION_LEASE_SECONDS * 1000) / 3;

type Env = { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown };

const encoder = new TextEncoder();

/* ----------------------------------------------------------------- crypto */

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(text: string): Uint8Array<ArrayBuffer> {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function randomToken(prefix: string): string {
  return `${prefix}_${toBase64Url(crypto.getRandomValues(new Uint8Array(32)))}`;
}

/** A raw Ed25519 public key: 32 bytes, base64url, 43 characters. */
export function isValidPublicKey(publicKey: unknown): publicKey is string {
  if (typeof publicKey !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(publicKey)) return false;
  try {
    return fromBase64Url(publicKey).length === 32;
  } catch {
    return false;
  }
}

async function fingerprint(publicKey: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", fromBase64Url(publicKey));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function verifySignature(publicKey: string, message: string, signature: string): Promise<boolean> {
  try {
    if (!isValidPublicKey(publicKey) || typeof signature !== "string" || !/^[A-Za-z0-9_-]{86}$/.test(signature)) return false;
    const key = await crypto.subtle.importKey("raw", fromBase64Url(publicKey), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, fromBase64Url(signature), encoder.encode(message));
  } catch {
    return false;
  }
}

/**
 * What the Agent signs. Domain-separated by action so a signature made for one
 * purpose can never be replayed for another.
 */
export function pairingMessage(challengeId: string, workerId: string, publicKey: string): string {
  return `syntila-worker/v1\npair\n${challengeId}\n${workerId}\n${publicKey}`;
}
export type AgentAction = "session" | "rotate" | "rotate-new" | "unpair";
export function actionMessage(action: AgentAction, workerId: string, nonceId: string, nonce: string, extra = ""): string {
  return `syntila-worker/v1\n${action}\n${workerId}\n${nonceId}\n${nonce}\n${extra}`;
}

/* ------------------------------------------------------------------ audit */

export async function recordWorkerAudit(
  q: Query,
  input: {
    workerId: string;
    ownerUserId: string;
    actorType: "user" | "agent" | "system";
    actorId: string;
    action: string;
    details?: Record<string, unknown>;
  },
): Promise<void> {
  await q.run`INSERT INTO worker_audit_log (id, worker_instance_id, owner_user_id, actor_type, actor_id, action, details_json)
    VALUES (${`wau-${crypto.randomUUID()}`}, ${input.workerId}, ${input.ownerUserId}, ${input.actorType},
            ${input.actorId}, ${input.action}, ${JSON.stringify(input.details ?? {})}::text::jsonb)`;
}

/** Ends the Worker's open session (credential revoked, rotated or transferred). */
function endSession(q: Query, workerId: string) {
  return q.run`UPDATE worker_agent_sessions SET disconnected_at = now(), disconnect_reason = 'credential_revoked'
     WHERE worker_instance_id = ${workerId} AND disconnected_at IS NULL`;
}

/** Makes every open pairing challenge of the Worker unusable. */
function expireOpenChallenges(q: Query, workerId: string) {
  return q.run`UPDATE worker_pairing_challenges SET expires_at = now()
     WHERE worker_instance_id = ${workerId} AND consumed_at IS NULL AND expires_at > now()`;
}

function insertCredential(q: Query, id: string, workerId: string, publicKey: string, keyFingerprint: string) {
  return q.run`INSERT INTO worker_credentials (id, worker_instance_id, public_key, key_fingerprint)
     VALUES (${id}, ${workerId}, ${publicKey}, ${keyFingerprint})`;
}

const iso = (value: unknown): string => (value instanceof Date ? value.toISOString() : String(value));

/* ------------------------------------------------------------ owner side */

export interface PairingChallenge {
  challengeId: string;
  /** Shown once. Hand it to the Agent; it is stored only as a digest. */
  secret: string;
  kind: "pair" | "transfer";
  workerId: string;
  expiresAt: string;
}

/** Lock a live Worker row owned by the user; null when it is gone or not theirs. */
function lockOwnedWorker(q: Parameters<typeof endSession>[0], workerId: string, ownerUserId: string) {
  return q.row<{ id: string }>`
    SELECT id FROM worker_instances
     WHERE id = ${workerId} AND owner_user_id = ${ownerUserId} AND revoked_at IS NULL
       FOR UPDATE`;
}

/**
 * Creates a pairing ('pair', first credential) or transfer ('transfer', move a
 * paired Worker to another host) challenge. Owner only: a stranger's Worker is
 * answered 404.
 */
export async function createPairingChallenge(
  env: Env,
  input: { ownerUserId: string; workerId: string; kind: "pair" | "transfer" },
): Promise<PairingChallenge> {
  const secret = randomToken("wps");
  const digest = await hashToken(secret);
  const challengeId = `wpc-${crypto.randomUUID()}`;
  const expiresAt = await dataOf(env).tx("worker.pairing.create", async (tx) => {
    const worker = await lockOwnedWorker(tx, input.workerId, input.ownerUserId);
    if (!worker) throw new HttpError(404, "Worker not found");
    const paired = await tx.row`SELECT 1 FROM worker_credentials WHERE worker_instance_id = ${input.workerId} AND revoked_at IS NULL`;
    if (input.kind === "pair" && paired) throw new HttpError(409, "The Worker is already paired; start a transfer to move it to another host");
    if (input.kind === "transfer" && !paired) throw new HttpError(409, "The Worker is not paired yet");
    // Only the newest challenge is valid.
    await expireOpenChallenges(tx, input.workerId);
    const row = await tx.row<{ expires_at: Date }>`
      INSERT INTO worker_pairing_challenges (id, worker_instance_id, owner_user_id, kind, secret_digest, expires_at)
      VALUES (${challengeId}, ${input.workerId}, ${input.ownerUserId}, ${input.kind}, ${digest},
              now() + ${PAIRING_TTL_SECONDS}::int * interval '1 second')
      RETURNING expires_at`;
    await recordWorkerAudit(tx, {
      workerId: input.workerId, ownerUserId: input.ownerUserId, actorType: "user", actorId: input.ownerUserId,
      action: input.kind === "pair" ? "pairing.created" : "transfer.requested", details: { challengeId },
    });
    return iso(row!.expires_at);
  });
  return { challengeId, secret, kind: input.kind, workerId: input.workerId, expiresAt };
}

/** Revokes the Worker's credential and closes its session. Idempotent. */
export async function revokeWorkerCredential(
  env: Env,
  input: { ownerUserId: string; workerId: string },
): Promise<{ revoked: boolean }> {
  return dataOf(env).tx("worker.credential.revoke", async (tx) => {
    const worker = await tx.row<{ id: string }>`
      SELECT id FROM worker_instances WHERE id = ${input.workerId} AND owner_user_id = ${input.ownerUserId} FOR UPDATE`;
    if (!worker) throw new HttpError(404, "Worker not found");
    const revoked = await tx.run`UPDATE worker_credentials SET revoked_at = now(), revoked_reason = 'revoked'
       WHERE worker_instance_id = ${input.workerId} AND revoked_at IS NULL`;
    await endSession(tx, input.workerId);
    // An unpaired Worker has no models: they belong to the pairing that reported them.
    await tx.run`UPDATE worker_agent_sessions
         SET models_json = NULL, models_status = NULL, models_reported_at = NULL, models_refresh_requested_at = NULL
       WHERE worker_instance_id = ${input.workerId}`;
    await expireOpenChallenges(tx, input.workerId);
    if (revoked > 0)
      await recordWorkerAudit(tx, {
        workerId: input.workerId, ownerUserId: input.ownerUserId, actorType: "user", actorId: input.ownerUserId,
        action: "credential.revoked",
      });
    return { revoked: revoked > 0 };
  }).then(async (result) => {
    await publishWorkerChanged(env, input.ownerUserId, input.workerId, "updated");
    await notifyWorkerAgent(env, input.workerId, { removed: true });
    return result;
  });
}

/* ------------------------------------------------------------ agent side */

export interface ClaimResult {
  workerId: string;
  workerName: string;
  workerType: string;
  credentialId: string;
  fingerprint: string;
  kind: "pair" | "transfer";
}

/**
 * The Agent claims a challenge with its public key. Single use: the challenge
 * is consumed by one conditional UPDATE, so two claims race to exactly one
 * winner. `claimingUserId` is set when the request carries a user session; a
 * claim by anyone but the owner is refused.
 */
export async function claimPairing(
  env: Env,
  input: { challengeId: string; secret: string; publicKey: string; signature: string; claimingUserId?: string },
): Promise<ClaimResult> {
  const refuse = (status: number, message: string): never => {
    throw new HttpError(status, message);
  };
  if (!isValidPublicKey(input.publicKey)) refuse(400, "publicKey must be a raw Ed25519 key (base64url)");
  const data = dataOf(env);
  const challenge = await data.read.row<{
    worker_instance_id: string; owner_user_id: string; kind: "pair" | "transfer"; secret_digest: string;
    expired: boolean; consumed: boolean;
  }>`SELECT worker_instance_id, owner_user_id, kind, secret_digest,
            (expires_at <= now()) AS expired, (consumed_at IS NOT NULL) AS consumed
       FROM worker_pairing_challenges WHERE id = ${input.challengeId}`;
  const digest = await hashToken(typeof input.secret === "string" ? input.secret : "");
  // Unknown challenge and wrong secret look the same.
  if (!challenge || !timingSafeEqual(challenge.secret_digest, digest)) return refuse(403, "Invalid pairing challenge");
  const audit = (action: string, details: Record<string, unknown>) =>
    recordWorkerAudit(data.read, {
      workerId: challenge.worker_instance_id, ownerUserId: challenge.owner_user_id, actorType: "agent",
      actorId: input.challengeId, action, details,
    }).catch(() => undefined);
  if (input.claimingUserId !== undefined && input.claimingUserId !== challenge.owner_user_id) {
    await audit("pairing.refused", { reason: "cross_user" });
    return refuse(403, "This pairing challenge belongs to another user");
  }
  if (challenge.consumed || challenge.expired) {
    await audit("pairing.refused", { reason: challenge.consumed ? "already_used" : "expired" });
    return refuse(410, "The pairing challenge has expired or was already used");
  }
  const valid = await verifySignature(
    input.publicKey,
    pairingMessage(input.challengeId, challenge.worker_instance_id, input.publicKey),
    input.signature,
  );
  if (!valid) {
    await audit("pairing.refused", { reason: "bad_signature" });
    return refuse(401, "The claim signature does not match the public key");
  }
  const credentialId = `wcr-${crypto.randomUUID()}`;
  const keyFingerprint = await fingerprint(input.publicKey);
  let workerName = "";
  let workerType = "";
  try {
    await data.tx("worker.pairing.claim", async (tx) => {
      // The one conditional UPDATE decides which claim wins.
      const consumed = await tx.row<{ id: string }>`
        UPDATE worker_pairing_challenges SET consumed_at = now(), consumed_credential_id = ${credentialId}
         WHERE id = ${input.challengeId} AND consumed_at IS NULL AND expires_at > now()
        RETURNING id`;
      if (!consumed) throw new HttpError(410, "The pairing challenge has expired or was already used");
      // The Worker must still exist and still belong to the challenge's owner.
      const worker = await lockOwnedWorker(tx, challenge.worker_instance_id, challenge.owner_user_id);
      if (!worker) throw new HttpError(409, "The Worker no longer exists");
      const meta = await tx.row<{ name: string; worker_type_name: string }>`
        SELECT w.name, COALESCE(c.display_name, w.worker_type_id) AS worker_type_name
          FROM worker_instances w
          LEFT JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id
         WHERE w.id = ${challenge.worker_instance_id}`;
      workerName = String(meta?.name ?? "");
      workerType = String(meta?.worker_type_name ?? "");
      const current = await tx.row<{ id: string }>`
        SELECT id FROM worker_credentials WHERE worker_instance_id = ${challenge.worker_instance_id} AND revoked_at IS NULL`;
      if (challenge.kind === "pair" && current) throw new HttpError(409, "The Worker is already paired");
      if (challenge.kind === "transfer") {
        if (!current) throw new HttpError(409, "The Worker is not paired");
        // The old host is locked out: its credential and its session end here.
        await tx.run`UPDATE worker_credentials SET revoked_at = now(), revoked_reason = 'transferred' WHERE id = ${current.id}`;
        await endSession(tx, challenge.worker_instance_id);
      }
      await insertCredential(tx, credentialId, challenge.worker_instance_id, input.publicKey, keyFingerprint);
      await recordWorkerAudit(tx, {
        workerId: challenge.worker_instance_id, ownerUserId: challenge.owner_user_id, actorType: "agent", actorId: credentialId,
        action: challenge.kind === "pair" ? "pairing.claimed" : "transfer.completed",
        details: { challengeId: input.challengeId, fingerprint: keyFingerprint },
      });
    });
  } catch (error) {
    if ((error as { errno?: string })?.errno === "23505")
      throw new HttpError(409, "This key is already in use by another Worker");
    throw error;
  }
  await publishWorkerChanged(env, challenge.owner_user_id, challenge.worker_instance_id, "updated");
  return {
    workerId: challenge.worker_instance_id,
    workerName,
    workerType,
    credentialId,
    fingerprint: keyFingerprint,
    kind: challenge.kind,
  };
}

export interface NonceIssue {
  nonceId: string;
  nonce: string;
  expiresAt: string;
}

/**
 * A server nonce for the Agent to sign. A Worker that is unknown, removed or
 * not paired is answered 404, the same for all three.
 */
export async function issueNonce(env: Env, workerId: string): Promise<NonceIssue> {
  const nonce = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
  const nonceId = `wnc-${crypto.randomUUID()}`;
  return dataOf(env).tx("worker.nonce.issue", async (tx) => {
    const worker = await tx.row<{ id: string }>`
      SELECT w.id FROM worker_instances w
        JOIN worker_credentials c ON c.worker_instance_id = w.id AND c.revoked_at IS NULL
       WHERE w.id = ${workerId} AND w.revoked_at IS NULL
         FOR UPDATE OF w`;
    if (!worker) throw new HttpError(404, "Worker not found");
    await tx.run`DELETE FROM worker_auth_nonces WHERE worker_instance_id = ${workerId} AND expires_at < now() - interval '1 hour'`;
    const open = await tx.row<{ n: number }>`
      SELECT count(*)::int AS n FROM worker_auth_nonces
       WHERE worker_instance_id = ${workerId} AND used_at IS NULL AND expires_at > now()`;
    if ((open?.n ?? 0) >= MAX_OPEN_NONCES) throw new HttpError(429, "Too many open nonces; use one or wait for them to expire");
    const row = await tx.row<{ expires_at: Date }>`
      INSERT INTO worker_auth_nonces (id, worker_instance_id, nonce, expires_at)
      VALUES (${nonceId}, ${workerId}, ${nonce}, now() + ${NONCE_TTL_SECONDS}::int * interval '1 second')
      RETURNING expires_at`;
    return { nonceId, nonce, expiresAt: iso(row!.expires_at) };
  });
}

interface AuthenticatedAgent {
  workerId: string;
  ownerUserId: string;
  actorId: string;
  credentialId: string;
  publicKey: string;
  nonce: string;
}

/**
 * Consumes the nonce in its own statement (so it is spent even when the
 * signature is wrong), then verifies the signature against the Worker's active
 * credential. Any failure answers the same 401.
 */
async function authenticateAction(
  env: Env,
  input: { action: AgentAction; workerId: string; nonceId: string; signature: string; extra?: string; allowDisabled?: boolean },
): Promise<AuthenticatedAgent> {
  const deny = (): never => {
    throw new HttpError(401, "Invalid, expired or already used nonce or signature");
  };
  const spent = await dataOf(env).read.row<{ nonce: string }>`
    UPDATE worker_auth_nonces SET used_at = now()
     WHERE id = ${input.nonceId} AND worker_instance_id = ${input.workerId} AND used_at IS NULL AND expires_at > now()
    RETURNING nonce`;
  if (!spent) return deny();
  const credential = await dataOf(env).read.row<{
    credential_id: string; public_key: string; owner_user_id: string; actor_id: string; enabled: boolean;
  }>`SELECT c.id AS credential_id, c.public_key, w.owner_user_id, w.actor_id, w.enabled
       FROM worker_credentials c JOIN worker_instances w ON w.id = c.worker_instance_id
      WHERE c.worker_instance_id = ${input.workerId} AND c.revoked_at IS NULL AND w.revoked_at IS NULL`;
  if (!credential) return deny();
  const ok = await verifySignature(
    credential.public_key,
    actionMessage(input.action, input.workerId, input.nonceId, spent.nonce, input.extra ?? ""),
    input.signature,
  );
  if (!ok) return deny();
  if (!credential.enabled && !input.allowDisabled) throw new HttpError(403, "The Worker is disabled");
  return {
    workerId: input.workerId, ownerUserId: credential.owner_user_id, actorId: credential.actor_id,
    credentialId: credential.credential_id, publicKey: credential.public_key, nonce: spent.nonce,
  };
}

export interface AgentSession extends AgentSessionFence {
  actorId: string;
  workerName: string;
  workerType: string;
  /** The Type's current published Profile, so the Agent can report the models it offers before any work. */
  workerTypeId: string;
  profile: { revision: number; digest: string } | null;
  /** Shown once; only its digest is stored. */
  sessionToken: string;
  leaseSeconds: number;
  leaseExpiresAt: string;
}

/**
 * Opens the Worker's session. The statement that replaces the session also
 * increments the epoch, so two connects with the same credential get distinct
 * epochs and the later one is current. The row is locked first, so concurrent
 * connects are ordered, and the audit knows whether it superseded a live one.
 */
export async function connectSession(
  env: Env,
  input: { workerId: string; nonceId: string; signature: string; clientVersion?: string },
): Promise<AgentSession> {
  const agent = await authenticateAction(env, { action: "session", ...input });
  const sessionId = `was-${crypto.randomUUID()}`;
  const sessionToken = randomToken("wst");
  const tokenDigest = await hashToken(sessionToken);
  const clientVersion = (input.clientVersion ?? "unknown").slice(0, 64);
  const connected = await dataOf(env).tx("worker.session.connect", async (tx) => {
    const previous = await tx.row<{ session_id: string; session_epoch: string; live: boolean }>`
      SELECT session_id, session_epoch::text AS session_epoch, (disconnected_at IS NULL) AS live
        FROM worker_agent_sessions WHERE worker_instance_id = ${agent.workerId} FOR UPDATE`;
    const meta = await tx.row<{ name: string; worker_type_name: string; worker_type_id: string }>`
      SELECT w.name, w.worker_type_id, COALESCE(c.display_name, w.worker_type_id) AS worker_type_name
        FROM worker_instances w
        LEFT JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id
       WHERE w.id = ${agent.workerId}`;
    const currentProfile = meta
      ? await tx.row<{ revision: number; digest: string }>`
          SELECT revision, digest FROM worker_profiles WHERE worker_type_id = ${meta.worker_type_id}`
      : null;
    const row = await tx.row<{ session_epoch: string; lease_expires_at: Date }>`
      INSERT INTO worker_agent_sessions
        (worker_instance_id, session_id, session_epoch, credential_id, token_digest, client_version, lease_expires_at)
      SELECT w.id, ${sessionId}, 1, c.id, ${tokenDigest}, ${clientVersion},
             now() + ${SESSION_LEASE_SECONDS}::int * interval '1 second'
        FROM worker_instances w JOIN worker_credentials c ON c.worker_instance_id = w.id AND c.revoked_at IS NULL
       WHERE w.id = ${agent.workerId} AND c.id = ${agent.credentialId} AND w.revoked_at IS NULL AND w.enabled
      ON CONFLICT (worker_instance_id) DO UPDATE SET
        session_id = EXCLUDED.session_id,
        session_epoch = worker_agent_sessions.session_epoch + 1,
        credential_id = EXCLUDED.credential_id,
        token_digest = EXCLUDED.token_digest,
        client_version = EXCLUDED.client_version,
        connected_at = now(),
        lease_expires_at = EXCLUDED.lease_expires_at,
        last_seen_at = now(),
        disconnected_at = NULL,
        disconnect_reason = NULL
      RETURNING session_epoch::text AS session_epoch, lease_expires_at`;
    // The credential was revoked between the signature check and here.
    if (!row) throw new HttpError(401, "The Worker credential is no longer valid");
    const epoch = Number(row.session_epoch);
    await recordWorkerAudit(tx, {
      workerId: agent.workerId, ownerUserId: agent.ownerUserId, actorType: "agent", actorId: agent.credentialId,
      action: "session.connected", details: { epoch, sessionId, clientVersion },
    });
    if (previous?.live)
      await recordWorkerAudit(tx, {
        workerId: agent.workerId, ownerUserId: agent.ownerUserId, actorType: "system", actorId: "gateway",
        action: "session.superseded", details: { epoch: Number(previous.session_epoch), sessionId: previous.session_id, by: epoch },
      });
    return {
      workerInstanceId: agent.workerId, sessionId, epoch, actorId: agent.actorId,
      workerName: String(meta?.name ?? ""), workerType: String(meta?.worker_type_name ?? ""),
      workerTypeId: String(meta?.worker_type_id ?? ""),
      profile: currentProfile ? { revision: Number(currentProfile.revision), digest: String(currentProfile.digest) } : null,
      sessionToken,
      leaseSeconds: SESSION_LEASE_SECONDS, leaseExpiresAt: iso(row.lease_expires_at),
    };
  });
  await publishWorkerChanged(env, agent.ownerUserId, agent.workerId, "connection");
  return connected;
}

/** The Agent ends its own pairing (the user removed the Worker on the device). A disabled Worker may too. */
export async function unpairByAgent(
  env: Env,
  input: { workerId: string; nonceId: string; signature: string },
): Promise<{ revoked: boolean }> {
  const agent = await authenticateAction(env, { action: "unpair", ...input, allowDisabled: true });
  return revokeWorkerCredential(env, { ownerUserId: agent.ownerUserId, workerId: agent.workerId });
}

export interface RotateResult {
  credentialId: string;
  fingerprint: string;
}

/**
 * The Agent replaces its own key. The request is signed with the CURRENT key
 * (over the new public key) and the new key signs the same nonce, proving both
 * sides. The current session ends; the Agent reconnects with the new key.
 */
export async function rotateCredential(
  env: Env,
  input: { workerId: string; nonceId: string; signature: string; newPublicKey: string; newKeySignature: string },
): Promise<RotateResult> {
  if (!isValidPublicKey(input.newPublicKey)) throw new HttpError(400, "newPublicKey must be a raw Ed25519 key (base64url)");
  const agent = await authenticateAction(env, {
    action: "rotate", workerId: input.workerId, nonceId: input.nonceId, signature: input.signature, extra: input.newPublicKey,
  });
  const provesNewKey = await verifySignature(
    input.newPublicKey,
    actionMessage("rotate-new", input.workerId, input.nonceId, agent.nonce, input.newPublicKey),
    input.newKeySignature,
  );
  if (!provesNewKey) throw new HttpError(401, "The new key did not sign the rotation");
  const credentialId = `wcr-${crypto.randomUUID()}`;
  const keyFingerprint = await fingerprint(input.newPublicKey);
  try {
    await dataOf(env).tx("worker.credential.rotate", async (tx) => {
      const revoked = await tx.run`UPDATE worker_credentials SET revoked_at = now(), revoked_reason = 'rotated'
         WHERE id = ${agent.credentialId} AND revoked_at IS NULL`;
      if (revoked !== 1) throw new HttpError(401, "The Worker credential is no longer valid");
      await endSession(tx, agent.workerId);
      await insertCredential(tx, credentialId, agent.workerId, input.newPublicKey, keyFingerprint);
      await recordWorkerAudit(tx, {
        workerId: agent.workerId, ownerUserId: agent.ownerUserId, actorType: "agent", actorId: agent.credentialId,
        action: "credential.rotated", details: { newCredentialId: credentialId, fingerprint: keyFingerprint },
      });
    });
  } catch (error) {
    if ((error as { errno?: string })?.errno === "23505")
      throw new HttpError(409, "This key is already in use by another Worker");
    throw error;
  }
  return { credentialId, fingerprint: keyFingerprint };
}

/* --------------------------------------------------- gateway adapter side */

export interface AgentPrincipal extends AgentSessionFence {
  actorId: string;
  ownerUserId: string;
  /** The Workspace the Worker was adopted from (legacy mapping), until P5. */
  executionWorkspaceId: string | null;
}

/**
 * Authenticates a connected Agent by its session (the compatibility adapter on
 * the Workspace gateway uses this). The token is compared by digest.
 */
export async function authenticateAgentSession(
  env: Env,
  input: { workerId: string; sessionId: string; sessionToken: string },
): Promise<AgentPrincipal | null> {
  const digest = await hashToken(input.sessionToken);
  const row = await dataOf(env).read.row<Row>`
    SELECT s.session_epoch::text AS epoch, s.token_digest, w.actor_id, w.owner_user_id,
           inv.workspace_id AS execution_workspace_id
      FROM worker_agent_sessions s
      JOIN worker_credentials c ON c.id = s.credential_id AND c.revoked_at IS NULL
      JOIN worker_instances w ON w.id = s.worker_instance_id AND w.revoked_at IS NULL AND w.enabled
      LEFT JOIN legacy_worker_mapping m ON m.worker_instance_id = w.id
      LEFT JOIN workspace_worker_inventory inv ON inv.worker_id = m.legacy_worker_id
     WHERE s.worker_instance_id = ${input.workerId} AND s.session_id = ${input.sessionId}
       AND s.disconnected_at IS NULL AND s.lease_expires_at > now()`;
  if (!row || !timingSafeEqual(String(row.token_digest), digest)) return null;
  return {
    workerInstanceId: input.workerId, sessionId: input.sessionId, epoch: Number(row.epoch),
    actorId: String(row.actor_id), ownerUserId: String(row.owner_user_id),
    executionWorkspaceId: row.execution_workspace_id == null ? null : String(row.execution_workspace_id),
  };
}

/** One statement; false when the session is no longer the current one. */
export async function renewLease(env: Env, fence: AgentSessionFence): Promise<boolean> {
  const n = await dataOf(env).read.run`
    UPDATE worker_agent_sessions
       SET lease_expires_at = now() + ${SESSION_LEASE_SECONDS}::int * interval '1 second', last_seen_at = now()
     WHERE worker_instance_id = ${fence.workerInstanceId} AND session_id = ${fence.sessionId}
       AND session_epoch = ${fence.epoch}::bigint AND disconnected_at IS NULL`;
  return n === 1;
}

export async function closeSession(env: Env, fence: AgentSessionFence, reason: "closed" | "superseded" = "closed"): Promise<void> {
  const closed = await dataOf(env).read.row<{ owner: string }>`
    UPDATE worker_agent_sessions SET disconnected_at = now(), disconnect_reason = ${reason}
     WHERE worker_instance_id = ${fence.workerInstanceId} AND session_id = ${fence.sessionId}
       AND session_epoch = ${fence.epoch}::bigint AND disconnected_at IS NULL
    RETURNING (SELECT owner_user_id FROM worker_instances WHERE id = worker_agent_sessions.worker_instance_id) AS owner`;
  // A session replaced by a newer one is not an offline Worker.
  if (closed && reason === "closed") await publishWorkerChanged(env, closed.owner, fence.workerInstanceId, "connection");
}

/** Closes sessions whose lease lapsed; they must connect again (new epoch). */
export async function expireLapsedSessions(env: Env): Promise<number> {
  const lapsed = await dataOf(env).read.rows<{ id: string; owner: string }>`
    UPDATE worker_agent_sessions SET disconnected_at = now(), disconnect_reason = 'lease_expired'
     WHERE disconnected_at IS NULL AND lease_expires_at <= now()
    RETURNING worker_instance_id AS id,
      (SELECT owner_user_id FROM worker_instances WHERE id = worker_agent_sessions.worker_instance_id) AS owner`;
  for (const row of lapsed) await publishWorkerChanged(env, row.owner, row.id, "connection");
  return lapsed.length;
}

/**
 * Lease renewal at a bounded rate: a heartbeat touches the database at most
 * once per `minIntervalMs` per session, however often the Agent pings. The
 * answer says whether the socket should be closed ("lost": a newer session
 * replaced this one, or it was closed).
 */
export class AgentLeaseKeeper {
  private readonly lastWrite = new Map<string, number>();
  private static readonly MAX_TRACKED = 1024;
  writes = 0;

  constructor(
    private readonly env: Env,
    private readonly now: () => number = Date.now,
    private readonly minIntervalMs: number = LEASE_RENEW_MIN_MS,
  ) {}

  /** A session just opened: its lease is fresh, so the next write is a while away. */
  begin(fence: AgentSessionFence): void {
    if (this.lastWrite.size >= AgentLeaseKeeper.MAX_TRACKED) this.lastWrite.clear();
    this.lastWrite.set(fence.sessionId, this.now());
  }

  async touch(fence: AgentSessionFence): Promise<"renewed" | "skipped" | "lost"> {
    const last = this.lastWrite.get(fence.sessionId);
    if (last !== undefined && this.now() - last < this.minIntervalMs) return "skipped";
    this.lastWrite.set(fence.sessionId, this.now());
    this.writes += 1;
    return (await renewLease(this.env, fence)) ? "renewed" : "lost";
  }

  end(fence: AgentSessionFence): void {
    this.lastWrite.delete(fence.sessionId);
  }
}
