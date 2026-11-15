/** Migration runner, schema lock and operational retention against real PostgreSQL. */
import { afterAll, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { migrate, migrationFiles, pendingMigrations, splitStatements } from "../src/migrate";
import { pruneOperationalTables } from "../src/retention";
import { schemaLock, verifySchemaLock } from "../src/schema-lock";

const BASE_URL = process.env.TEST_DATABASE_URL ?? "postgres://syntila_app:devpass@127.0.0.1:5432/postgres";
const admin = new SQL(BASE_URL, { max: 1 });
const databases: { name: string; sql: InstanceType<typeof SQL> }[] = [];

async function emptyDatabase() {
  const name = `syntila_t_${process.pid}_mig_${Math.random().toString(36).slice(2, 8)}`;
  await admin.unsafe(`CREATE DATABASE ${name}`);
  const url = new URL(BASE_URL); url.pathname = `/${name}`;
  const sql = new SQL(url.toString(), { max: 3 });
  databases.push({ name, sql });
  return sql;
}
function directory(files: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), "syntila-migrations-"));
  for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
  return dir;
}
afterAll(async () => {
  for (const d of databases) { await d.sql.close().catch(() => {}); await admin.unsafe(`DROP DATABASE IF EXISTS ${d.name} WITH (FORCE)`); }
  await admin.close();
});

describe("migration files", () => {
  test("a misnamed .sql file is an error instead of being silently skipped", async () => {
    await expect(migrationFiles(directory({ "0001_ok.sql": "SELECT 1;", "2_Bad-Name.sql": "SELECT 1;" }))).rejects.toThrow(/must match/);
  });
  test("two files cannot share a number", async () => {
    await expect(migrationFiles(directory({ "0001_a.sql": "SELECT 1;", "0001_b.sql": "SELECT 1;" }))).rejects.toThrow(/share the number/);
  });
  test("no-transaction files are split into statements and reject function bodies", () => {
    expect(splitStatements("-- migrate:no-transaction\n-- note; with semicolon\nCREATE INDEX a ON t (x);\nCREATE INDEX b\n  ON t (y);\n"))
      .toEqual(["CREATE INDEX a ON t (x)", "CREATE INDEX b\n  ON t (y)"]);
    expect(() => splitStatements("CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1; $$;")).toThrow(/dollar-quoted/);
  });
});

describe("migrate", () => {
  test("applies transactional and no-transaction migrations once, and detects edits", async () => {
    const sql = await emptyDatabase();
    const files = {
      "0001_table.sql": "CREATE TABLE t (id text PRIMARY KEY, owner text);",
      "0002_index.sql": "-- migrate:no-transaction\nCREATE INDEX CONCURRENTLY IF NOT EXISTS t_owner_idx ON t (owner);\n",
    };
    const dir = directory(files);
    expect(await pendingMigrations(sql as any, dir)).toEqual(Object.keys(files));
    expect((await migrate(sql as any, dir)).applied).toEqual(Object.keys(files));
    expect((await migrate(sql as any, dir)).applied).toEqual([]);
    expect(await pendingMigrations(sql as any, dir)).toEqual([]);
    const [{ valid }] = await sql`SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 't_owner_idx'::regclass`;
    expect(valid).toBe(true);
    writeFileSync(join(dir, "0001_table.sql"), "CREATE TABLE t (id text PRIMARY KEY);");
    await expect(migrate(sql as any, dir)).rejects.toThrow(/was modified/);
  });

  test("a failing transactional migration leaves nothing behind", async () => {
    const sql = await emptyDatabase();
    const dir = directory({ "0001_bad.sql": "CREATE TABLE half (id text); SELECT 1/0;" });
    await expect(migrate(sql as any, dir)).rejects.toThrow();
    const [{ present }] = await sql`SELECT to_regclass('half') IS NOT NULL AS present`;
    expect(present).toBe(false);
    expect(await pendingMigrations(sql as any, dir)).toEqual(["0001_bad.sql"]);
  });

  test("a statement that waits for a lock fails fast instead of queueing traffic behind it", async () => {
    const sql = await emptyDatabase();
    await sql`CREATE TABLE busy (id text PRIMARY KEY)`;
    const holder = await sql.reserve();
    await holder`BEGIN`; await holder`LOCK TABLE busy IN ACCESS EXCLUSIVE MODE`;
    try {
      const dir = directory({ "0001_alter.sql": "ALTER TABLE busy ADD COLUMN note text;" });
      await expect(migrate(sql as any, dir, { lockTimeout: "200ms" })).rejects.toThrow(/lock timeout/i);
    } finally { await holder`ROLLBACK`; holder.release(); }
  });
});

