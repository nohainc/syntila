# Backend API routes

Generated from `apps/backend/src/domain/routes/table.ts` by `bun run routes`. Do not edit by hand.

`:name` is a path parameter. `ANY` means the handler decides by method itself.
Every JSON error is `{ error, code, requestId }`; every response carries `x-syntila-api`.
A path that exists but not for the request's method answers `405` with an `Allow` header.
`Connect/server`: called with Connect or server credentials, no browser same-origin check.
`Idempotency-Key`: a retry with the same key returns the first response (see CONTRACT.md).

123 paths.

| Path | Methods | Notes |
| --- | --- | --- |
| `/api/admin/issue-reports` | GET |  |
| `/api/admin/issue-reports/:id` | GET, PATCH |  |
| `/api/admin/issue-reports/groups` | GET, POST | Idempotency-Key |
| `/api/admin/profile-lab/access` | GET |  |
| `/api/admin/workers` | GET |  |
| `/api/admin/workers/:workerTypeId/profile` | GET, PUT |  |
| `/api/admin/workers/:workerTypeId/profile/history` | GET |  |
| `/api/admin/workers/:workerTypeId/profile/restore` | POST |  |
| `/api/admin/workers/:workerTypeId/profile/validate` | POST |  |
| `/api/billing/live/checkout-config` | ANY |  |
| `/api/billing/sandbox/checkout-config` | ANY |  |
| `/api/billing/sandbox/portal` | ANY |  |
| `/api/billing/sandbox/webhook` | ANY | Connect/server |
| `/api/device-folders` | GET |  |
| `/api/device-folders/:deviceId` | DELETE |  |
| `/api/device-folders/:deviceId/:folderId` | DELETE |  |
| `/api/discussion-messages/:messageId` | GET, PATCH, DELETE |  |
| `/api/files` | GET |  |
| `/api/files/:fileId` | GET, DELETE |  |
| `/api/files/sync` | POST |  |
| `/api/invitations/:invitationId/accept` | POST |  |
| `/api/invitations/:invitationId/decline` | POST |  |
| `/api/issue-reports` | GET, POST | Idempotency-Key |
| `/api/me/invitations` | GET |  |
| `/api/me/plan` | ANY |  |
| `/api/me/privacy` | ANY |  |
| `/api/me/worker-plugins` | ANY |  |
| `/api/me/worker-plugins/:pluginRef` | ANY |  |
| `/api/media/:fileId` | GET |  |
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
| `/api/session` | GET |  |
| `/api/space-invitations/:invitationId/accept` | POST |  |
| `/api/space-invitations/:invitationId/decline` | POST |  |
| `/api/spaces` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId` | GET, PATCH, DELETE |  |
| `/api/spaces/:spaceId/audit` | GET |  |
| `/api/spaces/:spaceId/folder` | ANY |  |
| `/api/spaces/:spaceId/invitations` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId/invitations/:invitationId/expire` | POST |  |
| `/api/spaces/:spaceId/members` | GET |  |
| `/api/spaces/:spaceId/members/:userId/permissions` | PATCH |  |
| `/api/spaces/:spaceId/members/:userId/remove` | POST |  |
| `/api/spaces/:spaceId/members/:userId/role` | PATCH |  |
| `/api/spaces/:spaceId/threads` | GET, POST | Idempotency-Key |
| `/api/spaces/:spaceId/workers` | GET |  |
| `/api/spaces/:spaceId/workflow-configurations` | ANY |  |
| `/api/spaces/:spaceId/workflow-configurations/:workflowId` | ANY |  |
| `/api/spaces/:spaceId/workflow-default` | ANY |  |
| `/api/threads/:threadId` | PATCH, DELETE |  |
| `/api/threads/:threadId/chat/clear` | POST |  |
| `/api/threads/:threadId/conversations/:conversationId/history` | GET |  |
| `/api/threads/:threadId/discussion-messages` | GET, POST | Idempotency-Key |
| `/api/threads/:threadId/eligible-workers` | GET |  |
| `/api/threads/:threadId/files/:fileId` | GET |  |
| `/api/threads/:threadId/files/:fileId/media-link` | POST |  |
| `/api/threads/:threadId/note` | GET, PUT |  |
| `/api/threads/:threadId/queue` | ANY |  |
| `/api/threads/:threadId/queue/:itemId` | ANY |  |
| `/api/threads/:threadId/queue/:itemId/send-now` | ANY |  |
| `/api/threads/:threadId/queue/:itemId/stop-phases` | ANY |  |
| `/api/threads/:threadId/queue/pause` | ANY |  |
| `/api/threads/:threadId/queue/resume` | ANY |  |
| `/api/threads/:threadId/read` | POST |  |
| `/api/threads/:threadId/read-states` | GET |  |
| `/api/threads/:threadId/timeline` | GET |  |
| `/api/threads/:threadId/work-history/clear` | POST | Idempotency-Key |
| `/api/threads/:threadId/work-request-files` | POST |  |
| `/api/threads/:threadId/work-requests` | GET, POST | Idempotency-Key |
| `/api/threads/:threadId/work-requests/validate` | POST |  |
| `/api/user/workflow-configurations` | ANY |  |
| `/api/user/workflow-configurations/:workflowId` | ANY |  |
| `/api/user/workflow-default` | ANY |  |
| `/api/users/:userId/avatar` | GET |  |
| `/api/work-requests/:workRequestId` | GET |  |
| `/api/work-requests/:workRequestId/approve-plan` | POST |  |
| `/api/work-requests/:workRequestId/cancel` | POST |  |
| `/api/work-requests/:workRequestId/inputs/:inputId` | PUT |  |
| `/api/work-requests/:workRequestId/inputs/:inputId/failed` | POST |  |
| `/api/work-requests/:workRequestId/retry` | POST |  |
| `/api/worker-agent/artifacts` | POST | Connect/server |
| `/api/worker-agent/artifacts/:artifactId/content` | GET | Connect/server |
| `/api/worker-agent/claim` | POST | Connect/server |
| `/api/worker-agent/folders` | PUT | Connect/server |
| `/api/worker-agent/gateway` | GET | Connect/server |
| `/api/worker-agent/inputs/:fileId/content` | GET |  |
| `/api/worker-agent/models` | PUT | Connect/server |
| `/api/worker-agent/nonce` | POST | Connect/server |
| `/api/worker-agent/outputs` | POST | Connect/server |
| `/api/worker-agent/profile` | GET | Connect/server |
| `/api/worker-agent/rotate` | POST | Connect/server |
| `/api/worker-agent/sessions` | POST | Connect/server |
| `/api/worker-agent/unpair` | POST | Connect/server |
| `/api/worker-agent/usage` | PUT | Connect/server |
| `/api/workers` | GET, POST | Idempotency-Key |
| `/api/workers/:workerId` | GET, PATCH, DELETE |  |
| `/api/workers/:workerId/credential` | DELETE |  |
| `/api/workers/:workerId/mcp-pin` | ANY |  |
| `/api/workers/:workerId/member-model-access` | ANY |  |
| `/api/workers/:workerId/models/refresh` | POST |  |
| `/api/workers/:workerId/pairing` | POST |  |
| `/api/workers/:workerId/person-shares` | ANY |  |
| `/api/workers/:workerId/space-access` | ANY |  |
| `/api/workers/:workerId/transfer` | POST |  |
| `/api/workers/:workerId/usage` | ANY |  |
| `/api/workers/catalog` | GET |  |
| `/api/workers/shared-with-me` | GET |  |
| `/api/workflows/catalog` | GET |  |
