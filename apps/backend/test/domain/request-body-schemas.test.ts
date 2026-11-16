/**
 * Bodies that routes read with `readBody(request, Schema)`: each schema accepts
 * its valid body, answers 400 `invalid_request` to a wrong-typed value and to an
 * over-limit field (all well below the 2 MiB body cap, so never 413), and keeps
 * the message the app already shows where the old hand check had one.
 */
import { expect, test } from "bun:test";
import * as protocol from "@syntila/protocol";
import { readBody } from "../../src/domain/routes/validation";

type Case = { schema: keyof typeof protocol; valid: unknown[]; wrongType: unknown[]; overLimit: unknown[]; message?: string };

const CASES: Case[] = [
  { schema: "WorkspaceMemberAccessSchema", valid: [{ restricted: false }, { restricted: true, workers: {}, mode: "chat" }], wrongType: [{ restricted: "yes" }, { restricted: true, workers: [] }, { restricted: true, extra: 1 }, {}], overLimit: [{ restricted: true, mode: "x".repeat(33) }], message: "Invalid member access request" },
  { schema: "WorkspaceMemberOverrideSchema", valid: [{ workers: {}, mode: "work" }, {}], wrongType: [{ workers: "all" }, { mode: 3 }, { other: true }], overLimit: [{ mode: "x".repeat(33) }], message: "Invalid member access request" },
  { schema: "UpdateWorkspaceSchema", valid: [{ name: "Mac" }, { parallelSlots: 2 }, { spaceAiChat: true, spaceAiWork: false }], wrongType: [{ name: 5 }, { parallelSlots: "2" }, { spaceAiChat: "true" }, { spaceAiWork: 1 }], overLimit: [{ name: "x".repeat(1001) }] },
  { schema: "WorkspaceInvitationSchema", valid: [{ email: "a@b.co" }], wrongType: [{ email: 5 }, {}, { email: "a@b.co", extra: 1 }], overLimit: [{ email: "x".repeat(321) }], message: "An email address is required" },
  { schema: "PersonGrantQuotaSchema", valid: [{ maxConcurrentRequests: 3 }, { maxRunSecondsPerMonth: null }, { maxConcurrentRequests: 1, maxRunSecondsPerMonth: 60 }], wrongType: [{ maxConcurrentRequests: "3" }, { maxConcurrentRequests: 1.5 }, {}, { other: 1 }], overLimit: [{ maxConcurrentRequests: 11 }, { maxRunSecondsPerMonth: 31 * 24 * 3600 + 1 }, { maxRunSecondsPerMonth: 59 }], message: "maxConcurrentRequests must be 1-10 and maxRunSecondsPerMonth null or 60 to 2678400" },
  { schema: "InputUploadFailedSchema", valid: [{}, { message: "disk full" }], wrongType: [{ message: 5 }, { message: ["x"] }], overLimit: [{ message: "x".repeat(2001) }] },
  { schema: "InputDeliveredSchema", valid: [{}, { contentDigest: "a".repeat(64) }], wrongType: [{ contentDigest: 5 }], overLimit: [{ contentDigest: "a".repeat(129) }] },
  { schema: "InputAttemptSchema", valid: [{}, { final: true, message: "x" }], wrongType: [{ final: "yes" }, { message: 1 }], overLimit: [{ message: "x".repeat(2001) }] },
  { schema: "PinOrderSchema", valid: [{ kind: "space", ids: ["a"] }, { kind: "thread", ids: ["t1", "t2"], spaceId: "s" }], wrongType: [{ kind: "nope", ids: ["a"] }, { kind: "space", ids: [] }, { kind: "space", ids: [5] }, { kind: "space", ids: "a" }, { kind: "thread", ids: ["t"], spaceId: 7 }], overLimit: [{ kind: "space", ids: Array.from({ length: 501 }, (_, i) => `i${i}`) }, { kind: "space", ids: ["x".repeat(129)] }] },
  { schema: "AdditionalFoldersSchema", valid: [{ folderIds: [] }, { folderIds: ["folder-0123456789abcdef"] }], wrongType: [{ folderIds: "x" }, { folderIds: [5] }, { folderIds: ["nope"] }, { folderIds: ["folder-0123456789abcdef", "folder-0123456789abcdef"] }, { folderIds: [], extra: 1 }, {}], overLimit: [{ folderIds: Array.from({ length: 33 }, (_, i) => `folder-${i.toString(16).padStart(16, "0")}`) }], message: "Invalid folder selection" },
  { schema: "ReadReceiptPrivacySchema", valid: [{ shareReadReceipts: true }, { shareReadReceipts: false }], wrongType: [{ shareReadReceipts: "yes" }, {}, { shareReadReceipts: true, extra: 1 }], overLimit: [], message: "shareReadReceipts must be true or false" },
  { schema: "WorkflowDefaultSchema", valid: [{ defaultWorkflowId: "chat" }], wrongType: [{ defaultWorkflowId: 5 }, {}, { defaultWorkflowId: "chat", extra: 1 }], overLimit: [{ defaultWorkflowId: "x".repeat(65) }], message: "Invalid default workflow selection" },
  { schema: "WorkflowWorkspaceSchema", valid: [{ workspaceId: null }, { workspaceId: "w", confirmReset: true }, { workspaceId: "w", inherit: false }], wrongType: [{ workspaceId: 5 }, { confirmReset: "yes" }, { inherit: "no" }, { workspaceId: "w", extra: 1 }], overLimit: [{ workspaceId: "x".repeat(129) }], message: "Invalid Workspace selection" },
  { schema: "RevokeReasonSchema", valid: [{}, { reason: "key leaked" }], wrongType: [{ reason: 5 }, { reason: ["x"] }], overLimit: [{ reason: "x".repeat(2001) }] },
  { schema: "UpdateSpaceSchema", valid: [{ name: "Trip" }, { description: null }, { settings: { personalName: "x" } }, { hidden: true, archived: false }, { name: "x", extra: 1 }], wrongType: [{ name: 5 }, { description: 5 }, { settings: "x" }, { settings: [] }, { hidden: "yes" }, { archived: 1 }], overLimit: [{ name: "x".repeat(201) }, { description: "x".repeat(2001) }] },
  { schema: "SpaceInvitationSchema", valid: [{ email: "a@b.co", role: "viewer" }, { userId: "u", role: "collaborator", permissions: { chat: true } }], wrongType: [{ email: 5 }, { userId: [] }, { role: 3 }], overLimit: [{ email: "x".repeat(321) }, { userId: "x".repeat(129) }, { role: "x".repeat(33) }] },
  { schema: "SpaceMemberRoleSchema", valid: [{ role: "viewer" }, { permissions: { chat: true } }], wrongType: [{ role: 3 }, { role: ["viewer"] }], overLimit: [{ role: "x".repeat(33) }] },
  { schema: "CreateThreadSchema", valid: [{ name: "Plan" }, { name: "x", extra: 1 }], wrongType: [{ name: 5 }, { name: ["x"] }], overLimit: [{ name: "x".repeat(201) }] },
  { schema: "UpdateThreadSchema", valid: [{ status: "archived" }, { name: "x", accessPolicy: {}, metadata: { a: 1 }, workConfig: null }], wrongType: [{ name: 5 }, { status: 1 }], overLimit: [{ name: "x".repeat(201) }, { status: "x".repeat(33) }] },
  { schema: "DiscussionMessageSchema", valid: [{ body: "hi" }, { content: "hi", attachments: [], references: [], replyTo: null }], wrongType: [{ body: 5 }, { content: [] }, { attachments: {} }, { references: "x" }, { replyTo: 3 }], overLimit: [{ body: "x".repeat(20_001) }, { attachments: Array.from({ length: 11 }, () => ({})) }, { references: Array.from({ length: 51 }, () => ({})) }] },
  { schema: "RetryWorkRequestSchema", valid: [{ stepKind: "implement", sessionStrategy: "fresh" }, { stepKind: "plan", stepId: "plan", confirmSideEffects: true, partial: false }], wrongType: [{ stepKind: 5 }, { confirmSideEffects: "yes" }, { partial: 1 }, { clearAiHistory: "no" }], overLimit: [{ stepKind: "x".repeat(65) }, { stepId: "x".repeat(129) }] },
  { schema: "ApprovePlanSchema", valid: [{}, { verificationMode: "per_phase" }, { customPhases: [{ title: "A", description: "B", files: ["a.ts"], criteria: "ok" }] }], wrongType: [{ verificationMode: "all" }, { customPhases: "x" }, { customPhases: [{ title: 5, description: "x" }] }, { customPhases: [{ title: "a" }] }], overLimit: [{ customPhases: Array.from({ length: 51 }, () => ({ title: "t", description: "d" })) }, { customPhases: [{ title: "x".repeat(201), description: "d" }] }] },
  { schema: "PluginUploadSchema", valid: [{ manifest: {}, manifestDigest: "a".repeat(64), origin: { kind: "local_path", locator: "x" } }, { manifest: {} }], wrongType: [{ manifestDigest: 5 }, { origin: "path" }, { origin: [] }], overLimit: [{ manifest: {}, manifestDigest: "a".repeat(129) }] },
  { schema: "PluginPinSchema", valid: [{ version: "1.0.0", manifestDigest: "a".repeat(64), consentHash: "b".repeat(64), enabled: true, shareable: false }], wrongType: [{ version: 1 }, { enabled: "yes" }, { shareable: 0 }], overLimit: [{ version: "x".repeat(65) }, { consentHash: "x".repeat(129) }] },
  { schema: "PublishReleaseSchema", valid: [{ version: "1.2.3", channel: "beta", supportedOS: ["macos"], supportedArch: ["arm64"] }, {}], wrongType: [{ version: 5 }, { channel: "nightly" }, { supportedOS: "macos" }, { releaseNotes: 1 }], overLimit: [{ version: "x".repeat(65) }, { supportedOS: Array.from({ length: 21 }, () => "x") }, { releaseNotes: "x".repeat(20_001) }, { signature: "x".repeat(4097) }] },
  { schema: "WorkspaceGrantCreateSchema", valid: [{}, { allowedWorkerIds: ["w"], confirmContribution: true, workspaceId: "ws" }], wrongType: [{ allowedWorkerIds: "w" }, { confirmContribution: "yes" }, { workspaceId: 5 }], overLimit: [{ allowedWorkerIds: Array.from({ length: 201 }, () => "w") }, { workspaceId: "x".repeat(129) }] },
  { schema: "WorkspaceGrantUpdateSchema", valid: [{ status: "active" }, { expiresAt: null }, { allowedPermissions: {} }], wrongType: [{ status: 1 }, { expiresAt: 5 }], overLimit: [{ status: "x".repeat(33) }, { expiresAt: "x".repeat(65) }] },
  { schema: "WorkRequestBodySchema", valid: [{ workflowId: "chat", input: { originalRequest: "hi" } }, { workflowId: "direct", originalRequest: "x", attachments: [], executionSelection: null, extraStoredField: 1 }, {}], wrongType: [{ workflowId: 5 }, { originalRequest: 5 }, { input: "x" }, { input: { originalRequest: 5 } }, { attachments: {} }, { workflowVersion: "2" }, { replyTo: 3 }], overLimit: [{ originalRequest: "x".repeat(200_001) }, { input: { originalRequest: "x".repeat(200_001) } }, { attachments: Array.from({ length: 11 }, () => ({})) }, { workflowId: "x".repeat(65) }] },
  { schema: "QueueRequestSchema", valid: [{ request: { workflowId: "chat", input: { originalRequest: "hi" } } }, {}], wrongType: [{ request: "x" }, { request: { workflowId: 5 } }, { request: { attachments: "x" } }], overLimit: [{ request: { originalRequest: "x".repeat(200_001) } }, { request: { attachments: Array.from({ length: 11 }, () => ({})) } }] },
  { schema: "RuntimeIdentitySchema", valid: [{}, { contractVersion: "1.0", installationId: "install_x", workspaceId: "w", runtimeId: "r" }], wrongType: [{ installationId: 5 }, { workspaceId: [] }, { runtimeId: {} }, { contractVersion: 1 }], overLimit: [{ installationId: "x".repeat(257) }, { contractVersion: "x".repeat(17) }] },
  { schema: "RegisterWorkspaceSchema", valid: [{ contractVersion: "1.0", installationId: "install_x", proposedWorkspaceName: "Mac", hostname: "h", platform: "macos", architecture: "arm64", appVersion: "1.0.0", runtimeCapabilities: { os: "macos" } }, {}], wrongType: [{ proposedWorkspaceName: 5 }, { hostname: [] }, { platform: 1 }, { appVersion: {} }, { runtimeCapabilities: "x" }, { runtimeCapabilities: [] }], overLimit: [{ proposedWorkspaceName: "x".repeat(1001) }, { platform: "x".repeat(33) }, { appVersion: "x".repeat(129) }] },
  { schema: "RuntimeTransportSchema", valid: [{ workspaceRuntimeId: "r" }, { sessionId: "s", events: [] }], wrongType: [{ workspaceRuntimeId: 5 }, { sessionId: [] }], overLimit: [{ sessionId: "x".repeat(257) }] },
];

const req = (body: unknown) => new Request("https://x/api", { method: "POST", body: JSON.stringify(body) });

for (const c of CASES) {
  const schema = protocol[c.schema] as any;
  test(`${c.schema}: valid, wrong-typed and over-limit bodies`, async () => {
    for (const body of c.valid) await expect(readBody(req(body), schema)).resolves.toBeDefined();
    for (const body of [...c.wrongType, ...c.overLimit]) {
      const error: any = await readBody(req(body), schema, c.message ? { message: c.message } : {}).then(() => null, (e) => e);
      expect(error, JSON.stringify(body)).not.toBeNull();
      expect([error.status, error.code]).toEqual([400, "invalid_request"]);
      if (c.message) expect(error.message).toBe(c.message);
      expect(error.details.length).toBeGreaterThan(0);
    }
  });
}
