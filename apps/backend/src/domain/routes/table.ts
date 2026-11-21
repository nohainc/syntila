/**
 * Every HTTP route of the backend API, in one table.
 *
 * A route is a method (or "*" when the handler decides by method itself), a
 * path whose `:name` segments become `params` (URL-decoded), and a handler.
 * The first route whose path and method match wins, so a literal path is
 * listed before a parameter path that would also match it.
 *
 * `docs/api/ROUTES.md` is generated from this table (`bun run routes`).
 */
import { BUILTIN_WORKFLOWS, workflowCatalogEntry } from "@syntila/core";
import { conditionalJson } from "./conditional-read.js";
import { handleApprovePlan } from "./implement-plan.js";
import { handleWorkspaceMcpAction } from "./mcp-action.js";
import { handleWorkspaceMcpInventory } from "./mcp-inventory.js";
import { handleLiveCheckoutConfig } from "./paddle-live.js";
import {
  handleSandboxCheckoutConfig,
  handleSandboxPortal,
  handleSandboxWebhook,
} from "./paddle-sandbox.js";
import {
  handleAcceptPersonInvitation,
  handleBlockPerson,
  handleCancelPersonInvitation,
  handleCreatePersonInvitation,
  handleDeclinePersonInvitation,
  handleDisconnectPersonConnection,
  handleEnsureSupportSpace,
  handleListPeople,
  handleListPersonInvitations,
  handleOpenPersonalSpace,
  handleUnblockPerson,
} from "./people.js";
import {
  handleAccountPlan,
  handleGetAvatar,
  handleReadReceiptPrivacy,
  handleUploadAvatar,
} from "./profile.js";
import { handleSpaceAdditionalFolders } from "./space-additional-folders.js";
import { handleAgentFolders, handleDeleteDeviceFolders, handleListDeviceFolders, handleSpaceFolder } from "./device-folders.js";
import { handleThreadRequestQueue } from "./thread-request-queue.js";
import { handlePluginLibrary, handleWorkspacePluginPin } from "./worker-plugins.js";
import { handleWorkflowConfigurations } from "./workflow-configurations.js";
import { handleWorkflowDefault } from "./workflow-default.js";
import { handleWorkflowWorkspace } from "./workflow-workspace.js";
import {
  handleAcceptWorkspaceInvitation,
  handleDeclineWorkspaceInvitation,
  handleMyWorkspaceInvitations,
  handlePersonGrantQuota,
  handleRevokePersonGrant,
  handleWorkspaceInvitations,
} from "./workspace-invitations.js";
import { handleWorkspaceMemberAccess } from "./workspace-member-access.js";
import { handlePeopleWithAccess } from "./workspace-people-with-access.js";
import { handleWorkspaceWorkerPreferences } from "./workspace-worker-preferences.js";

export type RouteMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "*";
export type RouteHandler = (...args: unknown[]) => Promise<Response>;
export type WorkerRouteHandlers = Record<string, RouteHandler>;

export interface RouteContext {
  readonly request: Request;
  readonly env: Env;
  readonly ctx: ExecutionContext | undefined;
  readonly params: Readonly<Record<string, string>>;
}

export interface RouteOptions {
  /**
   * Called by connected Workspaces or servers with their own credentials,
   * not by a browser session: no same-origin check for mutations.
   */
  readonly machine?: boolean;
  /**
   * A create endpoint: an `Idempotency-Key` header makes a retried request
   * return the first response instead of creating twice. "route": handled
   * around the handler (route-idempotency.ts); "handler": the handler writes
   * its receipt in its own transaction.
   */
  readonly idempotent?: "route" | "handler";
}

export interface Route extends RouteOptions {
  readonly method: RouteMethod;
  readonly path: string;
  readonly segments: readonly string[];
  readonly handler: (route: RouteContext) => Promise<Response> | Response;
}

/* --------------------------------------------------------------- matching */

function compile(
  method: RouteMethod,
  path: string,
  handler: Route["handler"],
  options: RouteOptions = {},
): Route {
  return { method, path, segments: path.split("/").slice(1), handler, ...options };
}

