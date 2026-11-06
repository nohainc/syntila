import { McpInventorySchema } from "./mcp-inventory.js";
import {
  McpToolCallRequestSchema,
  McpToolCallResultSchema,
  McpToolCallStatusRequestSchema,
  McpToolCallStatusResultSchema,
} from "./mcp-tool-call.js";
import { z } from "zod";
import {
  EXECUTION_PERMISSIONS,
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
  NORMALIZED_ACTIVITY_EVENT_TYPES,
  NORMALIZED_ACTIVITY_STATUSES,
  NormalizedActivityDetailsSchema,
} from "@syntila/protocol";

export const WORKSPACE_RUNTIME_PROTOCOL_NAME =
  "syntila.workspace-runtime-protocol" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_VERSION = "5.1" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SUPPORTED_VERSIONS = [
  "5.0",
  "5.1",
] as const;

export const WORKSPACE_RUNTIME_MESSAGE_TYPES = [
  "workspace.hello",
  "workspace.hello.ack",
  "workspace.heartbeat",
  "workspace.heartbeat.ack",
  "workspace.sync.request",
  "workspace.sync.result",
  "workspace.status",
  "workspace.readiness",
  "workspace.update",
  "worker.inventory",
  "thread.status",
  "assignment.start",
  "assignment.start.ack",
  "assignment.startup",
  "assignment.start.permit.request",
  "assignment.start.permit.grant",
  "assignment.ack",
  "assignment.activity",
  "assignment.result",
  "assignment.error",
  "assignment.cancel",
  "assignment.cancel.ack",
  "assignment.cancelled",
  "diagnostic.probe",
  "diagnostic.probe.ack",
  "worker.usage.request",
  "worker.usage.result",
  "mcp.tool_call.request",
  "mcp.tool_call.result",
  "mcp.tool_call.status.request",
  "mcp.tool_call.status.result",
  "mcp.inventory",
  "input.available",
] as const;

export type WorkspaceRuntimeMessageType =
  (typeof WORKSPACE_RUNTIME_MESSAGE_TYPES)[number];

/** Maximum characters of raw provider usage output carried in one message. */
export const WORKER_USAGE_OUTPUT_MAX_CHARS = 64 * 1024;

const nonEmptyString = z.string().trim().min(1);
const timestamp = z.string().datetime();

/**
 * Service-level connection states. They describe the Service as a transport
 * endpoint, never an individual Worker: Worker eligibility is published
 * separately through inventory. Only `ready` may receive new assignments.
 */
export const SERVICE_CONNECTION_STATES = [
  "disconnected",
  "connecting",
  "authenticated",
  "synchronizing",
  "ready",
  "paused",
  "draining",
  "reconnecting",
] as const;

export type ServiceConnectionState = (typeof SERVICE_CONNECTION_STATES)[number];

/** Capability a Service advertises when it publishes `workspace.readiness`. */
export const SERVICE_READINESS_CAPABILITY = "workspace.readiness.v1";

/** Capability a Service advertises when it handles `mcp.tool_call.request`. */
export const SERVICE_MCP_TOOL_CALL_CAPABILITY = "workspace.mcp_tool_call.v1";

/** Capability a Service advertises when it answers `mcp.tool_call.status.request`. */
export const SERVICE_MCP_TOOL_CALL_STATUS_CAPABILITY =
  "workspace.mcp_tool_call_status.v1";

/** Capability a Service advertises when it publishes `mcp.inventory`. */
export const SERVICE_MCP_INVENTORY_CAPABILITY = "workspace.mcp_inventory.v1";

/**
 * Capability Cloud announces in `hello.ack` when `worker.inventory` may carry
 * `allowedFolders`. Older Cloud rejects the field, so Services wait for it.
 */
export const ALLOWED_FOLDERS_CAPABILITY = "workspace.allowed_folders.v1";

/**
 * Capability Cloud announces in `hello.ack` when `worker.inventory` entries may
 * carry the plugin `executor` object (ADR-027). Older Cloud rejects the field,
 * so Services wait for the announcement before reporting plugin Workers.
 */
export const WORKER_PLUGINS_CAPABILITY = "workspace.worker_plugins.v1";

/**
 * What a Service reports about a plugin Worker. Cloud freezes the digests into
 * the assignment snapshot and requires them to equal the Workspace pin.
 */
