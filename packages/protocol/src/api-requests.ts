/**
 * Request bodies of the backend API, validated with one shared mechanism
 * (`readBody` in apps/backend/src/domain/routes/validation.ts). A failed
 * validation answers 400 `invalid_request` with `details: [{ path, message }]`.
 */
import { z } from "zod";

/** POST /api/notes and PUT /api/notes/:id. */
export const NoteInputSchema = z.object({
  title: z.string({ error: "title must be text" }).max(200, "title must be text up to 200 characters").optional(),
  body: z.string({ error: "body must be text" }).max(200_000, "body must be text up to 200000 characters").optional(),
  revision: z.int({ error: "revision must be a positive integer" }).positive("revision must be a positive integer").optional(),
});
export type NoteInput = z.infer<typeof NoteInputSchema>;

/** POST /api/spaces. */
export const CreateSpaceSchema = z.object({
  name: z.string({ error: "name is required" }).min(1, "name is required").max(200, "name must be at most 200 characters"),
  description: z.string().max(2000, "description must be at most 2000 characters").nullish(),
  settings: z.record(z.string(), z.unknown(), { error: "settings must be an object" }).optional(),
  kind: z.literal("group", { error: "Direct Spaces cannot be created manually" }).optional(),
});
export type CreateSpaceInput = z.infer<typeof CreateSpaceSchema>;

/** POST /api/people/invitations: invite by email address or by user id. */
export const CreatePersonInvitationSchema = z
  .object({
    email: z.string().trim().min(1).max(320).optional(),
    userId: z.string().trim().min(1).max(128).optional(),
  })
  .refine((body) => Boolean(body.email) !== Boolean(body.userId), {
    message: "Exactly one of 'email' or 'userId' must be provided",
  });
export type CreatePersonInvitationInput = z.infer<typeof CreatePersonInvitationSchema>;

/** POST /api/notifications/read: the given Work notifications, or all when `ids` is absent. */
export const MarkNotificationsReadSchema = z.object({
  ids: z
    .array(z.string({ error: "ids must be a list of notification ids" }).min(1).max(128), { error: "ids must be a list of notification ids" })
    .max(500, "ids must list at most 500 notifications")
    .optional(),
});
export type MarkNotificationsReadInput = z.infer<typeof MarkNotificationsReadSchema>;

// ---- Work requests and the Thread request queue --------------------------------
// The body is stored on queue rows and replayed later, so unknown keys pass; the
// fields the handler reads are typed and bounded. A wrong-typed text field used
// to be skipped silently; it is now a 400.

const workRequestText = (name: string) => z.string({ error: `${name} must be text` }).max(200_000, `${name} must be at most 200000 characters`).optional();
const workRequestShape = {
  workflowId: z.string({ error: "workflowId must be text" }).max(64).optional(),
  workflowVersion: z.number({ error: "workflowVersion must be a positive integer" }).optional(),
  workflowSnapshot: z.unknown().optional(),
  mode: z.string({ error: "mode must be text" }).max(32).optional(),
  conversationId: z.string({ error: "conversationId must be text" }).max(128).nullish(),
  replyTo: z.string({ error: "replyTo must be text" }).max(128).nullish(),
  originalRequest: workRequestText("originalRequest"),
  request: workRequestText("request"),
  objective: workRequestText("objective"),
  executionSelection: z.unknown().optional(),
  attachments: z.array(z.unknown(), { error: "attachments must be an array" }).max(10, "At most 10 attachments are allowed").optional(),
  input: z
    .looseObject({
      originalRequest: workRequestText("originalRequest"),
      request: workRequestText("request"),
      objective: workRequestText("objective"),
      attachments: z.array(z.unknown(), { error: "attachments must be an array" }).max(10, "At most 10 attachments are allowed").optional(),
    }, { error: "input must be an object" })
    .optional(),
};

/** POST /api/threads/:id/work-requests and .../work-requests/validate. */
export const WorkRequestBodySchema = z.looseObject(workRequestShape);

/** POST|PUT /api/threads/:id/queue[/:item]: `{request}` holds the work request body. */
export const QueueRequestSchema = z.looseObject({
  request: z.looseObject(workRequestShape, { error: "request must be an object" }).optional(),
  beforeItemIds: z.array(z.string().max(128)).max(200).optional(),
  afterItemIds: z.array(z.string().max(128)).max(200).optional(),
});

// ---- Plugins, releases and grants ---------------------------------------------

/** POST /api/me/worker-plugins: the manifest is validated by PluginManifestSchema in the handler. */
export const PluginUploadSchema = z.looseObject({
  manifest: z.unknown(),
  manifestDigest: z.string({ error: "manifestDigest must be text" }).max(128).optional(),
  origin: z.record(z.string(), z.unknown(), { error: "origin must be an object" }).optional(),
  signer: z.unknown().optional(),
});

/** PUT /api/workers/:id/plugin-pin. */
export const PluginPinSchema = z.looseObject({
  version: z.string({ error: "version must be text" }).max(64).optional(),
  manifestDigest: z.string({ error: "manifestDigest must be text" }).max(128).optional(),
  consentHash: z.string({ error: "consentHash must be text" }).max(128).optional(),
  enabled: z.boolean({ error: "enabled must be true or false" }).optional(),
  shareable: z.boolean({ error: "shareable must be true or false" }).optional(),
});

// ---- Threads, discussion, retry and plan approval ----------------------------

/** POST /api/spaces/:id/threads. The handler still requires a non-empty name. */
export const CreateThreadSchema = z.looseObject({
  name: z.string({ error: "name is required" }).max(200, "name must be at most 200 characters").optional(),
});

