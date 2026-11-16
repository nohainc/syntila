# Route sweep inventory and baseline (before)

Measured with a temporary copy of `test/route-fuzz.test.ts` that logs every response in the `real` pass. Sweep runtime before: ~3 s (164 routes, 0 failures).

Routes: 164; routes with path params: 110; param slots: 131; mapped to a seeded row: 104; placeholder (no row): 25; missing from the map: 2.

## Baseline reachability (real pass, all methods x queries x bodies)

| Measure | All routes (164) | Routes with params (110) |
|---|---|---|
| A: some answer other than 404 | 106 | 56 |
| B: some answer other than 404/401/405 | 90 | 48 |
| C: some 2xx answer | 56 | 28 |

A is the task's metric. It overstates: 400 (validation), 403, 405 and 401 can answer before any lookup. B and C are stricter.

## Findings that change the plan

1. **The sweep destroys its own seed.** `DELETE /api/spaces/:spaceId` (table index 104) deletes the one seeded Space with its Threads, Work Requests, queue, notes and messages. Every param route after it (indexes 105 to the end, about 45 routes: members, invitations, audit, threads, queue, work requests, files, pins ...) answers only `404 ... not found` in the real pass, so their handlers beyond the first lookup are never reached, whatever is seeded. Seeds must be re-created (or isolated per route) before this can improve.
2. Placeholders: `id`, `inputId`, `pluginRef`, `version`, `workflowId` ("chat" is a built-in id, so it is real), `workerTypeId`, `workerId`. `invitationId`/`id` fall back to the string `unknown`: the seed reads `outgoing[0].id` from `GET /api/people/invitations` (the field exists) but no pending invitation is present at that point. Cause not yet determined (to be fixed with direct seeding in Phase 2).
3. Missing from the map: `sessionId`, `keyId`.

## Overloaded parameter names

- `fileId`: user file (user_files.id) owned by the caller; user file attached to that Thread; work request input file delivered to a Workspace (needs runtime token)
- `id`: issue report (issue_reports.id) or its public reference; person invitation (person_invitations.id), pending, addressed to the caller; workspace invitation (workspace_invitations.id), pending, addressed to the caller email
- `invitationId`: space invitation addressed to the caller (pending, not expired); space invitation of that Space (pending); workspace invitation of that Workspace (pending)
- `userId`: Space member (second user, role collaborator/viewer); second user with a People relationship / connection; user with a published avatar; user with an active workspace_person_grants row

## Access boundaries (a user token cannot reach the lookup)

- `/api/workspace-runtime/*` (index 0-15): Workspace/runtime tokens, answer 401/400 to a user token. Includes `sessionId`, `fileId` (runtime inputs). Needs a machine token to be exercised.
- `/api/admin/*`: 403 unless the caller is an admin (issue reports); `/api/admin/profile-lab/access` is open.
- `/api/billing/*`: 404 (Paddle not configured in the test).
- `/api/workspace-gateway/connect`: 426 (WebSocket upgrade).
- 503 `unavailable` for support, delivery probe, worker usage: services not configured.
- 402: workspace invitations need a paid plan (seed an `account_plans` row).

## Per route and parameter

