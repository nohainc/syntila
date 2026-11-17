/**
 * The duplicate-statement detector (scripts/dup-statements.ts): it must find
 * identical SQL repeated in one file, and must never call two statements the
 * same when they differ in anything that can change what they do.
 */
import { expect, test } from "bun:test";
import { join } from "node:path";
import { extractStatements, groupDuplicates, groupAcrossFiles, normalizeSql, scan, scanWithSkips, summarize } from "../scripts/dup-statements";

const groups = (source: string) => groupDuplicates(extractStatements(source, "f.ts"));

test("normalization drops comments and whitespace and renumbers placeholders by first appearance", () => {
  expect(normalizeSql("SELECT  a\n FROM t -- trailing\n WHERE id = ?1 /* why */ AND x = ?2")).toBe("SELECT a FROM t WHERE id = $1 AND x = $2");
  // ?3/?3 and $1/$1 are the same shape; ?1/?2 is not.
  expect(normalizeSql("A = ?3 AND B = ?3")).toBe(normalizeSql("A = $1 AND B = $1"));
  expect(normalizeSql("A = ?1 AND B = ?2")).not.toBe(normalizeSql("A = ?1 AND B = ?1"));
  // Text inside quotes is kept exactly, including spacing and comment-like text.
  expect(normalizeSql("SELECT 'a  --b' , \"Weird  Col\"")).toBe("SELECT 'a  --b' , \"Weird  Col\"");
  expect(normalizeSql("SELECT 'it''s  ok'")).toBe("SELECT 'it''s  ok'");
});

test("identical statements in one file are grouped with their line numbers", () => {
  const found = groups(`
    db.prepare("SELECT id FROM users WHERE id = ?1").bind(a).first();
    db.prepare(\`SELECT id
       FROM users   WHERE id = ?1 -- same\`).bind(b).first();
    tx.unsafe("SELECT id FROM users WHERE id = $1", [c]);
    db.prepare("SELECT name FROM users WHERE id = ?1");
  `);
  expect(found).toHaveLength(1);
  expect(found[0]!.lines).toEqual([2, 3, 5]);
});

test("statements that differ in anything meaningful are not grouped", () => {
  const same = (a: string, b: string) => groups(`db.prepare(${JSON.stringify(a)}); db.prepare(${JSON.stringify(b)});`).length === 1;
  expect(same("SELECT id FROM t WHERE id = ?1", "SELECT id FROM t WHERE id = ?1 FOR UPDATE")).toBe(false); // locking clause
  expect(same("SELECT id FROM t WHERE id = ?1", "SELECT id FROM t WHERE id = ?1::text")).toBe(false); // cast
  expect(same("SELECT id FROM t WHERE a = ?1", "SELECT id FROM t WHERE b = ?1")).toBe(false); // predicate
  expect(same("SELECT id FROM t WHERE a = ?1 AND b = ?1", "SELECT id FROM t WHERE a = ?1 AND b = ?2")).toBe(false); // repeated parameter
  expect(same("SELECT id FROM t WHERE s = 'a'", "SELECT id FROM t WHERE s = 'b'")).toBe(false); // literal
  expect(same("SELECT id FROM t WHERE s = 'a b'", "SELECT id FROM t WHERE s = 'a  b'")).toBe(false); // spacing inside a literal
  expect(same("SELECT id FROM t WHERE x IN (1)", "SELECT id FROM t WHERE x IN (1, 2)")).toBe(false);
  expect(same("SELECT id FROM t ORDER BY a", "SELECT id FROM t ORDER BY a DESC")).toBe(false);
  // And the genuinely identical pair is grouped, so the checks above can fail.
  expect(same("SELECT id FROM t WHERE id = ?1", "SELECT  id FROM t\nWHERE id = ?1")).toBe(true);
});

test("interpolated SQL text is part of the key and flagged dynamic", () => {
  const a = groups("db.prepare(`SELECT * FROM ${table} WHERE id = ?1`); db.prepare(`SELECT * FROM ${table} WHERE id = ?1`);");
  expect(a).toHaveLength(1);
  expect(a[0]!.dynamic).toBe(true);
  expect(groups("db.prepare(`SELECT * FROM ${a} WHERE id = ?1`); db.prepare(`SELECT * FROM ${b} WHERE id = ?1`);")).toHaveLength(0);
  // A `+` chain is resolved when its parts are literals, and keeps an expression's text otherwise.
  expect(groups(`db.prepare("SELECT 1 " + "FROM t"); db.prepare("SELECT 1 FROM t");`)).toHaveLength(1);
  expect(groups(`db.prepare("SELECT 1 FROM " + x); db.prepare("SELECT 1 FROM " + y);`)).toHaveLength(0);
});

