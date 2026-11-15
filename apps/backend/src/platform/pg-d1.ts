/**
 * D1-compatible facade over PostgreSQL (Bun.SQL).
 *
 * Lets the ported Cloudflare domain code keep its `prepare/bind/first/all/run/batch`
 * calls while running on PostgreSQL. It deliberately does NOT rewrite SQL
 * dialect beyond placeholders: SQLite-only constructs are fixed in the source,
 * so every query that runs here is plain PostgreSQL.
 *
 * Semantics kept from D1:
 *  - `?N` / `?` placeholders (translated to `$N`), `undefined` bindings rejected.
 *  - Single statements are atomic; `batch()` runs all statements in one
 *    transaction. D1 has one writer, so writes and batches run SERIALIZABLE
 *    here, serialized behind a global writer lock like D1, and retried on deadlocks.
 *  - Row values: int8 → number, boolean → 1/0, timestamptz → ISO-8601 string (`toISOString`),
 *    bytea → ArrayBuffer.
 *  - Results: `{ success, results, meta: { changes, rows_read, rows_written, duration } }`.
 * Errors keep PostgreSQL fields (`code`, `constraint`, `table`, `detail`) and a
 * D1-style message prefix for unique/foreign-key/check violations.
 */
import type { SQL } from "bun";

type Sql = InstanceType<typeof SQL>;
type Value = string | number | boolean | null | bigint | ArrayBuffer | ArrayBufferView;

export interface D1Result<T = Record<string, unknown>> {
  success: true;
  results: T[];
  meta: { changes: number; rows_read: number; rows_written: number; duration: number; last_row_id: number | null };
}

const RETRYABLE = new Set(["40001", "40P01"]); // serialization_failure, deadlock_detected
const MAX_ATTEMPTS = 25;
/** Advisory lock key for the global writer lock ("syntila.writer"). */
const WRITER_LOCK = 0x5359_4e57;
const translated = new Map<string, string>();

/**
 * Translates D1 SQL text for PostgreSQL, outside string literals and comments:
 *  - `?N` / bare `?` placeholders → `$N`;
 *  - mixed-case identifiers (camelCase result aliases such as `AS runtimeId`)
 *    are quoted, because PostgreSQL folds unquoted identifiers to lower case
 *    while SQLite preserves them. Schema identifiers are all snake_case.
 */
export function translatePlaceholders(sql: string): string {
  const cached = translated.get(sql);
  if (cached !== undefined) return cached;
  let out = "", next = 1, i = 0;
  while (i < sql.length) {
    const c = sql[i]!;
    if (c === "'" || c === '"') {
      const end = findQuoteEnd(sql, i, c);
      out += sql.slice(i, end);
      i = end;
    } else if (c === "-" && sql[i + 1] === "-") {
      const end = sql.indexOf("\n", i);
      i = end < 0 ? sql.length : end;
    } else if (c === "?") {
      let j = i + 1;
      while (j < sql.length && sql[j]! >= "0" && sql[j]! <= "9") j++;
      if (j > i + 1) {
        const n = Number(sql.slice(i + 1, j));
        out += `$${n}`;
        next = Math.max(next, n + 1);
      } else {
        out += `$${next++}`;
      }
      // Bun would JSON-encode a string bound to a json/jsonb-typed parameter
      // a second time; bind it as text and let PostgreSQL parse it.
      if (/^::jsonb?\b/i.test(sql.slice(j))) out += "::text";
      i = j;
    } else if (isIdentStart(c) && (i === 0 || !isIdentPart(sql[i - 1]!))) {
      let j = i + 1;
      while (j < sql.length && isIdentPart(sql[j]!)) j++;
      const word = sql.slice(i, j);
      out += /^[a-z_][a-z0-9_]*[A-Z][A-Za-z0-9_]*$/.test(word) && sql[j] !== "(" ? `"${word}"` : word;
      i = j;
    } else {
      out += c;
      i++;
    }
  }
  if (translated.size > 5000) translated.clear();
  translated.set(sql, out);
  return out;
}

