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

const isRead = (sql: string) => /^\s*(select|with\s+[\s\S]*?\)\s*select|show|explain)\b/i.test(sql) && !/\b(insert|update|delete)\b/i.test(sql);

function normalizeValue(v: unknown): unknown {
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "boolean") return v ? 1 : 0; // SQLite/D1 report predicates as 1/0
  if (v instanceof Date) return v.toISOString();
  if (v instanceof Uint8Array) return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
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

export class PgD1Database {
  constructor(readonly sql: Sql) {}

  prepare(query: string): PgD1PreparedStatement {
    return new PgD1PreparedStatement(this, query);
  }

  /** @internal */
  async execute<T>(stmt: PgD1PreparedStatement, tx?: Sql): Promise<D1Result<T>> {
    const text = translatePlaceholders(stmt.sql);
    const started = performance.now();
    const runOn = (conn: Sql) => conn.unsafe(text, stmt.values as Value[]);
    let result: any;
    try {
      if (tx) result = await runOn(tx);
      else if (isRead(text)) result = await runOn(this.sql);
      else result = await this.serializable((t) => runOn(t));
    } catch (e) {
      throw e instanceof PgD1Error ? e : new PgD1Error(e);
    }
    return toResult<T>(result, performance.now() - started);
  }

  async batch<T = Record<string, unknown>>(statements: PgD1PreparedStatement[]): Promise<D1Result<T>[]> {
    if (statements.length === 0) return [];
    try {
      return await this.serializable(async (tx) => {
        const out: D1Result<T>[] = [];
        for (const s of statements) {
          const started = performance.now();
          out.push(toResult<T>(await tx.unsafe(translatePlaceholders(s.sql), s.values as Value[]), performance.now() - started));
        }
        return out;
      });
    } catch (e) {
      throw e instanceof PgD1Error ? e : new PgD1Error(e);
    }
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
  private async serializable<R>(fn: (tx: Sql) => Promise<R>): Promise<R> {
    for (let attempt = 1; ; attempt++) {
      try {
        return await this.sql.begin(async (tx) => {
          await (tx as unknown as Sql).unsafe("SELECT pg_advisory_xact_lock($1)", [WRITER_LOCK]);
          return fn(tx as unknown as Sql);
        }) as R;
      } catch (e: any) {
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