| # | Route | Method | Param | Value in `real` | Kind | Required real row | Real-mode statuses |
|---|---|---|---|---|---|---|---|
| 8 | `/api/workspace-runtime/sessions/:sessionId/close` | POST | sessionId | - | missing | workspace runtime session (needs runtime token) | 400 |
| 11 | `/api/workspace-runtime/inputs/:fileId/content` | GET | fileId | fuzz-file | seeded | work request input file delivered to a Workspace (needs runtime token) | 401 |
| 12 | `/api/workspace-runtime/inputs/:fileId/delivered` | POST | fileId | fuzz-file | seeded | work request input file delivered to a Workspace (needs runtime token) | 401 |
| 13 | `/api/workspace-runtime/inputs/:fileId/attempt` | POST | fileId | fuzz-file | seeded | work request input file delivered to a Workspace (needs runtime token) | 401 |
| 22 | `/api/people/invitations/:id/accept` | POST | id | unknown | placeholder | person invitation (person_invitations.id), pending, addressed to the caller | 404 |
| 23 | `/api/people/invitations/:id/decline` | POST | id | unknown | placeholder | person invitation (person_invitations.id), pending, addressed to the caller | 404 |
| 24 | `/api/people/invitations/:id/cancel` | POST | id | unknown | placeholder | person invitation (person_invitations.id), pending, addressed to the caller | 404 |
| 25 | `/api/people/connections/:userId/space` | POST | userId | fuzz-other | seeded | second user with a People relationship / connection | 403 |
| 26 | `/api/people/connections/:userId` | POST | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 27 | `/api/people/connections/:userId` | DELETE | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 28 | `/api/people/connections/:userId/disconnect` | POST | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 29 | `/api/people/connections/:userId/disconnect` | DELETE | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 30 | `/api/people/blocks/:userId` | POST | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 31 | `/api/people/blocks/:userId` | DELETE | userId | fuzz-other | seeded | second user with a People relationship / connection | 200 |
| 33 | `/api/users/:userId/avatar` | GET | userId | fuzz-other | seeded | user with a published avatar | 404 |
| 46 | `/api/admin/issue-reports/:id` | GET | id | unknown | placeholder | issue report (issue_reports.id) or its public reference | 403 |
| 47 | `/api/admin/issue-reports/:id` | PATCH | id | unknown | placeholder | issue report (issue_reports.id) or its public reference | 403 |
| 49 | `/api/workspaces/:workspaceId/worker-preferences` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400/405/413 |
| 50 | `/api/workspaces/:workspaceId/member-access` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400/405 |
| 51 | `/api/workspaces/:workspaceId/member-access/people/:userId` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400/405 |
| 51 | `/api/workspaces/:workspaceId/member-access/people/:userId` | * | userId | fuzz-other | seeded | user with an active workspace_person_grants row | 200/400/405 |
| 52 | `/api/workspaces/:workspaceId/invitations` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/402/405 |
| 53 | `/api/workspaces/:workspaceId/invitations/:invitationId/revoke` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 404/405 |
| 53 | `/api/workspaces/:workspaceId/invitations/:invitationId/revoke` | * | invitationId | unknown | seeded | workspace invitation of that Workspace (pending) | 404/405 |
| 54 | `/api/workspaces/:workspaceId/people-with-access` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/405 |
| 55 | `/api/workspaces/:workspaceId/person-grants/:userId/quota` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 400/405 |
| 55 | `/api/workspaces/:workspaceId/person-grants/:userId/quota` | * | userId | fuzz-other | seeded | user with an active workspace_person_grants row | 400/405 |
| 56 | `/api/workspaces/:workspaceId/person-grants/:userId/revoke` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 404/405 |
| 56 | `/api/workspaces/:workspaceId/person-grants/:userId/revoke` | * | userId | fuzz-other | seeded | user with an active workspace_person_grants row | 404/405 |
| 58 | `/api/workspace-invitations/:id/accept` | * | id | unknown | placeholder | workspace invitation (workspace_invitations.id), pending, addressed to the caller email | 404/405 |
| 59 | `/api/workspace-invitations/:id/decline` | * | id | unknown | placeholder | workspace invitation (workspace_invitations.id), pending, addressed to the caller email | 404/405 |
| 60 | `/api/workspaces/:workspaceId/mcp-inventory` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/405 |
| 61 | `/api/workspaces/:workspaceId/mcp-action` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 400/405 |
| 62 | `/api/workspaces/:workspaceId/external-workers/:pluginRef` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 400 |
| 62 | `/api/workspaces/:workspaceId/external-workers/:pluginRef` | * | pluginRef | fuzz-plugin | placeholder | worker plugin / external worker ref installed on the Workspace | 400 |
| 63 | `/api/workspaces/:workspaceId/worker-plugins/:pluginRef` | * | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 400 |
| 63 | `/api/workspaces/:workspaceId/worker-plugins/:pluginRef` | * | pluginRef | fuzz-plugin | placeholder | worker plugin / external worker ref installed on the Workspace | 400 |
| 64 | `/api/workspaces/:workspaceId/delivery-probe` | POST | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 503 |
| 65 | `/api/workspaces/:workspaceId/audit-export` | GET | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200 |
| 66 | `/api/workspaces/:workspaceId/workers/:workerId/usage` | POST | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 503 |
| 66 | `/api/workspaces/:workspaceId/workers/:workerId/usage` | POST | workerId | claude | placeholder | worker (workspace_worker_inventory / workspace worker) registered on the Workspace | 503 |
| 67 | `/api/workspaces/:workspaceId` | GET | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400 |
| 68 | `/api/workspaces/:workspaceId` | PATCH | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400 |
| 69 | `/api/workspaces/:workspaceId` | DELETE | workspaceId | fuzz-ws | seeded | execution workspace owned by caller | 200/400 |
| 71 | `/api/spaces/:spaceId/workflow-workspace` | * | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/405 |
| 72 | `/api/spaces/:spaceId/additional-folders` | * | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/403/405 |
| 73 | `/api/spaces/:spaceId/workflow-default` | * | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/405 |
| 75 | `/api/spaces/:spaceId/workflow-configurations` | * | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/405 |
| 76 | `/api/spaces/:spaceId/workflow-configurations/:workflowId` | * | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/405 |
| 76 | `/api/spaces/:spaceId/workflow-configurations/:workflowId` | * | workflowId | chat | placeholder | built-in workflow id (chat, direct, plan_implement, research, ...) | 200/400/405 |
| 78 | `/api/user/workflow-configurations/:workflowId` | * | workflowId | chat | placeholder | built-in workflow id (chat, direct, plan_implement, research, ...) | 200/400/405 |
| 81 | `/api/admin/release-trust/keys/:keyId/revoke` | POST | keyId | - | missing | signing key id (identity/jwks route) | 403 |
| 85 | `/api/me/external-workers/:pluginRef` | * | pluginRef | fuzz-plugin | placeholder | worker plugin / external worker ref installed on the Workspace | 400/405 |
| 86 | `/api/me/worker-plugins/:pluginRef` | * | pluginRef | fuzz-plugin | placeholder | worker plugin / external worker ref installed on the Workspace | 400/405 |
| 88 | `/api/workers/:workerTypeId/profile` | GET | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 401 |
| 90 | `/api/admin/workers/:workerTypeId/profile` | GET | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 403 |
| 91 | `/api/admin/workers/:workerTypeId/profile` | PUT | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 403 |
| 92 | `/api/admin/workers/:workerTypeId/profile/validate` | POST | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 403 |
| 93 | `/api/admin/workers/:workerTypeId/profile/history` | GET | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 403 |
| 94 | `/api/admin/workers/:workerTypeId/profile/restore` | POST | workerTypeId | claude | placeholder | worker type with a Profile (worker_types / worker_profiles), published or unpublished | 403 |
| 97 | `/api/workspace-releases/:version/download` | GET | version | 1.0.0 | placeholder | workspace release (workspace_releases.version) | 403 |
| 98 | `/api/workspace-releases/:version/revoke` | POST | version | 1.0.0 | placeholder | workspace release (workspace_releases.version) | 403 |
| 99 | `/api/workspace-releases/:version` | GET | version | 1.0.0 | placeholder | workspace release (workspace_releases.version) | 404 |
| 102 | `/api/spaces/:spaceId` | GET | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/404 |
| 103 | `/api/spaces/:spaceId` | PATCH | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/404 |
| 104 | `/api/spaces/:spaceId` | DELETE | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 200/400/404 |
| 105 | `/api/spaces/:spaceId/members` | GET | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 106 | `/api/spaces/:spaceId/members/:userId/role` | PATCH | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 106 | `/api/spaces/:spaceId/members/:userId/role` | PATCH | userId | fuzz-other | seeded | Space member (second user, role collaborator/viewer) | 404 |
| 107 | `/api/spaces/:spaceId/members/:userId/permissions` | PATCH | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 107 | `/api/spaces/:spaceId/members/:userId/permissions` | PATCH | userId | fuzz-other | seeded | Space member (second user, role collaborator/viewer) | 404 |
| 108 | `/api/spaces/:spaceId/members/:userId/remove` | POST | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 108 | `/api/spaces/:spaceId/members/:userId/remove` | POST | userId | fuzz-other | seeded | Space member (second user, role collaborator/viewer) | 404 |
| 109 | `/api/spaces/:spaceId/invitations` | GET | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 110 | `/api/spaces/:spaceId/invitations` | POST | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 111 | `/api/spaces/:spaceId/invitations/:invitationId/expire` | POST | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 111 | `/api/spaces/:spaceId/invitations/:invitationId/expire` | POST | invitationId | unknown | seeded | space invitation of that Space (pending) | 404 |
| 112 | `/api/spaces/:spaceId/audit` | GET | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 113 | `/api/invitations/:invitationId/accept` | POST | invitationId | unknown | seeded | space invitation addressed to the caller (pending, not expired) | 404 |
| 114 | `/api/space-invitations/:invitationId/accept` | POST | invitationId | unknown | seeded | space invitation addressed to the caller (pending, not expired) | 404 |
| 115 | `/api/invitations/:invitationId/decline` | POST | invitationId | unknown | seeded | space invitation addressed to the caller (pending, not expired) | 404 |
| 116 | `/api/space-invitations/:invitationId/decline` | POST | invitationId | unknown | seeded | space invitation addressed to the caller (pending, not expired) | 404 |
| 117 | `/api/spaces/:spaceId/threads` | GET | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 118 | `/api/spaces/:spaceId/threads` | POST | spaceId | space-b1def46f-e249-4c20… | seeded | Space | 404 |
| 119 | `/api/threads/:threadId` | PATCH | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 120 | `/api/threads/:threadId` | DELETE | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 121 | `/api/threads/:threadId/read` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 122 | `/api/threads/:threadId/read-states` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 123 | `/api/threads/:threadId/note` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 124 | `/api/threads/:threadId/note` | PUT | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 125 | `/api/threads/:threadId/discussion-messages` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 126 | `/api/threads/:threadId/discussion-messages` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 127 | `/api/discussion-messages/:messageId` | GET | messageId | fuzz-dm | seeded | discussion message in that Thread | 404 |
| 128 | `/api/discussion-messages/:messageId` | PATCH | messageId | fuzz-dm | seeded | discussion message in that Thread | 404 |
| 129 | `/api/discussion-messages/:messageId` | DELETE | messageId | fuzz-dm | seeded | discussion message in that Thread | 404 |
| 130 | `/api/threads/:threadId/queue` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 131 | `/api/threads/:threadId/queue/pause` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 132 | `/api/threads/:threadId/queue/resume` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 133 | `/api/threads/:threadId/queue/:itemId` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 133 | `/api/threads/:threadId/queue/:itemId` | * | itemId | fuzz-q | seeded | queue item (thread_request_queue.id) authored by the caller | 404 |
| 134 | `/api/threads/:threadId/queue/:itemId/send-now` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 134 | `/api/threads/:threadId/queue/:itemId/send-now` | * | itemId | fuzz-q | seeded | queue item (thread_request_queue.id) authored by the caller | 404 |
| 135 | `/api/threads/:threadId/queue/:itemId/stop-phases` | * | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 135 | `/api/threads/:threadId/queue/:itemId/stop-phases` | * | itemId | fuzz-q | seeded | queue item (thread_request_queue.id) authored by the caller | 404 |
| 136 | `/api/threads/:threadId/conversations/:conversationId/history` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 136 | `/api/threads/:threadId/conversations/:conversationId/history` | GET | conversationId | conversation-97bfa6f3558… | seeded | conversation of the Thread | 404 |
| 137 | `/api/threads/:threadId/work-history/clear` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 138 | `/api/threads/:threadId/chat/clear` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 139 | `/api/threads/:threadId/files/:fileId` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 139 | `/api/threads/:threadId/files/:fileId` | GET | fileId | fuzz-file | seeded | user file attached to that Thread | 404 |
| 140 | `/api/threads/:threadId/work-request-files` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 141 | `/api/threads/:threadId/work-requests/validate` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 142 | `/api/threads/:threadId/work-requests` | POST | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 143 | `/api/threads/:threadId/work-requests` | GET | threadId | thread-021c70dd-ecf6-47e… | seeded | Thread of the Space | 404 |
| 144 | `/api/work-requests/:workRequestId/inputs/:inputId` | PUT | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 144 | `/api/work-requests/:workRequestId/inputs/:inputId` | PUT | inputId | fuzz-input | placeholder | work request input row (work_request_inputs.id) of that Work Request | 404 |
| 145 | `/api/work-requests/:workRequestId/inputs/:inputId/failed` | POST | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 145 | `/api/work-requests/:workRequestId/inputs/:inputId/failed` | POST | inputId | fuzz-input | placeholder | work request input row (work_request_inputs.id) of that Work Request | 404 |
| 146 | `/api/work-requests/:workRequestId/approve-plan` | POST | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 147 | `/api/work-requests/:workRequestId` | GET | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 148 | `/api/work-requests/:workRequestId/cancel` | POST | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 149 | `/api/work-requests/:workRequestId/retry` | POST | workRequestId | fuzz-wr | seeded | Work Request of the Thread | 404 |
| 152 | `/api/files/:fileId` | GET | fileId | fuzz-file | seeded | user file (user_files.id) owned by the caller | 404 |
| 153 | `/api/files/:fileId` | DELETE | fileId | fuzz-file | seeded | user file (user_files.id) owned by the caller | 404 |
| 156 | `/api/notes/:noteId` | GET | noteId | note-2396f620-fc6e-4431-… | seeded | note owned by caller | 200/400 |
| 157 | `/api/notes/:noteId` | PUT | noteId | note-2396f620-fc6e-4431-… | seeded | note owned by caller | 200/400 |
| 158 | `/api/notes/:noteId` | DELETE | noteId | note-2396f620-fc6e-4431-… | seeded | note owned by caller | 200/400 |
| 160 | `/api/pins/:kind/:targetId` | PUT | kind | thread | seeded | pin kind (thread|space|...) | 404 |
| 160 | `/api/pins/:kind/:targetId` | PUT | targetId | thread-021c70dd-ecf6-47e… | seeded | pinnable target of that kind | 404 |
| 161 | `/api/pins/:kind/:targetId` | DELETE | kind | thread | seeded | pin kind (thread|space|...) | 404 |
| 161 | `/api/pins/:kind/:targetId` | DELETE | targetId | thread-021c70dd-ecf6-47e… | seeded | pinnable target of that kind | 404 |