const isIdentStart = (c: string) => (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
const isIdentPart = (c: string) => isIdentStart(c) || (c >= "0" && c <= "9") || c === "$";

function findQuoteEnd(sql: string, start: number, quote: string): number {
  let i = start + 1;
  while (i < sql.length) {
    if (sql[i] === quote) {
      if (sql[i + 1] === quote) { i += 2; continue; }
      return i + 1;
    }
    i++;
  }
  return sql.length;
}

/* ------------------------------------------------------- writer-lock metrics */

export interface WriterLockStat { label: string; count: number; waitMs: number; holdMs: number; maxHoldMs: number }
const lockStats = new Map<string, WriterLockStat>();
const SLOW_WRITE_MS = Number(process.env.PG_SLOW_WRITE_MS ?? 250);

/** "insert realtime_events", "update worker_assignments", … for one statement. */
export function statementLabel(sql: string): string {
  const m = /^\s*(?:\/\*[\s\S]*?\*\/\s*)?(?:with\b[\s\S]*?\)\s*)?(insert\s+into|update|delete\s+from)\s+"?([a-z_][a-z0-9_]*)/i.exec(sql);
  return m ? `${m[1]!.toLowerCase().split(/\s+/)[0]} ${m[2]!.toLowerCase()}` : "other";
}

function recordWrite(label: string, waitMs: number, holdMs: number): void {
  let stat = lockStats.get(label);
  if (!stat) {
    if (lockStats.size >= 500) return; // labels are a closed set in practice; never grow unbounded
    stat = { label, count: 0, waitMs: 0, holdMs: 0, maxHoldMs: 0 };
    lockStats.set(label, stat);
  }
  stat.count++; stat.waitMs += waitMs; stat.holdMs += holdMs;
  if (holdMs > stat.maxHoldMs) stat.maxHoldMs = holdMs;
  if (SLOW_WRITE_MS > 0 && holdMs >= SLOW_WRITE_MS)
    console.warn(JSON.stringify({ level: "warn", message: "db.slow_write", details: { label, holdMs: Math.round(holdMs), waitMs: Math.round(waitMs) } }));
}

/**
 * What held the global writer lock since the last call, heaviest first.
 * `waitMs` is time spent queueing for the lock (plus BEGIN); `holdMs` is the
 * time every other writer in the system was blocked.
 */
export function drainWriterLockStats(): WriterLockStat[] {
  const out = [...lockStats.values()]
    .map((s) => ({ ...s, waitMs: Math.round(s.waitMs), holdMs: Math.round(s.holdMs), maxHoldMs: Math.round(s.maxHoldMs) }))
    .sort((a, b) => b.holdMs - a.holdMs);
  lockStats.clear();
  return out;
}

const isRead = (sql: string) => /^\s*(select|with\s+[\s\S]*?\)\s*select|show|explain)\b/i.test(sql) && !/\b(insert|update|delete)\b/i.test(sql);

function normalizeValue(v: unknown): unknown {
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "boolean") return v ? 1 : 0; // SQLite/D1 report predicates as 1/0
  if (v instanceof Date) return v.toISOString();
  if (v instanceof Uint8Array) return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
  // json/jsonb documents arrive parsed. D1 has no JSON type: the domain code
  // receives JSON as text and parses it itself, so hand it text.
  if (v !== null && typeof v === "object" && !(v instanceof ArrayBuffer)) return JSON.stringify(v);
  return v;
}

function normalizeRow(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k in row) out[k] = normalizeValue(row[k]);
  return out;
}

function bindValue(v: unknown, index: number): unknown {
  if (v === undefined) throw new TypeError(`D1_TYPE_ERROR: Type 'undefined' not supported for value at index ${index}`);
  if (typeof v === "boolean") return v ? 1 : 0;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  return v;
}

/** Positions (0-based) of the json/jsonb and boolean parameters of a statement. */
interface ParamKinds { json: number[]; bool: number[] }
const NO_KINDS: ParamKinds = { json: [], bool: [] };
let describeCounter = 0;

function kindsOf(types: string[]): ParamKinds {
  const kinds: ParamKinds = { json: [], bool: [] };
  types.forEach((type, i) => {
    if (type === "jsonb" || type === "json") kinds.json.push(i);
    else if (type === "boolean") kinds.bool.push(i);
  });
  return kinds;
}

