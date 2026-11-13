/**
 * PostgreSQL-backed replacement for Cloudflare Workflows, implementing the
 * subset `SyntilaRunWorkflow` uses: `create`, `get` → `status`, `sendEvent`,
 * `terminate`; inside `run`: `step.do` (memoised, retried), `step.sleep`,
 * `step.sleepUntil` and `step.waitForEvent` (events sent before the wait are
 * buffered).
 *
 * Execution model (same as Workflows): `run()` is replayed from the start
 * whenever an instance resumes; completed steps return their stored result,
 * so only new work executes. A step that was in progress when the process
 * died runs again (at-least-once). Instances are claimed with a lease, so a
 * crashed process's instances are picked up again after the lease expires.
 */
type Sql = { unsafe(text: string, params?: unknown[]): Promise<any> };

export interface StepConfig { retries?: { limit: number; delay: string | number; backoff?: "constant" | "linear" | "exponential" }; timeout?: string | number }
interface WorkflowLike { run(event: { payload: unknown; timestamp: Date; instanceId: string }, step: unknown): Promise<unknown> }

const DEFAULT_RETRIES = { limit: 5, delay: 10_000, backoff: "exponential" as const };
// Renewed every LEASE_MS/3 while running: a crashed process's instances are
// resumed by another process within about LEASE_MS.
const LEASE_MS = 30_000;
const POLL_MS = 1_000;

/** Thrown inside `run` to park the instance until an event or a deadline. */
class Suspend { constructor(readonly wakeAt: Date | null, readonly eventType: string | null) {} }
class WaitTimeout extends Error { constructor(name: string) { super(`waitForEvent "${name}" timed out`); this.name = "WorkflowTimeoutError"; } }

export function durationMs(value: string | number): number {
  if (typeof value === "number") return value;
  const m = value.trim().match(/^(\d+(?:\.\d+)?)\s*(ms|milliseconds?|s|secs?|seconds?|m|mins?|minutes?|h|hours?|d|days?|w|weeks?)?$/i);
  if (!m) throw new Error(`Invalid duration: ${value}`);
  const n = Number(m[1]), unit = (m[2] ?? "ms").toLowerCase();
  const factor = unit.startsWith("ms") || unit.startsWith("milli") ? 1 : unit.startsWith("s") ? 1000 : unit === "m" || unit.startsWith("min") ? 60_000
    : unit.startsWith("h") ? 3_600_000 : unit.startsWith("d") ? 86_400_000 : 604_800_000;
  return n * factor;
}

export class WorkflowHost {
  private timer: Timer | null = null;
  private running = new Set<string>();
  private kick: Promise<void> | null = null;
  private stopped = false;
  readonly owner = `${process.pid}-${crypto.randomUUID().slice(0, 8)}`;

  constructor(
    readonly name: string,
    private sql: Sql,
    private create: (env: unknown) => WorkflowLike,
    private env: () => unknown,
    private options: { concurrency?: number } = {},
  ) {}

  /* ---------------------------------------------------- binding API */

  async createInstance(input: { id?: string; params?: unknown } = {}) {
    const id = input.id ?? crypto.randomUUID();
    const rows = await this.sql.unsafe(
      `INSERT INTO workflow_instances(id, workflow, params, status) VALUES ($1, $2, $3::text::jsonb, 'queued')
       ON CONFLICT (id) DO NOTHING RETURNING id`, [id, this.name, JSON.stringify(input.params ?? null)]);
    if (rows.length === 0) throw new Error(`Workflow instance ${id} already exists`);
    this.poke();
    return this.handle(id);
  }

  async getInstance(id: string) {
    const rows = await this.sql.unsafe("SELECT 1 FROM workflow_instances WHERE id = $1 AND workflow = $2", [id, this.name]);
    if (!rows.length) throw new Error(`Workflow instance ${id} not found`);
    return this.handle(id);
  }