export const PluginInventoryExecutorSchema = z
  .object({
    kind: z.literal("plugin"),
    pluginId: z
      .string()
      .max(48)
      .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/),
    version: z.string().regex(/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/),
    manifestDigest: z.string().regex(/^[0-9a-f]{64}$/),
    /** Null when the artifact could not be verified on this host. */
    artifactDigest: z
      .string()
      .regex(/^[0-9a-f]{64}$/)
      .nullable(),
    pluginProtocol: z.string().regex(/^1\.\d+$/),
    isolation: z
      .object({
        tier: z.enum(["none", "best_effort", "enforced"]),
        readOnlyEnforced: z.boolean(),
      })
      .strict(),
    sessionResume: z.enum(["none", "declared_untested", "tested"]),
    shareable: z.boolean(),
  })
  .strict();
export type PluginInventoryExecutor = z.infer<
  typeof PluginInventoryExecutorSchema
>;

/**
 * The executor identity Cloud froze into an assignment (ADR-027). The Service
 * runs the plugin only if its local pin has exactly this `manifestDigest`.
 */
export const PluginSnapshotExecutorSchema = z
  .object({
    schemaVersion: z.literal(1),
    kind: z.literal("plugin"),
    pluginRef: z.string().regex(/^plugin-[0-9a-f]{12}$/),
    pluginId: z
      .string()
      .max(48)
      .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/),
    version: z.string().regex(/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/),
    manifestDigest: z.string().regex(/^[0-9a-f]{64}$/),
    artifactDigest: z.string().regex(/^[0-9a-f]{64}$/),
    pluginProtocol: z.string().regex(/^1\.\d+$/),
    isolation: z
      .object({
        tier: z.enum(["none", "best_effort", "enforced"]),
        readOnlyEnforced: z.boolean(),
      })
      .strict(),
  })
  .strict();
export type PluginSnapshotExecutor = z.infer<
  typeof PluginSnapshotExecutorSchema
>;

/**
 * Readiness published by the Service. `syncGeneration` increases every time
 * the Service completes a (re)synchronization with Cloud, so Cloud can ignore
 * a late readiness report from before the latest sync.
 */
export const serviceReadinessPayload = z
  .object({
    state: z.enum(SERVICE_CONNECTION_STATES),
    readyForAssignments: z.boolean(),
    syncGeneration: z.number().int().min(0).max(2_147_483_647),
    reason: nonEmptyString.max(200).optional(),
    pendingAssignments: z.number().int().min(0).max(100_000).optional(),
  })
  .strict()
  .superRefine((readiness, readinessCtx) => {
    if (readiness.readyForAssignments && readiness.state !== "ready") {
      readinessCtx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "only the ready state may accept assignments",
      });
    }
  });

export type ServiceReadinessPayload = z.infer<typeof serviceReadinessPayload>;

/** Capability Cloud announces when it understands `assignment.startup`. */
export const ASSIGNMENT_STARTUP_CAPABILITY = "assignment.startup.v1";

/**
 * Milestones of starting an accepted assignment locally, in order. Provider
 * start is reported by `assignment.start.ack`, not by this message.
 * `waiting_for_space` and `queued_for_slot` are waiting stages; the others
 * mean the Service is making progress.
 */
export const ASSIGNMENT_STARTUP_STAGES = [
  "worker_resolved",
  "profile_ready",
  "waiting_for_space",
  "queued_for_slot",
  "slot_reserved",
  "engine_spawned",
  "engine_initialized",
] as const;
export type AssignmentStartupStage = (typeof ASSIGNMENT_STARTUP_STAGES)[number];

/** Ordering used to ignore a late startup report that moves backwards. */
export const ASSIGNMENT_STARTUP_STAGE_RANK: Record<
  AssignmentStartupStage,
  number
> = {
  worker_resolved: 1,
  profile_ready: 2,
  waiting_for_space: 3,
  queued_for_slot: 4,
  slot_reserved: 5,
  engine_spawned: 6,
  engine_initialized: 7,
};

/**
 * Startup progress published by the Service for an accepted assignment. It is
 * evidence for observability only: it never grants, extends or shortens any
 * deadline and never changes the assignment status.
 */
export const assignmentStartupPayload = z
  .object({
    stage: z.enum(ASSIGNMENT_STARTUP_STAGES),
    at: timestamp.optional(),
    queuePosition: z.number().int().min(1).max(100_000).optional(),
    activeSlots: z.number().int().min(0).max(100_000).optional(),
    slotLimit: z.number().int().min(1).max(100_000).optional(),
    waitingForSession: z.boolean().optional(),
    queueWaitTimeoutMs: z.number().int().min(0).max(2_147_483_647).optional(),
    profileDigest: z
      .string()
      .regex(/^[a-f0-9]{64}$/)
      .optional(),
    profileRevision: z.number().int().min(0).max(2_147_483_647).optional(),
  })
  .strict();

