/**
 * The backend's data layer on PostgreSQL (claude/concurrency-plan.md, Phase 3).
 *
 * Replaces the D1-compatible adapter (`pg-d1.ts`) module by module. Unlike
 * the adapter it never takes the global writer lock: each business operation
 * is one explicit transaction, and correctness under parallel writes comes
 * from constraints, conditional writes and locks on exactly what the
 * operation touches (see the rules in apps/backend/migrations/README.md).
 *
 *   const data = dataOf(env);
 *   const notes = await data.read.rows<NoteRow>`SELECT … WHERE user_id = ${userId}`;
 *   const note = await data.tx("note.update", async (tx) => {
 *     const row = await tx.row<{ revision: number }>`UPDATE … RETURNING revision`;
 *     tx.afterCommit(() => publish(…));
 *     return row;
 *   });
 *
 * Values:
 *  - Parameters are bound as real PostgreSQL values: booleans are booleans,
 *    and a jsonb parameter takes a JS object or array. A *string* bound to a
 *    jsonb parameter is stored as a JSON string, not as a document: pass the
 *    object, or cast text explicitly (`${text}::text::jsonb`).
 *  - `undefined` is rejected (it is always a bug); use `null`.
 *  - camelCase result names must be quoted (`AS "threadId"`): PostgreSQL
 *    folds unquoted names to lower case. An unquoted one is an error, so the
 *    mistake shows up in the first test instead of as a missing field.
 *  - Rows come back with int8 as number, timestamptz as an ISO-8601 string,
 *    json/jsonb parsed, booleans as booleans.
 *
 * Transactions run READ COMMITTED: every statement sees what committed before
 * it started. Lock what the rule needs first (`tx.lock(...)` or
 * `SELECT … FOR UPDATE`), always in the order account → Space → Thread →
 * Conversation → Work Request → assignment, then read and write. A deadlock
 * or serialization failure retries the whole function, so it must not have
 * effects outside the database: register those with `tx.afterCommit`.
 */
import type { SQL } from "bun";

type Sql = InstanceType<typeof SQL>;
export type Row = Record<string, unknown>;

const RETRYABLE = new Set(["40001", "40P01"]); // serialization_failure, deadlock_detected
const MAX_ATTEMPTS = 5;
const SLOW_TX_MS = Number(process.env.PG_SLOW_TX_MS ?? 250);

/** Read-side queries; also the base of a transaction's query interface. */
export interface Query {
  /** All rows. */
  rows<T = Row>(strings: TemplateStringsArray, ...values: unknown[]): Promise<T[]>;
  /** The first row, or null. */
  row<T = Row>(strings: TemplateStringsArray, ...values: unknown[]): Promise<T | null>;
  /** Runs a statement; returns the number of rows it changed or returned. */
  run(strings: TemplateStringsArray, ...values: unknown[]): Promise<number>;
  /** A list for `IN ${q.list(ids)}` or a row set for `INSERT … ${q.list(rows)}`. */
  list(values: readonly unknown[]): unknown;
  /** A reusable piece of SQL with its own parameters, embedded as `${q.frag`…`}`. */
  frag(strings: TemplateStringsArray, ...values: unknown[]): unknown;
  /**
   * SQL text embedded as is. Only for constants written in the source
   * (column lists, ORDER BY clauses), never for anything from a request.
   */
  raw(text: string): unknown;
}

export interface Tx extends Query {
  /**
   * Transaction-scoped lock on one named thing, for rules no row lock covers
   * (for example "positions in this Thread's queue"). Same key as
   * `lockKeySql`, so SQL and code agree.
   */
  lock(scope: string, id: string): Promise<void>;
  /** Runs `fn` once the transaction committed; never on rollback or retry. */
  afterCommit(fn: () => unknown): void;
}

/** SQL expression for the lock key of `tx.lock(scope, id)`. */
export const lockKeySql = (scope: string, idSql: string) =>
  `hashtextextended('${scope.replace(/'/g, "''")}:' || ${idSql}, 0)`;

export interface TxStat { label: string; count: number; totalMs: number; maxMs: number; retries: number; failures: number }
const stats = new Map<string, TxStat>();

function record(label: string, ms: number, retries: number, failed: boolean) {
  let stat = stats.get(label);
  if (!stat) {
    if (stats.size >= 500) return; // labels are a closed set; never grow unbounded
    stat = { label, count: 0, totalMs: 0, maxMs: 0, retries: 0, failures: 0 };
    stats.set(label, stat);
  }
  stat.count++; stat.totalMs += ms; stat.maxMs = Math.max(stat.maxMs, ms);
  stat.retries += retries; if (failed) stat.failures++;
  if (ms >= SLOW_TX_MS)
    console.log(JSON.stringify({ level: "warn", message: "db.slow_tx", details: { label, ms: Math.round(ms), retries } }));
}

/** Transactions since the last call, slowest in total first. */
export function drainTxStats(): TxStat[] {
  const out = [...stats.values()].sort((a, b) => b.totalMs - a.totalMs)
    .map((s) => ({ ...s, totalMs: Math.round(s.totalMs), maxMs: Math.round(s.maxMs) }));
  stats.clear();
  return out;
}

