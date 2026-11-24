/** Migration runner, schema lock and operational retention against real PostgreSQL. */
import { afterAll, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { migrate, migrationFiles, pendingMigrations, splitStatements } from "../src/migrate";
import { pruneOperationalTables } from "../src/retention";
import { schemaLock, verifySchemaLock } from "../src/schema-lock";
import { copyFileSync, readdirSync } from "node:fs";
import { space, thread, user } from "./domain/helpers/seed";

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

  test("objects of installed extensions (pg_stat_statements) are not schema drift", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any);
    try {
      await sql.unsafe("CREATE EXTENSION IF NOT EXISTS pg_stat_statements");
    } catch {
      return; // not installed here, or the test role may not create extensions
    }
    const lockPath = join(import.meta.dir, "..", "migrations", "schema.lock");
    expect(await verifySchemaLock(sql as any, lockPath)).toEqual([]);
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

  test("files keep existing rows when their Thread or Space is gone, and detach when it is deleted later; notes keep their saved link (0025)", async () => {
    const sql = await emptyDatabase();
    const migrations = join(import.meta.dir, "..", "migrations");
    const dir = mkdtempSync(join(tmpdir(), "syntila-migrations-"));
    for (const f of readdirSync(migrations).filter((n) => /^\d{4}_.*\.sql$/.test(n) && n < "0025")) copyFileSync(join(migrations, f), join(dir, f));
    await migrate(sql as any, dir);
    await sql`INSERT INTO users (id, email, display_name) VALUES ('u1', 'u1@example.test', 'U1')`;
    await sql`INSERT INTO spaces (id, name, owner_user_id) VALUES ('s1', 'S1', 'u1')`;
    await sql`INSERT INTO threads (id, lead_user_id, name, space_id, status) VALUES ('t1', 'u1', 'T1', 's1', 'active')`;
    await sql`INSERT INTO user_notes (id, user_id, thread_id, space_id) VALUES ('n-live', 'u1', 't1', 's1'), ('n-gone', 'u1', 'gone-thread', 'gone-space')`;
    await sql`INSERT INTO user_files (id, user_id, thread_id, space_id, name, media_type, size_bytes) VALUES ('f-live', 'u1', 't1', 's1', 'a', 'text/plain', 1), ('f-gone', 'u1', 'gone-thread', 'gone-space', 'b', 'text/plain', 1)`;
    copyFileSync(join(migrations, "0024_file_approval_indexes.sql"), join(dir, "0024_file_approval_indexes.sql"));
    copyFileSync(join(migrations, "0025_file_approval_foreign_keys.sql"), join(dir, "0025_file_approval_foreign_keys.sql"));
    await migrate(sql as any, dir);
    // Notes are left alone: a note keeps the ids of a Thread that is gone (its saved titles are shown for it).
    const notes = await sql`SELECT id, thread_id, space_id FROM user_notes ORDER BY id`;
    expect(notes.map((r: any) => [r.id, r.thread_id, r.space_id])).toEqual([["n-gone", "gone-thread", "gone-space"], ["n-live", "t1", "s1"]]);
    const files = await sql`SELECT id, thread_id, space_id FROM user_files ORDER BY id`;
    expect(files.map((r: any) => [r.id, r.thread_id, r.space_id])).toEqual([["f-gone", null, null], ["f-live", "t1", "s1"]]);
    // Deleting the Space (which removes its Threads) keeps the file without the link, and the note as it was.
    await sql`DELETE FROM spaces WHERE id = 's1'`;
    const left = await sql`SELECT n.thread_id AS nt, n.space_id AS ns, f.thread_id AS ft, f.space_id AS fs FROM user_notes n, user_files f WHERE n.id = 'n-live' AND f.id = 'f-live'`;
    expect(left.map((r: any) => [r.nt, r.ns, r.ft, r.fs])).toEqual([["t1", "s1", null, null]]);
    // The approver of a plan may be unknown once the account is gone.
    const [{ nullable }] = await sql`SELECT NOT attnotnull AS nullable FROM pg_attribute WHERE attrelid = 'plan_approvals'::regclass AND attname = 'approved_by_user_id'`;
    expect(nullable).toBe(true);
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

describe("0019 unique Thread names", () => {
  test("existing duplicates are renamed (oldest keeps its name), then the rule is enforced", async () => {
    const real = new URL("../migrations/", import.meta.url).pathname;
    const dir = mkdtempSync(join(tmpdir(), "syntila-0019-"));
    for (const f of readdirSync(real).filter((f) => /^\d{4}_.*\.sql$/.test(f) && f < "0019")) copyFileSync(join(real, f), join(dir, f));
    const sql = await emptyDatabase();
    await migrate(sql as any, dir);
    // The state of an older database: the rule was only checked by the handlers.
    await sql.unsafe([
      user("u"), space("S", "u"), space("S2", "u"),
      thread("t1", "S", "u", "Plan"), thread("t2", "S", "u", "plan "), thread("t3", "S", "u", " PLAN"),
      thread("t4", "S", "u", "Plan (2)"),          // already holds the first free-looking name
      thread("o1", "S2", "u", "Plan"),             // another Space may reuse the name
    ].join("\n"));
    copyFileSync(join(real, "0019_unique_thread_names.sql"), join(dir, "0019_unique_thread_names.sql"));
    expect((await migrate(sql as any, dir)).applied).toEqual(["0019_unique_thread_names.sql"]);
    const rows = await sql.unsafe("SELECT id, name FROM threads WHERE space_id = 'S' ORDER BY id");
    const names = new Map(rows.map((r: any) => [r.id, r.name]));
    expect(names.get("t1")).toBe("Plan");                         // keeps its name (ties break by id)
    expect(new Set(rows.map((r: any) => String(r.name).trim().toLowerCase())).size).toBe(rows.length);
    expect(String(names.get("t2"))).toContain("(2)");
    expect((await sql.unsafe("SELECT name FROM threads WHERE id = 'o1'"))[0].name).toBe("Plan");
    await expect(sql.unsafe(
      "INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('t9','S','  pLaN  ','active','u',now(),now())",
    )).rejects.toMatchObject({ constraint: "threads_space_name_key" });
  });
});

describe("0020 unique Space names", () => {
  test("existing duplicates are renamed (oldest keeps its name); Direct Spaces and other owners are untouched", async () => {
    const real = new URL("../migrations/", import.meta.url).pathname;
    const dir = mkdtempSync(join(tmpdir(), "syntila-0020-"));
    for (const f of readdirSync(real).filter((f) => /^\d{4}_.*\.sql$/.test(f) && f < "0020")) copyFileSync(join(real, f), join(dir, f));
    const sql = await emptyDatabase();
    await migrate(sql as any, dir);
    const insert = (id: string, owner: string, name: string, kind = "group", created = "2026-01-01T00:00:00Z") =>
      `INSERT INTO spaces(id,owner_user_id,name,kind,created_at,updated_at) VALUES ('${id}','${owner}','${name}','${kind}','${created}','${created}');`;
    await sql.unsafe([
      user("u1"), user("u2"),
      insert("a1", "u1", "Trip", "group", "2026-01-01T00:00:00Z"),
      insert("a2", "u1", " trip", "group", "2026-01-02T00:00:00Z"),
      insert("a3", "u1", "TRIP ", "group", "2026-01-03T00:00:00Z"),
      insert("d1", "u1", "Trip", "direct"), insert("d2", "u1", "Trip", "direct"),
      insert("b1", "u2", "Trip"),
    ].join("\n"));
    copyFileSync(join(real, "0020_unique_space_names.sql"), join(dir, "0020_unique_space_names.sql"));
    expect((await migrate(sql as any, dir)).applied).toEqual(["0020_unique_space_names.sql"]);
    const names = new Map((await sql.unsafe("SELECT id, name FROM spaces")).map((r: any) => [r.id, r.name]));
    expect(names.get("a1")).toBe("Trip");
    expect(String(names.get("a2"))).toContain("(2)");
    expect(String(names.get("a3"))).toContain("(3)");
    expect(names.get("d1")).toBe("Trip"); expect(names.get("d2")).toBe("Trip"); expect(names.get("b1")).toBe("Trip");
    await expect(sql.unsafe(insert("a9", "u1", "  tRiP  "))).rejects.toMatchObject({ constraint: "spaces_owner_group_name_key" });
  });
});

describe("membership and invitation uniqueness already in the baseline", () => {
  test("duplicates are rejected by the named indexes the router maps to specific messages", async () => {
    const sql = await emptyDatabase();
    await migrate(sql as any, new URL("../migrations/", import.meta.url).pathname);
    await sql.unsafe([user("o1"), user("g1")].join("\n"));
    await sql.unsafe(`INSERT INTO spaces(id,owner_user_id,name,kind,created_at,updated_at) VALUES ('sp1','o1','S','group',now(),now());`);
    const member = (id: string) =>
      `INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES ('${id}','sp1','g1','viewer',now(),now());`;
    const invite = (id: string, email: string, invitee: string, status = "pending") =>
      `INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at,invitee_user_id)
       VALUES ('${id}','sp1','${email}','viewer','h-${id}','o1','${status}',now() + interval '1 day',now(),now(),${invitee});`;
    await sql.unsafe(member("m1"));
    await expect(sql.unsafe(member("m2"))).rejects.toMatchObject({ constraint: "space_memberships_space_id_user_id_key" });
    await sql.unsafe(invite("i1", "a@test", "'g1'"));
    // Same person, different address: only the user index catches it.
    await expect(sql.unsafe(invite("i2", "b@test", "'g1'"))).rejects.toMatchObject({ constraint: "idx_space_invitations_pending_user" });
    await expect(sql.unsafe(invite("i3", "A@test", "NULL"))).rejects.toMatchObject({ constraint: "idx_space_invitations_pending_email" });
    // Only pending rows count: an ended invitation does not block a new one.
    await sql.unsafe(invite("i4", "a@test", "NULL", "expired"));
  });
});

describe("0021 active access excludes a pending invitation", () => {
  test("overlapping invitations are expired, not deleted; new ones are rejected, and a new grant expires a pending one", async () => {
    const real = new URL("../migrations/", import.meta.url).pathname;
    const dir = mkdtempSync(join(tmpdir(), "syntila-0021-"));
    for (const f of readdirSync(real).filter((f) => /^\d{4}_.*\.sql$/.test(f) && f < "0021")) copyFileSync(join(real, f), join(dir, f));
    const sql = await emptyDatabase();
    await migrate(sql as any, dir);
    const invite = (id: string, ws: string, email: string, status = "pending") =>
      `INSERT INTO workspace_invitations(id,workspace_id,email,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at)
       VALUES ('${id}','${ws}','${email}','h-${id}','o1','${status}',now() + interval '1 day',now(),now());`;
    const grant = (ws: string, uid: string) =>
      `INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at) VALUES ('${ws}','${uid}','o1','active',now(),now());`;
    await sql.unsafe([
      user("o1"), user("g1"), user("g2"),
      `INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('w1','o1','Mac','online',now(),now()),('w2','o1','Mini','online',now(),now());`,
      grant("w1", "g1"),
      invite("overlap", "w1", "G1@test"),   // person already has access: expired
      invite("other-ws", "w2", "g1@test"),  // access is per Workspace: kept
      invite("no-access", "w1", "g2@test"), // nobody has access yet: kept
    ].join("\n"));
    copyFileSync(join(real, "0021_active_access_excludes_invitation.sql"), join(dir, "0021_active_access_excludes_invitation.sql"));
    expect((await migrate(sql as any, dir)).applied).toEqual(["0021_active_access_excludes_invitation.sql"]);
    const status = new Map((await sql.unsafe("SELECT id, status FROM workspace_invitations")).map((r: any) => [r.id, r.status]));
    expect(status.get("overlap")).toBe("expired");
    expect(status.get("other-ws")).toBe("pending");
    expect(status.get("no-access")).toBe("pending");
    await expect(sql.unsafe(invite("new", "w1", "g1@test"))).rejects.toMatchObject({ constraint: "workspace_invitations_no_active_grant" });
    // Reviving an ended invitation is a new pending invitation too.
    await expect(sql.unsafe("UPDATE workspace_invitations SET status='pending' WHERE id='overlap'")).rejects.toMatchObject({ constraint: "workspace_invitations_no_active_grant" });
    // Granting access ends the person's pending invitation and keeps its row.
    await sql.unsafe(grant("w1", "g2"));
    expect((await sql.unsafe("SELECT status FROM workspace_invitations WHERE id='no-access'"))[0].status).toBe("expired");
  });
});

describe("0022 plan approvals", () => {
  test("existing approvals are backfilled from the queue and from sent phases; a second claim is rejected", async () => {
    const real = new URL("../migrations/", import.meta.url).pathname;
    const dir = mkdtempSync(join(tmpdir(), "syntila-0022-"));
    for (const f of readdirSync(real).filter((f) => /^\d{4}_.*\.sql$/.test(f) && f < "0022")) copyFileSync(join(real, f), join(dir, f));
    const sql = await emptyDatabase();
    await migrate(sql as any, dir);
    const wr = (id: string, workflow: string, input: unknown, created: string) =>
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
       VALUES ('${id}','t1','u1','stateless','${workflow}',2,'{}','{}','completed','${JSON.stringify(input)}','${created}','${created}');`;
    const queued = (id: string, plan: string, author: string, created: string) =>
      `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
       VALUES ('${id}','t1','${author}','${JSON.stringify({ planWorkRequestId: plan })}',${Number(id.slice(1))},'queued','${created}','${created}');`;
    await sql.unsafe([
      user("u1"), space("s1", "u1"), thread("t1", "s1", "u1"),
      wr("plan-queue", "plan_implement", {}, "2026-01-01T00:00:00Z"),   // phases still queued
      wr("plan-sent", "plan_implement", {}, "2026-01-01T00:00:00Z"),    // phases already sent
      wr("plan-none", "plan_implement", {}, "2026-01-01T00:00:00Z"),    // never approved
      wr("phase-1", "direct", { planWorkRequestId: "plan-sent" }, "2026-02-01T00:00:00Z"),
      queued("q1", "plan-queue", "u1", "2026-03-02T00:00:00Z"),
      queued("q2", "plan-queue", "u1", "2026-03-01T00:00:00Z"),
      queued("q3", "plan-gone", "u1", "2026-03-01T00:00:00Z"),          // plan row no longer exists: no claim
    ].join("\n"));
    copyFileSync(join(real, "0022_plan_approvals.sql"), join(dir, "0022_plan_approvals.sql"));
    expect((await migrate(sql as any, dir)).applied).toEqual(["0022_plan_approvals.sql"]);
    const rows = await sql.unsafe("SELECT plan_work_request_id AS id, approved_by_user_id AS by, created_at FROM plan_approvals ORDER BY 1");
    expect(rows.map((r: any) => r.id)).toEqual(["plan-queue", "plan-sent"]);
    // The earliest evidence gives the time.
    expect(new Date(rows[0].created_at).toISOString()).toBe("2026-03-01T00:00:00.000Z");
    expect(new Date(rows[1].created_at).toISOString()).toBe("2026-02-01T00:00:00.000Z");
    // The source rows are untouched.
    expect((await sql.unsafe("SELECT count(*)::int AS n FROM thread_request_queue"))[0].n).toBe(3);
    // The claim survives the queue being emptied, and cannot be taken twice.
    await sql.unsafe("DELETE FROM thread_request_queue");
    await expect(sql.unsafe("INSERT INTO plan_approvals(plan_work_request_id,thread_id,approved_by_user_id) VALUES ('plan-queue','t1','u1')"))
      .rejects.toMatchObject({ constraint: "plan_approvals_pkey" });
    await sql.unsafe("INSERT INTO plan_approvals(plan_work_request_id,thread_id,approved_by_user_id) VALUES ('plan-none','t1','u1')");
  });
});
