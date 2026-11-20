import { buildEnvelope, FrameError, isStreamRef, parseCommandFrame, type MessagingEnvelope, type StreamRef } from "./envelope.js";
import { bucketFor, mayIssueCommand, type Principal, type TokenBucket } from "./principal.js";
import type { SubscriptionRegistry } from "./subscription-registry.js";

export interface SessionDeps {
  readonly registry: SubscriptionRegistry;
  readonly authorize: (principal: Principal, stream: StreamRef) => Promise<boolean>;
  readonly head: (stream: StreamRef) => Promise<number>;
  /** Streams this gateway can serve with a durable sequence. */
  readonly supports: (stream: StreamRef) => boolean;
  /**
   * The durable events of [stream] with a sequence above [afterSequence], up to
   * and including [throughSequence], oldest first; null when they are no longer
   * kept. Without it every subscription starts from a snapshot.
   */
  /** False for a stream whose sequences are shared with other streams (a Thread's view of its Space). Default true. */
  readonly gapless?: (stream: StreamRef) => boolean;
  readonly replay?: (stream: StreamRef, afterSequence: number, throughSequence: number) => Promise<MessagingEnvelope[] | null>;
}

/** The longest gap a cursor may resume across; a larger one takes a snapshot. */
export const MAX_REPLAY_EVENTS = 500;

/**
 * One connection's side of the protocol (ADR-038 layer 1 to 2): rate limit,
 * command policy, then subscribe / snapshot-applied / ack / ping. It returns
 * the envelopes to send; it owns no socket.
 */
export class MessagingSession {
  private readonly bucket: TokenBucket;

  constructor(readonly connectionId: string, readonly principal: Principal, private readonly deps: SessionDeps) {
    this.bucket = bucketFor(principal);
  }

  private control(type: string, payload: Record<string, unknown>, correlationId?: string, stream?: StreamRef): MessagingEnvelope {
    return buildEnvelope({
      type, payload, ...(correlationId ? { correlationId } : {}),
      stream: stream ?? { kind: "user", id: this.principal.id },
      actor: { kind: "system", id: "gateway" },
    });
  }

  /** Returns the frames to send in answer to [raw]. Never throws. */
  async handle(raw: unknown): Promise<MessagingEnvelope[]> {
    let frame;
    try {
      frame = parseCommandFrame(raw as string);
    } catch (error) {
      const code = error instanceof FrameError ? error.code : "invalid_frame";
      return [this.control("error", { code, message: error instanceof Error ? error.message : "Invalid frame" })];
    }
    if (!this.bucket.take()) return [this.control("error", { code: "rate_limited", message: "Too many commands" }, frame.requestId)];
    if (!mayIssueCommand(this.principal, frame.command))
      return [this.control("error", { code: "command_not_permitted", message: "Command is not available" }, frame.requestId)];
    const rid = frame.requestId;
    let stream = frame.payload.stream;
    // `me` names the caller's own user stream. Any other user id must be the caller's.
    if (isStreamRef(stream) && stream.kind === "user") {
      if (stream.id === "me") stream = { kind: "user", id: this.principal.id };
      else if (stream.id !== this.principal.id) return [this.control("subscription.denied", { reason: "stream_not_permitted", stream }, rid, stream)];
    }
    switch (frame.command) {
      case "session.ping":
        return [this.control("session.pong", {}, rid)];
      case "subscription.subscribe": {
        if (!isStreamRef(stream) || !this.deps.supports(stream))
          return [this.control("subscription.denied", { reason: "stream_not_supported", stream }, rid)];
        const result = await this.deps.registry.subscribe(this.connectionId, this.principal, stream, this.deps.authorize, () => this.deps.head(stream));
        if (result.ok === false) return [this.control("subscription.denied", { reason: result.reason, stream }, rid, stream)];
        const cursor = frame.payload.cursor;
        if (cursor === undefined || !this.deps.replay)
          return [this.control("subscription.ready", { stream, headSequence: result.headSequence }, rid, stream)];
        // A cursor says "I applied everything up to here": resume from it when
        // the events in between are still kept and contiguous, else snapshot.
        const head = result.headSequence;
        const snapshot = (reason: string) => [
          this.control("subscription.ready", { stream, headSequence: head, resumed: false }, rid, stream),
          this.control("sync.required", { stream, reason }, rid, stream),
        ];
        if (typeof cursor !== "number" || !Number.isSafeInteger(cursor) || cursor < 0) return snapshot("cursor_invalid");
        if (cursor > head) return snapshot("cursor_ahead");
        const missed = cursor === head || head - cursor > MAX_REPLAY_EVENTS ? [] : await this.deps.replay(stream, cursor, head);
        const gapless = this.deps.gapless?.(stream) ?? true;
        const ordered = (events: MessagingEnvelope[]) =>
          events.every((e, i) => (e.sequence ?? 0) > cursor && (e.sequence ?? 0) <= head && (i === 0 || (e.sequence ?? 0) > (events[i - 1]!.sequence ?? 0)));
        if (cursor < head && head - cursor > MAX_REPLAY_EVENTS) return snapshot("cursor_too_old");
        if (cursor < head && (missed === null || !ordered(missed) || (gapless && (missed.length !== head - cursor || missed.some((e, i) => e.sequence !== cursor + 1 + i)))))
          return snapshot("replay_unavailable");
        this.deps.registry.resumeAt(this.connectionId, stream, cursor);
        const buffered = this.deps.registry.completeBootstrap(this.connectionId, stream, head);
        return [this.control("subscription.ready", { stream, headSequence: head, resumed: true }, rid, stream), ...missed!, ...buffered];
      }
      case "subscription.snapshot_applied": {
        const seq = frame.payload.snapshotSequence;
        if (!isStreamRef(stream) || typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < 0)
          return [this.control("error", { code: "invalid_frame", message: "stream and snapshotSequence are required" }, rid)];
        return this.deps.registry.completeBootstrap(this.connectionId, stream, seq);
      }
      case "subscription.unsubscribe":
        if (!isStreamRef(stream)) return [this.control("error", { code: "invalid_frame", message: "stream is required" }, rid)];
        this.deps.registry.unsubscribe(this.connectionId, stream);
        return [this.control("subscription.ended", { stream }, rid, stream)];
      case "event.ack": {
        const seq = frame.payload.sequence;
        if (!isStreamRef(stream) || typeof seq !== "number")
          return [this.control("error", { code: "invalid_frame", message: "stream and sequence are required" }, rid)];
        const ok = this.deps.registry.ack(this.connectionId, stream, seq);
        return ok ? [] : [this.control("sync.required", { stream, reason: "ack_out_of_range" }, rid, stream)];
      }
      default:
        return [this.control("error", { code: "unknown_command", message: "Unknown command" }, rid)];
    }
  }
}
