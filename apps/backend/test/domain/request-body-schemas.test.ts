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
