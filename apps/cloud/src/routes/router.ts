import { handleListPeople } from "./people.js";
import {
  handleAccountPlan,
  handleGetAvatar,
  handleReadReceiptPrivacy,
  handleUploadAvatar,
} from "./profile.js";
import { handleWorkflowWorkspace } from "./workflow-workspace.js";
import { handleSpaceAdditionalFolders } from "./space-additional-folders.js";
import { handleWorkflowConfigurations } from "./workflow-configurations.js";
import { handleWorkflowDefault } from "./workflow-default.js";
import { handleWorkspaceMemberAccess } from "./workspace-member-access.js";
import { handlePeopleWithAccess } from "./workspace-people-with-access.js";
import {
  handleAcceptWorkspaceInvitation,
  handleDeclineWorkspaceInvitation,
  handleMyWorkspaceInvitations,
  handlePersonGrantQuota,
  handleRevokePersonGrant,
  handleWorkspaceInvitations,
} from "./workspace-invitations.js";
import { handleThreadRequestQueue } from "./thread-request-queue.js";
import { conditionalJson } from "./conditional-read.js";
import { BUILTIN_WORKFLOW_CATALOG, workflowCatalogEntry } from "@syntila/core";

export type RouteHandler = (...args: unknown[]) => Promise<Response>;
export type WorkerRouteHandlers = Record<string, RouteHandler>;

export interface WorkerRouteDependencies {
  readonly json: (data: unknown, init?: ResponseInit) => Response;
  readonly requireSameOriginForCookieMutation: (request: Request) => void;
  readonly errorMessage: (error: unknown) => string;
  readonly HttpError: new (...args: unknown[]) => Error;
}