  binding() {
    return {
      create: (input?: { id?: string; params?: unknown }) => this.createInstance(input),
      get: (id: string) => this.getInstance(id),
    };
  }

  private handle(id: string) {
    return {
      id,
      status: async () => {
        const [r] = await this.sql.unsafe("SELECT status, output, error FROM workflow_instances WHERE id = $1", [id]);
        return { status: r?.status ?? "unknown", output: r?.output ?? undefined, error: r?.error ?? undefined };
      },
      sendEvent: async (event: { type: string; payload?: unknown }) => {
        await this.sql.unsafe("INSERT INTO workflow_events(instance_id, type, payload) VALUES ($1, $2, $3::text::jsonb)",
          [id, event.type, JSON.stringify(event.payload ?? null)]);
        // Wake the instance if it is parked on this event type.
        await this.sql.unsafe(`UPDATE workflow_instances SET wake_at = now(), updated_at = now()
          WHERE id = $1 AND status = 'waiting' AND waiting_event_type = $2`, [id, event.type]);
        this.poke();
      },
      terminate: async () => {
        await this.sql.unsafe(`UPDATE workflow_instances SET status = 'terminated', wake_at = NULL, lease_owner = NULL, updated_at = now()
          WHERE id = $1 AND status NOT IN ('complete', 'errored', 'terminated')`, [id]);
      },
      pause: async () => { throw new Error("pause is not supported"); },
      resume: async () => { this.poke(); },
      restart: async () => { throw new Error("restart is not supported"); },
    };
  }

  /* -------------------------------------------------------- runner */

  start() {
    this.stopped = false;
    this.timer = setInterval(() => this.poke(), POLL_MS);
    this.poke();
  }

  async stop(timeoutMs = 10_000) {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    const until = Date.now() + timeoutMs;
    while (this.running.size && Date.now() < until) await Bun.sleep(50);
    // Instances still running (e.g. awaiting a long step) are handed back now
    // instead of after the lease: completed steps are memoised, so the next
    // process replays them without repeating side effects.
    if (this.running.size)
      await this.sql.unsafe(`UPDATE workflow_instances SET status = 'queued', lease_owner = NULL, lease_until = NULL, updated_at = now()
        WHERE lease_owner = $1 AND status = 'running'`, [this.owner]).catch(() => {});
  }

  poke() {
    if (this.stopped || this.kick) return;
    this.kick = this.claimAndRun().catch((e) => console.error(JSON.stringify({ level: "error", message: "workflow.poll_failed", error: String(e?.stack ?? e) })))
      .finally(() => { this.kick = null; });
  }

  private async claimAndRun() {
    const free = (this.options.concurrency ?? 32) - this.running.size;
    if (free <= 0) return;
    const claimed: { id: string; params: unknown; created_at: Date }[] = await this.sql.unsafe(
      `UPDATE workflow_instances SET status = 'running', lease_owner = $1, lease_until = now() + make_interval(secs => $2), updated_at = now()
       WHERE id IN (
         SELECT id FROM workflow_instances
          WHERE workflow = $3 AND (
            status = 'queued'
            OR (status = 'waiting' AND wake_at IS NOT NULL AND wake_at <= now())
            OR (status = 'running' AND lease_until < now()))
          ORDER BY created_at LIMIT $4 FOR UPDATE SKIP LOCKED)
       RETURNING id, params, created_at`, [this.owner, LEASE_MS / 1000, this.name, free]);
    for (const row of claimed) {
      this.running.add(row.id);
      void this.execute(row).finally(() => { this.running.delete(row.id); this.poke(); });
    }
  }