/**
 * Adapts D1-style values to PostgreSQL parameter types:
 *  - a JSON *string* bound to a json/jsonb parameter is parsed first (the
 *    driver would otherwise store it as a JSON string, not as the document);
 *  - 1/0 bound to a boolean parameter become true/false.
 */
function coerceValues(values: unknown[], kinds: ParamKinds): unknown[] {
  if (!kinds.json.length && !kinds.bool.length) return values;
  const out = values.slice();
  for (const i of kinds.json) {
    const v = out[i];
    if (typeof v === "string") {
      // The driver would store an unparsable string as a JSON *string* value,
      // so a malformed document has to be refused here.
      try { out[i] = JSON.parse(v); } catch { throw new TypeError(`Invalid JSON for the json/jsonb parameter at index ${i}`); }
    }
  }
  for (const i of kinds.bool) {
    const v = out[i];
    if (v === 1 || v === 0) out[i] = v === 1;
  }
  return out;
}

export class PgD1Error extends Error {
  code?: string; constraint?: string; table?: string; detail?: string;
  constructor(cause: any) {
    const code: string | undefined = cause?.errno ?? cause?.code;
    const prefix = code === "23505" ? `UNIQUE constraint failed: ${cause.constraint ?? ""}`
      : code === "23503" || code === "23001" ? "FOREIGN KEY constraint failed"
      : code === "23514" ? `CHECK constraint failed: ${cause.constraint ?? ""}`
      : code === "23502" ? `NOT NULL constraint failed: ${cause.table ?? ""}.${cause.column ?? ""}`
      : null;
    super(prefix ? `${prefix} (${cause.message})` : String(cause?.message ?? cause), { cause });
    this.name = "PgD1Error";
    this.code = code; this.constraint = cause?.constraint; this.table = cause?.table; this.detail = cause?.detail;
  }
}

export class PgD1PreparedStatement {
  constructor(private db: PgD1Database, readonly sql: string, readonly values: unknown[] = []) {}

  bind(...values: unknown[]): PgD1PreparedStatement {
    return new PgD1PreparedStatement(this.db, this.sql, values.map(bindValue));
  }

  async first<T = Record<string, unknown>>(column?: string): Promise<T | null> {
    const { results } = await this.all<Record<string, unknown>>();
    const row = results[0];
    if (!row) return null;
    if (column !== undefined) {
      if (!(column in row)) throw new Error(`D1_COLUMN_NOTFOUND: Column not found (${column})`);
      return row[column] as T;
    }
    return row as T;
  }

  all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return this.db.execute<T>(this);
  }

  run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return this.db.execute<T>(this);
  }

  async raw<T = unknown[]>(options?: { columnNames?: boolean }): Promise<T[]> {
    const { results } = await this.all<Record<string, unknown>>();
    const rows = results.map((r) => Object.values(r)) as T[];
    if (options?.columnNames) return [Object.keys(results[0] ?? {}) as T, ...rows];
    return rows;
  }
}

export interface PgD1Options {
  /**
   * Take the global writer lock before every write (D1's single-writer model).
   * Default off since the concurrency plan's audit (claude/concurrency-plan.md):
   * every write that depends on other rows locks exactly what it needs.
   * The server can turn it back on with SYNTILA_DB_WRITER_LOCK=on as an
   * emergency fallback, without a deploy.
   */
  writerLock?: boolean;
}

export class PgD1Database {
  readonly writerLock: boolean;
  constructor(readonly sql: Sql, options: PgD1Options = {}) {
    this.writerLock = options.writerLock ?? false;
  }

  private readonly kinds = new Map<string, Promise<ParamKinds>>();

  /**
   * Asks PostgreSQL which parameters of a statement are json/jsonb or
   * boolean. Done once per statement text (PREPARE on a spare connection,
   * never executed) and cached for the life of the process.
   */
  private paramKinds(text: string, tx?: Sql): Promise<ParamKinds> {
    if (!text.includes("$")) return Promise.resolve(NO_KINDS);
    let known = this.kinds.get(text);
    if (!known) {
      if (this.kinds.size > 5000) this.kinds.clear();
      known = tx ? this.describeWithin(text, tx) : this.describe(text);
      this.kinds.set(text, known);
    }
    return known;
  }

