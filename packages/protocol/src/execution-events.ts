import { z } from "zod";
import {
  NORMALIZED_ACTIVITY_EVENT_TYPES,
  NormalizedActivityPayloadSchema,
} from "./execution-activity.js";

/** Versioned contract for normalized observations of one Worker execution. */
export const EXECUTION_EVENTS_PROTOCOL = "syntila.execution-events" as const;
export const EXECUTION_EVENTS_PROTOCOL_VERSION = "1.0" as const;
export const EXECUTION_EVENT_SCHEMA_VERSION = 1 as const;

const identifier = z
  .string()
  .trim()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9._:-]+$/);
const timestamp = z.string().datetime({ offset: true });

export const EXECUTION_ACTIVITY_EVENT_TYPES = NORMALIZED_ACTIVITY_EVENT_TYPES;

export type ExecutionEventType =
  (typeof EXECUTION_ACTIVITY_EVENT_TYPES)[number];

export const TERMINAL_EXECUTION_EVENT_TYPES = [
  "execution.completed",
  "execution.failed",
  "execution.cancelled",
  "execution.timed_out",
  "execution.lost",
] as const;

const executionEventType = z.enum(EXECUTION_ACTIVITY_EVENT_TYPES);
const executionEventCategory = z.enum(["activity", "lifecycle"]);
const executionEventDelivery = z.enum(["ephemeral", "replayable", "terminal"]);

export const ExecutionEventPayloadSchema = NormalizedActivityPayloadSchema;

/**
 * Normalized execution evidence exchanged between adapters, Service and
 * Cloud. `sequence` is the source/Engine sequence; a Cloud realtime cursor is
 * assigned separately by the realtime event publisher.
 */
export const ExecutionEventEnvelopeSchema = z
  .object({
    protocol: z.literal(EXECUTION_EVENTS_PROTOCOL),
    protocolVersion: z.literal(EXECUTION_EVENTS_PROTOCOL_VERSION),
    schemaVersion: z.literal(EXECUTION_EVENT_SCHEMA_VERSION),
    eventId: identifier,
    eventType: executionEventType,
    category: executionEventCategory,
    delivery: executionEventDelivery,
    threadId: identifier,
    workRequestId: identifier,
    runId: identifier,
    taskId: identifier,
    assignmentId: identifier,
    attemptId: identifier,
    executionId: identifier,
    workerId: identifier,
    sequence: z.number().int().positive().max(2_147_483_647),
    occurredAt: timestamp,
    payload: ExecutionEventPayloadSchema,
  })
  .strict()
  .superRefine((event, context) => {
    const terminal = TERMINAL_EXECUTION_EVENT_TYPES.includes(
      event.eventType as (typeof TERMINAL_EXECUTION_EVENT_TYPES)[number],
    );
    const expectedCategory = terminal ? "lifecycle" : "activity";
    if (event.category !== expectedCategory) {
      context.addIssue({
        code: "custom",
        path: ["category"],
        message: `${event.eventType} must be categorized as ${expectedCategory}`,
      });
    }
    const expectedDelivery = terminal
      ? "terminal"
      : event.eventType === "model.status" ||
          event.eventType === "message.updated"
        ? "ephemeral"
        : "replayable";
    if (event.delivery !== expectedDelivery) {
      context.addIssue({
        code: "custom",
        path: ["delivery"],
        message: `${event.eventType} must use ${expectedDelivery} delivery`,
      });
    }
    if (terminal && event.payload.status === "running") {
      context.addIssue({
        code: "custom",
        path: ["payload", "status"],
        message: "Terminal execution events cannot be running",
      });
    }
  });

export type ExecutionEventEnvelope = z.infer<
  typeof ExecutionEventEnvelopeSchema
>;
export type ExecutionEventPayload = z.infer<typeof ExecutionEventPayloadSchema>;

export function parseExecutionEvent(input: unknown): ExecutionEventEnvelope {
  return ExecutionEventEnvelopeSchema.parse(input);
}