/** PATCH /api/threads/:id. The handler decides the permission level from the exact key set, so extra keys pass. */
export const UpdateThreadSchema = z.looseObject({
  name: z.string({ error: "name must be text" }).max(200, "name must be at most 200 characters").optional(),
  status: z.string({ error: "status must be text" }).max(32).optional(),
  accessPolicy: z.unknown().optional(),
  metadata: z.unknown().optional(),
  workConfig: z.unknown().optional(),
});

/** POST /api/threads/:id/discussion-messages and PATCH /api/discussion-messages/:id. `content` is the legacy name of `body`. */
export const DiscussionMessageSchema = z.looseObject({
  body: z.string({ error: "body must be text" }).max(20_000, "body must be at most 20000 characters").optional(),
  content: z.string({ error: "content must be text" }).max(20_000, "content must be at most 20000 characters").optional(),
  attachments: z.array(z.unknown(), { error: "attachments must be an array" }).max(10, "At most 10 attachments are allowed").optional(),
  references: z.array(z.unknown(), { error: "references must be an array" }).max(50, "references must list at most 50 items").optional(),
  replyTo: z.string({ error: "replyTo must be text" }).max(128).nullish(),
});

/** POST /api/work-requests/:id/retry. */
export const RetryWorkRequestSchema = z.looseObject({
  stepKind: z.string({ error: "A valid failed Step is required" }).max(64).optional(),
  stepId: z.string({ error: "stepId must be text" }).max(128).optional(),
  sessionStrategy: z.string({ error: "sessionStrategy must be text" }).max(16).optional(),
  contextResolution: z.string({ error: "contextResolution must be text" }).max(16).optional(),
  clearAiHistory: z.boolean({ error: "clearAiHistory must be true or false" }).optional(),
  confirmSideEffects: z.boolean({ error: "confirmSideEffects must be true or false" }).optional(),
  partial: z.boolean({ error: "partial must be true or false" }).optional(),
});

const BAD_PHASES = "Invalid customPhases";
/** POST /api/work-requests/:id/approve-plan. The handler still requires a non-empty phase title. */
export const ApprovePlanSchema = z.looseObject({
  verificationMode: z.enum(["none", "per_phase", "final"], { error: "Invalid verificationMode" }).optional(),
  customPhases: z
    .array(
      z.looseObject({
        title: z.string({ error: BAD_PHASES }).max(200, BAD_PHASES),
        description: z.string({ error: BAD_PHASES }).max(20_000, BAD_PHASES),
        files: z.array(z.string().max(500), { error: BAD_PHASES }).max(100, BAD_PHASES).optional(),
        criteria: z.string({ error: BAD_PHASES }).max(4000, BAD_PHASES).optional(),
      }, { error: BAD_PHASES }),
      { error: BAD_PHASES },
    )
    .max(50, BAD_PHASES)
    .optional(),
  implementer: z.unknown().optional(),
  verifier: z.unknown().optional(),
});

// ---- Spaces and invitations -------------------------------------------------
// These handlers reject unknown keys themselves (with their own messages), so
// the schemas are loose: known fields are typed and bounded, extra keys pass.

/** PATCH /api/spaces/:id. */
export const UpdateSpaceSchema = z.looseObject({
  name: z.string({ error: "name must be text" }).max(200, "name must be at most 200 characters").optional(),
  description: z.string({ error: "description must be text" }).max(2000, "description must be at most 2000 characters").nullish(),
  settings: z.record(z.string(), z.unknown(), { error: "settings must be an object" }).optional(),
  hidden: z.boolean({ error: "hidden must be true or false" }).nullish(),
  archived: z.boolean({ error: "archived must be true or false" }).nullish(),
  kind: z.string().max(32).optional(),
  ownerUserId: z.string().max(128).optional(),
});

/** POST /api/spaces/:id/invitations: email or userId (the handler checks exactly one), role, member permissions. */
export const SpaceInvitationSchema = z.looseObject({
  email: z.string({ error: "email must be text" }).max(320).optional(),
  userId: z.string({ error: "userId must be text" }).max(128).optional(),
  role: z.string({ error: "role must be text" }).max(32).optional(),
  permissions: z.unknown().optional(),
});

/** PATCH /api/spaces/:id/members/:userId/{role,permissions}. */
export const SpaceMemberRoleSchema = z.looseObject({
  role: z.string({ error: "role must be text" }).max(32).optional(),
  permissions: z.unknown().optional(),
});

// ---- Personal, workflow and admin routes ----------------------------------

/** PUT /api/pins/order. */
export const PinOrderSchema = z.object({
  kind: z.enum(["space", "thread"], { error: "kind must be space or thread" }),
  ids: z
    .array(z.string().min(1).max(128), { error: "ids must be a non-empty list of ids" })
    .min(1, "ids must be a non-empty list of ids")
    .max(500, "ids must be a non-empty list of ids"),
  spaceId: z.string({ error: "spaceId is required for threads" }).max(128).optional(),
});

/** PUT /api/me/privacy. */
export const ReadReceiptPrivacySchema = z.strictObject({
  shareReadReceipts: z.boolean({ error: "shareReadReceipts must be true or false" }),
});

/** PUT /api/spaces/:id/workflow-default and /api/user/workflow-default. */
export const WorkflowDefaultSchema = z.strictObject({
  defaultWorkflowId: z.string().min(1).max(64),
});

/** POST /api/work-requests/:id/inputs/:inputId/failed. */
export const InputUploadFailedSchema = z.object({
  message: z.string({ error: "message must be text" }).max(2000).optional(),
});
