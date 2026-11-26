/**
 * `syntila.messaging/1` (ADR-038): the one wire envelope shared by human
 * clients and Worker Agents. The shared format never means shared rights:
 * identity comes from the authenticated principal, never from a field the
 * client wrote.
 */
export const MESSAGING_PROTOCOL = "syntila.messaging/1";

export const STREAM_KINDS = ["user", "space", "thread", "worker_inbox", "assignment"] as const;
export type StreamKind = (typeof STREAM_KINDS)[number];
export interface StreamRef { readonly kind: StreamKind; readonly id: string }

export type ActorKind = "human" | "worker" | "system";

export interface MessagingEnvelope {
  readonly protocol: typeof MESSAGING_PROTOCOL;
  readonly eventId: string;
  readonly type: string;
  readonly stream: StreamRef;
  /** Present on durable frames only. */
  readonly sequence?: number;
  readonly occurredAt: string;
  readonly actor?: { readonly kind: ActorKind; readonly id: string };
  readonly correlationId?: string;
  /**
   * The entities the event belongs to (`spaceId`, `threadId`, `runId`, `taskId`,
   * `attemptId`, `assignmentId`, `workerId`), as ids only. Routing
   * information for clients; it grants nothing.
   */
  readonly context?: Record<string, string>;
  readonly payload: Record<string, unknown>;
}

export interface CommandFrame {
  readonly protocol: typeof MESSAGING_PROTOCOL;
  readonly requestId: string;
  readonly type: "command";
  readonly command: string;
  readonly idempotencyKey?: string;
  readonly payload: Record<string, unknown>;
}

export const MAX_FRAME_BYTES = 256 * 1024;
const ID = /^[A-Za-z0-9._:-]{1,160}$/;

export class FrameError extends Error {
  constructor(readonly code: "invalid_frame" | "unsupported_protocol" | "frame_too_large" | "forged_identity", message: string) {
    super(message);
  }
}

/** Fields a client must never author: the server derives who is speaking. */
const FORBIDDEN_IDENTITY_FIELDS = ["actor", "actorId", "principal", "principalId", "userId"] as const;

export function isStreamRef(value: unknown): value is StreamRef {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (STREAM_KINDS as readonly string[]).includes(v.kind as string) && typeof v.id === "string" && ID.test(v.id);
}

export function isMessagingFrame(value: unknown): boolean {
  return !!value && typeof value === "object" && (value as { protocol?: unknown }).protocol === MESSAGING_PROTOCOL;
}

/** Parses one client→server command frame strictly. */
export function parseCommandFrame(raw: string | unknown): CommandFrame {
  let value: unknown = raw;
  if (typeof raw === "string") {
    if (Buffer.byteLength(raw) > MAX_FRAME_BYTES) throw new FrameError("frame_too_large", "Frame is too large");
    try { value = JSON.parse(raw); } catch { throw new FrameError("invalid_frame", "Frame is not JSON"); }
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new FrameError("invalid_frame", "Frame must be an object");
  const f = value as Record<string, unknown>;
  if (f.protocol !== MESSAGING_PROTOCOL) throw new FrameError("unsupported_protocol", "Unsupported protocol");
  for (const key of FORBIDDEN_IDENTITY_FIELDS)
    if (key in f || (f.payload && typeof f.payload === "object" && key in (f.payload as object)))
      throw new FrameError("forged_identity", `${key} is derived from the credential and cannot be sent`);
  if (f.type !== "command" || typeof f.command !== "string" || !/^[a-z][a-z0-9_.]{0,63}$/.test(f.command))
    throw new FrameError("invalid_frame", "A command frame needs type \"command\" and a command name");
  if (typeof f.requestId !== "string" || !ID.test(f.requestId)) throw new FrameError("invalid_frame", "requestId is required");
  if (f.idempotencyKey !== undefined && (typeof f.idempotencyKey !== "string" || !ID.test(f.idempotencyKey)))
    throw new FrameError("invalid_frame", "idempotencyKey is invalid");
  const payload = f.payload ?? {};
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) throw new FrameError("invalid_frame", "payload must be an object");
  return {
    protocol: MESSAGING_PROTOCOL, requestId: f.requestId, type: "command", command: f.command,
    ...(f.idempotencyKey ? { idempotencyKey: f.idempotencyKey as string } : {}),
    payload: payload as Record<string, unknown>,
  };
}

/** The entity ids an event carries, without the empty ones. */
export function eventContext(ids: Record<string, string | null | undefined>): Record<string, string> {
  return Object.fromEntries(Object.entries(ids).filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0));
}

export function buildEnvelope(input: Omit<MessagingEnvelope, "protocol" | "eventId" | "occurredAt"> & { eventId?: string; occurredAt?: string }): MessagingEnvelope {
  return {
    protocol: MESSAGING_PROTOCOL,
    eventId: input.eventId ?? `evt-${crypto.randomUUID()}`,
    occurredAt: input.occurredAt ?? new Date().toISOString(),
    type: input.type, stream: input.stream, payload: input.payload,
    ...(input.sequence !== undefined ? { sequence: input.sequence } : {}),
    ...(input.actor ? { actor: input.actor } : {}),
    ...(input.correlationId ? { correlationId: input.correlationId } : {}),
    ...(input.context && Object.keys(input.context).length ? { context: input.context } : {}),
  };
}
