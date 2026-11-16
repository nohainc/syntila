/**
 * Finds SQL statements whose text appears more than once in one file, so each
 * can get one definition. Syntax-aware: the TypeScript parser finds the calls,
 * so comments, unrelated strings and test fixtures in prose are never mistaken
 * for SQL.
 *
 * Sources of SQL:
 *   .prepare(sql) .query(sql) .unsafe(sql)   the first argument, when it is a
 *       string, a template or a `+` chain of those that starts like SQL
 *   rows`..` row`..` run`..` frag`..`        the data layer's tagged templates
 *       (generic type arguments such as rows<Row>`..` are handled)
 *
 * Normalization is conservative: it only removes what cannot change meaning.
 *   - SQL comments are dropped; whitespace outside quoted text is collapsed
 *   - `?N` and `$N` placeholders are renumbered by first appearance (so ?3 ... ?3
 *     matches $1 ... $1, but ?1 ... ?2 does not match ?1 ... ?1)
 *   - quoted text ('..' and ".."), casts, locking clauses (FOR UPDATE), predicates,
 *     keywords' case and every interpolated expression are kept as written
 * A statement built with `${...}` inside .prepare/.query/.unsafe is "dynamic":
 * its interpolated source text is part of the key, and it is reported on its own.
 *
 * Usage: bun scripts/dup-statements.ts [--json] [--cross-file] [--min-length N] [--all]
 *   default: groups that repeat inside one file; --cross-file also lists texts
 *   repeated across files; --all prints statement counts per kind too.
 */
import ts from "typescript";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

export type Kind = "prepare" | "query" | "unsafe" | "tagged" | "constant";

export interface Statement {
  readonly file: string;
  readonly line: number;
  readonly kind: Kind;
  /** Normalized text: the comparison key. */
  readonly sql: string;
  /** True when `${...}` text is part of an .prepare/.query/.unsafe statement. */
  readonly dynamic: boolean;
  /** A call whose argument is a module-level SQL constant: a use, not a definition (never a duplicate). */
  readonly viaConstant?: boolean;
}

export interface Group {
  readonly file: string;
  readonly sql: string;
  readonly dynamic: boolean;
  readonly lines: readonly number[];
}

const SQL_START = /^\s*(?:--[^\n]*\n\s*)*(?:\(\s*)*(SELECT|INSERT|UPDATE|DELETE|WITH|CREATE|ALTER|DROP|BEGIN|COMMIT|ROLLBACK|SET|LOCK|TRUNCATE|VALUES|EXPLAIN|ANALYZE|REINDEX|VACUUM|DO|COPY|SAVEPOINT|RELEASE)\b/i;
const TAGS = new Set(["rows", "row", "run", "frag"]);

/** Comments dropped, whitespace collapsed outside quotes, placeholders renumbered by first appearance. */
export function normalizeSql(input: string): string {
  let out = "";
  let i = 0;
  const seen = new Map<string, number>();
  let bare = 0;
  const space = () => {
    if (!out.endsWith(" ")) out += " ";
  };
  const placeholder = (key: string) => {
    if (!seen.has(key)) seen.set(key, seen.size + 1);
    return `$${seen.get(key)}`;
  };
  while (i < input.length) {
    const c = input[i]!;
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < input.length) {
        if (input[j] === c) {
          if (input[j + 1] === c) j += 2; // doubled quote
          else break;
        } else j++;
      }
      out += input.slice(i, j + 1);
      i = j + 1;
    } else if (c === "-" && input[i + 1] === "-") {
      while (i < input.length && input[i] !== "\n") i++;
    } else if (c === "/" && input[i + 1] === "*") {
      const end = input.indexOf("*/", i + 2);
      i = end === -1 ? input.length : end + 2;
      space();
    } else if ((c === "?" || c === "$") && /\d/.test(input[i + 1] ?? "")) {
      let j = i + 1;
      while (/\d/.test(input[j] ?? "")) j++;
      out += placeholder(`n${input.slice(i + 1, j)}`);
      i = j;
    } else if (c === "?") {
      out += placeholder(`b${bare++}`);
      i++;
    } else if (/\s/.test(c)) {
      while (/\s/.test(input[i] ?? "")) i++;
      space();
    } else {
      out += c;
      i++;
    }
  }
  return out.trim();
}

interface Resolved { text: string; dynamic: boolean }