describe("bundling", () => {
  test("a bundle that imports the migration module does not run the migrate command line", async () => {
    // Regression: in the bundled server.js `import.meta.main` is true for this
    // module too, so its command line ran inside the server and ended it.
    const dir = mkdtempSync(join(tmpdir(), "syntila-bundle-"));
    writeFileSync(join(dir, "server.ts"),
      `import { migrationFiles } from ${JSON.stringify(join(import.meta.dir, "..", "src", "migrate.ts"))};\n` +
      `setTimeout(() => console.log("server-still-running", typeof migrationFiles), 300);\n`);
    // Same shape as scripts/build.sh: the server and the migration runner are
    // both entry points of one build, which is what marks this module as "main".
    const built = await Bun.build({ entrypoints: [join(dir, "server.ts"), join(import.meta.dir, "..", "src", "migrate.ts")], outdir: join(dir, "dist"), target: "bun" });
    expect(built.success).toBe(true);
    const serverJs = built.outputs.map((o) => o.path).find((p) => p.endsWith("server.js"))!;
    const proc = Bun.spawn(["bun", serverJs], { stdout: "pipe", stderr: "pipe", env: { ...process.env, PGHOST: "127.0.0.1", PGPORT: "1" } });
    const guard = setTimeout(() => proc.kill(), 8000);
    const output = (await new Response(proc.stdout).text()) + (await new Response(proc.stderr).text());
    const exitCode = await proc.exited;
    clearTimeout(guard);
    expect(output).toContain("server-still-running function");
    expect(exitCode).toBe(0);
    expect(output).not.toMatch(/Schema is up to date|PostgreSQL not reachable|Applied:/);
  });
});