export async function routeWorkerRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext | undefined,
  handlers: WorkerRouteHandlers,
  deps: WorkerRouteDependencies,
): Promise<Response> {
  const url = new URL(request.url);
  try {
    const desktopWorkspaceRegistration =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/register";
    const desktopWorkspaceOwnershipCheck =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/ownership";
    const desktopWorkspaceOwnershipReconcile =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/ownership/reconcile";
    const desktopWorkspaceRelease =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/release";
    const desktopWorkspaceDisconnect =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/disconnect";
    const workspaceRuntimeTransport =
      request.method === "POST" &&
      (url.pathname === "/api/workspace-runtime/sessions" ||
        url.pathname === "/api/workspace-runtime/events" ||
        url.pathname === "/api/workspace-runtime/poll" ||
        /^\/api\/workspace-runtime\/sessions\/[^/]+\/close$/.test(
          url.pathname,
        ));
    // Input Delivery v1 reports use the runtime bearer credential, not a
    // cookie; they are handled by their own routes below.
    const workspaceRuntimeInputReport =
      request.method === "POST" &&
      /^\/api\/workspace-runtime\/inputs\/[^/]+\/(delivered|attempt)$/.test(
        url.pathname,
      );
    const desktopAuthPath = url.pathname.startsWith("/api/desktop-auth/");
    const desktopAuthRequiresSameOrigin =
      desktopAuthPath &&
      (url.pathname.endsWith("/approve") || url.pathname.endsWith("/deny"));
    if (
      !desktopWorkspaceRegistration &&
      !desktopWorkspaceOwnershipCheck &&
      !desktopWorkspaceOwnershipReconcile &&
      !desktopWorkspaceRelease &&
      !desktopWorkspaceDisconnect &&
      !workspaceRuntimeTransport &&
      !workspaceRuntimeInputReport &&
      (!desktopAuthPath || desktopAuthRequiresSameOrigin) &&
      (request.method === "POST" ||
        request.method === "PUT" ||
        request.method === "PATCH" ||
        request.method === "DELETE")
    ) {
      deps.requireSameOriginForCookieMutation(request);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/profile-lab/access"
    ) {
      return await handlers.handleProfileLabAccess!(request, env, ctx);
    }
    if (desktopWorkspaceRegistration) {
      return await handlers.handleRegisterWorkspaceFromDesktop!(
        request,
        env,
        ctx,
      );
    }
    if (desktopWorkspaceOwnershipCheck) {
      return await handlers.handleCheckWorkspaceOwnership!(request, env);
    }
    if (desktopWorkspaceOwnershipReconcile) {
      return await handlers.handleReconcileWorkspaceOwnership!(request, env);
    }
    if (desktopWorkspaceRelease) {
      return await handlers.handleReleaseDesktopWorkspace!(request, env);
    }
    if (desktopWorkspaceDisconnect) {
      return await handlers.handleDisconnectDesktopWorkspace!(request, env);
    }
    if (workspaceRuntimeTransport) {
      return await handlers.handleWorkspaceRuntimeTransport!(request, env);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/desktop-auth/intents"
    ) {
      return await handlers.handleCreateDesktopAuthIntent!(request, env);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/desktop-auth/password"
    ) {
      return await handlers.handleDesktopPasswordSignIn!(request, env);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/desktop-auth/session"
    ) {
      return await handlers.handleGetDesktopHumanSession!(request, env);
    }
    const desktopIntentMatch = url.pathname.match(
      /^\/api\/desktop-auth\/intents\/([^/]+)(?:\/(approve|claim|cancel|deny|browser-status))?$/,
    );
    if (desktopIntentMatch?.[1]) {
      const intentId = decodeURIComponent(desktopIntentMatch[1]);
      if (request.method === "GET" && !desktopIntentMatch[2]) {
        return await handlers.handleDesktopAuthIntentStatus!(
          request,
          env,
          intentId,
        );
      }
      if (
        request.method === "GET" &&
        desktopIntentMatch[2] === "browser-status"
      ) {
        return await handlers.handleDesktopAuthIntentBrowserStatus!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "cancel") {
        return await handlers.handleCancelDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "deny") {
        return await handlers.handleDenyDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "approve") {
        return await handlers.handleApproveDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "claim") {
        return await handlers.handleClaimDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
    }
    const desktopSessionRevokeMatch = url.pathname.match(
      /^\/api\/desktop-auth\/sessions\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && desktopSessionRevokeMatch?.[1]) {
      return await handlers.handleRevokeDesktopHumanSession!(
        request,
        env,
        decodeURIComponent(desktopSessionRevokeMatch[1]),
      );
    }
    const desktopSessionRotateMatch = url.pathname.match(
      /^\/api\/desktop-auth\/sessions\/([^/]+)\/rotate$/,
    );
    if (request.method === "POST" && desktopSessionRotateMatch?.[1]) {
      return await handlers.handleRotateDesktopHumanSession!(
        request,
        env,
        decodeURIComponent(desktopSessionRotateMatch[1]),
      );
    }
    if (url.pathname === "/api/people")
      return await handleListPeople(request, env, ctx);
    if (request.method === "PUT" && url.pathname === "/api/profile/avatar")
      return await handleUploadAvatar(request, env, ctx);
    if (url.pathname === "/api/me/privacy")
      return await handleReadReceiptPrivacy(request, env, ctx);
    if (url.pathname === "/api/me/plan")
      return await handleAccountPlan(request, env, ctx);
    const avatarMatch = url.pathname.match(/^\/api\/users\/([^/]+)\/avatar$/);
    if (request.method === "GET" && avatarMatch?.[1])
      return await handleGetAvatar(
        request,
        env,
        decodeURIComponent(avatarMatch[1]),
        ctx,
      );
    if (request.method === "GET" && url.pathname === "/api/session") {
      return await handlers.handleSession!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/issue-reports") {
      return await handlers.handleCreateIssueReport!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/issue-reports") {
      return await handlers.handleGetIssueReportForRequest!(request, env, ctx);
    }
    const issueReportMatch = url.pathname.match(
      /^\/api\/issue-reports\/([^/]+)$/,
    );
    if (request.method === "GET" && issueReportMatch?.[1]) {
      return await handlers.handleGetIssueReport!(
        request,
        env,
        decodeURIComponent(issueReportMatch[1]),
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/issue-reports"
    ) {
      return await handlers.handleListAdminIssueReports!(request, env, ctx);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/issue-reports/groups"
    ) {
      return await handlers.handleListAdminIssueReportGroups!(
        request,
        env,
        ctx,
      );
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/admin/issue-reports/groups"
    ) {
      return await handlers.handleCreateAdminIssueReportGroup!(
        request,
        env,
        ctx,
      );
    }
    const adminIssueReportGroupMatch = url.pathname.match(
      /^\/api\/admin\/issue-reports\/groups\/([^/]+)$/,
    );
    if (adminIssueReportGroupMatch?.[1] && request.method === "GET") {
      return await handlers.handleGetAdminIssueReportGroup!(
        request,
        env,
        decodeURIComponent(adminIssueReportGroupMatch[1]),
        ctx,
      );
    }
    const adminIssueReportMatch = url.pathname.match(
      /^\/api\/admin\/issue-reports\/([^/]+)$/,
    );
    if (adminIssueReportMatch?.[1] && request.method === "GET") {
      return await handlers.handleGetAdminIssueReport!(
        request,
        env,
        decodeURIComponent(adminIssueReportMatch[1]),
        ctx,
      );
    }
    if (adminIssueReportMatch?.[1] && request.method === "PATCH") {
      return await handlers.handlePatchAdminIssueReport!(
        request,
        env,
        decodeURIComponent(adminIssueReportMatch[1]),
        ctx,
      );
    }
    if (request.method === "POST" && url.pathname === "/api/session/logout") {
      return await handlers.handleSessionLogout!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/workspaces") {
      return await handlers.handleListWorkspaces!(request, env, ctx);
    }
    const memberAccessMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/member-access(?:\/people\/([^/]+))?$/,
    );
    if (memberAccessMatch)
      return await handleWorkspaceMemberAccess(
        request,
        env,
        decodeURIComponent(memberAccessMatch[1]!),
        ctx,
        memberAccessMatch[2]
          ? decodeURIComponent(memberAccessMatch[2])
          : undefined,
      );
    const workspaceInvitationsMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/invitations(?:\/([^/]+)\/revoke)?$/,
    );
    if (workspaceInvitationsMatch)
      return await handleWorkspaceInvitations(
        request,
        env,
        decodeURIComponent(workspaceInvitationsMatch[1]!),
        workspaceInvitationsMatch[2]
          ? decodeURIComponent(workspaceInvitationsMatch[2])
          : undefined,
        ctx,
      );
    const peopleWithAccessMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/people-with-access$/,
    );
    if (peopleWithAccessMatch)
      return await handlePeopleWithAccess(
        request,
        env,
        decodeURIComponent(peopleWithAccessMatch[1]!),
        ctx,
      );
    const personGrantQuotaMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/person-grants\/([^/]+)\/quota$/,
    );
    if (personGrantQuotaMatch)
      return await handlePersonGrantQuota(
        request,
        env,
        decodeURIComponent(personGrantQuotaMatch[1]!),
        decodeURIComponent(personGrantQuotaMatch[2]!),
        ctx,
      );
    const personGrantRevokeMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/person-grants\/([^/]+)\/revoke$/,
    );
    if (personGrantRevokeMatch)
      return await handleRevokePersonGrant(
        request,
        env,
        decodeURIComponent(personGrantRevokeMatch[1]!),
        decodeURIComponent(personGrantRevokeMatch[2]!),
        ctx,
      );
    if (url.pathname === "/api/workspace-invitations")
      return await handleMyWorkspaceInvitations(request, env, ctx);
    const workspaceInvitationAcceptMatch = url.pathname.match(
      /^\/api\/workspace-invitations\/([^/]+)\/accept$/,
    );
    if (workspaceInvitationAcceptMatch)
      return await handleAcceptWorkspaceInvitation(
        request,
        env,
        decodeURIComponent(workspaceInvitationAcceptMatch[1]!),
        ctx,
      );
    const workspaceInvitationDeclineMatch = url.pathname.match(
      /^\/api\/workspace-invitations\/([^/]+)\/decline$/,
    );
    if (workspaceInvitationDeclineMatch)
      return await handleDeclineWorkspaceInvitation(
        request,
        env,
        decodeURIComponent(workspaceInvitationDeclineMatch[1]!),
        ctx,
      );
    const workspaceSettingsMatch = url.pathname.match(
      /^\/api\/(user|spaces\/([^/]+))\/workflow-workspace$/,
    );
    if (workspaceSettingsMatch)
      return await handleWorkflowWorkspace(
        request,
        env,
        workspaceSettingsMatch[2],
        ctx,
      );
    const spaceAdditionalFoldersMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/additional-folders$/,
    );
    if (spaceAdditionalFoldersMatch)
      return await handleSpaceAdditionalFolders(
        request,
        env,
        decodeURIComponent(spaceAdditionalFoldersMatch[1]!),
        ctx,
      );
    const spaceWorkflowDefaultMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/workflow-default$/,
    );
    if (spaceWorkflowDefaultMatch)
      return await handleWorkflowDefault(
        request,
        env,
        decodeURIComponent(spaceWorkflowDefaultMatch[1]!),
        ctx,
      );
    if (url.pathname === "/api/user/workflow-default")
      return await handleWorkflowDefault(request, env, undefined, ctx);
    const spaceWorkflowMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/workflow-configurations(?:\/([^/]+))?$/,
    );
    if (spaceWorkflowMatch)
      return await handleWorkflowConfigurations(
        request,
        env,
        spaceWorkflowMatch[2]
          ? decodeURIComponent(spaceWorkflowMatch[2])
          : undefined,
        ctx,
        decodeURIComponent(spaceWorkflowMatch[1]!),
      );
    const workflowConfigurationMatch = url.pathname.match(
      /^\/api\/user\/workflow-configurations(?:\/([^/]+))?$/,
    );
    if (workflowConfigurationMatch) {
      return await handleWorkflowConfigurations(
        request,
        env,
        workflowConfigurationMatch[1]
          ? decodeURIComponent(workflowConfigurationMatch[1])
          : undefined,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workflows/catalog") {
      return conditionalJson(request, {
        workflows: Object.values(BUILTIN_WORKFLOW_CATALOG).map(
          workflowCatalogEntry,
        ),
      });
    }
    if (request.method === "GET" && url.pathname === "/api/release-trust") {
      return await handlers.handleGetReleaseTrustState!(env);
    }
    const releaseKeyRevocation = url.pathname.match(
      /^\/api\/admin\/release-trust\/keys\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && releaseKeyRevocation?.[1]) {
      return await handlers.handleRevokeReleaseSigningKey!(
        request,
        env,
        decodeURIComponent(releaseKeyRevocation[1]),
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workers/catalog") {
      return await handlers.handleListWorkerCatalog!(request, env, ctx);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-runtime/inputs"
    ) {
      return await handlers.handleListRuntimeInputs!(request, env);
    }
    const runtimeInputMatch = url.pathname.match(
      /^\/api\/workspace-runtime\/inputs\/([^/]+)\/(content|delivered|attempt)$/,
    );
    if (runtimeInputMatch?.[1]) {
      const [, fileId, action] = runtimeInputMatch;
      if (request.method === "GET" && action === "content")
        return await handlers.handleDownloadRuntimeInput!(request, env, fileId);
      if (request.method === "POST" && action === "delivered")
        return await handlers.handleConfirmRuntimeInput!(request, env, fileId);
      if (request.method === "POST" && action === "attempt")
        return await handlers.handleReportRuntimeInputAttempt!(
          request,
          env,
          fileId,
        );
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-runtime/workers/catalog"
    ) {
      return await handlers.handleListWorkspaceWorkerCatalog!(
        request,
        env,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workers") {
      return await handlers.handleListWorkspaceWorkerInventory!(
        request,
        env,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/admin/workers") {
      return await handlers.handleListV9WorkerProfiles!(request, env, ctx);
    }
    const v9AdminWorkerProfileMatch = url.pathname.match(
      /^\/api\/admin\/workers\/([^/]+)\/profile(?:\/(validate|history|restore))?$/,
    );
    if (v9AdminWorkerProfileMatch?.[1]) {
      const workerTypeId = decodeURIComponent(v9AdminWorkerProfileMatch[1]);
      const action = v9AdminWorkerProfileMatch[2];
      if (request.method === "GET" && !action) {
        return await handlers.handleGetV9WorkerProfile!(
          request,
          env,
          workerTypeId,
          ctx,
        );
      }
      if (request.method === "POST" && action === "validate") {
        return await handlers.handleValidateV9WorkerProfile!(
          request,
          env,
          workerTypeId,
          ctx,
        );
      }
      if (request.method === "PUT" && !action) {
        return await handlers.handlePublishV9WorkerProfile!(
          request,
          env,
          workerTypeId,
          ctx,
        );
      }
      if (request.method === "GET" && action === "history") {
        return await handlers.handleListV9WorkerProfileHistory!(
          request,
          env,
          workerTypeId,
          ctx,
        );
      }
      if (request.method === "POST" && action === "restore") {
        return await handlers.handleRestoreV9WorkerProfile!(
          request,
          env,
          workerTypeId,
          ctx,
        );
      }
    }
    const v9WorkspaceWorkerProfileMatch = url.pathname.match(
      /^\/api\/workers\/([^/]+)\/profile$/,
    );
    if (request.method === "GET" && v9WorkspaceWorkerProfileMatch?.[1]) {
      return await handlers.handleGetWorkspaceV9WorkerProfile!(
        request,
        env,
        decodeURIComponent(v9WorkspaceWorkerProfileMatch[1]),
      );
    }
    const artifactUploadMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/artifacts$/,
    );
    if (request.method === "POST" && artifactUploadMatch?.[1]) {
      return await handlers.handleUploadArtifact!(
        request,
        env,
        artifactUploadMatch[1],
        ctx,
      );
    }
    const artifactMatch = url.pathname.match(/^\/api\/artifacts\/([^/]+)$/);
    if (
      (request.method === "GET" || request.method === "HEAD") &&
      artifactMatch?.[1]
    ) {
      return await handlers.handleGetArtifact!(
        request,
        env,
        artifactMatch[1],
        ctx,
      );
    }
    const auditExportMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/audit-export$/,
    );
    if (request.method === "GET" && auditExportMatch?.[1]) {
      return await handlers.handleExportWorkspaceAudit!(
        request,
        env,
        auditExportMatch[1],
        ctx,
      );
    }
    // Workspace runtime Gateway & Protocol routes
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-gateway/connect"
    ) {
      return await handlers.handleWorkspaceGatewayConnect!(request, env);
    }
    // Workspace application release routes.
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-releases/latest"
    ) {
      return await handlers.handleGetLatestWorkspaceRelease!(request, env);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/workspace-releases/publish"
    ) {
      return await handlers.handlePublishWorkspaceRelease!(request, env, ctx);
    }
    const workspaceReleaseDownloadMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)\/download$/,
    );
    if (request.method === "GET" && workspaceReleaseDownloadMatch?.[1]) {
      return await handlers.handleDownloadWorkspaceRelease!(
        request,
        env,
        workspaceReleaseDownloadMatch[1],
        ctx,
      );
    }
    const workspaceReleaseRevokeMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && workspaceReleaseRevokeMatch?.[1]) {
      return await handlers.handleRevokeWorkspaceRelease!(
        request,
        env,
        workspaceReleaseRevokeMatch[1],
        ctx,
      );
    }
    const singleWorkspaceReleaseMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)$/,
    );
    if (request.method === "GET" && singleWorkspaceReleaseMatch?.[1]) {
      return await handlers.handleGetWorkspaceRelease!(
        env,
        singleWorkspaceReleaseMatch[1],
      );
    }

    const workspaceProbeMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/delivery-probe$/,
    );
    if (request.method === "POST" && workspaceProbeMatch?.[1]) {
      return await handlers.handleWorkspaceDeliveryProbe!(
        request,
        env,
        workspaceProbeMatch[1],
        ctx,
      );
    }

    const workerUsageMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/workers\/([^/]+)\/usage$/,
    );
    if (
      request.method === "POST" &&
      workerUsageMatch?.[1] &&
      workerUsageMatch[2]
    ) {
      return await handlers.handleWorkerUsage!(
        request,
        env,
        workerUsageMatch[1],
        decodeURIComponent(workerUsageMatch[2]),
        ctx,
      );
    }

    const workspaceMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)$/);
    if (request.method === "DELETE" && workspaceMatch?.[1]) {
      return await handlers.handleRevokeWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }
    if (request.method === "PATCH" && workspaceMatch?.[1]) {
      return await handlers.handleUpdateWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }
    if (request.method === "GET" && workspaceMatch?.[1]) {
      return await handlers.handleGetWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }

    if (
      request.method === "GET" &&
      (url.pathname === "/api/home" || url.pathname === "/home")
    ) {
      return await handlers.handleGetHomeReadModel!(request, env, ctx);
    }

    if (request.method === "GET" && url.pathname === "/api/spaces") {
      return await handlers.handleListSpaces!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/spaces") {
      return await handlers.handleCreateSpace!(request, env, ctx);
    }
    const spaceMembersMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members$/,
    );
    if (request.method === "GET" && spaceMembersMatch?.[1]) {
      return await handlers.handleListSpaceMembers!(
        request,
        env,
        spaceMembersMatch[1],
        ctx,
      );
    }
    const spaceMemberRoleMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members\/([^/]+)\/(?:role|permissions)$/,
    );
    if (
      request.method === "PATCH" &&
      spaceMemberRoleMatch?.[1] &&
      spaceMemberRoleMatch[2]
    ) {
      return await handlers.handleChangeSpaceMemberRole!(
        request,
        env,
        spaceMemberRoleMatch[1],
        spaceMemberRoleMatch[2],
        ctx,
      );
    }
    const spaceMemberRemoveMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members\/([^/]+)\/remove$/,
    );
    if (
      request.method === "POST" &&
      spaceMemberRemoveMatch?.[1] &&
      spaceMemberRemoveMatch[2]
    ) {
      return await handlers.handleRemoveSpaceMember!(
        request,
        env,
        spaceMemberRemoveMatch[1],
        spaceMemberRemoveMatch[2],
        ctx,
      );
    }
    const spaceInvitationsMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/invitations$/,
    );
    if (request.method === "GET" && spaceInvitationsMatch?.[1]) {
      return await handlers.handleListSpaceInvitations!(
        request,
        env,
        spaceInvitationsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && spaceInvitationsMatch?.[1]) {
      return await handlers.handleCreateSpaceInvitation!(
        request,
        env,
        spaceInvitationsMatch[1],
        ctx,
      );
    }
    const spaceAuditMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/audit$/,
    );
    if (request.method === "GET" && spaceAuditMatch?.[1]) {
      return await handlers.handleListSpaceAudit!(
        request,
        env,
        spaceAuditMatch[1],
        ctx,
      );
    }
    const spaceInvitationExpireMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/invitations\/([^/]+)\/expire$/,
    );
    if (
      request.method === "POST" &&
      spaceInvitationExpireMatch?.[1] &&
      spaceInvitationExpireMatch[2]
    ) {
      return await handlers.handleExpireSpaceInvitation!(
        request,
        env,
        spaceInvitationExpireMatch[1],
        spaceInvitationExpireMatch[2],
        ctx,
      );
    }
    const spaceInvitationAcceptMatch = url.pathname.match(
      /^\/api\/(?:space-)?invitations\/([^/]+)\/accept$/,
    );
    if (request.method === "POST" && spaceInvitationAcceptMatch?.[1]) {
      return await handlers.handleAcceptSpaceInvitation!(
        request,
        env,
        spaceInvitationAcceptMatch[1],
        ctx,
      );
    }
    const spaceInvitationDeclineMatch = url.pathname.match(
      /^\/api\/(?:space-)?invitations\/([^/]+)\/decline$/,
    );
    if (request.method === "POST" && spaceInvitationDeclineMatch?.[1]) {
      return await handlers.handleDeclineSpaceInvitation!(
        request,
        env,
        spaceInvitationDeclineMatch[1],
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      (url.pathname === "/api/me/invitations" ||
        url.pathname === "/api/invitations")
    ) {
      return await handlers.handleListCurrentUserInvitations!(
        request,
        env,
        ctx,
      );
    }
    const spaceMatch = url.pathname.match(/^\/api\/spaces\/([^/]+)$/);
    if (request.method === "GET" && spaceMatch?.[1]) {
      return await handlers.handleGetSpace!(request, env, spaceMatch[1], ctx);
    }
    if (request.method === "PATCH" && spaceMatch?.[1]) {
      return await handlers.handleUpdateSpace!(
        request,
        env,
        spaceMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && spaceMatch?.[1]) {
      return await handlers.handleDeleteSpace!(
        request,
        env,
        spaceMatch[1],
        ctx,
      );
    }

    const spaceThreadsMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/threads$/,
    );
    if (request.method === "GET" && spaceThreadsMatch?.[1]) {
      return await handlers.handleListSpaceThreads!(
        request,
        env,
        spaceThreadsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && spaceThreadsMatch?.[1]) {
      return await handlers.handleCreateThread!(
        request,
        env,
        spaceThreadsMatch[1],
        ctx,
      );
    }

    const threadMatch = url.pathname.match(/^\/api\/threads\/([^/]+)$/);
    if (request.method === "PATCH" && threadMatch?.[1]) {
      return await handlers.handleUpdateThread!(
        request,
        env,
        threadMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && threadMatch?.[1]) {
      return await handlers.handleDeleteThread!(
        request,
        env,
        threadMatch[1],
        ctx,
      );
    }

    if (url.pathname === "/api/files" && request.method === "GET")
      return await handlers.handleListUserFiles!(request, env, ctx);
    if (url.pathname === "/api/files/sync" && request.method === "POST")
      return await handlers.handleSyncUserFiles!(request, env, ctx);
    const userFileMatch = url.pathname.match(/^\/api\/files\/([^/]+)$/);
    if (userFileMatch?.[1] && request.method === "DELETE")
      return await handlers.handleDeleteUserFile!(
        request,
        env,
        decodeURIComponent(userFileMatch[1]),
        ctx,
      );

    if (url.pathname === "/api/notes") {
      if (request.method === "GET")
        return await handlers.handleListNotes!(request, env, ctx);
      if (request.method === "POST")
        return await handlers.handleCreateNote!(request, env, ctx);
    }
    const noteMatch = url.pathname.match(/^\/api\/notes\/([^/]+)$/);
    if (
      noteMatch?.[1] &&
      (request.method === "GET" ||
        request.method === "PUT" ||
        request.method === "DELETE")
    ) {
      return await handlers.handleNote!(
        request,
        env,
        decodeURIComponent(noteMatch[1]),
        ctx,
      );
    }
    const threadNoteMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/note$/,
    );
    if (
      threadNoteMatch?.[1] &&
      (request.method === "GET" || request.method === "PUT")
    ) {
      return await handlers.handleThreadNote!(
        request,
        env,
        threadNoteMatch[1],
        ctx,
      );
    }

    if (url.pathname === "/api/pins/order" && request.method === "PUT") {
      return await handlers.handleSetPinOrder!(request, env, ctx);
    }
    const pinMatch = url.pathname.match(/^\/api\/pins\/([^/]+)\/([^/]+)$/);
    if (pinMatch && (request.method === "PUT" || request.method === "DELETE")) {
      return await handlers.handleSetPin!(
        request,
        env,
        decodeURIComponent(pinMatch[1]!),
        decodeURIComponent(pinMatch[2]!),
        ctx,
      );
    }
    if (url.pathname === "/api/notifications") {
      if (request.method === "GET")
        return await handlers.handleListNotifications!(request, env, ctx);
    }
    if (
      url.pathname === "/api/notifications/read" &&
      request.method === "POST"
    ) {
      return await handlers.handleMarkNotificationsRead!(request, env, ctx);
    }

    const threadReadMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/read$/,
    );
    if (request.method === "POST" && threadReadMatch?.[1]) {
      return await handlers.handleMarkThreadRead!(
        request,
        env,
        threadReadMatch[1],
        ctx,
      );
    }
    const threadReadStatesMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/read-states$/,
    );
    if (request.method === "GET" && threadReadStatesMatch?.[1]) {
      return await handlers.handleListThreadReadStates!(
        request,
        env,
        threadReadStatesMatch[1],
        ctx,
      );
    }

    const threadDiscussionMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/discussion-messages$/,
    );
    if (request.method === "GET" && threadDiscussionMatch?.[1]) {
      return await handlers.handleListDiscussionMessages!(
        request,
        env,
        threadDiscussionMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && threadDiscussionMatch?.[1]) {
      return await handlers.handleCreateDiscussionMessage!(
        request,
        env,
        threadDiscussionMatch[1],
        ctx,
      );
    }
    const discussionMessageMatch = url.pathname.match(
      /^\/api\/discussion-messages\/([^/]+)$/,
    );
    if (request.method === "GET" && discussionMessageMatch?.[1]) {
      return await handlers.handleGetDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    if (request.method === "PATCH" && discussionMessageMatch?.[1]) {
      return await handlers.handleEditDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && discussionMessageMatch?.[1]) {
      return await handlers.handleDeleteDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    const threadQueueMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/queue(?:\/(pause|resume)|\/([^/]+)(?:\/(send-now))?)?$/,
    );
    if (threadQueueMatch)
      return await handleThreadRequestQueue(
        request,
        env,
        decodeURIComponent(threadQueueMatch[1]!),
        threadQueueMatch[3] ? decodeURIComponent(threadQueueMatch[3]) : null,
        threadQueueMatch[2] ?? threadQueueMatch[4] ?? null,
        ctx,
      );
    const createWorkRequestMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-requests$/,
    );
    const conversationHistoryMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/conversations\/([^/]+)\/history$/,
    );
    if (
      request.method === "GET" &&
      conversationHistoryMatch?.[1] &&
      conversationHistoryMatch[2]
    ) {
      return await handlers.handleListConversationHistory!(
        request,
        env,
        conversationHistoryMatch[1],
        conversationHistoryMatch[2],
        ctx,
      );
    }
    const conversationsMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/conversations$/,
    );
    if (request.method === "GET" && conversationsMatch?.[1]) {
      return await handlers.handleListConversations!(
        request,
        env,
        conversationsMatch[1],
        ctx,
      );
    }
    const clearWorkHistoryMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-history\/clear$/,
    );
    if (request.method === "POST" && clearWorkHistoryMatch?.[1]) {
      return await handlers.handleClearWorkHistory!(
        request,
        env,
        clearWorkHistoryMatch[1],
        ctx,
      );
    }
    const clearChatHistoryMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/chat\/clear$/,
    );
    if (request.method === "POST" && clearChatHistoryMatch?.[1]) {
      return await handlers.handleClearChatHistory!(
        request,
        env,
        clearChatHistoryMatch[1],
        ctx,
      );
    }
    const threadFileDownload = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/files\/([^/]+)$/,
    );
    if (
      request.method === "GET" &&
      threadFileDownload?.[1] &&
      threadFileDownload[2]
    ) {
      return await handlers.handleDownloadThreadFile!(
        request,
        env,
        threadFileDownload[1],
        threadFileDownload[2],
        ctx,
      );
    }
    const workRequestFileMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-request-files$/,
    );
    if (request.method === "POST" && workRequestFileMatch?.[1]) {
      return await handlers.handleUploadWorkRequestFile!(
        request,
        env,
        workRequestFileMatch[1],
        ctx,
      );
    }
    const workRequestInputMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/inputs\/([^/]+)(\/failed)?$/,
    );
    if (workRequestInputMatch?.[1] && workRequestInputMatch[2]) {
      if (request.method === "PUT" && !workRequestInputMatch[3])
        return await handlers.handleUploadWorkRequestInput!(
          request,
          env,
          workRequestInputMatch[1],
          workRequestInputMatch[2],
          ctx,
        );
      if (request.method === "POST" && workRequestInputMatch[3])
        return await handlers.handleFailWorkRequestInputUpload!(
          request,
          env,
          workRequestInputMatch[1],
          workRequestInputMatch[2],
          ctx,
        );
    }
    const validateWorkRequestMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-requests\/validate$/,
    );
    if (request.method === "POST" && validateWorkRequestMatch?.[1]) {
      return await handlers.handleValidateWorkRequest!(
        request,
        env,
        validateWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && createWorkRequestMatch?.[1]) {
      return await handlers.handleCreateWorkRequest!(
        request,
        env,
        createWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "GET" && createWorkRequestMatch?.[1]) {
      return await handlers.handleListWorkRequests!(
        request,
        env,
        createWorkRequestMatch[1],
        ctx,
      );
    }
    const cancelWorkRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/cancel$/,
    );
    const retryWorkRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/retry$/,
    );
    const workRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)$/,
    );
    if (request.method === "GET" && workRequestMatch?.[1]) {
      return await handlers.handleGetWorkRequest!(
        request,
        env,
        workRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && cancelWorkRequestMatch?.[1]) {
      return await handlers.handleCancelWorkRequest!(
        request,
        env,
        cancelWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && retryWorkRequestMatch?.[1]) {
      return await handlers.handleRetryWorkRequest!(
        request,
        env,
        retryWorkRequestMatch[1],
        ctx,
      );
    }
  } catch (error) {
    if (!(error instanceof deps.HttpError)) {
      // Unexpected failures are reported as 400; keep their cause visible.
      console.error(
        JSON.stringify({
          level: "error",
          message: "http.unhandled_error",
          details: {
            method: request.method,
            path: url.pathname,
            error: error instanceof Error ? error.message : String(error),
            stack: error instanceof Error ? error.stack : undefined,
          },
        }),
      );
    }
    // Only HttpErrors expose a stable code; driver error codes stay internal.
    const code =
      error instanceof deps.HttpError &&
      "code" in error &&
      typeof error.code === "string"
        ? error.code
        : undefined;
    return deps.json(
      code
        ? { error: deps.errorMessage(error), code }
        : { error: deps.errorMessage(error) },
      {
        status:
          error instanceof deps.HttpError ||
          (typeof error === "object" &&
            error !== null &&
            "status" in error &&
            typeof error.status === "number")
            ? (error as { status: number }).status
            : 400,
      },
    );
  }

  return deps.json({ error: "not_found" }, { status: 404 });
}