  private async execute(row: { id: string; params: unknown; created_at: Date }) {
    const id = row.id;
    const renew = setInterval(() => void this.sql.unsafe(
      "UPDATE workflow_instances SET lease_until = now() + make_interval(secs => $1) WHERE id = $2 AND lease_owner = $3",
      [LEASE_MS / 1000, id, this.owner]).catch(() => {}), LEASE_MS / 3);
    try {
      const workflow = this.create(this.env());
      // A wait parks the instance through `parked`; the step's own promise never
      // settles, so a user try/catch around a wait cannot observe suspension.
      let park!: (s: Suspend) => void;
      const parked = new Promise<Suspend>((resolve) => { park = resolve; });
      const outcome = await Promise.race([
        workflow.run({ payload: row.params, timestamp: new Date(row.created_at), instanceId: id }, this.stepApi(id, park)).then((output) => ({ output })),
        parked,
      ]);
      if (outcome instanceof Suspend) throw outcome;
      const { output } = outcome;
      await this.finish(id, "complete", { output });
    } catch (e) {
      if (e instanceof Suspend) {
        await this.sql.unsafe(`UPDATE workflow_instances SET status = 'waiting', wake_at = $1, waiting_event_type = $2, lease_owner = NULL, lease_until = NULL, updated_at = now()
          WHERE id = $3 AND lease_owner = $4 AND status = 'running'`, [e.wakeAt?.toISOString() ?? null, e.eventType, id, this.owner]);
        // An event may have arrived between the inbox check and parking.
        if (e.eventType) await this.sql.unsafe(`UPDATE workflow_instances SET wake_at = now() WHERE id = $1 AND status = 'waiting'
          AND EXISTS (SELECT 1 FROM workflow_events WHERE instance_id = $1 AND type = $2 AND consumed_by IS NULL)`, [id, e.eventType]);
      } else if (e instanceof Terminated) {
        // Terminated while running: leave the terminal status as set by terminate().
      } else {
        console.error(JSON.stringify({ level: "error", message: "workflow.instance_errored", workflow: this.name, id, error: String((e as Error)?.stack ?? e) }));
        await this.finish(id, "errored", { error: (e as Error)?.message ?? String(e) });
      }
    } finally {
      clearInterval(renew);
    }
  }

  private async finish(id: string, status: "complete" | "errored", r: { output?: unknown; error?: string }) {
    await this.sql.unsafe(`UPDATE workflow_instances SET status = $1, output = $2::text::jsonb, error = $3, wake_at = NULL, lease_owner = NULL, lease_until = NULL, updated_at = now()
      WHERE id = $4 AND lease_owner = $5 AND status = 'running'`, [status, r.output === undefined ? null : JSON.stringify(r.output), r.error ?? null, id, this.owner]);
  }

  private async stepRecord(id: string, name: string): Promise<{ result: unknown; outcome: string } | null> {
    const [r] = await this.sql.unsafe("SELECT result, outcome FROM workflow_steps WHERE instance_id = $1 AND name = $2", [id, name]);
    return r ? { result: r.result, outcome: r.outcome } : null;
  }

  private async saveStep(id: string, name: string, outcome: "done" | "timeout" | "failed", result: unknown) {
    // Only the lease holder may record progress; otherwise the instance moved on.
    const rows = await this.sql.unsafe(`INSERT INTO workflow_steps(instance_id, name, outcome, result)
      SELECT $1, $2, $3, $4::text::jsonb WHERE EXISTS (SELECT 1 FROM workflow_instances WHERE id = $1 AND lease_owner = $5 AND status = 'running')
      ON CONFLICT (instance_id, name) DO NOTHING RETURNING 1`, [id, name, outcome, result === undefined ? null : JSON.stringify({ v: result }), this.owner]);
    if (!rows.length) {
      const [s] = await this.sql.unsafe("SELECT status FROM workflow_instances WHERE id = $1", [id]);
      if (s?.status === "terminated") throw new Terminated();
    }
  }