  /**
   * The same probe on a transaction's own connection, inside a savepoint.
   * A transaction must never wait for a second pool connection: with every
   * connection held by transactions waiting on each other's locks, that wait
   * would never end (pool exhaustion deadlock).
   */
  private async describeWithin(text: string, tx: Sql): Promise<ParamKinds> {
    const name = `syntila_describe_${process.pid}_${++describeCounter}`;
    await tx.unsafe("SAVEPOINT syntila_describe");
    try {
      await tx.unsafe(`PREPARE ${name} AS ${text}`);
      const rows: { types: string[] }[] = await tx.unsafe(
        "SELECT parameter_types::text[] AS types FROM pg_prepared_statements WHERE name = $1", [name]);
      await tx.unsafe(`DEALLOCATE ${name}`);
      await tx.unsafe("RELEASE SAVEPOINT syntila_describe");
      return kindsOf(rows[0]?.types ?? []);
    } catch {
      // Any further error would abort the transaction: only clean up what exists.
      await tx.unsafe("ROLLBACK TO SAVEPOINT syntila_describe");
      const left = await tx.unsafe("SELECT 1 FROM pg_prepared_statements WHERE name = $1", [name]);
      if (left.length) await tx.unsafe(`DEALLOCATE ${name}`);
      return NO_KINDS;
    }
  }

  private async describe(text: string): Promise<ParamKinds> {
    const name = `syntila_describe_${process.pid}_${++describeCounter}`;
    const conn = await this.sql.reserve();
    try {
      await conn.unsafe(`PREPARE ${name} AS ${text}`);
      const rows: { types: string[] }[] = await conn.unsafe(
        "SELECT parameter_types::text[] AS types FROM pg_prepared_statements WHERE name = $1", [name]);
      return kindsOf(rows[0]?.types ?? []);
    } catch {
      // Not preparable as written (the real execution reports why).
      return NO_KINDS;
    } finally {
      await conn.unsafe(`DEALLOCATE ${name}`).catch(() => {});
      conn.release();
    }
  }

  prepare(query: string): PgD1PreparedStatement {
    return new PgD1PreparedStatement(this, query);
  }

  /**
   * The adapter's statement API inside an open data-layer transaction
   * (`src/platform/tx-env.ts`): statements and batches run on that
   * transaction's connection, without the global writer lock and without a
   * transaction of their own. Lets existing helpers join a transaction while
   * their module moves to the data layer.
   */
  within(tx: Sql): PgD1Database {
    return new PgD1TxDatabase(this, tx);
  }

  /** @internal */
  async execute<T>(stmt: PgD1PreparedStatement, tx?: Sql): Promise<D1Result<T>> {
    const text = translatePlaceholders(stmt.sql);
    const values = stmt.values.length ? coerceValues(stmt.values, await this.paramKinds(text, tx)) : stmt.values;
    const started = performance.now();
    const runOn = (conn: Sql) => conn.unsafe(text, values as Value[]);
    let result: any;
    try {
      if (tx) result = await runOn(tx);
      else if (isRead(text)) result = await runOn(this.sql);
      else result = await this.serializable((t) => runOn(t), statementLabel(text));
    } catch (e) {
      throw e instanceof PgD1Error ? e : new PgD1Error(e);
    }
    return toResult<T>(result, performance.now() - started);
  }

  async batch<T = Record<string, unknown>>(statements: PgD1PreparedStatement[]): Promise<D1Result<T>[]> {
    if (statements.length === 0) return [];
    try {
      const label = `batch(${statements.length}) ${statementLabel(statements[0]!.sql)}`;
      // Resolve parameter kinds before the transaction takes the writer lock.
      const prepared = await Promise.all(statements.map(async (s) => {
        const text = translatePlaceholders(s.sql);
        return { text, values: s.values.length ? coerceValues(s.values, await this.paramKinds(text)) : s.values };
      }));
      return await this.serializable(async (tx) => {
        // The statements of a batch do not depend on each other's results, so
        // they are sent together (pipelined, in order, on the one transaction
        // connection) instead of waiting a network round trip for each. This
        // is what keeps the global writer lock short. The first failure in
        // statement order is the one reported, as with sequential execution.
        const started = performance.now();
        const settled = await Promise.allSettled(
          prepared.map((s) => tx.unsafe(s.text, s.values as Value[])));
        const duration = (performance.now() - started) / statements.length;
        const out: D1Result<T>[] = [];
        for (const result of settled) {
          if (result.status === "rejected") throw result.reason;
          out.push(toResult<T>(result.value, duration));
        }
        return out;
      }, label);
    } catch (e) {
      throw e instanceof PgD1Error ? e : new PgD1Error(e);
    }
  }