export type AssignmentStartupPayload = z.infer<typeof assignmentStartupPayload>;
const executionErrorCode = z.enum(EXECUTION_ERROR_CODES);

/** Canonical execution permissions carried from Cloud to Workspace. */
export const EXECUTION_PERMISSION_IDS = EXECUTION_PERMISSIONS;
const executionPermission = z.enum(EXECUTION_PERMISSIONS);
const workerActivityPayload = z
  .object({
    assignmentId: nonEmptyString.max(128),
    executionId: nonEmptyString.max(128),
    workerId: nonEmptyString.max(128),
    eventId: nonEmptyString.max(128),
    sequence: z.number().int().positive().max(2_147_483_647),
    timestamp,
    eventType: z.enum(NORMALIZED_ACTIVITY_EVENT_TYPES),
    status: z.enum(NORMALIZED_ACTIVITY_STATUSES),
    title: z.string().min(1).max(256),
    activityId: nonEmptyString.max(128).optional(),
    percentage: z.number().min(0).max(100).optional(),
    details: NormalizedActivityDetailsSchema.optional(),
    durationMs: z.number().int().min(0).optional(),
    toolId: nonEmptyString.max(128).optional(),
    toolName: nonEmptyString.max(128).optional(),
  })
  .strict();

/** Product-facing Worker Type IDs; legacy provider package IDs are not valid. */
export const WorkspaceProductWorkerTypeIdSchema = nonEmptyString
  .max(128)
  .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
  .refine((id) => id !== "codex" && id !== "antigravity", {
    message: "legacy package IDs are not Workspace product Worker Types",
  });

const DiscoveredModelCatalogV1Schema = z
  .object({
    schemaVersion: z.literal(1),
    profileDigest: z.string().regex(/^[0-9a-f]{64}$/),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/),
    discoveredAt: timestamp,
    models: z
      .array(
        z
          .object({
            id: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
            name: z
              .string()
              .min(1)
              .max(256)
              // eslint-disable-next-line no-control-regex -- Disallow ASCII control characters in names.
              .regex(/^[^\x00-\x1f\x7f]+$/),
            status: z.enum(["listed", "verified", "unavailable"]),
            supportedReasoningEfforts: z
              .array(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/))
              .max(16)
              .refine(
                (efforts) => new Set(efforts).size === efforts.length,
                "Duplicate reasoning efforts",
              )
              .optional(),
            defaultReasoningEffort: z
              .string()
              .regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/)
              .optional(),
          })
          .strict()
          .superRefine((model, ctx) => {
            if (
              model.defaultReasoningEffort !== undefined &&
              !model.supportedReasoningEfforts?.includes(
                model.defaultReasoningEffort,
              )
            ) {
              ctx.addIssue({
                code: z.ZodIssueCode.custom,
                path: ["defaultReasoningEffort"],
                message: "Default reasoning effort must be listed as supported",
              });
            }
          }),
      )
      .max(128)
      .refine(
        (models) => new Set(models.map((m) => m.id)).size === models.length,
        "Duplicate model IDs",
      ),
  })
  .strict();

/** Sanitized inventory: native IDs/mappings are forbidden at this boundary. */
export const DiscoveredModelCatalogV2Schema = z
  .object({
    schemaVersion: z.literal(2),
    stale: z.boolean().optional(),
    catalogRevision: z.string().regex(/^[0-9a-f]{64}$/),
    profileDigest: z.string().regex(/^[0-9a-f]{64}$/),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/),
    discoveredAt: timestamp,
    models: z
      .array(
        z
          .object({
            id: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
            name: z
              .string()
              .min(1)
              .max(256)
              // eslint-disable-next-line no-control-regex -- Disallow ASCII control characters in names.
              .regex(/^[^\x00-\x1f\x7f]+$/),
            status: z.enum(["listed", "verified", "unavailable"]),
            selectionMode: z.enum(["separate", "combined"]),
            efforts: z
              .array(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/))
              .max(16)
              .refine(
                (values) => new Set(values).size === values.length,
                "Duplicate efforts",
              )
              .default([]),
            defaultEffort: z
              .string()
              .regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/)
              .nullable()
              .default(null),
          })
          .strict()
          .superRefine((model, ctx) => {
            if (
              model.defaultEffort !== null &&
              !model.efforts.includes(model.defaultEffort)
            ) {
              ctx.addIssue({
                code: "custom",
                path: ["defaultEffort"],
                message: "Default effort must be supported",
              });
            }
          }),
      )
      .max(128)
      .refine(
        (models) => new Set(models.map((m) => m.id)).size === models.length,
        "Duplicate model IDs",
      ),
  })
  .strict();