  private stepApi(id: string, park: (s: Suspend) => void) {
    const suspend = (s: Suspend): Promise<never> => { park(s); return new Promise<never>(() => {}); };
    const unwrap = (r: unknown) => (r && typeof r === "object" && "v" in (r as object) ? (r as { v: unknown }).v : undefined);
    const host = this;
    return {
      async do<T>(name: string, configOrFn: StepConfig | (() => Promise<T>), maybeFn?: () => Promise<T>): Promise<T> {
        const fn = (typeof configOrFn === "function" ? configOrFn : maybeFn)!;
        const config = typeof configOrFn === "function" ? {} : configOrFn;
        const prior = await host.stepRecord(id, name);
        if (prior?.outcome === "done") return unwrap(prior.result) as T;
        if (prior?.outcome === "failed") throw new Error((unwrap(prior.result) as string) ?? `Step "${name}" failed`);
        const retries = { ...DEFAULT_RETRIES, ...(config.retries ?? {}) };
        const timeout = config.timeout === undefined ? null : durationMs(config.timeout);
        for (let attempt = 0; ; attempt++) {
          try {
            const value = timeout === null ? await fn()
              : await Promise.race([fn(), Bun.sleep(timeout).then(() => { throw new Error(`Step "${name}" timed out`); })]);
            await host.saveStep(id, name, "done", value);
            return value as T;
          } catch (e) {
            if (e instanceof Terminated) throw e;
            if (attempt >= retries.limit) {
              await host.saveStep(id, name, "failed", (e as Error)?.message ?? String(e));
              throw e;
            }
            const base = durationMs(retries.delay);
            const wait = retries.backoff === "exponential" ? base * 2 ** attempt : retries.backoff === "linear" ? base * (attempt + 1) : base;
            await Bun.sleep(Math.min(wait, 10 * 60_000));
          }
        }
      },
      async sleep(name: string, duration: string | number) {
        return this.sleepUntil(name, Date.now() + durationMs(duration));
      },
      async sleepUntil(name: string, when: Date | number) {
        const prior = await host.stepRecord(id, name);
        if (prior) return;
        const at = typeof when === "number" ? when : when.getTime();
        // The deadline is stored as the step's pending marker so replays agree on it.
        const marker = await host.pending(id, name, at);
        if (Date.now() >= marker) { await host.saveStep(id, name, "done", null); return; }
        return suspend(new Suspend(new Date(marker), null));
      },
      async waitForEvent<T>(name: string, options: { type: string; timeout?: string | number }) {
        const prior = await host.stepRecord(id, name);
        if (prior?.outcome === "done") return unwrap(prior.result) as { payload: T; timestamp: Date; type: string };
        if (prior?.outcome === "timeout") throw new WaitTimeout(name);
        const [event] = await host.sql.unsafe(`UPDATE workflow_events SET consumed_by = $3 WHERE id = (
            SELECT id FROM workflow_events WHERE instance_id = $1 AND type = $2 AND consumed_by IS NULL ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
          RETURNING payload, created_at, type`, [id, options.type, name]);
        if (event) {
          const value = { payload: event.payload as T, timestamp: new Date(event.created_at), type: event.type as string };
          await host.saveStep(id, name, "done", value);
          return value;
        }
        const deadline = await host.pending(id, name, Date.now() + durationMs(options.timeout ?? "24 hours"));
        if (Date.now() >= deadline) {
          await host.saveStep(id, name, "timeout", null);
          throw new WaitTimeout(name);
        }
        return suspend(new Suspend(new Date(deadline), options.type));
      },
    };
  }

  /** First-seen deadline for a waiting step, kept stable across replays. */
  private async pending(id: string, name: string, at: number): Promise<number> {
    const [r] = await this.sql.unsafe(`INSERT INTO workflow_pending(instance_id, name, deadline) VALUES ($1, $2, $3)
      ON CONFLICT (instance_id, name) DO UPDATE SET deadline = workflow_pending.deadline RETURNING deadline`, [id, name, new Date(at).toISOString()]);
    return new Date(r.deadline).getTime();
  }
}

class Terminated extends Error { constructor() { super("Workflow instance was terminated"); } }
