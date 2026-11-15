/**
 * What PostgreSQL itself says about contention (claude/concurrency-plan.md,
 * Phase 3). Sampled every five minutes into one `db.health` log line; these
 * numbers replace `db.writer_lock` once the global writer lock is gone.
 *
 *  - lockWaiting / lockWaitMaxMs: backends of this database waiting for a
 *    lock right now, and how long the longest has waited;
 *  - idleInTransaction / oldestTransactionMs: open transactions doing
 *    nothing (a leak) and the age of the oldest transaction;
 *  - deadlocks / conflicts: increase since the previous sample;
 *  - connections: by state;
 *  - topStatements: by total time since the previous sample, when the
 *    pg_stat_statements extension is installed.
 */
import type { SQL } from "bun";

type Sql = InstanceType<typeof SQL>;

export interface DbHealth {
  lockWaiting: number;
  lockWaitMaxMs: number;
  idleInTransaction: number;
  oldestTransactionMs: number;
  deadlocks: number;
  conflicts: number;
  connections: Record<string, number>;
  topStatements?: { query: string; calls: number; totalMs: number; meanMs: number }[];
}

let previous: { deadlocks: number; conflicts: number } | null = null;
let previousStatements = new Map<string, { calls: number; totalMs: number }>();

export async function sampleDbHealth(sql: Sql): Promise<DbHealth> {
  const [activity] = await sql`
    SELECT count(*) FILTER (WHERE wait_event_type = 'Lock')::int AS "lockWaiting",
           COALESCE(max(EXTRACT(EPOCH FROM now() - state_change) * 1000)
             FILTER (WHERE wait_event_type = 'Lock'), 0)::int AS "lockWaitMaxMs",
           count(*) FILTER (WHERE state = 'idle in transaction')::int AS "idleInTransaction",
           COALESCE(max(EXTRACT(EPOCH FROM now() - xact_start) * 1000), 0)::int AS "oldestTransactionMs",
           COALESCE(jsonb_object_agg(state, n) FILTER (WHERE state IS NOT NULL), '{}') AS connections
      FROM (SELECT wait_event_type, state, state_change, xact_start,
                   count(*) OVER (PARTITION BY state) AS n
              FROM pg_stat_activity
             WHERE datname = current_database() AND pid <> pg_backend_pid()) a`;
  const [db] = await sql`
    SELECT deadlocks::int8 AS deadlocks, conflicts::int8 AS conflicts
      FROM pg_stat_database WHERE datname = current_database()`;
  const now = { deadlocks: Number(db?.deadlocks ?? 0), conflicts: Number(db?.conflicts ?? 0) };
  const health: DbHealth = {
    lockWaiting: Number(activity?.lockWaiting ?? 0),
    lockWaitMaxMs: Number(activity?.lockWaitMaxMs ?? 0),
    idleInTransaction: Number(activity?.idleInTransaction ?? 0),
    oldestTransactionMs: Number(activity?.oldestTransactionMs ?? 0),
    deadlocks: previous ? now.deadlocks - previous.deadlocks : 0,
    conflicts: previous ? now.conflicts - previous.conflicts : 0,
    connections: Object.fromEntries(Object.entries(activity?.connections ?? {}).map(([k, v]) => [k, Number(v)])),
  };
  previous = now;
  const statements = await topStatements(sql);
  if (statements) health.topStatements = statements;
  return health;
}

async function topStatements(sql: Sql) {
  try {
    const [installed] = await sql`SELECT 1 AS ok FROM pg_extension WHERE extname = 'pg_stat_statements'`;
    if (!installed) return undefined;
    const rows: { queryid: string; query: string; calls: number | bigint; total: number }[] = await sql`
      SELECT queryid::text AS queryid, left(query, 160) AS query, calls, total_exec_time AS total
        FROM pg_stat_statements
       WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
       ORDER BY total_exec_time DESC LIMIT 200`;
    const next = new Map<string, { calls: number; totalMs: number }>();
    const deltas = rows.map((r) => {
      const calls = Number(r.calls), totalMs = Number(r.total);
      next.set(r.queryid, { calls, totalMs });
      const before = previousStatements.get(r.queryid);
      return { query: r.query, calls: calls - (before?.calls ?? 0), totalMs: totalMs - (before?.totalMs ?? 0) };
    });
    const first = previousStatements.size === 0;
    previousStatements = next;
    if (first) return undefined; // the first sample only sets the baseline
    return deltas.filter((d) => d.calls > 0).sort((a, b) => b.totalMs - a.totalMs).slice(0, 8)
      .map((d) => ({ ...d, totalMs: Math.round(d.totalMs), meanMs: Math.round((d.totalMs / d.calls) * 10) / 10 }));
  } catch {
    return undefined; // no permission or extension not loaded: not an error
  }
}
