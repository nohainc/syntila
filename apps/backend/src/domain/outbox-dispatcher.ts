import {
  CloudEventPublisher,
  type EventPublisherEnv,
  type OutboxSweepResult,
} from "./event-publisher.js";
import { expireLapsedSessions } from "./worker-agents.js";
import { expireArtifacts } from "./artifacts.js";

/**
 * Delivers what the committing process did not (ADR-033 decision 8).
 *
 * The process that commits an event delivers it inline, right after the
 * commit. This dispatcher is the safety net behind that fast path:
 *  - a process killed between commit and send leaves a pending outbox row; the
 *    next dispatcher claims it (`FOR UPDATE SKIP LOCKED`, 30 s lease) and wakes
 *    the local gateway;
 *  - a failed delivery is retried with backoff, then marked dead (clients
 *    recover through replay or `sync.required`);
 *  - a periodic sweep repairs events without an outbox row, reports sequence
 *    gaps and expires old Worker commands.
 *
 * On one server it wakes the local gateway directly. Waking gateways on other
 * servers is ADR-039 and does not change this contract.
 */
export class OutboxDispatcher {
  private poll: ReturnType<typeof setInterval> | null = null;
  private sweepTimer: ReturnType<typeof setInterval> | null = null;
  private running: Promise<void> | null = null;
  private sweeping: Promise<unknown> | null = null;
  private stopped = false;
  readonly metrics = { delivered: 0, sweeps: 0, repaired: 0, gaps: 0, expiredCommands: 0 };

  constructor(
    private readonly env: EventPublisherEnv,
    private readonly options: { pollMs?: number; sweepMs?: number; batch?: number } = {},
  ) {}

  start(): void {
    this.stopped = false;
    this.poll ??= setInterval(() => this.poke(), this.options.pollMs ?? 1_000);
    this.sweepTimer ??= setInterval(() => {
      this.sweeping = this.sweep();
    }, this.options.sweepMs ?? 5 * 60_000);
    // Do not keep the process alive for the timers alone.
    (this.poll as { unref?: () => void }).unref?.();
    (this.sweepTimer as { unref?: () => void }).unref?.();
    this.poke();
    this.sweeping = this.sweep();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.poll) clearInterval(this.poll);
    if (this.sweepTimer) clearInterval(this.sweepTimer);
    this.poll = this.sweepTimer = null;
    await this.running;
    await this.sweeping;
  }

  /** Starts a delivery pass unless one is already running. */
  poke(): void {
    if (this.stopped) return;
    this.running ??= this.deliverDue()
      .then(() => undefined)
      .catch((error) => log("error", "outbox.dispatch_failed", { error: String((error as Error)?.stack ?? error) }))
      .finally(() => {
        this.running = null;
      });
  }

  /** Delivers every due row, oldest first; returns how many it handled. */
  async deliverDue(): Promise<number> {
    const publisher = new CloudEventPublisher(this.env);
    const batch = this.options.batch ?? 100;
    let total = 0;
    for (;;) {
      const handled = await publisher.deliverDueOutbox(batch);
      total += handled;
      this.metrics.delivered += handled;
      if (handled < batch || this.stopped) return total;
    }
  }

  /** One sweep: repair, gap report, command expiry. Never throws. */
  async sweep(): Promise<OutboxSweepResult | null> {
    try {
      // Worker Agent sessions whose lease lapsed must connect again (new epoch).
      const lapsed = await expireLapsedSessions(this.env as never);
      if (lapsed > 0) log("warn", "worker.sessions_expired", { sessions: lapsed });
    } catch (error) {
      log("error", "worker.session_expiry_failed", { error: String((error as Error)?.stack ?? error) });
    }
    try {
      const expired = await expireArtifacts(this.env as never);
      if (expired > 0) log("warn", "artifacts.expired", { artifacts: expired });
    } catch (error) {
      log("error", "artifacts.expiry_failed", { error: String((error as Error)?.stack ?? error) });
    }
    try {
      const result = await new CloudEventPublisher(this.env).sweepOutbox();
      this.metrics.sweeps += 1;
      this.metrics.repaired += result.repaired;
      this.metrics.gaps += result.gaps.length;
      this.metrics.expiredCommands += result.expiredCommands;
      if (result.repaired > 0) log("warn", "outbox.repaired", { rows: result.repaired });
      if (result.gaps.length > 0) log("error", "outbox.sequence_gap", { gaps: result.gaps.slice(0, 10) });
      if (result.repaired > 0) this.poke();
      return result;
    } catch (error) {
      log("error", "outbox.sweep_failed", { error: String((error as Error)?.stack ?? error) });
      return null;
    }
  }
}

function log(level: "warn" | "error", message: string, details: Record<string, unknown>): void {
  (level === "error" ? console.error : console.warn)(JSON.stringify({ level, message, ...details }));
}