/** The SQL text of an argument, or null when it is not built from literals/templates. */
function resolve(node: ts.Expression, sf: ts.SourceFile): Resolved | null {
  if (ts.isParenthesizedExpression(node)) return resolve(node.expression, sf);
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return { text: node.text, dynamic: false };
  if (ts.isTemplateExpression(node)) {
    let text = node.head.text;
    for (const span of node.templateSpans) text += `{{${span.expression.getText(sf).replace(/\s+/g, " ")}}}${span.literal.text}`;
    return { text, dynamic: true };
  }
  if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const left = resolve(node.left, sf);
    const right = resolve(node.right, sf);
    if (left && right) return { text: left.text + right.text, dynamic: left.dynamic || right.dynamic };
    // One side is an expression: keep its source text so different values never match.
    const l = left ?? { text: `{{${node.left.getText(sf).replace(/\s+/g, " ")}}}`, dynamic: true };
    const r = right ?? { text: `{{${node.right.getText(sf).replace(/\s+/g, " ")}}}`, dynamic: true };
    return { text: l.text + r.text, dynamic: true };
  }
  return null;
}

/** Statement text of a tagged template: each ${value} is one parameter, except SQL helpers (frag, raw, list) kept as written. */
function taggedText(node: ts.TaggedTemplateExpression, sf: ts.SourceFile): string {
  const t = node.template;
  if (ts.isNoSubstitutionTemplateLiteral(t)) return t.text;
  let text = t.head.text;
  let n = 0;
  for (const span of t.templateSpans) {
    const e = span.expression;
    const helper = (ts.isTaggedTemplateExpression(e) && TAGS.has(tagName(e.tag))) || (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && ["list", "raw"].includes(e.expression.name.text));
    text += helper ? `{{${e.getText(sf).replace(/\s+/g, " ")}}}` : `$${++n}`;
    text += span.literal.text;
  }
  return text;
}

function tagName(tag: ts.Expression): string {
  if (ts.isPropertyAccessExpression(tag)) return tag.name.text;
  if (ts.isIdentifier(tag)) return tag.text;
  return "";
}

export interface Skipped {
  readonly file: string;
  readonly line: number;
  readonly why: string;
  readonly text: string;
}

/** `skipped` collects SQL-looking calls whose text could not be resolved (a variable, a call): the uncertain ones. */
export function extractStatements(source: string, file: string, skipped?: Skipped[]): Statement[] {
  const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const out: Statement[] = [];
  // Module-level `const NAME = "SQL..."`: the one definition of a statement used by several calls.
  const constants = new Map<string, { text: string; line: number; dynamic: boolean }>();
  const usedConstants = new Set<string>();
  for (const st of sf.statements) {
    if (!ts.isVariableStatement(st) || !(st.declarationList.flags & ts.NodeFlags.Const)) continue;
    for (const d of st.declarationList.declarations) {
      if (!ts.isIdentifier(d.name) || !d.initializer) continue;
      const r = resolve(d.initializer, sf);
      if (r && SQL_START.test(r.text)) constants.set(d.name.text, { text: r.text, line: sf.getLineAndCharacterOfPosition(d.getStart(sf)).line + 1, dynamic: r.dynamic });
    }
  }
  const add = (node: ts.Node, kind: Kind, text: string, dynamic: boolean) => {
    if (!SQL_START.test(text)) {
      // Not recognizably SQL (for example a template that starts with ${...}): reported, never compared.
      if (skipped && kind === "prepare")
        skipped.push({ file, line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1, why: "does not start like SQL", text: text.replace(/\s+/g, " ").slice(0, 80) });
      return;
    }
    out.push({ file, line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1, kind, sql: normalizeSql(text), dynamic });
  };
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
      const name = node.expression.name.text;
      if ((name === "prepare" || name === "query" || name === "unsafe") && node.arguments[0]) {
        const arg = node.arguments[0];
        const r = resolve(arg, sf);
        if (r) add(node, name, r.text, r.dynamic);
        else if (ts.isIdentifier(arg) && constants.has(arg.text)) {
          usedConstants.add(arg.text);
          out.push({ file, line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1, kind: name, sql: normalizeSql(constants.get(arg.text)!.text), dynamic: constants.get(arg.text)!.dynamic, viaConstant: true });
        }
        else if (skipped && name === "prepare")
          skipped.push({ file, line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1, why: ts.SyntaxKind[node.arguments[0].kind], text: node.arguments[0].getText(sf).replace(/\s+/g, " ").slice(0, 80) });
      }
    } else if (ts.isTaggedTemplateExpression(node) && TAGS.has(tagName(node.tag))) {
      add(node, "tagged", taggedText(node, sf), false);
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  // A constant counts as a definition only when a query call uses it (a SQL-looking string alone is not a statement).
  for (const name of usedConstants) {
    const c = constants.get(name)!;
    out.push({ file, line: c.line, kind: "constant", sql: normalizeSql(c.text), dynamic: c.dynamic });
  }
  return out;
}