  /**
   * Runs one already-translated statement with the adapter's value
   * conventions but outside the writer lock. For test fixtures and tools;
   * application writes go through `prepare()` / `batch()`.
   */
  async unlocked(text: string, values: unknown[] = []): Promise<{ rows: Record<string, unknown>[]; count: number; command: string }> {
    const bound = values.length ? coerceValues(values, await this.paramKinds(text)) : values;
    const result: any = await this.sql.unsafe(text, bound as Value[]);
    return {
      rows: Array.isArray(result) ? result.map((r: Record<string, unknown>) => normalizeRow(r)) : [],
      count: Number(result?.count ?? 0),
      command: result?.command ?? "",
    };
  }

  /** D1 `exec`: runs raw multi-statement SQL without bindings. */
  async exec(query: string): Promise<{ count: number; duration: number }> {
    const started = performance.now();
    await this.sql.unsafe(query);
    return { count: query.split(";").filter((s) => s.trim()).length, duration: performance.now() - started };
  }

  /**
   * D1's write model: write transactions run one at a time. Each takes a
   * transaction-scoped global writer lock first and then runs READ COMMITTED,
   * so every statement sees all earlier writes (SERIALIZABLE would freeze its
   * snapshot while waiting for the lock and compute stale sequence numbers).
   * Reads never wait. Deadlocks with writers outside this adapter are retried.
   */
  private async serializable<R>(fn: (tx: Sql) => Promise<R>, label = "other"): Promise<R> {
    for (let attempt = 1; ; attempt++) {
      const queued = performance.now();
      let locked = 0;
      try {
        const result = await this.sql.begin(async (tx) => {
          if (this.writerLock) await (tx as unknown as Sql).unsafe("SELECT pg_advisory_xact_lock($1)", [WRITER_LOCK]);
          locked = performance.now();
          return fn(tx as unknown as Sql);
        }) as R;
        // The lock is released by COMMIT, so the hold time includes it.
        recordWrite(label, locked - queued, performance.now() - locked);
        return result;
      } catch (e: any) {
        if (locked) recordWrite(label, locked - queued, performance.now() - locked);
        const code = e?.errno ?? e?.code;
        if (!RETRYABLE.has(code) || attempt >= MAX_ATTEMPTS) throw e;
        await Bun.sleep(Math.random() * Math.min(500, 5 * 2 ** attempt));
      }
    }
  }

}

function toResult<T>(result: any, duration: number): D1Result<T> {
  const rows: T[] = Array.isArray(result) ? result.map((r: Record<string, unknown>) => normalizeRow(r) as T) : [];
  const command: string = result?.command ?? "";
  const changes = /^(INSERT|UPDATE|DELETE|MERGE)/i.test(command) ? Number(result?.count ?? 0) : 0;
  return {
    success: true,
    results: rows,
    meta: { changes, rows_read: rows.length, rows_written: changes, duration, last_row_id: null },
  };
}

/** See `PgD1Database.within`. */
class PgD1TxDatabase extends PgD1Database {
  constructor(private readonly base: PgD1Database, private readonly tx: Sql) {
    super(base.sql, { writerLock: false });
  }

  override execute<T>(stmt: PgD1PreparedStatement): Promise<D1Result<T>> {
    return this.base.execute<T>(stmt, this.tx);
  }

  /** Already inside a transaction: the statements run in order on it. */
  override async batch<T = Record<string, unknown>>(statements: PgD1PreparedStatement[]): Promise<D1Result<T>[]> {
    const out: D1Result<T>[] = [];
    for (const statement of statements) out.push(await this.base.execute<T>(statement, this.tx));
    return out;
  }

  override within(tx: Sql): PgD1Database {
    return tx === this.tx ? this : this.base.within(tx);
  }
}