export const DiscoveredModelCatalogSchema = z.union([
  DiscoveredModelCatalogV1Schema,
  DiscoveredModelCatalogV2Schema,
]);

export const WorkspaceWorkerInventoryEntrySchema = z
  .object({
    workerId: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/),
    workerTypeId: WorkspaceProductWorkerTypeIdSchema,
    activationState: z.enum(["enabled", "disabled"]),
    readinessState: z.enum([
      "not_probed",
      "ready",
      "setup_required",
      "sign_in_required",
      "worker_runtime_unavailable",
      "test_failed",
    ]),
    readinessIssueCode: z
      .string()
      .regex(/^[a-z][a-z0-9_]{0,127}$/)
      .optional(),
    engineVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$/)
      .nullable(),
    profileDefinitionId: z
      .string()
      .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
      .max(96)
      .nullable(),
    profileReleaseVersion: z
      .number()
      .int()
      .positive()
      .max(Number.MAX_SAFE_INTEGER)
      .nullable(),
    providerToolName: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$/)
      .nullable(),
    providerToolVersion: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/)
      .nullable(),
    modelCatalog: DiscoveredModelCatalogSchema.optional(),
    /** Present only for a plugin Worker (ADR-027). */
    executor: PluginInventoryExecutorSchema.optional(),
    localConcurrencyLimit: z.number().int().min(1).max(1024),
    revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
    createdAt: timestamp,
    updatedAt: timestamp,
    lastSeenAt: timestamp,
  })
  .strict();

/**
 * Path-free summary of an owner-managed Allowed Folder. The local absolute
 * path never crosses this boundary; execution maps the ID back locally.
 */
export const WorkspaceAllowedFolderSchema = z
  .object({
    id: z.string().regex(/^folder-[a-f0-9]{16}$/),
    displayName: z
      .string()
      .min(1)
      .max(80)
      .refine(
        (value) =>
          [...value].every((char) => {
            const code = char.charCodeAt(0);
            return code > 0x1f && code !== 0x7f;
          }),
        "displayName must not contain control characters",
      ),
    status: z.enum(["available", "read_only", "denied", "missing"]),
    checkedAt: timestamp,
  })
  .strict();

export type WorkspaceAllowedFolder = z.infer<
  typeof WorkspaceAllowedFolderSchema
>;

export const WorkerInventoryPayloadSchema = z
  .object({
    workers: z.array(WorkspaceWorkerInventoryEntrySchema).max(500),
    // Workspace-wide parallel execution slots, shared by all Workers. Optional
    // so older Services remain valid; they report it per Worker only.
    parallelSlots: z.number().int().min(1).max(1024).optional(),
    // The complete Allowed Folders list. Optional so older Services remain
    // valid; omission keeps Cloud's last known list.
    allowedFolders: z.array(WorkspaceAllowedFolderSchema).max(32).optional(),
    fullSnapshot: z.boolean(),
  })
  .strict();

