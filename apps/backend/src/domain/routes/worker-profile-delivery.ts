import { extractBearerToken } from "@syntila/security";
import { dataOf } from "../../platform/data.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { authenticateAgentSession } from "../worker-agents.js";
import { getCurrentWorkerProfile, listWorkerProfileHistory } from "../worker-profile-registry.js";
import { DiscoveredModelCatalogSchema } from "@syntila/workspace-runtime-protocol";
import { readJson } from "./validation.js";
import { publishWorkerChanged } from "../worker-events.js";
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

/**
 * PUT /api/worker-agent/models: the Agent publishes what its provider CLI
 * offers (captured each time its service starts). It replaces the Worker's
 * previous report. A failed capture is reported as a short reason code so the
 * Workers page can say why no models are listed.
 */
export async function handleAgentModels(request: Request, env: SecurityEnv): Promise<Response> {
  if (!isFeatureEnabled("worker_agent_connect")) throw new HttpError(404, "Not found");
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  const token = extractBearerToken(request.headers);
  const principal = workerId && sessionId && token ? await authenticateAgentSession(env, { workerId, sessionId, sessionToken: token }) : null;
  if (!workerId || !sessionId || !principal) throw new HttpError(401, "Invalid Worker session");
  const body = await readJson(request);
  const status = typeof body.status === "string" && /^[a-z0-9_.-]{1,64}$/.test(body.status) ? body.status : null;
  if (!status) throw new HttpError(400, "status must be a short code");
  let models: string | null = null;
  if (status === "ok") {
    const parsed = DiscoveredModelCatalogSchema.safeParse(body.modelCatalog);
    if (!parsed.success) throw new HttpError(422, "modelCatalog is not valid");
    models = JSON.stringify({
      modelCatalog: parsed.data,
      ...(typeof body.providerToolName === "string" ? { providerToolName: body.providerToolName.slice(0, 128) } : {}),
      ...(typeof body.providerToolVersion === "string" ? { providerToolVersion: body.providerToolVersion.slice(0, 128) } : {}),
    });
    if (models.length > 256 * 1024) throw new HttpError(413, "modelCatalog is too large");
  }
  // A failed capture keeps the previous list: the person may still use it.
  await dataOf(env).read.run`UPDATE worker_agent_sessions
       SET models_json = COALESCE(${models}::text, models_json), models_status = ${status}, models_reported_at = now()
     WHERE worker_instance_id = ${workerId} AND session_id = ${sessionId} AND disconnected_at IS NULL`;
  await publishWorkerChanged(env, principal.ownerUserId, workerId, "models");
  return json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}

/**
 * PUT /api/worker-agent/usage — the Agent's answer to an owner's usage request.
 * It is relayed to the waiting owner and never stored.
 */
export async function handleAgentUsage(request: Request, env: SecurityEnv): Promise<Response> {
  if (!isFeatureEnabled("worker_agent_connect")) throw new HttpError(404, "Not found");
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  const token = extractBearerToken(request.headers);
  const principal = workerId && sessionId && token ? await authenticateAgentSession(env, { workerId, sessionId, sessionToken: token }) : null;
  if (!workerId || !sessionId || !principal) throw new HttpError(401, "Invalid Worker session");
  const body = await readJson(request);
  const text = (value: unknown, max: number): string | undefined => (typeof value === "string" ? value.slice(0, max) : undefined);
  const status = body.status === "ok" || body.status === "unavailable" ? body.status : "error";
  const report = {
    requestId: text(body.requestId, 128) ?? "",
    status,
    output: text(body.output, 65536),
    errorOutput: text(body.errorOutput, 65536),
    exitCode: typeof body.exitCode === "number" ? body.exitCode : null,
    truncated: body.truncated === true,
    errorCode: text(body.errorCode, 64),
    errorMessage: text(body.errorMessage, 500),
  };
  const gateways = (env as { SYNTILA_WORKER_GATEWAY?: DurableObjectNamespace }).SYNTILA_WORKER_GATEWAY;
  if (gateways) {
    await gateways.get(gateways.idFromName(`worker:${workerId}`)).fetch("http://gateway/usage-result", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(report),
    });
  }
  return json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}
