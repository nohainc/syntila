import { SQL } from "bun";
import { PgD1Error, runFixtureStatement, translatePlaceholders } from "./fixture-sql";

type Sql = InstanceType<typeof SQL>;
const fix = (v: unknown) => (typeof v === "boolean" ? (v ? 1 : 0) : v === undefined ? null : v);

function asFixtureError(e: any): Error {
  if (e instanceof PgD1Error) return e;
  return new PgD1Error({ errno: e?.errno ?? e?.code, message: e?.message, constraint: e?.constraint, table: e?.table, column: e?.column, detail: e?.detail });
}

/**
 * Async fixture access for tests (seeds and assertions): exec(sql) /
 * prepare(sql).run|get|all(...). It keeps the conventions of the former
 * synchronous bridge: `?`/`?N` placeholders, booleans as 1/0, JSON as text,
 * SQLite-style `INSERT OR IGNORE/REPLACE` and failure-injection triggers.
 * It owns one connection, separate from the pool under test.
 */
export class FixtureDb {
  private sql: Sql;
  private closed = false;
  constructor(url: string) {
    this.sql = new SQL(url, { bigint: true, max: 1, idleTimeout: 2, connection: { lock_timeout: "5000" } });
  }
  private async query(text: string, params: unknown[] = []) {
    try { return await runFixtureStatement(this.sql, text, params); } catch (e) { throw asFixtureError(e); }
  }
  async exec(sql: string): Promise<void> {
    // SQLite pragmas from the original fixtures have no PostgreSQL meaning.
    const text = await this.fixtureSql(sql.replace(/^\s*PRAGMA[^;]*;?/gim, ""));
    if (text.trim()) { try { await this.sql.unsafe(text); } catch (e) { throw asFixtureError(e); } }
  }
  /**
   * Fixture-only rewrite of SQLite upserts: `INSERT OR IGNORE` → `ON CONFLICT
   * DO NOTHING`, `INSERT OR REPLACE` → upsert on the table's primary key.
   */
  private async fixtureSql(sql: string): Promise<string> {
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
    const parts: string[] = [];
    for (const stmt of splitStatements(sql)) {
      const m = stmt.match(/^\s*INSERT\s+OR\s+(IGNORE|REPLACE)\s+INTO\s+"?(\w+)"?\s*(\(([^)]*)\))?/i);
      if (!m) { parts.push(stmt); continue; }
      const body = stmt.replace(/INSERT\s+OR\s+(IGNORE|REPLACE)\s+INTO/i, "INSERT INTO").replace(/;\s*$/, "");
      if (m[1]!.toUpperCase() === "IGNORE") { parts.push(`${body} ON CONFLICT DO NOTHING`); continue; }
      const table = m[2]!;
      let cols = (m[4] ?? "").split(",").map((c) => c.trim().replace(/"/g, "")).filter(Boolean);
      if (!cols.length)
        cols = ((await this.query(`SELECT attname FROM pg_attribute WHERE attrelid = '${table}'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum`)).rows as { attname: string }[]).map((r) => r.attname);
      const pk = ((await this.query(`SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = '${table}'::regclass AND i.indisprimary`)).rows as { attname: string }[]).map((r) => r.attname);
      const updates = cols.filter((c) => !pk.includes(c)).map((c) => `${c} = excluded.${c}`);
      parts.push(`${body} ON CONFLICT (${pk.join(", ")}) ${updates.length ? `DO UPDATE SET ${updates.join(", ")}` : "DO NOTHING"}`);
    }
    return parts.join(";\n");
  }
  prepare(sql: string) {
    if (/^\s*PRAGMA\b/i.test(sql)) return {
      run: async (..._p: unknown[]) => ({ changes: 0, lastInsertRowid: 0 }),
      get: async (..._p: unknown[]): Promise<any> => undefined,
      all: async (..._p: unknown[]): Promise<any[]> => [],
    };
    const text = this.fixtureSql(sql).then(translatePlaceholders);
    return {
      run: async (...params: unknown[]) => { const r = await this.query(await text, params.map(fix)); return { changes: r.count, lastInsertRowid: 0 }; },
      get: async (...params: unknown[]): Promise<any> => (await this.query(await text, params.map(fix))).rows[0],
      all: async (...params: unknown[]): Promise<any[]> => (await this.query(await text, params.map(fix))).rows,
    };
  }
  async close() { if (!this.closed) { this.closed = true; await this.sql.close({ timeout: 0 }).catch(() => {}); } }
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
