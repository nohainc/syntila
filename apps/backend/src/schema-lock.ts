import type { Db } from "./db";

/**
 * A readable, version-stable description of the public schema: one line per
 * table column, index, constraint, trigger and function. `migrations/schema.lock`
 * holds the result of applying every migration to an empty database, so
 *  - a pull request shows exactly what a migration changes, and
 *  - `migrate --verify` can tell when a live database has drifted from it.
 * Only catalog facts that print the same on every supported PostgreSQL
 * version are included (no reconstructed definitions).
 */
export async function schemaLock(db: Db): Promise<string> {
  const lines: string[] = [];
  const columns: any[] = await db`
    SELECT c.table_name, c.column_name, c.udt_name, c.is_nullable, c.column_default IS NOT NULL AS has_default, c.is_identity
    FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema, table_name)
    WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE' AND c.table_name <> 'schema_migrations'`;
  for (const c of columns)
    lines.push(`column ${c.table_name}.${c.column_name} ${c.udt_name}${c.is_nullable === "NO" ? " not-null" : ""}${c.has_default ? " default" : ""}${c.is_identity === "YES" ? " identity" : ""}`);
  const indexes: any[] = await db`
    SELECT t.relname AS table_name, i.relname AS index_name, x.indisunique, x.indpred IS NOT NULL AS partial,
      (SELECT string_agg(COALESCE(a.attname, '(expr)'), ',' ORDER BY k.ord)
         FROM unnest(string_to_array(x.indkey::text, ' ')::int[]) WITH ORDINALITY k(attnum, ord)
         LEFT JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum AND k.attnum <> 0) AS cols
    FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
    WHERE t.relnamespace = 'public'::regnamespace AND t.relname <> 'schema_migrations' AND x.indisvalid`;
  for (const i of indexes)
    lines.push(`index ${i.table_name}.${i.index_name} (${i.cols})${i.indisunique ? " unique" : ""}${i.partial ? " partial" : ""}`);
  const constraints: any[] = await db`
    SELECT t.relname AS table_name, c.conname, c.contype::text AS contype, r.relname AS ref, c.confdeltype::text AS del
    FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid LEFT JOIN pg_class r ON r.oid = c.confrelid
    WHERE c.connamespace = 'public'::regnamespace AND t.relname <> 'schema_migrations'`;
  const kinds: Record<string, string> = { p: "primary-key", u: "unique", f: "foreign-key", c: "check", x: "exclude" };
  const onDelete: Record<string, string> = { a: "no-action", r: "restrict", c: "cascade", n: "set-null", d: "set-default" };
  for (const c of constraints)
    lines.push(`constraint ${c.table_name}.${c.conname} ${kinds[c.contype] ?? c.contype}${c.ref ? ` -> ${c.ref} on-delete-${onDelete[c.del] ?? c.del}` : ""}`);
  const triggers: any[] = await db`
    SELECT t.relname AS table_name, g.tgname, p.proname
    FROM pg_trigger g JOIN pg_class t ON t.oid = g.tgrelid JOIN pg_proc p ON p.oid = g.tgfoid
    WHERE NOT g.tgisinternal AND t.relnamespace = 'public'::regnamespace`;
  for (const g of triggers) lines.push(`trigger ${g.table_name}.${g.tgname} -> ${g.proname}`);
  const functions: any[] = await db`
    SELECT p.proname, p.pronargs FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace`;
  for (const f of functions) lines.push(`function ${f.proname}/${f.pronargs}`);
  return lines.sort().join("\n") + "\n";
}

/** Lines that differ between the live schema (+) and the lock file (-). */
export async function verifySchemaLock(db: Db, lockPath: string): Promise<string[]> {
  const expected = new Set((await Bun.file(lockPath).text()).split("\n").filter(Boolean));
  const actual = new Set((await schemaLock(db)).split("\n").filter(Boolean));
  const drift: string[] = [];
  for (const line of expected) if (!actual.has(line)) drift.push(`- ${line}`);
  for (const line of actual) if (!expected.has(line)) drift.push(`+ ${line}`);
  return drift.sort((a, b) => a.slice(2).localeCompare(b.slice(2)));
}