export function normalizeValue(v: unknown): unknown {
  if (typeof v === "bigint") {
    if (v > BigInt(Number.MAX_SAFE_INTEGER) || v < BigInt(Number.MIN_SAFE_INTEGER))
      throw new RangeError(`int8 value ${v} does not fit a JS number`);
    return Number(v);
  }
  if (v instanceof Date) return v.toISOString();
  return v;
}

function normalizeRow<T>(row: Row): T {
  const out: Row = {};
  for (const k in row) out[k] = normalizeValue(row[k]);
  return out as T;
}

const checked = new WeakSet<TemplateStringsArray>();
const UNQUOTED_ALIAS = /\bAS\s+([a-z][a-z0-9_]*[A-Z][A-Za-z0-9_]*)/;

function checkText(text: string) {
  const m = UNQUOTED_ALIAS.exec(text);
  if (m) throw new Error(`Quote the result name ${m[1]}: AS "${m[1]}" (PostgreSQL folds unquoted names to lower case)`);
}

function checkStrings(strings: TemplateStringsArray) {
  if (checked.has(strings)) return;
  for (const part of strings) checkText(part);
  checked.add(strings);
}

function checkValues(values: unknown[]) {
  values.forEach((v, i) => {
    if (v === undefined) throw new TypeError(`SQL parameter ${i + 1} is undefined; use null`);
  });
}

function queryOn(conn: Sql): Query {
  const exec = (strings: TemplateStringsArray, values: unknown[]) => {
    checkStrings(strings);
    checkValues(values);
    return (conn as unknown as (s: TemplateStringsArray, ...v: unknown[]) => Promise<any>)(strings, ...values);
  };
  return {
    async rows<T>(strings: TemplateStringsArray, ...values: unknown[]) {
      const result = await exec(strings, values);
      return (Array.isArray(result) ? result : []).map((r: Row) => normalizeRow<T>(r));
    },
    async row<T>(strings: TemplateStringsArray, ...values: unknown[]) {
      const result = await exec(strings, values);
      return Array.isArray(result) && result.length ? normalizeRow<T>(result[0]) : null;
    },
    async run(strings: TemplateStringsArray, ...values: unknown[]) {
      const result = await exec(strings, values);
      return Number(result?.count ?? 0);
    },
    list: (values) => (conn as unknown as (v: readonly unknown[]) => unknown)(values),
    frag(strings: TemplateStringsArray, ...values: unknown[]) {
      checkStrings(strings);
      checkValues(values);
      return (conn as unknown as (s: TemplateStringsArray, ...v: unknown[]) => unknown)(strings, ...values);
    },
    raw: (text) => { checkText(text); return conn.unsafe(text); },
  };
}

export class Data {
  /** Queries outside a transaction (reads, and single self-contained writes). */
  readonly read: Query;

  constructor(readonly sql: Sql) {
    this.read = queryOn(sql);
  }

  /**
   * Runs `fn` as one transaction (READ COMMITTED), retried as a whole on a
   * deadlock or serialization failure. `label` names the operation in the
   * metrics (`db.tx` log line) and the slow-transaction warning.
   */
  async tx<T>(label: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
    const started = performance.now();
    for (let attempt = 1; ; attempt++) {
      const after: (() => unknown)[] = [];
      try {
        const result = await this.sql.begin(async (conn) => {
          const q = queryOn(conn as unknown as Sql);
          const tx: Tx = {
            ...q,
            async lock(scope, id) {
              await (conn as unknown as Sql).unsafe(`SELECT pg_advisory_xact_lock(${lockKeySql(scope, "$1")})`, [id]);
            },
            afterCommit: (f) => { after.push(f); },
          };
          return fn(tx);
        }) as T;
        record(label, performance.now() - started, attempt - 1, false);
        for (const f of after) {
          try { await f(); } catch (e) {
            console.error(JSON.stringify({ level: "error", message: "db.after_commit_failed", details: { label, error: String((e as Error)?.stack ?? e) } }));
          }
        }
        return result;
      } catch (e: any) {
        const code = e?.errno ?? e?.code;
        if (!RETRYABLE.has(code) || attempt >= MAX_ATTEMPTS) {
          record(label, performance.now() - started, attempt - 1, true);
          throw e;
        }
        await Bun.sleep(Math.random() * Math.min(200, 5 * 2 ** attempt));
      }
    }
  }
}

const instances = new WeakMap<object, Data>();

/**
 * The data layer of an environment. Uses `env.SYNTILA_DATA` when the runtime
 * set it, otherwise the connection pool behind the adapter (`SYNTILA_DB.sql`),
 * so handlers and test fixtures that only provide the adapter keep working.
 */
export function dataOf(env: { SYNTILA_DATA?: unknown; SYNTILA_DB: unknown }): Data {
  if (env.SYNTILA_DATA instanceof Data) return env.SYNTILA_DATA;
  const db = env.SYNTILA_DB as { sql?: Sql } | null;
  if (!db?.sql) throw new Error("SYNTILA_DB has no PostgreSQL pool; the data layer needs one");
  let data = instances.get(db);
  if (!data) instances.set(db, (data = new Data(db.sql)));
  return data;
}
