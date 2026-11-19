/**
 * Worker Instance DTOs (ADR-032): the wire shapes of `/api/workers` and
 * `/api/features`. A Worker Instance is a durable, user-owned Worker with its
 * own Actor; its name is editable and not unique, so every reference uses `id`.
 */
import { z } from "zod";

const workerName = z
  .string({ error: "name is required" })
  .trim()
  .min(1, "name is required")
  .max(120, "name must be at most 120 characters");
const workerDescription = z
  .string({ error: "description must be text" })
  .max(500, "description must be at most 500 characters");
const defaultModel = z
  .string({ error: "defaultModel must be text" })
  .min(1, "defaultModel must not be empty")
  .max(200, "defaultModel must be at most 200 characters");

/** A Worker Instance as the API returns it. */
export const WorkerInstanceSchema = z.object({
  id: z.string(),
  actorId: z.string(),
  workerTypeId: z.string(),
  workerTypeName: z.string(),
  name: z.string(),
  description: z.string(),
  /** Configured by the owner. */
  enabled: z.boolean(),
  /** Observed: a connection is open. Never set by the owner. */
  online: z.boolean(),
  /** Observed: the Worker passed its readiness checks. Never set by the owner. */
  ready: z.boolean(),
  defaultModel: z.string().nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
  /** Set when the Worker was removed (tombstone); such a Worker never changes again. */
  revokedAt: z.string().nullable(),
});
export type WorkerInstance = z.infer<typeof WorkerInstanceSchema>;

/** GET /api/workers. */
export const WorkerInstanceListSchema = z.object({
  workers: z.array(WorkerInstanceSchema),
});
export type WorkerInstanceList = z.infer<typeof WorkerInstanceListSchema>;

/** POST /api/workers. The Type is fixed for the life of the Worker. */
export const CreateWorkerRequestSchema = z.object({
  workerTypeId: z
    .string({ error: "workerTypeId is required" })
    .min(1, "workerTypeId is required")
    .max(128, "workerTypeId must be at most 128 characters"),
  name: workerName,
  description: workerDescription.optional(),
  defaultModel: defaultModel.nullish(),
});
export type CreateWorkerRequest = z.infer<typeof CreateWorkerRequestSchema>;

/** PATCH /api/workers/:workerId. Only configured fields; `online` and `ready` are observed. */
export const UpdateWorkerRequestSchema = z
  .object({
    name: workerName.optional(),
    description: workerDescription.optional(),
    enabled: z.boolean({ error: "enabled must be true or false" }).optional(),
    defaultModel: defaultModel.nullable().optional(),
  })
  .refine((value) => Object.values(value).some((field) => field !== undefined), {
    message: "Provide at least one field to change",
  });
export type UpdateWorkerRequest = z.infer<typeof UpdateWorkerRequestSchema>;

/** GET /api/features: the rollout flags that are on for this deployment. */
export const FeatureFlagsResponseSchema = z.object({
  flags: z.array(z.string()),
});
export type FeatureFlagsResponse = z.infer<typeof FeatureFlagsResponseSchema>;