/** Parameters when `pathname` has the route's shape, otherwise null. */
export function matchPath(route: Route, pathname: string): Record<string, string> | null {
  const parts = pathname.split("/").slice(1);
  if (parts.length !== route.segments.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < parts.length; i++) {
    const want = route.segments[i]!;
    const got = parts[i]!;
    if (want.startsWith(":")) {
      if (!got) return null;
      try {
        params[want.slice(1)] = decodeURIComponent(got);
      } catch {
        return null;
      }
    } else if (want !== got) return null;
  }
  return params;
}

export interface RouteMatch {
  readonly route: Route;
  readonly params: Record<string, string>;
}

/**
 * The route for a request. When the path exists but not for this method,
 * `allowed` lists the methods it does accept.
 */
export function findRoute(
  routes: readonly Route[],
  method: string,
  pathname: string,
): { match: RouteMatch | null; allowed: string[] } {
  const allowed = new Set<string>();
  for (const route of routes) {
    const params = matchPath(route, pathname);
    if (!params) continue;
    if (route.method === "*" || route.method === method) return { match: { route, params }, allowed: [] };
    allowed.add(route.method);
  }
  return { match: null, allowed: [...allowed] };
}

/* ------------------------------------------------------------------ table */

const cache = new WeakMap<WorkerRouteHandlers, readonly Route[]>();

/** The route table for a set of injected handlers (built once per set). */
export function routeTable(h: WorkerRouteHandlers): readonly Route[] {
  let routes = cache.get(h);
  if (!routes) {
    routes = buildRoutes(h);
    cache.set(h, routes);
  }
  return routes;
}

