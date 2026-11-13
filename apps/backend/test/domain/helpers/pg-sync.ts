import { PgD1Error, translatePlaceholders } from "../../../src/platform/pg-d1";
/**
 * Synchronous PostgreSQL access for test fixtures (replaces node:sqlite's
 * DatabaseSync in seeds). A worker owns the connection; the test thread blocks
 * on Atomics.wait. Test-only: never use in application code.
 */
const BUFFER_BYTES = 32 * 1024 * 1024;

export class SyncPostgres {
  private worker: Worker;
  private signal = new SharedArrayBuffer(4);
  private buffer = new SharedArrayBuffer(BUFFER_BYTES);
  constructor(private url: string) {
    this.worker = new Worker(new URL("./pg-sync-worker.ts", import.meta.url).href);
  }
  private call(text: string, params: unknown[], multi: boolean) {
    const flag = new Int32Array(this.signal);
    Atomics.store(flag, 0, 0);
    this.worker.postMessage({ url: this.url, text, params, multi, signal: this.signal, buffer: this.buffer });
    if (Atomics.wait(flag, 0, 0, 30_000) === "timed-out") throw new Error("SyncPostgres timeout");
    const len = new DataView(this.buffer).getUint32(0);
    const res = JSON.parse(new TextDecoder().decode(new Uint8Array(this.buffer, 4, len).slice()));
    if (!res.ok) throw new PgD1Error({ errno: res.code, message: res.message, constraint: res.constraint, table: res.table, column: res.column, detail: res.detail });
    return res;
  }
  exec(sql: string): void {
    // SQLite pragmas from the original fixtures have no PostgreSQL meaning.
    const text = this.fixtureSql(sql.replace(/^\s*PRAGMA[^;]*;?/gim, ""));
    if (text.trim()) this.call(text, [], true);
  }

  /**
   * Fixture-only rewrite of SQLite upserts: `INSERT OR IGNORE` → `ON CONFLICT
   * DO NOTHING`, `INSERT OR REPLACE` → upsert on the table's primary key.
   */
  private fixtureSql(sql: string): string {
    // The PostgreSQL schema is final: fixture DDL that recreated tables or
    // replayed D1 column additions must be idempotent here.
    sql = sql.replace(/ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(?!IF\s)/gi, "ALTER TABLE $1 ADD COLUMN IF NOT EXISTS ")
      .replace(/CREATE\s+TABLE\s+(?!IF\s)/gi, "CREATE TABLE IF NOT EXISTS ")
      .replace(/CREATE\s+(UNIQUE\s+)?INDEX\s+(?!IF\s)/gi, "CREATE $1INDEX IF NOT EXISTS ")
      // SQLite failure-injection triggers → PL/pgSQL.
      .replace(/CREATE\s+TRIGGER\s+(\w+)\s+(BEFORE|AFTER)\s+(INSERT|UPDATE|DELETE)\s+ON\s+(\w+)\s+BEGIN\s+SELECT\s+RAISE\s*\(\s*ABORT\s*,\s*'([^']*)'\s*\)\s*;\s*END\s*;?/gi,
        (_m, name, when, event, table, msg) =>
          `CREATE FUNCTION ${name}_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION '${msg}'; END $$; ` +
          `CREATE TRIGGER ${name} ${when} ${event} ON ${table} FOR EACH ROW EXECUTE FUNCTION ${name}_fn();`);
    if (!/INSERT\s+OR\s+(IGNORE|REPLACE)/i.test(sql)) return sql;
    return splitStatements(sql).map((stmt) => {
      const m = stmt.match(/^\s*INSERT\s+OR\s+(IGNORE|REPLACE)\s+INTO\s+"?(\w+)"?\s*(\(([^)]*)\))?/i);
      if (!m) return stmt;
      const body = stmt.replace(/INSERT\s+OR\s+(IGNORE|REPLACE)\s+INTO/i, "INSERT INTO").replace(/;\s*$/, "");
      if (m[1]!.toUpperCase() === "IGNORE") return `${body} ON CONFLICT DO NOTHING`;
      const table = m[2]!;
      let cols = (m[4] ?? "").split(",").map((c) => c.trim().replace(/"/g, "")).filter(Boolean);
      if (!cols.length)
        cols = (this.call(`SELECT attname FROM pg_attribute WHERE attrelid = '${table}'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum`, [], false).rows as { attname: string }[]).map((r) => r.attname);
      const pk = (this.call(`SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = '${table}'::regclass AND i.indisprimary`, [], false).rows as { attname: string }[]).map((r) => r.attname);
      const updates = cols.filter((c) => !pk.includes(c)).map((c) => `${c} = excluded.${c}`);
      return `${body} ON CONFLICT (${pk.join(", ")}) ${updates.length ? `DO UPDATE SET ${updates.join(", ")}` : "DO NOTHING"}`;
    }).join(";\n");
  }
  prepare(sql: string) {
    if (/^\s*PRAGMA\b/i.test(sql)) return { run: () => ({ changes: 0, lastInsertRowid: 0 }), get: () => undefined, all: () => [] };
    const text = translatePlaceholders(this.fixtureSql(sql));
    return {
      run: (...params: unknown[]) => { const r = this.call(text, params.map(fix), false); return { changes: r.count, lastInsertRowid: 0 }; },
      get: (...params: unknown[]) => this.call(text, params.map(fix), false).rows[0],
      all: (...params: unknown[]) => this.call(text, params.map(fix), false).rows,
    };
  }
  private closed = false;
  close() { if (!this.closed) { this.closed = true; this.worker.terminate(); } }
}

const fix = (v: unknown) => (typeof v === "boolean" ? (v ? 1 : 0) : v === undefined ? null : v);
function toDollar(sql: string) {
  let n = 0;
  return sql.replace(/'(?:[^']|'')*'|\?(\d*)/g, (m, num) => (m.startsWith("'") ? m : `$${num ? num : ++n}`));
}

function splitStatements(sql: string): string[] {
  const out: string[] = []; let cur = "", q = false;
  for (const ch of sql) {
    if (ch === "'") q = !q;
    if (ch === ";" && !q) { if (cur.trim()) out.push(cur); cur = ""; continue; }
    cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out;
}
