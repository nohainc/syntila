import { json } from "./handlers.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { workerGatewayName } from "../worker-dispatch.js";
import type { SecurityEnv } from "./http-security.js";

/**
 * GET /api/worker-agent/gateway?workerId=&workerSessionId= (WebSocket upgrade).
 * Forwards to the Worker's own gateway object, which authenticates the session
 * token (ADR-034, ADR-035).
 */
export async function handleWorkerGatewayConnect(request: Request, env: SecurityEnv): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }
  const workerId = new URL(request.url).searchParams.get("workerId");
  if (!workerId || !env.SYNTILA_WORKER_GATEWAY) {
    return json({ error: "workerId is required" }, { status: 400 });
  }
  return env.SYNTILA_WORKER_GATEWAY.get(env.SYNTILA_WORKER_GATEWAY.idFromName(workerGatewayName(workerId))).fetch(request);
}