---

# After (Phase 2-4)

## Reach, same measure as the baseline (real pass, owner, all methods x queries x bodies)

| Measure | Before (all / with params) | After (all / with params) |
|---|---|---|
| A: some answer other than 404 | 106 / 56 | 158 / 108 (of 164 / 110) |
| B: some answer other than 404/401/405 | 90 / 48 | 146 / 104 |
| C: some 2xx answer | 56 / 28 | 92 / 66 |

Sweep: 15,936 requests (owner/paid 5312, member/paid 2656, stranger/paid 2656, owner/archived 2656, member/archived 2656), 0 unexpected 5xx, 0 hangs, about 23 s (before: 164 routes, owner only, ~3 s). Every route and pass runs in its own seeded world.

## Wrong-typed body answered 2xx (JUNK[2]): 28 distinct mutations, all reviewed

All 28 are actions with no request body in their contract; the handler never reads the body, so any body is ignored. None is a missing validation. Handlers that do read a body (worker preferences, member access, the queue, workflow configurations) read it only on their PUT/POST branches, not on the accepted DELETE/pause/resume/send-now calls.

| Group | Mutations | Disposition |
|---|---|---|
| Invitation answers | `POST /api/invitations/:id/{accept,decline}`, `/api/space-invitations/:id/{accept,decline}`, `/api/people/invitations/:id/{accept,decline,cancel}`, `/api/workspace-invitations/:id/decline` | Body-less decision on the caller's own invitation |
| People | `POST/DELETE /api/people/blocks/:userId`, `POST/DELETE /api/people/connections/:userId[/disconnect]` | Body-less, scoped to the caller; idempotent (also 200 for an unknown or unconnected user, no information leaked) |
| Pins | `PUT/DELETE /api/pins/:kind/:targetId` | Body-less, scoped to the caller |
| Thread actions | `POST /api/threads/:id/read`, `chat/clear`, `work-history/clear`, `queue/pause`, `queue/resume`, `queue/:item/send-now` | Body-less. A plain Space member may read, pause/resume the shared queue and clear work history; chat/clear and send-now are owner/author only in the sweep. Permission model, not an input defect |
| Notes / configs | `DELETE /api/notes/:id`, `DELETE /api/user/workflow-configurations/:id`, `DELETE /api/spaces/:id/workflow-configurations/:id` | Scoped by `user_id` (a stranger's note delete is a no-op), or owner only |
| Workspace | `DELETE /api/workspaces/:id`, `.../worker-preferences`, `.../member-access/people/:userId` | Body-less, owner only |

Items worth a product decision (not changed): a collaborator can clear a Thread's work history (`work-history/clear` answers 200 for a plain member).

## Routes that still cannot reach their entity lookup (18 of 164)

- Workspace runtime token required, 401 to a user token (11): `/api/workspace-runtime/{register,ownership,ownership/reconcile,release,disconnect,inputs,outputs,inputs/:fileId/{content,delivered,attempt},workers/catalog}`; `GET /api/workers/:workerTypeId/profile` is also machine-authenticated (1).
- Billing provider not configured, 404 (4): `/api/billing/{live,sandbox}/*`.
- File storage not configured in the test (2): `GET /api/files/:fileId` and `GET /api/threads/:threadId/files/:fileId` find the `user_files` row but then look for the stored object and answer 404.
- Admin-only, 403 to a non-admin (counted as reached by measure B because 403 is not 404, but their lookup is not reached): `/api/admin/*` except `profile-lab/access`.
- Seeded in this phase: the `wrf-<uuid>` file and input ids, an open Work Request with an `awaiting_upload` input, and an avatar url for the connected person (storage is unconfigured, so the avatar route answers 503).
- Measures overstate lookup coverage: validation (400), authorization (403) and the 402 plan gate can answer before the lookup, so B and C are the safer numbers.
