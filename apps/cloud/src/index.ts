import { sweepThreadRequestQueues } from "./routes/thread-request-queue.js";
import type { SecurityEnv } from "./routes/http-security.js";
export { SyntilaRunWorkflow } from "./workflow.js";
export { WorkspaceGateway } from "./workspace-gateway.js";
export { ThreadExecutionCoordinator } from "./thread-coordinator.js";
export { RealtimeGateway } from "./realtime-gateway.js";
export {
  CloudEventPublisher,
  createEventPublisher,
  type DomainEventInput,
  type EventPublisher,
  type EventPublisherEnv,
  type PublishedEventResult,
} from "./event-publisher.js";
export {
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
export {
  IdentityService,
  identityService,
  type AuthenticatedIdentity,
} from "./auth/index.js";
export { requireSameOriginForCookieMutation } from "./routes/handlers.js";

type StaticAssetEnvironment = {
  ASSETS?: {
    fetch: (request: Request) => Promise<Response>;
  };
};

import { sweepUnsignaledTerminals } from "./assignment-workflow-signal.js";
import * as handlers from "./routes/handlers.js";
import { handleBetterAuthRequest, identityService } from "./auth/index.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "./routes/router.js";
import {
  isTrustedOrigin,
  isTrustedRealtimeOrigin,
  logStructured,
  requestIdFor,
  withRequestId,
} from "./observability.js";
import { pruneExpiredRealtimeEvents } from "./realtime-retention.js";
import { pruneWorkerActivityHistory } from "./worker-activity-history.js";
import { recoverStaleAssignments } from "./assignment-dispatcher.js";
import { pruneExpiredIssueReports } from "./issue-report-retention.js";
import { pruneOrphanUserFiles } from "./routes/user-files.js";
import { pruneEndedAuthSessions } from "./auth/session-retention.js";
import {
  handleCreateIssueReport,
  handleGetIssueReport,
  handleGetIssueReportForRequest,
  handleListAdminIssueReports,
  handleGetAdminIssueReport,
  handlePatchAdminIssueReport,
  handleListAdminIssueReportGroups,
  handleCreateAdminIssueReportGroup,
  handleGetAdminIssueReportGroup,
} from "./routes/issue-reports.js";

function applyCorsHeaders(
  response: Response,
  origin: string | null,
  isTrusted: boolean,
): Response {
  if (!origin || !isTrusted || response.status === 101) return response;
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-credentials", "true");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export const routeHandlers = {
  handleCreateIssueReport,
  handleGetIssueReport,
  handleGetIssueReportForRequest,
  handleListAdminIssueReports,
  handleGetAdminIssueReport,
  handlePatchAdminIssueReport,
  handleListAdminIssueReportGroups,
  handleCreateAdminIssueReportGroup,
  handleGetAdminIssueReportGroup,
  handleProfileLabAccess: handlers.handleProfileLabAccess,
  handleSession: handlers.handleSession,
  handleSessionLogout: handlers.handleSessionLogout,
  handleCreateDesktopAuthIntent: handlers.handleCreateDesktopAuthIntent,
  handleDesktopPasswordSignIn: handlers.handleDesktopPasswordSignIn,
  handleDesktopAuthIntentStatus: handlers.handleDesktopAuthIntentStatus,
  handleDesktopAuthIntentBrowserStatus:
    handlers.handleDesktopAuthIntentBrowserStatus,
  handleCancelDesktopAuthIntent: handlers.handleCancelDesktopAuthIntent,
  handleDenyDesktopAuthIntent: handlers.handleDenyDesktopAuthIntent,
  handleApproveDesktopAuthIntent: handlers.handleApproveDesktopAuthIntent,
  handleClaimDesktopAuthIntent: handlers.handleClaimDesktopAuthIntent,
  handleRevokeDesktopHumanSession: handlers.handleRevokeDesktopHumanSession,
  handleGetDesktopHumanSession: handlers.handleGetDesktopHumanSession,
  handleCheckWorkspaceOwnership: handlers.handleCheckWorkspaceOwnership,
  handleReconcileWorkspaceOwnership: handlers.handleReconcileWorkspaceOwnership,
  handleDisconnectDesktopWorkspace: handlers.handleDisconnectDesktopWorkspace,
  handleReleaseDesktopWorkspace: handlers.handleReleaseDesktopWorkspace,
  handleRegisterWorkspaceFromDesktop:
    handlers.handleRegisterWorkspaceFromDesktop,
  handleRotateDesktopHumanSession: handlers.handleRotateDesktopHumanSession,
  handleCompleteStepUp: handlers.handleCompleteStepUp,
  handleListWorkspaces: handlers.handleListWorkspaces,
  handleUploadArtifact: handlers.handleUploadArtifact,
  handleGetArtifact: handlers.handleGetArtifact,
  handleExportWorkspaceAudit: handlers.handleExportWorkspaceAudit,
  handleWorkspaceGatewayConnect: handlers.handleWorkspaceGatewayConnect,
  handleWorkspaceRuntimeTransport: handlers.handleWorkspaceRuntimeTransport,
  handleGetReleaseTrustState: handlers.handleGetReleaseTrustState,
  handleRevokeReleaseSigningKey: handlers.handleRevokeReleaseSigningKey,
  handleListWorkerCatalog: handlers.handleListWorkerCatalog,
  handleListWorkspaceWorkerCatalog: handlers.handleListWorkspaceWorkerCatalog,
  handleListWorkspaceWorkerInventory:
    handlers.handleListWorkspaceWorkerInventory,
  handleGetLatestWorkspaceRelease: handlers.handleGetLatestWorkspaceRelease,
  handlePublishWorkspaceRelease: handlers.handlePublishWorkspaceRelease,
  handleDownloadWorkspaceRelease: handlers.handleDownloadWorkspaceRelease,
  handleRevokeWorkspaceRelease: handlers.handleRevokeWorkspaceRelease,
  handleGetWorkspaceRelease: handlers.handleGetWorkspaceRelease,
  handleGetWorkspace: handlers.handleGetWorkspace,
  handleUpdateWorkspace: handlers.handleUpdateWorkspace,
  handleWorkspaceDeliveryProbe: handlers.handleWorkspaceDeliveryProbe,
  handleWorkerUsage: handlers.handleWorkerUsage,
  handleRevokeWorkspace: handlers.handleRevokeWorkspace,
  handleListSpaces: handlers.handleListSpaces,
  handleCreateSpace: handlers.handleCreateSpace,
  handleUpdateSpace: handlers.handleUpdateSpace,
  handleDeleteSpace: handlers.handleDeleteSpace,
  handleListSpaceMembers: handlers.handleListSpaceMembers,
  handleListSpaceInvitations: handlers.handleListSpaceInvitations,
  handleListSpaceAudit: handlers.handleListSpaceAudit,
  handleCreateSpaceInvitation: handlers.handleCreateSpaceInvitation,
  handleChangeSpaceMemberRole: handlers.handleChangeSpaceMemberRole,
  handleRemoveSpaceMember: handlers.handleRemoveSpaceMember,
  handleExpireSpaceInvitation: handlers.handleExpireSpaceInvitation,
  handleAcceptSpaceInvitation: handlers.handleAcceptSpaceInvitation,
  handleDeclineSpaceInvitation: handlers.handleDeclineSpaceInvitation,
  handleListCurrentUserInvitations: handlers.handleListCurrentUserInvitations,
  handleGetSpace: handlers.handleGetSpace,
  handleListSpaceThreads: handlers.handleListSpaceThreads,
  handleCreateThread: handlers.handleCreateThread,
  handleUpdateThread: handlers.handleUpdateThread,
  handleDeleteThread: handlers.handleDeleteThread,
  handleMarkThreadRead: handlers.handleMarkThreadRead,
  handleListThreadReadStates: handlers.handleListThreadReadStates,
  handleSetPin: handlers.handleSetPin,
  handleSetPinOrder: handlers.handleSetPinOrder,
  handleListUserFiles: handlers.handleListUserFiles,
  handleSyncUserFiles: handlers.handleSyncUserFiles,
  handleDeleteUserFile: handlers.handleDeleteUserFile,
  handleListNotes: handlers.handleListNotes,
  handleCreateNote: handlers.handleCreateNote,
  handleNote: handlers.handleNote,
  handleThreadNote: handlers.handleThreadNote,
  handleListNotifications: handlers.handleListNotifications,
  handleMarkNotificationsRead: handlers.handleMarkNotificationsRead,
  handleListDiscussionMessages: handlers.handleListDiscussionMessages,
  handleCreateDiscussionMessage: handlers.handleCreateDiscussionMessage,
  handleEditDiscussionMessage: handlers.handleEditDiscussionMessage,
  handleDeleteDiscussionMessage: handlers.handleDeleteDiscussionMessage,
  handleClearChatHistory: handlers.handleClearChatHistory,
  handleGetDiscussionMessage: handlers.handleGetDiscussionMessage,
  handleCreateWorkRequest: handlers.handleCreateWorkRequest,
  handleRetryWorkRequest: handlers.handleRetryWorkRequest,
  handleValidateWorkRequest: handlers.handleValidateWorkRequest,
  handleUploadWorkRequestInput: handlers.handleUploadWorkRequestInput,
  handleFailWorkRequestInputUpload: handlers.handleFailWorkRequestInputUpload,
  handleListRuntimeInputs: handlers.handleListRuntimeInputs,
  handleDownloadRuntimeInput: handlers.handleDownloadRuntimeInput,
  handleConfirmRuntimeInput: handlers.handleConfirmRuntimeInput,
  handleReportRuntimeInputAttempt: handlers.handleReportRuntimeInputAttempt,
  handleUploadWorkRequestFile: handlers.handleUploadWorkRequestFile,
  handleDownloadThreadFile: handlers.handleDownloadThreadFile,
  handleCancelWorkRequest: handlers.handleCancelWorkRequest,
  handleClearWorkHistory: handlers.handleClearWorkHistory,
  handleGetWorkRequest: handlers.handleGetWorkRequest,
  handleListWorkRequests: handlers.handleListWorkRequests,
  handleListConversations: handlers.handleListConversations,
  handleListConversationHistory: handlers.handleListConversationHistory,
  handleListV9WorkerProfiles: handlers.handleListV9WorkerProfiles,
  handleGetV9WorkerProfile: handlers.handleGetV9WorkerProfile,
  handleValidateV9WorkerProfile: handlers.handleValidateV9WorkerProfile,
  handlePublishV9WorkerProfile: handlers.handlePublishV9WorkerProfile,
  handleListV9WorkerProfileHistory: handlers.handleListV9WorkerProfileHistory,
  handleRestoreV9WorkerProfile: handlers.handleRestoreV9WorkerProfile,
  handleGetWorkspaceV9WorkerProfile: handlers.handleGetWorkspaceV9WorkerProfile,
  handleGetHomeReadModel: handlers.handleGetHomeReadModel,
  handleGetAvatar: handlers.handleGetAvatar,
  handleUploadAvatar: handlers.handleUploadAvatar,
} as unknown as WorkerRouteHandlers;

const routeDependencies = {
  json: handlers.json,
  requireSameOriginForCookieMutation:
    handlers.requireSameOriginForCookieMutation,
  errorMessage: handlers.errorMessage,
  HttpError: handlers.HttpError,
} as unknown as WorkerRouteDependencies;

export default {
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const recoveredAssignments = await recoverStaleAssignments(
      env.SYNTILA_DB,
      new Date(),
      env,
    );
    // Outbox: terminal assignments whose Workflow notification was not
    // delivered. Independent of the recovery pass above and best effort.
    const workflowSignals = await sweepUnsignaledTerminals(env).catch(() => ({
      attempted: 0,
      signaled: 0,
    }));
    // Queued Thread requests whose turn came without a Workflow event.
    await sweepThreadRequestQueues(env as SecurityEnv).catch((error) =>
      console.error("Thread request queue sweep failed", error),
    );
    if (controller.cron !== "17 3 * * *") {
      console.log(
        JSON.stringify({
          event: "assignment_recovery_complete",
          recoveredAssignments,
          workflowSignals,
        }),
      );
      return;
    }
    const deleted = await pruneExpiredRealtimeEvents(env.SYNTILA_DB);
    const deletedWorkerActivity = await pruneWorkerActivityHistory(
      env.SYNTILA_DB,
    );
    const deletedIssueReports = await pruneExpiredIssueReports(
      env.SYNTILA_DB,
      env.SYNTILA_ARTIFACTS,
    );
    const deletedOrphanFiles = await pruneOrphanUserFiles(
      env as unknown as Parameters<typeof pruneOrphanUserFiles>[0],
    ).catch(() => 0);
    const deletedAuthSessions = await pruneEndedAuthSessions(
      env.SYNTILA_DB,
    ).catch((error) => {
      console.error("Auth session retention failed", error);
      return 0;
    });
    console.log(
      JSON.stringify({
        event: "realtime_event_retention_complete",
        deleted,
        deletedAuthSessions,
        deletedOrphanFiles,
        deletedWorkerActivity,
        deletedIssueReports,
        recoveredAssignments,
      }),
    );
  },
  async fetch(
    request: Request,
    env: Env,
    ctx?: ExecutionContext,
  ): Promise<Response> {
    const requestId = requestIdFor(request);
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      const requestHeaders = new Headers(request.headers);
      requestHeaders.set("x-request-id", requestId);
      request = new Request(request, { headers: requestHeaders });
    }
    const url = new URL(request.url);
    logStructured(
      "info",
      "http.request",
      { requestId },
      {
        method: request.method,
        path: url.pathname,
      },
    );

    const origin = request.headers.get("origin");
    const configuredOrigins = (
      env as unknown as { BETTER_AUTH_TRUSTED_ORIGINS?: string }
    ).BETTER_AUTH_TRUSTED_ORIGINS?.split(",")
      .map((item) => item.trim().replace(/\/$/, ""))
      .filter(Boolean);
    const isTrusted = origin
      ? isTrustedOrigin(request, configuredOrigins)
      : false;

    if (request.method === "OPTIONS" && origin && isTrusted) {
      return withRequestId(
        new Response(null, {
          status: 204,
          headers: {
            "access-control-allow-origin": origin,
            "access-control-allow-credentials": "true",
            "access-control-allow-methods":
              "GET, POST, PUT, PATCH, DELETE, OPTIONS",
            "access-control-allow-headers":
              request.headers.get("access-control-request-headers") ||
              "authorization, content-type, accept, x-request-id, idempotency-key",
            "access-control-max-age": "86400",
          },
        }),
        requestId,
      );
    }

    const response = await (async (): Promise<Response> => {
      const staticAssets = (env as Env & StaticAssetEnvironment).ASSETS;
      if (
        staticAssets &&
        (request.method === "GET" || request.method === "HEAD") &&
        !url.pathname.startsWith("/api/") &&
        url.pathname !== "/health"
      ) {
        // The AX Flutter app owns browser routes such as
        // /desktop-auth/approve. Explicitly delegate these requests to the
        // SPA asset binding; otherwise a Worker deployment can return the
        // API router's JSON not_found response before SPA fallback runs.
        return staticAssets.fetch(request);
      }
      if (request.method === "GET" && url.pathname === "/health") {
        return handlers.json({
          ok: true,
          environment: env.SYNTILA_ENVIRONMENT,
        });
      }
      if (request.method === "GET" && url.pathname === "/api/dev/sign-in") {
        if (env.SYNTILA_ENVIRONMENT !== "development") {
          return new Response("Not found", { status: 404 });
        }
        const provider = url.searchParams.get("provider") ?? "github";
        if (provider !== "github" && provider !== "google") {
          return handlers.json(
            { error: "provider must be github or google" },
            { status: 400 },
          );
        }
        const returnTo = url.searchParams.get("returnTo") ?? "/";
        const signInUrl = new URL(`/api/auth/sign-in/${provider}`, request.url);
        signInUrl.searchParams.set("returnTo", returnTo);
        return Response.redirect(signInUrl.toString(), 302);
      }
      if (
        request.method === "POST" &&
        url.pathname === "/api/auth/step-up/passkey/complete"
      ) {
        handlers.requireSameOriginForCookieMutation(request);
        return handlers.handleCompleteStepUp(request, env, ctx);
      }
      if (
        request.method === "POST" &&
        url.pathname === "/api/desktop-auth/profile-lab/step-up/complete"
      ) {
        return handlers.handleCompleteProfileLabStepUp(request, env, ctx);
      }
      if (
        url.pathname === "/api/auth" ||
        url.pathname.startsWith("/api/auth/")
      ) {
        return handleBetterAuthRequest(request, env);
      }
      if (url.pathname === "/api/realtime") {
        if (!isTrustedRealtimeOrigin(request, configuredOrigins)) {
          return handlers.json(
            { error: "Trusted realtime Origin required" },
            { status: 403 },
          );
        }
        const identity = await identityService.resolve(request, env);
        if (!identity) {
          return handlers.json(
            { error: "Authentication required" },
            { status: 401 },
          );
        }
        const gateway = env.SYNTILA_REALTIME_GATEWAY.getByName(
          `user:${identity.userId}`,
        );
        return gateway.fetch(request);
      }
      return routeWorkerRequest(
        request,
        env,
        ctx,
        routeHandlers,
        routeDependencies,
      );
    })();

    return applyCorsHeaders(
      withRequestId(response, requestId),
      origin,
      isTrusted,
    );
  },
} satisfies ExportedHandler<Env>;