describe("schema lock", () => {
  test("migrations/schema.lock is what the migrations produce (run `bun run schema:lock` after adding one)", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    const lockPath = join(import.meta.dir, "..", "migrations", "schema.lock");
    expect(await verifySchemaLock(sql as any, lockPath)).toEqual([]);
    expect(await schemaLock(sql as any)).toBe(await Bun.file(lockPath).text());
  });

  test("every foreign key has an index that starts with its columns", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    const missing: { fk: string }[] = await sql.unsafe(`
      SELECT c.conrelid::regclass::text || '.' || c.conname AS fk FROM pg_constraint c
      WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace AND NOT EXISTS (
        SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indpred IS NULL
          AND (string_to_array(i.indkey::text, ' ')::int2[])[1:cardinality(c.conkey)] @> c.conkey
          AND (string_to_array(i.indkey::text, ' ')::int2[])[1:cardinality(c.conkey)] <@ c.conkey)`);
    expect(missing.map((m) => m.fk)).toEqual([]);
  });

  test("every JSON-as-text column refuses malformed JSON", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    const unguarded: { col: string }[] = await sql.unsafe(`
      SELECT c.table_name || '.' || c.column_name AS col FROM information_schema.columns c
      JOIN information_schema.tables t USING (table_schema, table_name)
      WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE' AND c.udt_name = 'text' AND c.column_name LIKE '%\\_json'
        AND NOT EXISTS (
          SELECT 1 FROM pg_constraint k JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)
          WHERE k.contype = 'c' AND k.conrelid = format('%I', c.table_name)::regclass AND a.attname = c.column_name
            AND pg_get_constraintdef(k.oid) ILIKE '%IS JSON%')`);
    expect(unguarded.map((u) => u.col)).toEqual([]);
    await sql`INSERT INTO users (id, email, display_name) VALUES ('u', 'u@test', 'U')`;
    const insert = (settings: string) => sql`INSERT INTO spaces (id, name, owner_user_id, settings_json) VALUES (${crypto.randomUUID()}, 'S', 'u', ${settings})`;
    await expect(insert("{not json")).rejects.toThrow(/spaces_settings_json_is_json/);
    await expect(insert("")).rejects.toThrow(/spaces_settings_json_is_json/);
    await insert('{"ok":true}');
  });

  test("event cursors have a primary key and one row per stream", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    const [{ pk }] = await sql`SELECT count(*)::int AS pk FROM pg_constraint WHERE conrelid = 'realtime_event_cursors'::regclass AND contype = 'p'`;
    expect(pk).toBe(1);
    await sql`INSERT INTO realtime_event_cursors (stream_kind, stream_id, next_sequence) VALUES ('space', 's1', 1)`;
    await sql`INSERT INTO realtime_event_cursors (stream_kind, workspace_id, next_sequence) VALUES ('execution_workspace', 'w1', 1)`;
    await sql`INSERT INTO realtime_event_cursors (stream_kind, stream_id, next_sequence) VALUES ('space', 's1', 9) ON CONFLICT DO NOTHING`;
    const rows = await sql`SELECT stream_kind, stream_key, next_sequence::int AS n FROM realtime_event_cursors ORDER BY stream_kind`;
    expect(rows.map((r: any) => [r.stream_kind, r.stream_key, r.n])).toEqual([["execution_workspace", "w1", 1], ["space", "s1", 1]]);
  });

  test("author and actor columns that hold a user id reference users", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    const rows: { col: string }[] = await sql.unsafe(`
      SELECT c.conrelid::regclass::text || '.' || a.attname AS col FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND c.confrelid = 'users'::regclass AND c.conrelid::regclass::text IN
        ('conversation_user_messages', 'thread_request_queue', 'thread_request_queue_state', 'work_request_inputs')
      ORDER BY 1`);
    expect(rows.map((r) => r.col)).toEqual([
      "conversation_user_messages.author_user_id",
      "thread_request_queue.author_user_id",
      "thread_request_queue_state.paused_by_user_id",
      "work_request_inputs.user_id",
    ]);
  });

  test("drift is reported line by line", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    await sql`CREATE INDEX drift_idx ON users (display_name)`;
    expect(await verifySchemaLock(sql as any, join(import.meta.dir, "..", "migrations", "schema.lock")))
      .toEqual(["+ index users.drift_idx (display_name)"]);
  });
});

describe("operational retention", () => {
  test("removes only old, finished rows", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    await sql.unsafe(`
      INSERT INTO users (id, email, display_name) VALUES ('u', 'u@test', 'U');
      INSERT INTO email_outbox (id, message, status, created_at) VALUES
        ('old-sent', '{}', 'sent', now() - interval '40 days'), ('old-pending', '{}', 'pending', now() - interval '40 days'), ('new-sent', '{}', 'sent', now());
      INSERT INTO mutation_receipts (user_id, scope, idempotency_key, request_hash, response_json, response_status, created_at) VALUES
        ('u', 's', 'old', 'h', '{}', 200, now() - interval '31 days'), ('u', 's', 'new', 'h', '{}', 200, now());
      INSERT INTO workflow_instances (id, workflow, status, updated_at) VALUES
        ('old-done', 'w', 'complete', now() - interval '100 days'), ('old-waiting', 'w', 'waiting', now() - interval '100 days'), ('new-done', 'w', 'complete', now());
      INSERT INTO workflow_events (instance_id, type) VALUES ('old-done', 'x');`);
    expect(await pruneOperationalTables(sql as any)).toEqual({ email_outbox: 1, mutation_receipts: 1, workflow_instances: 1 });
    expect((await sql`SELECT id FROM email_outbox ORDER BY id`).map((r: any) => r.id)).toEqual(["new-sent", "old-pending"]);
    expect((await sql`SELECT id FROM workflow_instances ORDER BY id`).map((r: any) => r.id)).toEqual(["new-done", "old-waiting"]);
    expect(Number((await sql`SELECT count(*) AS n FROM workflow_events`)[0].n)).toBe(0);
  });
});
