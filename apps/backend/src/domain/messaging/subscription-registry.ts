import type { MessagingEnvelope, StreamRef } from "./envelope.js";
import { mayUseStream, type Principal } from "./principal.js";

export const streamKey = (s: StreamRef): string => `${s.kind}:${s.id}`;

export type SubscribeResult =
  | { ok: true; stream: StreamRef; headSequence: number }
  | { ok: false; reason: "stream_not_permitted" | "access_denied" };

interface Subscription {
  readonly principal: Principal;
  readonly stream: StreamRef;
  /** Until the snapshot is applied, newer events are held, not delivered. */
  buffering: boolean;
  buffer: MessagingEnvelope[];
  /** Last durable event handed to the connection; NOT an acknowledgement. */
  lastEnqueued: number;
  /** Last contiguous durable event the client says it applied. */
  lastAcked: number;
}

export interface Delivery { readonly connectionId: string; readonly envelope: MessagingEnvelope }

/**
 * Who is listening to which stream (ADR-038 layer 2). Pure state: no sockets, no
 * Durable Objects. Access is authorized once, on subscribe; revoking it
 * removes the subscriptions at once and tells the caller whom to notify.
 */
export class SubscriptionRegistry {
  private readonly byStream = new Map<string, Map<string, Subscription>>();
  private readonly byConnection = new Map<string, Map<string, Subscription>>();

  /**
   * Subscribes and returns the stream's head watermark. The subscription
   * buffers newer events until `completeBootstrap`, so a snapshot taken after
   * this call cannot miss an event: snapshot, then apply buffered events above it.
   */
  async subscribe(
    connectionId: string,
    principal: Principal,
    stream: StreamRef,
    authorize: (principal: Principal, stream: StreamRef) => Promise<boolean>,
    headSequence: () => Promise<number>,
  ): Promise<SubscribeResult> {
    if (!mayUseStream(principal, stream)) return { ok: false, reason: "stream_not_permitted" };
    if (!(await authorize(principal, stream))) return { ok: false, reason: "access_denied" };
    const head = await headSequence();
    const sub: Subscription = { principal, stream, buffering: true, buffer: [], lastEnqueued: head, lastAcked: 0 };
    const key = streamKey(stream);
    if (!this.byStream.has(key)) this.byStream.set(key, new Map());
    this.byStream.get(key)!.set(connectionId, sub);
    if (!this.byConnection.has(connectionId)) this.byConnection.set(connectionId, new Map());
    this.byConnection.get(connectionId)!.set(key, sub);
    return { ok: true, stream, headSequence: head };
  }

  /** Re-creates a subscription after a hibernation; access was checked when it was first made. */
  restore(connectionId: string, principal: Principal, stream: StreamRef): void {
    const sub: Subscription = { principal, stream, buffering: false, buffer: [], lastEnqueued: 0, lastAcked: 0 };
    const key = streamKey(stream);
    if (!this.byStream.has(key)) this.byStream.set(key, new Map());
    this.byStream.get(key)!.set(connectionId, sub);
    if (!this.byConnection.has(connectionId)) this.byConnection.set(connectionId, new Map());
    this.byConnection.get(connectionId)!.set(key, sub);
  }

  streamsOf(connectionId: string): StreamRef[] {
    return [...(this.byConnection.get(connectionId)?.values() ?? [])].map((s) => s.stream);
  }

  subscribersOf(stream: StreamRef): Array<{ connectionId: string; principal: Principal }> {
    return [...(this.byStream.get(streamKey(stream)) ?? [])].map(([connectionId, sub]) => ({ connectionId, principal: sub.principal }));
  }

  /** Ends buffering. Returns the buffered events above the snapshot, in order, without gaps or repeats. */
  completeBootstrap(connectionId: string, stream: StreamRef, snapshotSequence: number): MessagingEnvelope[] {
    const sub = this.byConnection.get(connectionId)?.get(streamKey(stream));
    if (!sub) return [];
    sub.buffering = false;
    const seen = new Set<number>();
    const out = sub.buffer
      .filter((e) => (e.sequence ?? 0) > snapshotSequence)
      .sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))
      .filter((e) => (seen.has(e.sequence!) ? false : (seen.add(e.sequence!), true)));
    sub.buffer = [];
    for (const e of out) sub.lastEnqueued = Math.max(sub.lastEnqueued, e.sequence ?? 0);
    return out;
  }

  /** Subscribers that should receive [envelope] now (buffering ones keep it for later). */
  publish(envelope: MessagingEnvelope): Delivery[] {
    const subs = this.byStream.get(streamKey(envelope.stream));
    if (!subs) return [];
    const out: Delivery[] = [];
    for (const [connectionId, sub] of subs) {
      if (sub.buffering) { sub.buffer.push(envelope); continue; }
      if (envelope.sequence !== undefined) {
        if (envelope.sequence <= sub.lastEnqueued) continue; // duplicate
        sub.lastEnqueued = envelope.sequence;
      }
      out.push({ connectionId, envelope });
    }
    return out;
  }

  /** The client applied events up to [sequence]; only a contiguous advance counts. */
  ack(connectionId: string, stream: StreamRef, sequence: number): boolean {
    const sub = this.byConnection.get(connectionId)?.get(streamKey(stream));
    if (!sub || sequence > sub.lastEnqueued || sequence < sub.lastAcked) return false;
    sub.lastAcked = sequence;
    return true;
  }

  /** A resumed subscription starts acknowledged at the client's cursor. */
  resumeAt(connectionId: string, stream: StreamRef, cursor: number): void {
    const sub = this.byConnection.get(connectionId)?.get(streamKey(stream));
    if (sub) sub.lastAcked = cursor;
  }

  lastAcked(connectionId: string, stream: StreamRef): number | null {
    return this.byConnection.get(connectionId)?.get(streamKey(stream))?.lastAcked ?? null;
  }

  unsubscribe(connectionId: string, stream: StreamRef): boolean {
    const key = streamKey(stream);
    const had = this.byConnection.get(connectionId)?.delete(key) ?? false;
    this.byStream.get(key)?.delete(connectionId);
    return had;
  }

  closeConnection(connectionId: string): void {
    for (const sub of [...(this.byConnection.get(connectionId)?.values() ?? [])]) this.unsubscribe(connectionId, sub.stream);
    this.byConnection.delete(connectionId);
  }

  /**
   * Access was revoked. Drops every subscription the [matches] predicate
   * selects, immediately, and returns who to tell (`subscription.denied`).
   */
  revoke(matches: (principal: Principal, stream: StreamRef) => boolean): Array<{ connectionId: string; stream: StreamRef }> {
    const removed: Array<{ connectionId: string; stream: StreamRef }> = [];
    for (const [connectionId, subs] of this.byConnection)
      for (const sub of [...subs.values()])
        if (matches(sub.principal, sub.stream)) {
          this.unsubscribe(connectionId, sub.stream);
          removed.push({ connectionId, stream: sub.stream });
        }
    return removed;
  }

  count(): number {
    let n = 0;
    for (const subs of this.byConnection.values()) n += subs.size;
    return n;
  }
}