export const workspaceRuntimeEnvelopeSchema = z
  .object({
    protocol: z.literal(WORKSPACE_RUNTIME_PROTOCOL_NAME),
    protocolVersion: z.enum(WORKSPACE_RUNTIME_PROTOCOL_SUPPORTED_VERSIONS),
    messageId: nonEmptyString,
    correlationId: nonEmptyString.optional(),
    timestamp,
    type: z.enum(WORKSPACE_RUNTIME_MESSAGE_TYPES),
    executionWorkspaceId: nonEmptyString.optional(),
    workspaceRuntimeId: nonEmptyString.optional(),
    workerId: nonEmptyString.optional(),
    runId: nonEmptyString.optional(),
    taskId: nonEmptyString.optional(),
    attemptId: nonEmptyString.optional(),
    assignmentId: nonEmptyString.optional(),
    idempotencyKey: nonEmptyString.optional(),
    payload: z.unknown(),
  })
  .strict()
  .superRefine((message, ctx) => {
    if (message.type.startsWith("assignment.")) {
      for (const field of [
        "executionWorkspaceId",
        "workspaceRuntimeId",
        "workerId",
        "runId",
        "taskId",
        "attemptId",
        "assignmentId",
        "idempotencyKey",
      ] as const) {
        if (!message[field]) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: [field],
            message: `${field} is required for assignment messages`,
          });
        }
      }
    }
    if (message.type === "assignment.start") {
      const payload = z
        .object({
          snapshot: z
            .object({
              workerTypeId: WorkspaceProductWorkerTypeIdSchema,
              executionSelection: z
                .object({
                  schemaVersion: z.literal(1),
                  catalogSource: z.enum([
                    "provider_catalog",
                    "profile_catalog",
                  ]),
                  workerTypeId: WorkspaceProductWorkerTypeIdSchema,
                  workerDisplayName: nonEmptyString.max(256),
                  profileReleaseVersion: z.number().int().positive(),
                  modelId: nonEmptyString.max(128).nullable(),
                  modelName: nonEmptyString.max(256).nullable(),
                  effort: nonEmptyString.max(128).nullable(),
                  catalogRevision: z
                    .string()
                    .regex(/^[a-f0-9]{64}$/)
                    .nullable(),
                  modelSource: z.enum([
                    "explicit",
                    "catalog_default",
                    "provider_default",
                  ]),
                  effortSource: z.enum([
                    "explicit",
                    "catalog_default",
                    "provider_default",
                  ]),
                  /** Present only for a plugin Worker: the admitted identity. */
                  executor: PluginSnapshotExecutorSchema.optional(),
                })
                .strict()
                .optional(),
              permissions: z.array(executionPermission).optional(),
              permissionSnapshot: z
                .object({
                  permissions: z.array(executionPermission),
                })
                .passthrough()
                .optional(),
              model: nonEmptyString.max(128).nullable().optional(),
              reasoningEffort: nonEmptyString.max(128).nullable().optional(),
              readOnly: z.boolean().optional(),
              sessionPolicy: z
                .enum(["stateless", "durable_session"])
                .optional(),
              sessionKey: nonEmptyString.max(256).optional(),
            })
            .superRefine((snapshot, ctx) => {
              if (
                snapshot.executionSelection &&
                (snapshot.executionSelection.workerTypeId !==
                  snapshot.workerTypeId ||
                  snapshot.executionSelection.modelId !==
                    (snapshot.model ?? null) ||
                  snapshot.executionSelection.effort !==
                    (snapshot.reasoningEffort ?? null))
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["executionSelection"],
                  message: "Frozen selection must match assignment invocation",
                });
              }

              if (
                (snapshot.sessionPolicy === "stateless" &&
                  snapshot.sessionKey !== undefined) ||
                (snapshot.sessionPolicy === "durable_session" &&
                  snapshot.sessionKey === undefined)
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["sessionKey"],
                  message:
                    "Session policy and logical session key are inconsistent",
                });
              }
            })
            .superRefine((snapshot, ctx) => {
              if (
                snapshot.permissions &&
                snapshot.permissionSnapshot &&
                JSON.stringify(snapshot.permissions) !==
                  JSON.stringify(snapshot.permissionSnapshot.permissions)
              ) {
                ctx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["permissionSnapshot", "permissions"],
                  message: "assignment permission fields must match",
                });
              }
            })
            .passthrough(),
          permissions: z.array(executionPermission).optional(),
          input: z.record(z.string(), z.unknown()).optional(),
        })
        .passthrough()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.error") {
      const payload = z
        .object({
          error: z
            .object({
              code: executionErrorCode,
              message: nonEmptyString.max(512),
              retryable: z.boolean(),
              details: z
                .record(
                  z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/),
                  z.union([
                    z.string().max(2048),
                    z.number(),
                    z.boolean(),
                    z.null(),
                  ]),
                )
                .optional(),
            })
            .strict()
            .superRefine((error, errorCtx) => {
              if (error.message !== EXECUTION_ERROR_MESSAGES[error.code]) {
                errorCtx.addIssue({
                  code: z.ZodIssueCode.custom,
                  path: ["message"],
                  message:
                    "assignment errors must use the canonical safe message",
                });
              }
            }),
        })
        .passthrough()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (
      message.type === "diagnostic.probe" ||
      message.type === "diagnostic.probe.ack"
    ) {
      const probeId = nonEmptyString.max(128).regex(/^[A-Za-z0-9._:-]+$/);
      const schema =
        message.type === "diagnostic.probe"
          ? z.object({ probeId, sentAt: timestamp }).strict()
          : z
              .object({
                probeId,
                receivedAt: timestamp,
                ackedAt: timestamp,
                transport: probeId.optional(),
                syncState: probeId.optional(),
                localQueueLength: z
                  .number()
                  .int()
                  .min(0)
                  .max(100_000)
                  .optional(),
                activeAssignments: z
                  .number()
                  .int()
                  .min(0)
                  .max(100_000)
                  .optional(),
                clockOffsetMs: z
                  .number()
                  .int()
                  .min(-86_400_000)
                  .max(86_400_000)
                  .optional(),
                clockRttMs: z.number().int().min(0).max(600_000).optional(),
              })
              .strict();
      const payload = schema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (
      message.type === "worker.usage.request" ||
      message.type === "worker.usage.result"
    ) {
      const token = nonEmptyString.max(128).regex(/^[A-Za-z0-9._:-]+$/);
      const reportText = z.string().max(WORKER_USAGE_OUTPUT_MAX_CHARS);
      const schema =
        message.type === "worker.usage.request"
          ? z.object({ requestId: token, workerId: token }).strict()
          : z
              .object({
                requestId: token,
                status: z.enum(["ok", "unavailable", "error"]),
                // The provider's own report, returned verbatim and never
                // interpreted by Syntila.
                output: reportText.optional(),
                errorOutput: reportText.optional(),
                exitCode: z.number().int().min(-1024).max(1024).optional(),
                truncated: z.boolean().optional(),
                errorCode: token.optional(),
                errorMessage: z.string().max(512).optional(),
              })
              .strict();
      const payload = schema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "mcp.tool_call.request") {
      const payload = McpToolCallRequestSchema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "mcp.tool_call.status.request") {
      const payload = McpToolCallStatusRequestSchema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "mcp.tool_call.status.result") {
      const payload = McpToolCallStatusResultSchema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "mcp.inventory") {
      const payload = McpInventorySchema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "mcp.tool_call.result") {
      const payload = McpToolCallResultSchema.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "input.available") {
      // A wake-up only: the Service lists and downloads inputs over HTTPS
      // (Input Delivery v1), so the message never carries file content.
      const payload = z.object({}).strict().safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "workspace.readiness") {
      const payload = serviceReadinessPayload.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.start.permit.request") {
      const payload = z
        .object({ requestedAt: timestamp.optional() })
        .strict()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.start.permit.grant") {
      const payload = z
        .object({
          granted: z.boolean(),
          permitId: nonEmptyString.max(256).optional(),
          expiresAt: timestamp.optional(),
          reason: z
            .enum([
              "revoked",
              "terminal",
              "already_started",
              "stale",
              "not_found",
            ])
            .optional(),
        })
        .strict()
        .superRefine((grant, grantCtx) => {
          if (grant.granted && (!grant.permitId || !grant.expiresAt)) {
            grantCtx.addIssue({
              code: z.ZodIssueCode.custom,
              message: "a granted permit needs permitId and expiresAt",
            });
          }
          if (!grant.granted && !grant.reason) {
            grantCtx.addIssue({
              code: z.ZodIssueCode.custom,
              path: ["reason"],
              message: "a denied permit needs a reason",
            });
          }
        })
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.startup") {
      const payload = assignmentStartupPayload.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.start.ack") {
      const payload = z
        .object({
          started: z.literal(true),
          engineStarted: z.literal(true),
          providerStarted: z.literal(true),
          startedAt: timestamp.optional(),
        })
        .strict()
        .safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
    if (message.type === "assignment.activity") {
      const payload = workerActivityPayload.safeParse(message.payload);
      if (!payload.success) {
        for (const issue of payload.error.issues) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["payload", ...issue.path],
            message: issue.message,
          });
        }
      }
    }
  });

export type WorkspaceRuntimeMessage = z.infer<
  typeof workspaceRuntimeEnvelopeSchema
>;

export function parseWorkspaceRuntimeMessage(
  input: unknown,
): WorkspaceRuntimeMessage {
  const message = workspaceRuntimeEnvelopeSchema.parse(input);
  if (message.type === "worker.inventory") {
    if (message.protocolVersion !== "5.1") {
      throw new Error("worker.inventory requires Workspace protocol 5.1");
    }
    WorkerInventoryPayloadSchema.parse(message.payload);
  }
  return message;
}

export function serializeWorkspaceRuntimeMessage(
  input: WorkspaceRuntimeMessage,
): string {
  return JSON.stringify(parseWorkspaceRuntimeMessage(input));
}