function buildRoutes(h: WorkerRouteHandlers): Route[] {
  const r = compile;
  // Injected handlers are looked up when called, so a test can pass only
  // the handlers it exercises.
  const call =
    (name: string, ...pick: ((c: RouteContext) => unknown)[]) =>
    (c: RouteContext) => {
      const handler = h[name];
      if (!handler) throw new Error(`Route handler ${name} is not configured`);
      return handler(c.request, c.env, ...pick.map((p) => p(c)));
    };
  const p = (name: string) => (c: RouteContext) => c.params[name];
  const ctx = (c: RouteContext) => c.ctx;
  const machine = { machine: true } as const;
  const idempotent = { idempotent: "route" } as const;
  const ownReceipt = { idempotent: "handler" } as const;

  return [
    // Connected Workspace: registration and runtime transport.
    r("POST", "/api/workspace-runtime/register", call("handleRegisterWorkspaceFromDesktop", ctx), machine),
    r("POST", "/api/workspace-runtime/ownership", call("handleCheckWorkspaceOwnership"), machine),
    r("POST", "/api/workspace-runtime/ownership/reconcile", call("handleReconcileWorkspaceOwnership"), machine),
    r("POST", "/api/workspace-runtime/release", call("handleReleaseDesktopWorkspace"), machine),
    r("POST", "/api/workspace-runtime/disconnect", call("handleDisconnectDesktopWorkspace"), machine),
    r("POST", "/api/workspace-runtime/sessions", call("handleWorkspaceRuntimeTransport"), machine),
    r("POST", "/api/workspace-runtime/events", call("handleWorkspaceRuntimeTransport"), machine),
    r("POST", "/api/workspace-runtime/poll", call("handleWorkspaceRuntimeTransport"), machine),
    r("POST", "/api/workspace-runtime/sessions/:sessionId/close", call("handleWorkspaceRuntimeTransport"), machine),
    r("GET", "/api/workspace-runtime/inputs", call("handleListRuntimeInputs")),
    r("POST", "/api/workspace-runtime/outputs", call("handleUploadWorkerOutputImage"), machine),
    r("GET", "/api/workspace-runtime/inputs/:fileId/content", call("handleDownloadRuntimeInput", p("fileId"))),
    r("POST", "/api/workspace-runtime/inputs/:fileId/delivered", call("handleConfirmRuntimeInput", p("fileId")), machine),
    r("POST", "/api/workspace-runtime/inputs/:fileId/attempt", call("handleReportRuntimeInputAttempt", p("fileId")), machine),
    r("GET", "/api/workspace-runtime/workers/catalog", call("handleListWorkspaceWorkerCatalog", ctx)),
    r("GET", "/api/workspace-gateway/connect", call("handleWorkspaceGatewayConnect")),

    // Account and people.
    r("GET", "/api/session", call("handleSession", ctx)),
    r("GET", "/api/admin/profile-lab/access", call("handleProfileLabAccess", ctx)),
    r("*", "/api/people/support", (c) => handleEnsureSupportSpace(c.request, c.env, c.ctx)),
    r("*", "/api/people", (c) => handleListPeople(c.request, c.env, c.ctx)),
    r("POST", "/api/people/invitations", (c) => handleCreatePersonInvitation(c.request, c.env, c.ctx), idempotent),
    r("GET", "/api/people/invitations", (c) => handleListPersonInvitations(c.request, c.env, c.ctx)),
    r("POST", "/api/people/invitations/:id/accept", (c) => handleAcceptPersonInvitation(c.request, c.env, c.params.id!, c.ctx)),
    r("POST", "/api/people/invitations/:id/decline", (c) => handleDeclinePersonInvitation(c.request, c.env, c.params.id!, c.ctx)),
    r("POST", "/api/people/invitations/:id/cancel", (c) => handleCancelPersonInvitation(c.request, c.env, c.params.id!, c.ctx)),
    r("POST", "/api/people/connections/:userId/space", (c) => handleOpenPersonalSpace(c.request, c.env, c.params.userId!, c.ctx)),
    r("POST", "/api/people/connections/:userId", (c) => handleDisconnectPersonConnection(c.request, c.env, c.params.userId!, c.ctx)),
    r("DELETE", "/api/people/connections/:userId", (c) => handleDisconnectPersonConnection(c.request, c.env, c.params.userId!, c.ctx)),
    r("POST", "/api/people/connections/:userId/disconnect", (c) => handleDisconnectPersonConnection(c.request, c.env, c.params.userId!, c.ctx)),
    r("DELETE", "/api/people/connections/:userId/disconnect", (c) => handleDisconnectPersonConnection(c.request, c.env, c.params.userId!, c.ctx)),
    r("POST", "/api/people/blocks/:userId", (c) => handleBlockPerson(c.request, c.env, c.params.userId!, c.ctx)),
    r("DELETE", "/api/people/blocks/:userId", (c) => handleUnblockPerson(c.request, c.env, c.params.userId!, c.ctx)),
    r("PUT", "/api/profile/avatar", (c) => handleUploadAvatar(c.request, c.env, c.ctx)),
    r("GET", "/api/users/:userId/avatar", (c) => handleGetAvatar(c.request, c.env, c.params.userId!, c.ctx)),
    r("*", "/api/me/privacy", (c) => handleReadReceiptPrivacy(c.request, c.env, c.ctx)),
    r("*", "/api/me/plan", (c) => handleAccountPlan(c.request, c.env, c.ctx)),
    r("GET", "/api/me/invitations", call("handleListCurrentUserInvitations", ctx)),

    // Billing. Live checkout remains disabled until explicitly configured.
    r("*", "/api/billing/live/checkout-config", (c) => handleLiveCheckoutConfig(c.request, c.env, c.ctx)),

    // Billing (Paddle sandbox).
    r("*", "/api/billing/sandbox/checkout-config", (c) => handleSandboxCheckoutConfig(c.request, c.env, c.ctx)),
    r("*", "/api/billing/sandbox/webhook", (c) => handleSandboxWebhook(c.request, c.env), machine),
    r("*", "/api/billing/sandbox/portal", (c) => handleSandboxPortal(c.request, c.env, c.ctx)),

    // Issue reports.
    r("POST", "/api/issue-reports", call("handleCreateIssueReport", ctx), idempotent),
    r("GET", "/api/issue-reports", call("handleGetIssueReportForRequest", ctx)),
    r("GET", "/api/admin/issue-reports", call("handleListAdminIssueReports", ctx)),
    r("GET", "/api/admin/issue-reports/groups", call("handleListAdminIssueReportGroups", ctx)),
    r("POST", "/api/admin/issue-reports/groups", call("handleCreateAdminIssueReportGroup", ctx), idempotent),
    r("GET", "/api/admin/issue-reports/:id", call("handleGetAdminIssueReport", p("id"), ctx)),
    r("PATCH", "/api/admin/issue-reports/:id", call("handlePatchAdminIssueReport", p("id"), ctx)),

    // Workspaces.
    r("GET", "/api/workspaces", call("handleListWorkspaces", ctx)),
    r("*", "/api/workspaces/:workspaceId/worker-preferences", (c) => handleWorkspaceWorkerPreferences(c.request, c.env, c.params.workspaceId!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/member-access", (c) => handleWorkspaceMemberAccess(c.request, c.env, c.params.workspaceId!, c.ctx, undefined)),
    r("*", "/api/workspaces/:workspaceId/member-access/people/:userId", (c) => handleWorkspaceMemberAccess(c.request, c.env, c.params.workspaceId!, c.ctx, c.params.userId)),
    r("*", "/api/workspaces/:workspaceId/invitations", (c) => handleWorkspaceInvitations(c.request, c.env, c.params.workspaceId!, undefined, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/invitations/:invitationId/revoke", (c) => handleWorkspaceInvitations(c.request, c.env, c.params.workspaceId!, c.params.invitationId, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/people-with-access", (c) => handlePeopleWithAccess(c.request, c.env, c.params.workspaceId!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/person-grants/:userId/quota", (c) => handlePersonGrantQuota(c.request, c.env, c.params.workspaceId!, c.params.userId!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/person-grants/:userId/revoke", (c) => handleRevokePersonGrant(c.request, c.env, c.params.workspaceId!, c.params.userId!, c.ctx)),
    r("*", "/api/workspace-invitations", (c) => handleMyWorkspaceInvitations(c.request, c.env, c.ctx)),
    r("*", "/api/workspace-invitations/:id/accept", (c) => handleAcceptWorkspaceInvitation(c.request, c.env, c.params.id!, c.ctx)),
    r("*", "/api/workspace-invitations/:id/decline", (c) => handleDeclineWorkspaceInvitation(c.request, c.env, c.params.id!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/mcp-inventory", (c) => handleWorkspaceMcpInventory(c.request, c.env, c.params.workspaceId!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/mcp-action", (c) => handleWorkspaceMcpAction(c.request, c.env, c.params.workspaceId!, c.ctx)),
    r("*", "/api/workspaces/:workspaceId/worker-plugins/:pluginRef", (c) => handleWorkspacePluginPin(c.request, c.env, c.params.workspaceId!, c.params.pluginRef!, c.ctx)),
    r("POST", "/api/workspaces/:workspaceId/delivery-probe", call("handleWorkspaceDeliveryProbe", p("workspaceId"), ctx)),
    r("GET", "/api/workspaces/:workspaceId/audit-export", call("handleExportWorkspaceAudit", p("workspaceId"), ctx)),
    r("POST", "/api/workspaces/:workspaceId/workers/:workerId/usage", call("handleWorkerUsage", p("workspaceId"), p("workerId"), ctx)),
    r("GET", "/api/workspaces/:workspaceId", call("handleGetWorkspace", p("workspaceId"), ctx)),
    r("PATCH", "/api/workspaces/:workspaceId", call("handleUpdateWorkspace", p("workspaceId"), ctx)),
    r("DELETE", "/api/workspaces/:workspaceId", call("handleRevokeWorkspace", p("workspaceId"), ctx)),

    // Workflow settings.
    r("*", "/api/user/workflow-workspace", (c) => handleWorkflowWorkspace(c.request, c.env, undefined, c.ctx)),
    r("*", "/api/spaces/:spaceId/workflow-workspace", (c) => handleWorkflowWorkspace(c.request, c.env, c.params.spaceId, c.ctx)),
    r("GET", "/api/device-folders", (c) => handleListDeviceFolders(c.request, c.env, c.ctx)),
    r("DELETE", "/api/device-folders/:deviceId", (c) => handleDeleteDeviceFolders(c.request, c.env, c.params.deviceId!, undefined, c.ctx)),
    r("DELETE", "/api/device-folders/:deviceId/:folderId", (c) => handleDeleteDeviceFolders(c.request, c.env, c.params.deviceId!, c.params.folderId!, c.ctx)),
    r("*", "/api/spaces/:spaceId/folder", (c) => handleSpaceFolder(c.request, c.env, c.params.spaceId!, c.ctx)),
    r("*", "/api/spaces/:spaceId/additional-folders", (c) => handleSpaceAdditionalFolders(c.request, c.env, c.params.spaceId!, c.ctx)),
    r("*", "/api/spaces/:spaceId/workflow-default", (c) => handleWorkflowDefault(c.request, c.env, c.params.spaceId, c.ctx)),
    r("*", "/api/user/workflow-default", (c) => handleWorkflowDefault(c.request, c.env, undefined, c.ctx)),
    r("*", "/api/spaces/:spaceId/workflow-configurations", (c) => handleWorkflowConfigurations(c.request, c.env, undefined, c.ctx, c.params.spaceId)),
    r("*", "/api/spaces/:spaceId/workflow-configurations/:workflowId", (c) => handleWorkflowConfigurations(c.request, c.env, c.params.workflowId, c.ctx, c.params.spaceId)),
    r("*", "/api/user/workflow-configurations", (c) => handleWorkflowConfigurations(c.request, c.env, undefined, c.ctx)),
    r("*", "/api/user/workflow-configurations/:workflowId", (c) => handleWorkflowConfigurations(c.request, c.env, c.params.workflowId, c.ctx)),
    r("GET", "/api/workflows/catalog", (c) =>
      conditionalJson(c.request, {
        // Only active selectable built-in workflows are offered.
        workflows: Object.values(BUILTIN_WORKFLOWS)
          .filter((definition) => definition.steps.every((step) => step.kind !== "tool_call"))
          .map(workflowCatalogEntry),
      }),
    ),

    // Workers, Worker Profiles and releases.
    r("GET", "/api/release-trust", (c) => h.handleGetReleaseTrustState!(c.env)),
    r("POST", "/api/admin/release-trust/keys/:keyId/revoke", call("handleRevokeReleaseSigningKey", p("keyId"), ctx)),
    r("GET", "/api/workers/catalog", call("handleListWorkerCatalog", ctx)),
    r("*", "/api/me/worker-plugins", (c) => handlePluginLibrary(c.request, c.env, undefined, c.ctx)),
    r("*", "/api/me/worker-plugins/:pluginRef", (c) => handlePluginLibrary(c.request, c.env, c.params.pluginRef, c.ctx)),
    // Worker Instances (ADR-032), behind the worker_identity flag. The Workspace
    // inventory moved to /api/workspace-workers; P5/P6 retire it.
    r("GET", "/api/features", call("handleListFeatures", ctx)),
    r("GET", "/api/workers", call("handleListWorkers", ctx)),
    r("POST", "/api/workers", call("handleCreateWorker", ctx), idempotent),
    r("GET", "/api/workspace-workers", call("handleListWorkspaceWorkerInventory", ctx)),
    r("GET", "/api/workers/:workerId", call("handleWorker", p("workerId"), ctx)),
    r("PATCH", "/api/workers/:workerId", call("handleWorker", p("workerId"), ctx)),
    r("DELETE", "/api/workers/:workerId", call("handleWorker", p("workerId"), ctx)),
    r("*", "/api/workers/:workerId/mcp-pin", call("handleWorkerMcpPin", p("workerId"), ctx)),
    r("POST", "/api/workers/:workerId/models/refresh", call("handleWorkerModelsRefresh", p("workerId"), ctx)),
    r("*", "/api/workers/:workerId/usage", call("handleWorkerUsageRead", p("workerId"), ctx)),
    // Pairing, credentials and sessions (ADR-034). Owner routes need the signed-in
    // owner; Agent routes carry a pairing secret or an Ed25519 signature instead of
    // a browser session (flags: worker_identity, worker_agent_connect).
    r("POST", "/api/workers/:workerId/pairing", call("handleWorkerPairing", p("workerId"), ctx)),
    r("POST", "/api/workers/:workerId/transfer", call("handleWorkerTransfer", p("workerId"), ctx)),
    r("DELETE", "/api/workers/:workerId/credential", call("handleWorkerCredential", p("workerId"), ctx)),
    r("POST", "/api/worker-agent/claim", call("handleClaimWorkerPairing", ctx), machine),
    r("POST", "/api/worker-agent/nonce", call("handleWorkerNonce"), machine),
    r("GET", "/api/worker-agent/profile", call("handleAgentProfile"), machine),
    r("PUT", "/api/worker-agent/models", call("handleAgentModels"), machine),
    r("PUT", "/api/worker-agent/usage", call("handleAgentUsage"), machine),
    r("PUT", "/api/worker-agent/folders", (c) => handleAgentFolders(c.request, c.env), machine),
    r("POST", "/api/worker-agent/sessions", call("handleConnectWorkerSession"), machine),
    r("GET", "/api/worker-agent/gateway", call("handleWorkerGatewayConnect"), machine),
    r("POST", "/api/worker-agent/unpair", call("handleUnpairWorkerAgent"), machine),
    r("POST", "/api/worker-agent/rotate", call("handleRotateWorkerCredential"), machine),
    r("POST", "/api/worker-agent/artifacts", call("handleUploadArtifact"), machine),
    r("GET", "/api/worker-agent/artifacts/:artifactId/content", call("handleDownloadArtifact", p("artifactId")), machine),
    r("GET", "/api/workers/:workerTypeId/profile", call("handleGetWorkspaceV9WorkerProfile", p("workerTypeId"))),
    r("GET", "/api/admin/workers", call("handleListV9WorkerProfiles", ctx)),
    r("GET", "/api/admin/workers/:workerTypeId/profile", call("handleGetV9WorkerProfile", p("workerTypeId"), ctx)),
    r("PUT", "/api/admin/workers/:workerTypeId/profile", call("handlePublishV9WorkerProfile", p("workerTypeId"), ctx)),
    r("POST", "/api/admin/workers/:workerTypeId/profile/validate", call("handleValidateV9WorkerProfile", p("workerTypeId"), ctx)),
    r("GET", "/api/admin/workers/:workerTypeId/profile/history", call("handleListV9WorkerProfileHistory", p("workerTypeId"), ctx)),
    r("POST", "/api/admin/workers/:workerTypeId/profile/restore", call("handleRestoreV9WorkerProfile", p("workerTypeId"), ctx)),
    r("GET", "/api/workspace-releases/latest", call("handleGetLatestWorkspaceRelease")),
    r("POST", "/api/workspace-releases/publish", call("handlePublishWorkspaceRelease", ctx)),
    r("GET", "/api/workspace-releases/:version/download", call("handleDownloadWorkspaceRelease", p("version"), ctx)),
    r("POST", "/api/workspace-releases/:version/revoke", call("handleRevokeWorkspaceRelease", p("version"), ctx)),
    r("GET", "/api/workspace-releases/:version", (c) => h.handleGetWorkspaceRelease!(c.env, c.params.version)),

    // Spaces.
    r("GET", "/api/spaces", call("handleListSpaces", ctx)),
    r("POST", "/api/spaces", call("handleCreateSpace", ctx), idempotent),
    r("GET", "/api/spaces/:spaceId", call("handleGetSpace", p("spaceId"), ctx)),
    r("PATCH", "/api/spaces/:spaceId", call("handleUpdateSpace", p("spaceId"), ctx)),
    r("DELETE", "/api/spaces/:spaceId", call("handleDeleteSpace", p("spaceId"), ctx)),
    r("GET", "/api/spaces/:spaceId/members", call("handleListSpaceMembers", p("spaceId"), ctx)),
    r("PATCH", "/api/spaces/:spaceId/members/:userId/role", call("handleChangeSpaceMemberRole", p("spaceId"), p("userId"), ctx)),
    r("PATCH", "/api/spaces/:spaceId/members/:userId/permissions", call("handleChangeSpaceMemberRole", p("spaceId"), p("userId"), ctx)),
    r("POST", "/api/spaces/:spaceId/members/:userId/remove", call("handleRemoveSpaceMember", p("spaceId"), p("userId"), ctx)),
    r("GET", "/api/spaces/:spaceId/invitations", call("handleListSpaceInvitations", p("spaceId"), ctx)),
    r("POST", "/api/spaces/:spaceId/invitations", call("handleCreateSpaceInvitation", p("spaceId"), ctx), ownReceipt),
    r("POST", "/api/spaces/:spaceId/invitations/:invitationId/expire", call("handleExpireSpaceInvitation", p("spaceId"), p("invitationId"), ctx)),
    r("GET", "/api/spaces/:spaceId/audit", call("handleListSpaceAudit", p("spaceId"), ctx)),
    r("POST", "/api/invitations/:invitationId/accept", call("handleAcceptSpaceInvitation", p("invitationId"), ctx)),
    r("POST", "/api/space-invitations/:invitationId/accept", call("handleAcceptSpaceInvitation", p("invitationId"), ctx)),
    r("POST", "/api/invitations/:invitationId/decline", call("handleDeclineSpaceInvitation", p("invitationId"), ctx)),
    r("POST", "/api/space-invitations/:invitationId/decline", call("handleDeclineSpaceInvitation", p("invitationId"), ctx)),

    // Threads.
    r("GET", "/api/spaces/:spaceId/threads", call("handleListSpaceThreads", p("spaceId"), ctx)),
    r("POST", "/api/spaces/:spaceId/threads", call("handleCreateThread", p("spaceId"), ctx), ownReceipt),
    r("PATCH", "/api/threads/:threadId", call("handleUpdateThread", p("threadId"), ctx)),
    r("DELETE", "/api/threads/:threadId", call("handleDeleteThread", p("threadId"), ctx)),
    r("POST", "/api/threads/:threadId/read", call("handleMarkThreadRead", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/read-states", call("handleListThreadReadStates", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/note", call("handleThreadNote", p("threadId"), ctx)),
    r("PUT", "/api/threads/:threadId/note", call("handleThreadNote", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/discussion-messages", call("handleListDiscussionMessages", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/timeline", call("handleListThreadTimeline", p("threadId"), ctx)),
    r("POST", "/api/threads/:threadId/discussion-messages", call("handleCreateDiscussionMessage", p("threadId"), ctx), ownReceipt),
    r("GET", "/api/discussion-messages/:messageId", call("handleGetDiscussionMessage", p("messageId"), ctx)),
    r("PATCH", "/api/discussion-messages/:messageId", call("handleEditDiscussionMessage", p("messageId"), ctx)),
    r("DELETE", "/api/discussion-messages/:messageId", call("handleDeleteDiscussionMessage", p("messageId"), ctx)),
    r("*", "/api/threads/:threadId/queue", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, null, null, c.ctx)),
    r("*", "/api/threads/:threadId/queue/pause", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, null, "pause", c.ctx)),
    r("*", "/api/threads/:threadId/queue/resume", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, null, "resume", c.ctx)),
    r("*", "/api/threads/:threadId/queue/:itemId", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, c.params.itemId!, null, c.ctx)),
    r("*", "/api/threads/:threadId/queue/:itemId/send-now", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, c.params.itemId!, "send-now", c.ctx)),
    r("*", "/api/threads/:threadId/queue/:itemId/stop-phases", (c) => handleThreadRequestQueue(c.request, c.env, c.params.threadId!, c.params.itemId!, "stop-phases", c.ctx)),
    r("GET", "/api/threads/:threadId/conversations/:conversationId/history", call("handleListConversationHistory", p("threadId"), p("conversationId"), ctx)),
    r("POST", "/api/threads/:threadId/work-history/clear", call("handleClearWorkHistory", p("threadId"), ctx), ownReceipt),
    r("POST", "/api/threads/:threadId/chat/clear", call("handleClearChatHistory", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/files/:fileId", call("handleDownloadThreadFile", p("threadId"), p("fileId"), ctx)),
    r("POST", "/api/threads/:threadId/work-request-files", call("handleUploadWorkRequestFile", p("threadId"), ctx)),

    // Work Requests.
    r("POST", "/api/threads/:threadId/work-requests/validate", call("handleValidateWorkRequest", p("threadId"), ctx)),
    r("GET", "/api/threads/:threadId/eligible-workers", call("handleListEligibleWorkers", p("threadId"), ctx)),
    r("POST", "/api/threads/:threadId/work-requests", call("handleCreateWorkRequest", p("threadId"), ctx), ownReceipt),
    r("GET", "/api/threads/:threadId/work-requests", call("handleListWorkRequests", p("threadId"), ctx)),
    r("PUT", "/api/work-requests/:workRequestId/inputs/:inputId", call("handleUploadWorkRequestInput", p("workRequestId"), p("inputId"), ctx)),
    r("POST", "/api/work-requests/:workRequestId/inputs/:inputId/failed", call("handleFailWorkRequestInputUpload", p("workRequestId"), p("inputId"), ctx)),
    r("POST", "/api/work-requests/:workRequestId/approve-plan", (c) => handleApprovePlan(c.request, c.env, c.params.workRequestId!, c.ctx)),
    r("GET", "/api/work-requests/:workRequestId", call("handleGetWorkRequest", p("workRequestId"), ctx)),
    r("POST", "/api/work-requests/:workRequestId/cancel", call("handleCancelWorkRequest", p("workRequestId"), ctx)),
    r("POST", "/api/work-requests/:workRequestId/retry", call("handleRetryWorkRequest", p("workRequestId"), ctx)),

    // Personal files, notes, pins, notifications.
    r("GET", "/api/files", call("handleListUserFiles", ctx)),
    r("POST", "/api/files/sync", call("handleSyncUserFiles", ctx)),
    r("GET", "/api/files/:fileId", call("handleDownloadUserFile", p("fileId"), ctx)),
    r("DELETE", "/api/files/:fileId", call("handleDeleteUserFile", p("fileId"), ctx)),
    r("GET", "/api/notes", call("handleListNotes", ctx)),
    r("POST", "/api/notes", call("handleCreateNote", ctx), idempotent),
    r("GET", "/api/notes/:noteId", call("handleNote", p("noteId"), ctx)),
    r("PUT", "/api/notes/:noteId", call("handleNote", p("noteId"), ctx)),
    r("DELETE", "/api/notes/:noteId", call("handleNote", p("noteId"), ctx)),
    r("PUT", "/api/pins/order", call("handleSetPinOrder", ctx)),
    r("PUT", "/api/pins/:kind/:targetId", call("handleSetPin", p("kind"), p("targetId"), ctx)),
    r("DELETE", "/api/pins/:kind/:targetId", call("handleSetPin", p("kind"), p("targetId"), ctx)),
    r("GET", "/api/notifications", call("handleListNotifications", ctx)),
    r("POST", "/api/notifications/read", call("handleMarkNotificationsRead", ctx)),
  ];
}

/* -------------------------------------------------------- same-origin rule */

/**
 * Browser mutations must come from a trusted origin. Exempt: routes marked
 * `machine` (Workspaces, webhooks) and desktop sign-in except its
 * approve/deny steps, which a person performs in the browser.
 */
export function requiresSameOrigin(route: Route | null, method: string, pathname: string): boolean {
  if (method !== "POST" && method !== "PUT" && method !== "PATCH" && method !== "DELETE") return false;
  if (route?.machine) return false;
  if (pathname.startsWith("/api/desktop-auth/"))
    return pathname.endsWith("/approve") || pathname.endsWith("/deny");
  return true;
}
