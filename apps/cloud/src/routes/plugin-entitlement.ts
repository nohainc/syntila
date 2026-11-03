import { extractBearerToken } from "@syntila/security";
import { getAccountPlan, requirePaidFeature } from "../account-plan.js";
import { issuePluginEntitlementLease } from "../plugin-entitlement-lease.js";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";
import { HttpError, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

/**
 * Optional Cloud secrets (ADR-027). They are not declared as required
 * secrets, so deployments without plugin support keep working; the route
 * answers 503 until a signing key is configured.
 */
type EntitlementEnv = SecurityEnv & {
  SYNTILA_ENTITLEMENT_SIGNING_KEY?: string;
  SYNTILA_ENTITLEMENT_KEY_ID?: string;
};

/**
 * `POST /api/workspace-runtime/worker-plugins/entitlement` — a short-lived,
 * signed statement that the Workspace owner currently holds
 * `workers.custom_plugins`. The Service stores it for offline decisions; Cloud
 * scheduling remains authoritative. Authenticated with the Workspace runtime
 * credential, so the lease is bound to that installation.
 */
export async function handlePluginEntitlementLease(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");
  const config = env as EntitlementEnv;
  const runtimeId = new URL(request.url).searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential)
    throw new HttpError(401, "Workspace runtime credentials are required");
  const runtime = await new WorkspaceRuntimeAuthenticator(
    env.SYNTILA_DB,
  ).authenticateRuntime(runtimeId, credential);
  if (!runtime)
    throw new HttpError(401, "Workspace runtime credential is invalid");
  if (!runtime.installationId)
    throw new HttpError(409, "Workspace runtime has no installation");

  const workspace = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id AS ownerUserId FROM execution_workspaces WHERE id = ?1 AND status != 'revoked'",
  )
    .bind(runtime.executionWorkspaceId)
    .first<{ ownerUserId: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");

  // The authoritative check: 402 paid_plan_required for a Free owner.
  await requirePaidFeature(
    env as unknown as Env,
    workspace.ownerUserId,
    "workers.custom_plugins",
  );
  if (!config.SYNTILA_ENTITLEMENT_SIGNING_KEY)
    throw new HttpError(503, "Entitlement signing is not configured");

  const now = new Date();
  const plan = await getAccountPlan(
    env as unknown as Env,
    workspace.ownerUserId,
    now,
  );
  if (
    plan.status !== "active" &&
    plan.status !== "trialing" &&
    plan.status !== "past_due"
  )
    throw new HttpError(402, "Custom Worker plugins require a paid plan");

  const envelope = issuePluginEntitlementLease({
    privateKeyBase64OrPem: config.SYNTILA_ENTITLEMENT_SIGNING_KEY,
    now,
    claims: {
      kid: config.SYNTILA_ENTITLEMENT_KEY_ID ?? "ent-1",
      ownerUserId: workspace.ownerUserId,
      workspaceId: runtime.executionWorkspaceId,
      installationId: runtime.installationId,
      leaseId: crypto.randomUUID(),
      issuedAt: now.toISOString(),
      planStatus: plan.status,
      planPeriodEnd: plan.currentPeriodEnd,
    },
  });
  return json(envelope, { headers: { "cache-control": "no-store" } });
}
