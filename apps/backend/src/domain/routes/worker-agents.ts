import {
  ClaimWorkerPairingRequestSchema,
  ConnectWorkerSessionRequestSchema,
  RotateWorkerCredentialRequestSchema,
  UnpairWorkerRequestSchema,
  WorkerNonceRequestSchema,
} from "@syntila/protocol";
import { isFeatureEnabled } from "../../feature-flags.js";
import {
  claimPairing,
  connectSession,
  createPairingChallenge,
  issueNonce,
  revokeWorkerCredential,
  rotateCredential,
  unpairByAgent,
} from "../worker-agents.js";
import { readBody } from "./validation.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

/**
 * Worker pairing and sessions (ADR-034, phase P3).
 *
 * Owner routes (`/api/workers/:workerId/pairing|transfer|credential`) need the
 * signed-in owner and the `worker_identity` flag; a stranger's Worker is 404.
 * Agent routes (`/api/worker-agent/*`) carry no browser session: the Agent
 * proves itself with a pairing secret (claim) or an Ed25519 signature over a
 * server nonce (everything else), and they need `worker_agent_connect`.
 * Secrets are returned once, never logged, and never cached.
 */
const NO_STORE = { "Cache-Control": "no-store" };

function requireOwnerFlag(): void {
  if (!isFeatureEnabled("worker_identity")) throw new HttpError(404, "Not found");
}
function requireAgentFlag(): void {
  if (!isFeatureEnabled("worker_agent_connect")) throw new HttpError(404, "Not found");
}

/** POST /api/workers/:workerId/pairing: start pairing the Worker's first credential. */
export async function handleWorkerPairing(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireOwnerFlag();
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, accessContext);
  const challenge = await createPairingChallenge(env, { ownerUserId: context.userId, workerId, kind: "pair" });
  return json({ challenge }, { status: 201, headers: NO_STORE });
}

/** POST /api/workers/:workerId/transfer: start moving a paired Worker to another host. */
export async function handleWorkerTransfer(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireOwnerFlag();
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, accessContext);
  const challenge = await createPairingChallenge(env, { ownerUserId: context.userId, workerId, kind: "transfer" });
  return json({ challenge }, { status: 201, headers: NO_STORE });
}

/** DELETE /api/workers/:workerId/credential: revoke the credential and end the session. */
export async function handleWorkerCredential(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireOwnerFlag();
  if (request.method !== "DELETE") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, accessContext);
  return json(await revokeWorkerCredential(env, { ownerUserId: context.userId, workerId }), { headers: NO_STORE });
}

/** POST /api/worker-agent/claim: the Agent claims a challenge with its public key. */
export async function handleClaimWorkerPairing(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireAgentFlag();
  const input = await readBody(request, ClaimWorkerPairingRequestSchema);
  // An Agent has no browser session. If the request does carry one, it must
  // be the owner's: a claim made while signed in as someone else is refused.
  let claimingUserId: string | undefined;
  try {
    claimingUserId = (await securityContext(request, env, accessContext)).userId;
  } catch (error) {
    if (!(error instanceof HttpError) || (error.status !== 401 && error.status !== 403)) throw error;
  }
  const result = await claimPairing(env, { ...input, ...(claimingUserId ? { claimingUserId } : {}) });
  return json({ pairing: result }, { status: 201, headers: NO_STORE });
}

/** POST /api/worker-agent/nonce: a short-lived nonce for the Agent to sign. */
export async function handleWorkerNonce(request: Request, env: SecurityEnv): Promise<Response> {
  requireAgentFlag();
  const input = await readBody(request, WorkerNonceRequestSchema);
  return json({ nonce: await issueNonce(env, input.workerId) }, { headers: NO_STORE });
}

/** POST /api/worker-agent/sessions: connect; the newest session for a Worker is the only current one. */
export async function handleConnectWorkerSession(request: Request, env: SecurityEnv): Promise<Response> {
  requireAgentFlag();
  const input = await readBody(request, ConnectWorkerSessionRequestSchema);
  return json({ session: await connectSession(env, input) }, { status: 201, headers: NO_STORE });
}

/** POST /api/worker-agent/unpair: the Agent ends its own pairing. */
export async function handleUnpairWorkerAgent(request: Request, env: SecurityEnv): Promise<Response> {
  requireAgentFlag();
  const input = await readBody(request, UnpairWorkerRequestSchema);
  return json(await unpairByAgent(env, input), { headers: NO_STORE });
}

/** POST /api/worker-agent/rotate: the Agent replaces its key. */
export async function handleRotateWorkerCredential(request: Request, env: SecurityEnv): Promise<Response> {
  requireAgentFlag();
  const input = await readBody(request, RotateWorkerCredentialRequestSchema);
  return json({ credential: await rotateCredential(env, input) }, { status: 201, headers: NO_STORE });
}
