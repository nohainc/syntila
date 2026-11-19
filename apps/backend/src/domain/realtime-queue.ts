export interface RealtimeQueueItem {
  readonly frame: string;
  readonly durable: boolean;
  readonly coalesceKey?: string;
}

export type RealtimeQueueEnqueueResult =
  "queued" | "coalesced" | "dropped" | "resync-required";

/** Default bounds of one socket's queue (ADR-033 decision 9). */
export const DEFAULT_QUEUE_MAX_ITEMS = 128;
export const DEFAULT_QUEUE_MAX_BYTES = 1024 * 1024;

interface Entry {
  readonly item: RealtimeQueueItem;
  readonly size: number;
}

/**
 * A per-connection queue bounded in items and in bytes, so a slow client can
 * hold neither many frames nor a few huge ones in memory. Ephemeral frames may
 * be coalesced, replaced or dropped; durable frames never silently disappear:
 * when the queue cannot retain one it answers "resync-required" and the caller
 * tells the client to synchronize.
 */
export class BoundedRealtimeQueue {
  private readonly entries: Entry[] = [];
  private bytes = 0;

  constructor(
    readonly maxDepth = DEFAULT_QUEUE_MAX_ITEMS,
    readonly maxBytes = DEFAULT_QUEUE_MAX_BYTES,
  ) {}

  get depth(): number {
    return this.entries.length;
  }

  /** UTF-8 bytes of the frames currently held. */
  get byteSize(): number {
    return this.bytes;
  }

  enqueue(item: RealtimeQueueItem): RealtimeQueueEnqueueResult {
    const size = Buffer.byteLength(item.frame);
    if (item.coalesceKey) {
      const existing = this.entries.findIndex(
        (candidate) => candidate.item.coalesceKey === item.coalesceKey,
      );
      if (existing >= 0) {
        const old = this.entries[existing]!;
        if (this.bytes - old.size + size > this.maxBytes) {
          // The newer frame no longer fits: the stale one goes, the new one is dropped.
          this.remove(existing);
          return "dropped";
        }
        this.bytes += size - old.size;
        this.entries[existing] = { item, size };
        return "coalesced";
      }
    }
    while (
      this.entries.length >= this.maxDepth ||
      this.bytes + size > this.maxBytes
    ) {
      if (!item.durable) return "dropped";
      const ephemeralIndex = this.entries.findIndex(
        (candidate) => !candidate.item.durable,
      );
      if (ephemeralIndex < 0) return "resync-required";
      this.remove(ephemeralIndex);
    }
    this.entries.push({ item, size });
    this.bytes += size;
    return "queued";
  }

  take(): RealtimeQueueItem | undefined {
    const entry = this.entries.shift();
    if (!entry) return undefined;
    this.bytes -= entry.size;
    return entry.item;
  }

  drain(): RealtimeQueueItem[] {
    const items = this.entries.splice(0, this.entries.length).map((entry) => entry.item);
    this.bytes = 0;
    return items;
  }

  clear(): void {
    this.entries.splice(0, this.entries.length);
    this.bytes = 0;
  }

  private remove(index: number): void {
    const [entry] = this.entries.splice(index, 1);
    if (entry) this.bytes -= entry.size;
  }
}
