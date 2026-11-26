import { z } from "zod";

import {
  DURABLE_REALTIME_EVENT_TYPES,
  REALTIME_STREAM_KINDS,
  COLLABORATION_REALTIME_EVENT_TYPES,
  EPHEMERAL_REALTIME_EVENT_TYPES,
} from "./generated.js";
import {
  NORMALIZED_ACTIVITY_EVENT_TYPES,
  NORMALIZED_ACTIVITY_STATUSES,
  NormalizedActivityDetailsSchema,
} from "./execution-activity.js";

const realtimeVersionPattern = /^\d+\.\d+$/;
const id = z.string().trim().min(1);
const timestamp = z.string().datetime();

export const WORKER_ACTIVITY_EVENT_TYPES = NORMALIZED_ACTIVITY_EVENT_TYPES;

const workerActivityEventType = z.enum(WORKER_ACTIVITY_EVENT_TYPES);
const workerActivityStatus = z.enum(NORMALIZED_ACTIVITY_STATUSES);
const MAX_WORKER_ACTIVITY_PAYLOAD_BYTES = 16 * 1024;

export const RealtimeEventPayloadSchema = z
  .object({
    entityId: id.optional(),
    status: id.optional(),
    message: z.string().max(32768).optional(),
    summary: z.string().max(32768).optional(),
    text: z.string().max(32768).optional(),
    delta: z.string().max(8192).optional(),
    tool: id.optional(),
    artifactId: id.optional(),
    workRequestId: id.optional(),
    requestedByUserId: id.optional(),
    submissionId: id.optional(),
    threadId: id.optional(),
    stepKind: id.optional(),
    leaseId: id.optional(),
    workerId: id.optional(),
    percentage: z.number().min(0).max(100).optional(),
    sourceEventId: id.max(128).optional(),
    executionId: id.max(128).optional(),
    activityId: id.max(128).optional(),
    activitySequence: z.number().int().positive().max(2_147_483_647).optional(),
    activityType: workerActivityEventType.optional(),
    activityStatus: workerActivityStatus.optional(),
    title: z.string().min(1).max(256).optional(),
    details: NormalizedActivityDetailsSchema.optional(),
    durationMs: z.number().int().min(0).optional(),
    toolId: id.max(128).optional(),
    toolName: id.max(128).optional(),
    tokenCount: z.number().int().min(0).optional(),
    coalesced: z.boolean().optional(),
  })
  .strict();
export type RealtimeEventPayload = z.infer<typeof RealtimeEventPayloadSchema>;

export const RealtimeStreamSchema = z
  .object({
    kind: z.enum(REALTIME_STREAM_KINDS),
    id,
  })
  .strict();
export type RealtimeStream = z.infer<typeof RealtimeStreamSchema>;

export const RealtimeEventEnvelopeSchema = z
  .object({
    eventId: id,
    type: z.string().regex(/^[a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+)+$/),
    version: z.string().regex(realtimeVersionPattern),
    timestamp,
    stream: RealtimeStreamSchema.optional(),
    spaceId: id.optional(),
    threadId: id.optional(),
    runId: id.optional(),
    taskId: id.optional(),
    attemptId: id.optional(),
    assignmentId: id.optional(),
    sequence: z.number().int().min(0),
    payload: RealtimeEventPayloadSchema,
  })
  .strict()
  .superRefine((event, context) => {
    const stream = event.stream;
    const people = event.type === "people.updated";
    const collaboration = (
      COLLABORATION_REALTIME_EVENT_TYPES as readonly string[]
    ).includes(event.type);
    if (
      collaboration &&
      (!stream ||
        (!people && !event.spaceId) ||
        !event.payload.entityId)
    ) {
      context.addIssue({
        code: "custom",
        message:
          "Collaboration signals require a synchronization stream, spaceId and entityId",
      });
    }
    if (
      people &&
      (stream?.kind !== "user" ||
        event.spaceId ||
        event.threadId ||
        Object.keys(event.payload).some((key) => key !== "entityId"))
    ) {
      context.addIssue({
        code: "custom",
        message:
          "People signals require a user stream and an entity identifier only",
      });
    }
    if (
      collaboration &&
      (event.type.startsWith("thread.") ||
        event.type.startsWith("discussion.")) &&
      (!event.threadId || event.payload.threadId !== event.threadId)
    ) {
      context.addIssue({
        code: "custom",
        message: "Thread signals require matching threadId",
      });
    }
    if (
      collaboration &&
      Object.keys(event.payload).some(
        (key) => !["entityId", "threadId"].includes(key),
      )
    ) {
      context.addIssue({
        code: "custom",
        message: "Collaboration payloads contain identifiers only",
      });
    }
    const spaceWorkEvent =
      (event.type.startsWith("work_request.") ||
        event.type.startsWith("step.")) &&
      stream?.kind === "space" &&
      stream.id === event.spaceId &&
      !!event.payload.threadId &&
      !!event.payload.workRequestId;
    const spaceActivity = event.type === "assignment.activity" &&
      stream?.kind === "space" && stream.id === event.spaceId && !!event.threadId;
    if (
      !collaboration &&
      isKnownRealtimeEventType(event.type) &&
      !spaceWorkEvent && !spaceActivity
    ) {
      context.addIssue({
        code: "custom",
        message:
          "Execution events require a scoped Space Work stream",
      });
    }
    if (event.type === "assignment.activity") {
      const payload = event.payload;
      const required = [
        "entityId",
        "workerId",
        "sourceEventId",
        "executionId",
        "activitySequence",
        "activityType",
        "activityStatus",
        "title",
      ] as const;
      for (const field of required) {
        if (payload[field] === undefined) {
          context.addIssue({
            code: "custom",
            path: ["payload", field],
            message: `assignment.activity requires ${field}`,
          });
        }
      }
      if (
        !event.assignmentId ||
        !event.attemptId ||
        !spaceActivity
      ) {
        context.addIssue({
          code: "custom",
          message:
            "assignment.activity requires assignment, attempt and a Space stream",
        });
      }
      if (payload.entityId !== event.assignmentId) {
        context.addIssue({
          code: "custom",
          path: ["payload", "entityId"],
          message: "assignment.activity entityId must match assignmentId",
        });
      }
      if (
        new TextEncoder().encode(JSON.stringify(payload)).byteLength >
        MAX_WORKER_ACTIVITY_PAYLOAD_BYTES
      ) {
        context.addIssue({
          code: "custom",
          message: "assignment.activity payload exceeds size limit",
        });
      }
    }
    if (!stream) {
      context.addIssue({
        code: "custom",
        message: "Realtime events require a stream",
      });
    }
    if (stream?.kind === "space" && stream.id !== event.spaceId) {
      context.addIssue({
        code: "custom",
        message: "Space stream must match spaceId",
      });
    }
    if (stream && event.version === "1.0") {
      context.addIssue({
        code: "custom",
        message: "Synchronization streams require version 1.1",
      });
    }
  });
