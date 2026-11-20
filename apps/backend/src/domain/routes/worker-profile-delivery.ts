import { extractBearerToken } from "@syntila/security";
import { dataOf } from "../../platform/data.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { authenticateAgentSession } from "../worker-agents.js";
import { getCurrentWorkerProfile, listWorkerProfileHistory } from "../worker-profile-registry.js";
import { HttpError, json, type SecurityEnv } from "./handlers.js";

/** Serve only published snapshots for the authenticated Agent's own Type. */
export async function handleAgentProfile(request: Request, env: SecurityEnv): Promise<Response> {
  if (!isFeatureEnabled("worker_agent_connect")) throw new HttpError(404, "Not found");
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  const token = extractBearerToken(request.headers);
  if (!workerId || !sessionId || !token || !(await authenticateAgentSession(env, { workerId, sessionId, sessionToken: token })))
    throw new HttpError(401, "Invalid Worker session");
  const query = new URL(request.url).searchParams;
  const revision = Number(query.get("revision"));
  const digest = query.get("digest");
  if (!Number.isSafeInteger(revision) || revision < 1 || !digest || !/^[0-9a-f]{64}$/.test(digest))
    throw new HttpError(400, "Invalid Profile pin");
  const worker = await dataOf(env).read.row<{ type: string }>`SELECT worker_type_id AS type FROM worker_instances WHERE id = ${workerId}`;
  if (!worker) throw new HttpError(404, "Profile not found");
  const current = await getCurrentWorkerProfile(env as never, worker.type);
  const snapshot = current.revision === revision ? current : (await listWorkerProfileHistory(env as never, worker.type)).history.find((item) => item.revision === revision);
  if (!snapshot || snapshot.digest !== digest) throw new HttpError(404, "Profile not found");
  const keyId = process.env.SYNTILA_PROFILE_SIGNING_KEY_ID;
  const encoded = process.env.SYNTILA_PROFILE_SIGNING_JWK;
  if (!keyId || !/^[A-Za-z0-9._-]{1,128}$/.test(keyId) || !encoded) throw new HttpError(503, "Profile signing unavailable");
  let signature: string;
  try {
    const key = await crypto.subtle.importKey("jwk", JSON.parse(encoded), { name: "Ed25519" }, false, ["sign"]);
    const signed = await crypto.subtle.sign("Ed25519", key, new TextEncoder().encode(`syntila-worker-profile-v1\n${digest}`));
    signature = Buffer.from(signed).toString("base64url");
  } catch {
    throw new HttpError(503, "Profile signing unavailable");
  }
  return json({ snapshot: { workerTypeId: snapshot.workerTypeId, schemaVersion: snapshot.schemaVersion, profile: snapshot.profile, revision: snapshot.revision, digest: snapshot.digest, updatedByUserId: snapshot.updatedByUserId, updatedAt: snapshot.updatedAt }, proof: JSON.stringify({ version: 1, keyId, signature }) }, { headers: { "Cache-Control": "no-store" } });
}
