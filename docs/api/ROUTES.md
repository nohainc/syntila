# Backend API routes

Generated from `apps/backend/src/domain/routes/table.ts` by `bun run routes`. Do not edit by hand.

`:name` is a path parameter. `ANY` means the handler decides by method itself.
Every JSON error is `{ error, code, requestId }`; every response carries `x-syntila-api`.
A path that exists but not for the request's method answers `405` with an `Allow` header.
`Workspace/server`: called with Workspace or server credentials, no browser same-origin check.
`Idempotency-Key`: a retry with the same key returns the first response (see CONTRACT.md).

138 paths.

| Path | Methods | Notes |
| --- | --- | --- |
| `/api/admin/issue-reports` | GET |  |
| `/api/admin/issue-reports/:id` | GET, PATCH |  |
| `/api/admin/issue-reports/groups` | GET, POST | Idempotency-Key |
| `/api/admin/profile-lab/access` | GET |  |
| `/api/admin/release-trust/keys/:keyId/revoke` | POST |  |
| `/api/admin/workers` | GET |  |
| `/api/admin/workers/:workerTypeId/profile` | GET, PUT |  |
| `/api/admin/workers/:workerTypeId/profile/history` | GET |  |
| `/api/admin/workers/:workerTypeId/profile/restore` | POST |  |
| `/api/admin/workers/:workerTypeId/profile/validate` | POST |  |
| `/api/billing/live/checkout-config` | ANY |  |
| `/api/billing/sandbox/checkout-config` | ANY |  |
| `/api/billing/sandbox/portal` | ANY |  |
| `/api/billing/sandbox/webhook` | ANY | Workspace/server |
| `/api/discussion-messages/:messageId` | GET, PATCH, DELETE |  |
| `/api/files` | GET |  |
| `/api/files/:fileId` | GET, DELETE |  |
| `/api/files/sync` | POST |  |
| `/api/invitations/:invitationId/accept` | POST |  |
| `/api/invitations/:invitationId/decline` | POST |  |
| `/api/issue-reports` | GET, POST | Idempotency-Key |
| `/api/me/external-workers` | ANY |  |
| `/api/me/external-workers/:pluginRef` | ANY |  |
| `/api/me/invitations` | GET |  |
| `/api/me/plan` | ANY |  |
| `/api/me/privacy` | ANY |  |
| `/api/me/worker-plugins` | ANY |  |
| `/api/me/worker-plugins/:pluginRef` | ANY |  |
| `/api/notes` | GET, POST | Idempotency-Key |
| `/api/notes/:noteId` | GET, PUT, DELETE |  |
| `/api/notifications` | GET |  |
| `/api/notifications/read` | POST |  |
| `/api/people` | ANY |  |
| `/api/people/blocks/:userId` | POST, DELETE |  |
| `/api/people/connections/:userId` | POST, DELETE |  |
| `/api/people/connections/:userId/disconnect` | POST, DELETE |  |
| `/api/people/connections/:userId/space` | POST |  |
| `/api/people/invitations` | GET, POST | Idempotency-Key |
| `/api/people/invitations/:id/accept` | POST |  |
| `/api/people/invitations/:id/cancel` | POST |  |
| `/api/people/invitations/:id/decline` | POST |  |
| `/api/people/support` | ANY |  |
| `/api/pins/:kind/:targetId` | PUT, DELETE |  |
| `/api/pins/order` | PUT |  |
| `/api/profile/avatar` | PUT |  |
| `/api/release-trust` | GET |  |
| `/api/session` | GET |  |
| `/api/space-invitations/:invitationId/accept` | POST |  |
| `/api/space-invitations/:invitationId/decline` | POST |  |
| `/api/spaces` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId` | GET, PATCH, DELETE |  |
| `/api/spaces/:spaceId/additional-folders` | ANY |  |
| `/api/spaces/:spaceId/audit` | GET |  |
| `/api/spaces/:spaceId/invitations` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId/invitations/:invitationId/expire` | POST |  |
| `/api/spaces/:spaceId/members` | GET |  |
| `/api/spaces/:spaceId/members/:userId/permissions` | PATCH |  |
| `/api/spaces/:spaceId/members/:userId/remove` | POST |  |
| `/api/spaces/:spaceId/members/:userId/role` | PATCH |  |
| `/api/spaces/:spaceId/threads` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId/workflow-configurations` | ANY |  |
| `/api/spaces/:spaceId/workflow-configurations/:workflowId` | ANY |  |
| `/api/spaces/:spaceId/workflow-default` | ANY |  |
| `/api/spaces/:spaceId/workflow-workspace` | ANY |  |
| `/api/threads/:threadId` | PATCH, DELETE |  |
| `/api/threads/:threadId/chat/clear` | POST |  |
| `/api/threads/:threadId/conversations/:conversationId/history` | GET |  |
| `/api/threads/:threadId/discussion-messages` | GET, POST | Idempotency-Key |
| `/api/threads/:threadId/files/:fileId` | GET |  |
| `/api/threads/:threadId/note` | GET, PUT |  |
| `/api/threads/:threadId/queue` | ANY |  |
| `/api/threads/:threadId/queue/:itemId` | ANY |  |
| `/api/threads/:threadId/queue/:itemId/send-now` | ANY |  |
| `/api/threads/:threadId/queue/:itemId/stop-phases` | ANY |  |
| `/api/threads/:threadId/queue/pause` | ANY |  |
| `/api/threads/:threadId/queue/resume` | ANY |  |
| `/api/threads/:threadId/read` | POST |  |
| `/api/threads/:threadId/read-states` | GET |  |
| `/api/threads/:threadId/work-history/clear` | POST | Idempotency-Key |
| `/api/threads/:threadId/work-request-files` | POST |  |
| `/api/threads/:threadId/work-requests` | GET, POST | Idempotency-Key |
| `/api/threads/:threadId/work-requests/validate` | POST |  |
| `/api/user/workflow-configurations` | ANY |  |
| `/api/user/workflow-configurations/:workflowId` | ANY |  |
| `/api/user/workflow-default` | ANY |  |
| `/api/user/workflow-workspace` | ANY |  |
| `/api/users/:userId/avatar` | GET |  |
| `/api/work-requests/:workRequestId` | GET |  |
| `/api/work-requests/:workRequestId/approve-plan` | POST |  |
| `/api/work-requests/:workRequestId/cancel` | POST |  |
| `/api/work-requests/:workRequestId/inputs/:inputId` | PUT |  |
| `/api/work-requests/:workRequestId/inputs/:inputId/failed` | POST |  |
| `/api/work-requests/:workRequestId/retry` | POST |  |
| `/api/workers` | GET |  |
| `/api/workers/:workerTypeId/profile` | GET |  |
| `/api/workers/catalog` | GET |  |
| `/api/workflows/catalog` | GET |  |
| `/api/workspace-gateway/connect` | GET |  |
| `/api/workspace-invitations` | ANY |  |
| `/api/workspace-invitations/:id/accept` | ANY |  |
| `/api/workspace-invitations/:id/decline` | ANY |  |
| `/api/workspace-releases/:version` | GET |  |
| `/api/workspace-releases/:version/download` | GET |  |
| `/api/workspace-releases/:version/revoke` | POST |  |
| `/api/workspace-releases/latest` | GET |  |
| `/api/workspace-releases/publish` | POST |  |
| `/api/workspace-runtime/disconnect` | POST | Workspace/server |
| `/api/workspace-runtime/events` | POST | Workspace/server |
| `/api/workspace-runtime/inputs` | GET |  |
| `/api/workspace-runtime/inputs/:fileId/attempt` | POST | Workspace/server |
| `/api/workspace-runtime/inputs/:fileId/content` | GET |  |
| `/api/workspace-runtime/inputs/:fileId/delivered` | POST | Workspace/server |
| `/api/workspace-runtime/outputs` | POST | Workspace/server |
| `/api/workspace-runtime/ownership` | POST | Workspace/server |
| `/api/workspace-runtime/ownership/reconcile` | POST | Workspace/server |
| `/api/workspace-runtime/poll` | POST | Workspace/server |
| `/api/workspace-runtime/register` | POST | Workspace/server |
| `/api/workspace-runtime/release` | POST | Workspace/server |
| `/api/workspace-runtime/sessions` | POST | Workspace/server |
| `/api/workspace-runtime/sessions/:sessionId/close` | POST | Workspace/server |
| `/api/workspace-runtime/workers/catalog` | GET |  |
| `/api/workspaces` | GET |  |
| `/api/workspaces/:workspaceId` | GET, PATCH, DELETE |  |
| `/api/workspaces/:workspaceId/audit-export` | GET |  |
| `/api/workspaces/:workspaceId/delivery-probe` | POST |  |
| `/api/workspaces/:workspaceId/external-workers/:pluginRef` | ANY |  |
| `/api/workspaces/:workspaceId/invitations` | ANY |  |
| `/api/workspaces/:workspaceId/invitations/:invitationId/revoke` | ANY |  |
| `/api/workspaces/:workspaceId/mcp-action` | ANY |  |
| `/api/workspaces/:workspaceId/mcp-inventory` | ANY |  |
| `/api/workspaces/:workspaceId/member-access` | ANY |  |
| `/api/workspaces/:workspaceId/member-access/people/:userId` | ANY |  |
| `/api/workspaces/:workspaceId/people-with-access` | ANY |  |
| `/api/workspaces/:workspaceId/person-grants/:userId/quota` | ANY |  |
| `/api/workspaces/:workspaceId/person-grants/:userId/revoke` | ANY |  |
| `/api/workspaces/:workspaceId/worker-plugins/:pluginRef` | ANY |  |
| `/api/workspaces/:workspaceId/worker-preferences` | ANY |  |
| `/api/workspaces/:workspaceId/workers/:workerId/usage` | POST |  |