export type RealtimeEventEnvelope = z.infer<typeof RealtimeEventEnvelopeSchema>;

function versionParts(version: string): [number, number] {
  const parsed = version.match(/^(\d+)\.(\d+)$/);
  if (!parsed) throw new Error(`Invalid realtime event version: ${version}`);
  return [Number(parsed[1]), Number(parsed[2])];
}

export function isCompatibleRealtimeEventVersion(
  local: string,
  remote: string,
): boolean {
  const [localMajor, localMinor] = versionParts(local);
  const [remoteMajor, remoteMinor] = versionParts(remote);
  return localMajor === remoteMajor && remoteMinor >= localMinor;
}

export function isKnownRealtimeEventType(type: string): boolean {
  return (
    DURABLE_REALTIME_EVENT_TYPES.includes(
      type as (typeof DURABLE_REALTIME_EVENT_TYPES)[number],
    ) ||
    EPHEMERAL_REALTIME_EVENT_TYPES.includes(
      type as (typeof EPHEMERAL_REALTIME_EVENT_TYPES)[number],
    )
  );
}

export function isDurableRealtimeEventType(type: string): boolean {
  return DURABLE_REALTIME_EVENT_TYPES.includes(
    type as (typeof DURABLE_REALTIME_EVENT_TYPES)[number],
  );
}

export function isEphemeralRealtimeEventType(type: string): boolean {
  return EPHEMERAL_REALTIME_EVENT_TYPES.includes(
    type as (typeof EPHEMERAL_REALTIME_EVENT_TYPES)[number],
  );
}

export function isReplayableRealtimeEvent(
  event: Pick<RealtimeEventEnvelope, "type" | "payload">,
): boolean {
  return isDurableRealtimeEventType(event.type);
}

/**
 * Parses facts received from Cloud realtime transport. Unknown event types are
 * retained when their event version is compatible so newer servers can add
 * facts without breaking older clients.
 */
export function parseRealtimeEvent(input: unknown): RealtimeEventEnvelope {
  const value = typeof input === "string" ? JSON.parse(input) : input;
  const event = RealtimeEventEnvelopeSchema.parse(value);
  if (!isCompatibleRealtimeEventVersion("1.0", event.version)) {
    throw new Error(`Unsupported realtime event version: ${event.version}`);
  }
  return event;
}

/** The stream an event belongs to; every event carries one. */
export function realtimeEventStream(
  event: RealtimeEventEnvelope,
): RealtimeStream {
  if (!event.stream) throw new Error("Realtime event has no stream");
  return event.stream;
}

/** Structured JSON keys cannot collide across stream kinds or arbitrary IDs. */
export function realtimeStreamKey(stream: RealtimeStream): string {
  return JSON.stringify([stream.kind, stream.id]);
}
