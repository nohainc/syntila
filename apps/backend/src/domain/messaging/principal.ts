import type { ActorKind, StreamKind, StreamRef } from "./envelope.js";

/**
 * What each kind of principal may do on the shared gateway. The server builds
 * a Principal from the credential (a browser ticket or a Worker key session);
 * nothing in a frame can widen it.
 */
export interface Principal {
  readonly kind: ActorKind;
  /** User id for a human, Worker Instance id for a Worker. */
  readonly id: string;
  readonly actorId?: string;
}

interface Policy {
  readonly streams: readonly StreamKind[];
  readonly commandPrefixes: readonly string[];
  readonly rate: { readonly capacity: number; readonly refillPerSecond: number };
}

export const PRINCIPAL_POLICY: Record<ActorKind, Policy> = {
  human: {
    streams: ["user", "space", "thread"],
    commandPrefixes: ["subscription.", "event.", "session.ping"],
    rate: { capacity: 60, refillPerSecond: 20 },
  },
  worker: {
    streams: ["worker_inbox", "assignment"],
    commandPrefixes: ["session.", "assignment.", "event.", "subscription."],
    rate: { capacity: 200, refillPerSecond: 100 },
  },
  system: { streams: [], commandPrefixes: [], rate: { capacity: 0, refillPerSecond: 0 } },
};

/** Structural check, before any database authorization. */
export function mayUseStream(principal: Principal, stream: StreamRef): boolean {
  if (!PRINCIPAL_POLICY[principal.kind].streams.includes(stream.kind)) return false;
  // A Worker's inbox is its own and nothing else's.
  if (principal.kind === "worker" && stream.kind === "worker_inbox") return stream.id === principal.id;
  if (principal.kind === "human" && stream.kind === "user") return stream.id === principal.id;
  return true;
}

export function mayIssueCommand(principal: Principal, command: string): boolean {
  return PRINCIPAL_POLICY[principal.kind].commandPrefixes.some((p) => command.startsWith(p));
}

/** A per-connection token bucket; each principal kind has its own size and rate. */
export class TokenBucket {
  private tokens: number;
  private last: number;
  constructor(private readonly policy: Policy["rate"], private readonly now: () => number = Date.now) {
    this.tokens = policy.capacity;
    this.last = now();
  }
  take(): boolean {
    const t = this.now();
    this.tokens = Math.min(this.policy.capacity, this.tokens + ((t - this.last) / 1000) * this.policy.refillPerSecond);
    this.last = t;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}

export const bucketFor = (principal: Principal, now?: () => number) => new TokenBucket(PRINCIPAL_POLICY[principal.kind].rate, now);
