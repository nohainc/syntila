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
  workspaceId: z.string({ error: "workspaceId must be a string or null" }).nullish(),
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

// ---- Workspace routes ------------------------------------------------------

/** PUT /api/workspaces/:id/member-access: the policy itself is parsed deeper by parseWorkspaceMemberAccessPolicy. */
export const WorkspaceMemberAccessSchema = z.strictObject({
  restricted: z.boolean({ error: "restricted must be true or false" }),
  workers: z.record(z.string().max(128), z.unknown(), { error: "workers must be an object" }).optional(),
  mode: z.string({ error: "mode must be text" }).max(32).optional(),
});

/** PUT /api/workspaces/:id/member-access/people/:userId. */
export const WorkspaceMemberOverrideSchema = z.strictObject({
  workers: z.record(z.string().max(128), z.unknown(), { error: "workers must be an object" }).optional(),
  mode: z.string({ error: "mode must be text" }).max(32).optional(),
});

/** PATCH /api/workspaces/:id: at least one option; ranges are checked by the handler. */
export const UpdateWorkspaceSchema = z.object({
  name: z.string({ error: "Workspace name must be 1 to 120 characters" }).max(1000).optional(),
  parallelSlots: z.number({ error: "parallelSlots must be a number" }).optional(),
  spaceAiChat: z.boolean({ error: "spaceAiChat and spaceAiWork must be booleans" }).optional(),
  spaceAiWork: z.boolean({ error: "spaceAiChat and spaceAiWork must be booleans" }).optional(),
});

/** POST /api/workspaces/:id/invitations. */
export const WorkspaceInvitationSchema = z.strictObject({
  email: z.string({ error: "An email address is required" }).max(320, "Enter a valid email address"),
});

/** PUT /api/workspaces/:id/person-grants/:userId/quota. */
export const PersonGrantQuotaSchema = z
  .strictObject({
    maxConcurrentRequests: z.int().min(1).max(10).optional(),
    maxRunSecondsPerMonth: z.int().min(60).max(31 * 24 * 3600).nullable().optional(),
  })
  .refine((body) => Object.keys(body).length > 0, { message: "Provide a limit" });

/** POST /api/work-requests/:id/inputs/:inputId/failed. */
export const InputUploadFailedSchema = z.object({
  message: z.string({ error: "message must be text" }).max(2000).optional(),
});

/** POST /api/workspace-runtime/inputs/:fileId/delivered. */
export const InputDeliveredSchema = z.object({
  contentDigest: z.string({ error: "contentDigest must be text" }).max(128).optional(),
});

/** POST /api/workspace-runtime/inputs/:fileId/attempt. */
export const InputAttemptSchema = z.object({
  final: z.boolean({ error: "final must be true or false" }).optional(),
  message: z.string({ error: "message must be text" }).max(2000).optional(),
});
