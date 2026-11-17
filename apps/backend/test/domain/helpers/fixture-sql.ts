/**
 * TEST ONLY. Value conventions of the synchronous fixture bridge (`pg-sync.ts`).
 *
 * Fixtures seed and inspect through `exec` / `prepare(...).run|get|all` with
 * SQLite-style SQL. This module turns that SQL into PostgreSQL and the values
 * back into the shapes the fixtures expect. The application never uses it: it
 * runs on the tagged data layer (`src/platform/data.ts`).
 *
 *  - `?N` / `?` placeholders become `$N`; camelCase aliases are quoted.
 *  - Row values: int8 -> number, boolean -> 1/0, timestamptz -> ISO string,
 *    bytea -> ArrayBuffer, json/jsonb -> text.
 *  - Bound values: `undefined` is rejected; JSON text bound to a json/jsonb
 *    parameter is parsed first; 1/0 bound to a boolean parameter become booleans.
 *  - Errors keep the PostgreSQL fields and a readable prefix for unique,
 *    foreign-key, check and not-null violations.
 */
import type { SQL } from "bun";

type Sql = InstanceType<typeof SQL>;
type Value = string | number | boolean | null | bigint | ArrayBuffer | ArrayBufferView;

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


/** Asks PostgreSQL which parameters are json/jsonb or boolean (PREPARE, never executed); cached per statement text. */
const kindCache = new Map<string, Promise<ParamKinds>>();
async function paramKinds(sql: Sql, text: string): Promise<ParamKinds> {
  if (!text.includes("$")) return NO_KINDS;
  let known = kindCache.get(text);
  if (!known) {
    if (kindCache.size > 5000) kindCache.clear();
    known = describe(sql, text);
    kindCache.set(text, known);
  }
  return known;
}

async function describe(sql: Sql, text: string): Promise<ParamKinds> {
  const name = `syntila_describe_${process.pid}_${++describeCounter}`;
  const conn = await sql.reserve();
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

/** Runs one statement (already translated) with the fixture value conventions. */
export async function runFixtureStatement(
  sql: Sql,
  text: string,
  values: unknown[] = [],
): Promise<{ rows: Record<string, unknown>[]; count: number; command: string }> {
  const bound = values.length ? coerceValues(values, await paramKinds(sql, text)) : values;
  const result: any = await sql.unsafe(text, bound as Value[]);
  return {
    rows: Array.isArray(result) ? result.map((r: Record<string, unknown>) => normalizeRow(r)) : [],
    count: Number(result?.count ?? 0),
    command: result?.command ?? "",
  };
}

// ---- Async fixture statements -------------------------------------------
// Async counterpart of the sync bridge for tests that seed or read through
// the same PgDb the code under test uses. `?N` placeholders are accepted.
export interface FixtureStatement {
  text: string;
  values: unknown[];
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<{ meta: { changes: number } }>;
}

const poolOf = (db: unknown): Sql =>
  ((db as { SYNTILA_DB?: { sql: Sql } }).SYNTILA_DB ?? (db as { sql: Sql })).sql;

export function fixtureStatement(
  db: unknown,
  text: string,
  values: unknown[] = [],
  sql: Sql = poolOf(db),
): FixtureStatement {
  const translated = translatePlaceholders(text);
  const exec = () => runFixtureStatement(sql, translated, values);
  return {
    text: translated,
    values,
    first: async <T,>() => ((await exec()).rows[0] as T | undefined) ?? null,
    all: async <T,>() => ({ results: (await exec()).rows as T[] }),
    run: async () => ({ meta: { changes: (await exec()).count } }),
  };
}

/** Runs the statements in one transaction, like a D1 batch. */
export async function fixtureBatch(db: unknown, statements: FixtureStatement[]) {
  await poolOf(db).begin(async (tx: Sql) => {
    for (const s of statements) await runFixtureStatement(tx, s.text, s.values);
  });
}