test("tagged templates, with generic type arguments, are found; each value is a parameter", () => {
  const found = groups(`
    await tx.rows<Row>\`SELECT id FROM notes WHERE user_id = \${a}\`;
    await tx.rows<{ id: string }>\`SELECT id   FROM notes WHERE user_id = \${b}\`;
    await tx.row\`SELECT id FROM notes WHERE user_id = \${c}\`;
  `);
  expect(found).toHaveLength(1);
  expect(found[0]!.lines).toEqual([2, 3, 4]);
  // A value that is SQL (frag/list) is part of the text, not a parameter.
  expect(groups("q.rows`SELECT 1 WHERE ${q.frag`a = ${x}`}`; q.rows`SELECT 1 WHERE ${q.frag`b = ${x}`}`;")).toHaveLength(0);
});

test("comments, prose and unrelated strings are never mistaken for SQL", () => {
  const found = extractStatements(`
    // db.prepare("SELECT 1 FROM t")
    /* db.prepare("SELECT 1 FROM t") */
    console.log("SELECT 1 FROM t");
    const text = "UPDATE t SET a = 1";
    foo.prepare("hello world");
    url.query("x");
  `, "f.ts");
  expect(found).toEqual([]);
});

test("a shared module-level constant is one definition however many calls use it", () => {
  const src = `const GET = "SELECT id FROM t WHERE id = ?1";\ndb.prepare(GET).bind(a); db.prepare(GET).bind(b);`;
  const found = extractStatements(src, "f.ts");
  expect(found.filter((s) => s.viaConstant)).toHaveLength(2);
  expect(found.filter((s) => s.kind === "constant")).toHaveLength(1);
  expect(groupDuplicates(found)).toEqual([]);
  // The same SQL written inline next to the constant is still a duplicate definition.
  const again = groupDuplicates(extractStatements(src + `\ndb.prepare("SELECT id FROM t WHERE id = ?1");`, "f.ts"));
  expect(again).toHaveLength(1);
  expect(again[0]!.lines).toEqual([1, 3]);
});

test("unresolvable arguments are reported as skipped, not compared", () => {
  const skipped: any[] = [];
  const found = extractStatements("db.prepare(sql); db.prepare(sql); db.prepare(build(1));", "f.ts", skipped);
  expect(found).toEqual([]);
  expect(skipped).toHaveLength(3);
});

test("statements repeated across files are reported separately from same-file duplicates", () => {
  const a = extractStatements('db.prepare("SELECT 1 FROM t");', "a.ts");
  const b = extractStatements('db.prepare("SELECT 1 FROM t");', "b.ts");
  expect(groupDuplicates([...a, ...b])).toEqual([]);
  expect(groupAcrossFiles([...a, ...b])).toHaveLength(1);
});

test("the real source tree scans reproducibly and every group is a same-file repeat", () => {
  const src = join(import.meta.dir, "..", "src");
  const first = summarize(scan(src));
  const second = summarize(scan(src));
  expect(second.groups).toBe(first.groups);
  expect(second.excess).toBe(first.excess);
  for (const g of first.groupList) expect(g.lines.length).toBeGreaterThan(1);
});

// ---- Regression ceiling (Package 2, Phase 4) -----------------------------------
// Baseline before folding: 34 groups / 39 excess occurrences (claude/dup-statements-baseline.md).
// After folding: the groups below remain, each with its reason. A new duplicate,
// or one more occurrence of a retained one, fails this test: give the statement one
// named constant instead.
const RETAINED: Record<string, string> = {};
const CEILING = { groups: 0, excess: 0 };

test("no new duplicate statements: the ceiling holds and every remaining group is a documented exception", () => {
  const s = summarize(scan(join(import.meta.dir, "..", "src")));
  const files = [...new Set(s.groupList.map((g) => g.file))];
  expect(files.filter((f) => !(f in RETAINED))).toEqual([]);
  expect(s.groups).toBeLessThanOrEqual(CEILING.groups);
  expect(s.excess).toBeLessThanOrEqual(CEILING.excess);
});
