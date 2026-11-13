import { logStructured, requestIdFor } from "../observability.js";

import { extractBearerToken } from "@syntila/security";

import { json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";

export async function handleWorkspaceGatewayConnect(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const requestId = requestIdFor(request);
  const url = new URL(request.url);
  const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
  const upgradeHeaderPresent =
    request.headers.get("Upgrade")?.toLowerCase() === "websocket";
  const authorizationPresent = request.headers.has("Authorization");
  logStructured(
    "info",
    "GW-01 workspace_gateway_request_received",
    { requestId },
    {
      method: request.method,
      path: url.pathname,
      upgradeHeaderPresent,
      runtimeIdPresent: Boolean(workspaceRuntimeId),
      authorizationPresent,
    },
  );

  if (!upgradeHeaderPresent) {
    logStructured(
      "warn",
      "GW-01 workspace_gateway_upgrade_rejected",
      { requestId },
      { reason: "upgrade_header_missing" },
    );
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }

  const authToken = extractBearerToken(request.headers);

  if (!workspaceRuntimeId || !authToken) {
    logStructured(
      "warn",
      "GW-02 runtime_authentication_not_started",
      { requestId },
      {
        runtimeIdPresent: Boolean(workspaceRuntimeId),
        credentialPresent: Boolean(authToken),
      },
    );
    return json(
      {
        error:
          "workspaceRuntimeId and an Authorization bearer credential are required",
      },
      { status: 401 },
    );
  }

  logStructured("info", "GW-02 runtime_authentication_started", {
    requestId,
    runtimeId: workspaceRuntimeId,
  });
  let workspace: { executionWorkspaceId: string } | null;
  try {
    const identity = await new WorkspaceRuntimeAuthenticator(
      env.SYNTILA_DB,
    ).authenticateRuntime(workspaceRuntimeId, authToken);
    workspace = identity
      ? { executionWorkspaceId: identity.executionWorkspaceId }
      : null;
  } catch (error) {
    logStructured(
      "error",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "credential_lookup_failed" },
    );
    throw error;
  }

  if (!workspace) {
    logStructured(
      "warn",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "invalid_or_revoked_credential" },
    );
    return json(
      { error: "Invalid or revoked Workspace runtime credential" },
      { status: 401 },
    );
  }
  logStructured("info", "GW-03 runtime_authenticated", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.executionWorkspaceId,
  });

  if (!env.SYNTILA_WORKSPACE_GATEWAY) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_rejected",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.executionWorkspaceId,
      },
      { reason: "gateway_binding_missing" },
    );
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  }
  const stub = env.SYNTILA_WORKSPACE_GATEWAY.getByName(
    workspace.executionWorkspaceId,
  );
  logStructured("info", "GW-04 forwarding_to_workspace_gateway_do", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.executionWorkspaceId,
  });
  try {
    // Preserve the original upgrade Request. CF-Ray is already part of it and
    // is used as the shared request ID by the Durable Object.
    const response = await stub.fetch(request);
    logStructured(
      response.status === 101 ? "info" : "warn",
      "GW-04 workspace_gateway_do_response_received",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.executionWorkspaceId,
      },
      { status: response.status },
    );
    return response;
  } catch (error) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_failed",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.executionWorkspaceId,
      },
      {
        errorName: error instanceof Error ? error.name : "UnknownError",
      },
    );
    throw error;
  }
}

export async function handleWorkspaceRuntimeTransport(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (!env.SYNTILA_WORKSPACE_GATEWAY)
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  const url = new URL(request.url);
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!body) return json({ error: "Invalid request body" }, { status: 400 });
  const authToken = extractBearerToken(request.headers);
  if (!authToken)
    return json(
      { error: "Workspace runtime credential required" },
      { status: 401 },
    );
  let workspaceId: string | null = null;
  const authenticator = new WorkspaceRuntimeAuthenticator(env.SYNTILA_DB);
  if (url.pathname === "/api/workspace-runtime/sessions") {
    if (typeof body.workspaceRuntimeId !== "string")
      return json({ error: "workspaceRuntimeId is required" }, { status: 400 });
    const authorized = await authenticator.authenticateRuntime(
      body.workspaceRuntimeId,
      authToken,
    );
    workspaceId = authorized?.executionWorkspaceId ?? null;
  } else {
    if (typeof body.sessionId !== "string")
      return json({ error: "sessionId is required" }, { status: 400 });
    const session = await authenticator.authenticateSession(
      body.sessionId,
      authToken,
    );
    workspaceId = session?.executionWorkspaceId ?? null;
  }
  if (!workspaceId)
    return json(
      { error: "Runtime session not found or credential revoked" },
      { status: 401 },
    );
  const stub = env.SYNTILA_WORKSPACE_GATEWAY.getByName(workspaceId);
  let internalPath = "/runtime/" + url.pathname.split("/").pop();
  if (url.pathname === "/api/workspace-runtime/sessions")
    internalPath = "/runtime/sessions";
  else if (url.pathname.endsWith("/close")) internalPath = "/runtime/close";
  const forwarded = new Request(
    `https://workspace-gateway.internal${internalPath}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${authToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return stub.fetch(forwarded);
}
