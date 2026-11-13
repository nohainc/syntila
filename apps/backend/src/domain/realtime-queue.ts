export interface RealtimeQueueItem {
  readonly frame: string;
  readonly durable: boolean;
  readonly coalesceKey?: string;
}

export type RealtimeQueueEnqueueResult =
  "queued" | "coalesced" | "dropped" | "resync-required";

/**
 * A small per-connection queue. Ephemeral frames may be replaced or dropped;
 * durable frames never silently disappear and force cursor resync when the
 * bounded queue cannot retain them.
 */
export class BoundedRealtimeQueue {
  private readonly items: RealtimeQueueItem[] = [];

  constructor(readonly maxDepth = 128) {}

  get depth(): number {
    return this.items.length;
  }

  enqueue(item: RealtimeQueueItem): RealtimeQueueEnqueueResult {
    if (item.coalesceKey) {
      const existing = this.items.findIndex(
        (candidate) => candidate.coalesceKey === item.coalesceKey,
      );
      if (existing >= 0) {
        this.items[existing] = item;
        return "coalesced";
      }
    }
    if (this.items.length >= this.maxDepth) {
      if (!item.durable) return "dropped";
      const ephemeralIndex = this.items.findIndex(
        (candidate) => !candidate.durable,
      );
      if (ephemeralIndex < 0) return "resync-required";
      this.items.splice(ephemeralIndex, 1);
    }
    this.items.push(item);
    return "queued";
  }

  take(): RealtimeQueueItem | undefined {
    return this.items.shift();
  }

  drain(): RealtimeQueueItem[] {
    return this.items.splice(0, this.items.length);
  }

  clear(): void {
    this.items.splice(0, this.items.length);
  }
}