export function groupDuplicates(statements: readonly Statement[], minLength = 0): Group[] {
  const byKey = new Map<string, Statement[]>();
  for (const s of statements) {
    if (s.sql.length < minLength || s.viaConstant) continue;
    const key = `${s.file}\0${s.sql}`;
    (byKey.get(key) ?? byKey.set(key, []).get(key)!).push(s);
  }
  return [...byKey.values()]
    .filter((g) => g.length > 1)
    .map((g) => ({ file: g[0]!.file, sql: g[0]!.sql, dynamic: g.some((s) => s.dynamic), lines: g.map((s) => s.line).sort((a, b) => a - b) }))
    .sort((a, b) => a.file.localeCompare(b.file) || a.lines[0]! - b.lines[0]!);
}

/** SQL repeated across files (informational: a shared helper may be worth a module). */
export function groupAcrossFiles(statements: readonly Statement[], minLength = 0) {
  const byKey = new Map<string, Statement[]>();
  for (const s of statements) {
    if (s.sql.length < minLength || s.viaConstant) continue;
    (byKey.get(s.sql) ?? byKey.set(s.sql, []).get(s.sql)!).push(s);
  }
  return [...byKey.values()]
    .filter((g) => new Set(g.map((s) => s.file)).size > 1)
    .map((g) => ({ sql: g[0]!.sql, places: g.map((s) => `${s.file}:${s.line}`) }));
}

function listSources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? listSources(path) : name.endsWith(".ts") && !name.endsWith(".d.ts") ? [path] : [];
  }).sort();
}

export function scan(srcDir: string, root = join(srcDir, "..")): Statement[] {
  return scanWithSkips(srcDir, root).statements;
}

export function scanWithSkips(srcDir: string, root = join(srcDir, "..")): { statements: Statement[]; skipped: Skipped[] } {
  const skipped: Skipped[] = [];
  const statements = listSources(srcDir).flatMap((path) => extractStatements(readFileSync(path, "utf8"), relative(root, path), skipped));
  return { statements, skipped };
}

/** The numbers the report prints; the guard test uses `excess`. */
export function summarize(statements: readonly Statement[], minLength = 0) {
  const groups = groupDuplicates(statements, minLength);
  return {
    statements: statements.length,
    byKind: Object.fromEntries((["prepare", "query", "unsafe", "tagged", "constant"] as Kind[]).map((k) => [k, statements.filter((s) => s.kind === k).length])),
    dynamic: statements.filter((s) => s.dynamic).length,
    groups: groups.length,
    /** Occurrences beyond the first, summed: how many definitions folding removes. */
    excess: groups.reduce((n, g) => n + g.lines.length - 1, 0),
    files: new Set(groups.map((g) => g.file)).size,
    groupList: groups,
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const flag = (name: string) => args.includes(name);
  const minIdx = args.indexOf("--min-length");
  const minLength = minIdx >= 0 ? Number(args[minIdx + 1]) : 0;
  const src = join(import.meta.dir, "..", "src");
  const { statements, skipped } = scanWithSkips(src);
  const s = summarize(statements, minLength);
  if (flag("--json")) {
    console.log(JSON.stringify({ ...s, groupList: undefined, groups: s.groupList }, null, 2));
  } else {
    console.log(`statements: ${s.statements} (prepare ${s.byKind.prepare}, query ${s.byKind.query}, unsafe ${s.byKind.unsafe}, tagged ${s.byKind.tagged}, shared constants ${s.byKind.constant}); dynamic: ${s.dynamic}`);
    console.log(`same-file duplicate groups: ${s.groups} in ${s.files} files; excess occurrences: ${s.excess} (min length ${minLength})\n`);
    for (const g of s.groupList)
      console.log(`${g.file}  lines ${g.lines.join(", ")}${g.dynamic ? "  [dynamic]" : ""}\n    ${g.sql.length > 160 ? g.sql.slice(0, 157) + "..." : g.sql}`);
    console.log(`\nunresolved .prepare( arguments (not literals; not compared): ${skipped.length}`);
    if (flag("--all")) for (const k of skipped) console.log(`  ${k.file}:${k.line} ${k.why} ${k.text}`);
    if (flag("--cross-file")) {
      const cross = groupAcrossFiles(statements, minLength);
      console.log(`\nrepeated across files: ${cross.length}`);
      for (const c of cross) console.log(`  ${c.places.join(" ")}\n    ${c.sql.slice(0, 140)}`);
    }
  }
}
