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
  { schema: "InputUploadFailedSchema", valid: [{}, { message: "disk full" }], wrongType: [{ message: 5 }, { message: ["x"] }], overLimit: [{ message: "x".repeat(2001) }] },
  { schema: "PinOrderSchema", valid: [{ kind: "space", ids: ["a"] }, { kind: "thread", ids: ["t1", "t2"], spaceId: "s" }], wrongType: [{ kind: "nope", ids: ["a"] }, { kind: "space", ids: [] }, { kind: "space", ids: [5] }, { kind: "space", ids: "a" }, { kind: "thread", ids: ["t"], spaceId: 7 }], overLimit: [{ kind: "space", ids: Array.from({ length: 501 }, (_, i) => `i${i}`) }, { kind: "space", ids: ["x".repeat(129)] }] },
  { schema: "ReadReceiptPrivacySchema", valid: [{ shareReadReceipts: true }, { shareReadReceipts: false }], wrongType: [{ shareReadReceipts: "yes" }, {}, { shareReadReceipts: true, extra: 1 }], overLimit: [], message: "shareReadReceipts must be true or false" },
  { schema: "WorkflowDefaultSchema", valid: [{ defaultWorkflowId: "chat" }], wrongType: [{ defaultWorkflowId: 5 }, {}, { defaultWorkflowId: "chat", extra: 1 }], overLimit: [{ defaultWorkflowId: "x".repeat(65) }], message: "Invalid default workflow selection" },
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
  { schema: "WorkRequestBodySchema", valid: [{ workflowId: "chat", input: { originalRequest: "hi" } }, { workflowId: "direct", originalRequest: "x", attachments: [], executionSelection: null, extraStoredField: 1 }, {}], wrongType: [{ workflowId: 5 }, { originalRequest: 5 }, { input: "x" }, { input: { originalRequest: 5 } }, { attachments: {} }, { workflowVersion: "2" }, { replyTo: 3 }], overLimit: [{ originalRequest: "x".repeat(200_001) }, { input: { originalRequest: "x".repeat(200_001) } }, { attachments: Array.from({ length: 11 }, () => ({})) }, { workflowId: "x".repeat(65) }] },
  { schema: "QueueRequestSchema", valid: [{ request: { workflowId: "chat", input: { originalRequest: "hi" } } }, {}], wrongType: [{ request: "x" }, { request: { workflowId: 5 } }, { request: { attachments: "x" } }], overLimit: [{ request: { originalRequest: "x".repeat(200_001) } }, { request: { attachments: Array.from({ length: 11 }, () => ({})) } }] },
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
