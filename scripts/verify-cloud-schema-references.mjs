import { readFile, readdir } from "node:fs/promises";
import { resolve, relative, extname } from "node:path";

const root = resolve(import.meta.dirname, "..");
const migrationsDirectory = resolve(root, "apps/cloud/migrations-v8");
const cloudSource = resolve(root, "apps/cloud/src");

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await filesUnder(path)));
    else if (extname(path) === ".ts") files.push(path);
  }
  return files;
}

function sqlStrings(source) {
  const values = [];
  for (let index = 0; index < source.length;) {
    if (source.startsWith("//", index)) {
      const end = source.indexOf("\n", index + 2);
      index = end < 0 ? source.length : end + 1;
      continue;
    }
    if (source.startsWith("/*", index)) {
      const end = source.indexOf("*/", index + 2);
      index = end < 0 ? source.length : end + 2;
      continue;
    }
    const quote = source[index];
    if (quote !== "'" && quote !== '"' && quote !== "`") {
      index += 1;
      continue;
    }
    const start = index++;
    let value = "";
    while (index < source.length) {
      const current = source[index++];
      if (current === "\\") {
        if (index < source.length) value += source[index++];
      } else if (current === quote) {
        break;
      } else {
        value += current;
      }
    }
    values.push({ value, offset: start });
  }
  return values;
}

function lineAt(source, offset) {
  let line = 1;
  for (let index = 0; index < offset; index += 1) {
    if (source[index] === "\n") line += 1;
  }
  return line;
}

const migrationFiles = (await readdir(migrationsDirectory))
  .filter((file) => file.endsWith(".sql"))
  .sort();
const knownTables = new Set();
for (const filename of migrationFiles) {
  const migration = await readFile(
    resolve(migrationsDirectory, filename),
    "utf8",
  );
  const tableOperations =
    /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?([\w]+)|DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?["`]?([\w]+)|ALTER\s+TABLE\s+["`]?([\w]+)["`]?\s+RENAME\s+TO\s+["`]?([\w]+)/gi;
  for (const match of migration.matchAll(tableOperations)) {
    if (match[1]) {
      const tableName = match[1].toLowerCase();
      if (!tableName.startsWith("__migration_")) knownTables.add(tableName);
    } else if (match[2]) {
      knownTables.delete(match[2].toLowerCase());
    } else if (match[3] && match[4]) {
      const oldName = match[3].toLowerCase();
      const newName = match[4].toLowerCase();
      const oldWasKnown = knownTables.delete(oldName);
      if (oldWasKnown || !newName.startsWith("__migration_")) {
        knownTables.add(newName);
      }
    }
  }
}
const sources = await filesUnder(cloudSource);
const errors = [];
const tableReference =
  /\b(?:FROM|JOIN|INTO|DELETE\s+FROM)\s+["`]?([a-z_][\w]*)|\bUPDATE\s+(?!SET\b)["`]?([a-z_][\w]*)/gi;
const cteDeclaration =
  /(?:\bWITH|,)\s*(?:RECURSIVE\s+)?([a-z_][\w]*)\s+AS\s*\(/gi;
const sqlFunctions = new Set(["json_each", "json_tree", "pragma_table_info"]);

for (const path of sources) {
  const source = await readFile(path, "utf8");
  for (const literal of sqlStrings(source)) {
    const sql = literal.value.replace(/--[^\n]*|\/\*[\s\S]*?\*\//g, " ");
    if (
      !/^\s*(?:SELECT|INSERT|UPDATE|DELETE|WITH|REPLACE|CREATE|PRAGMA)\b/i.test(
        sql,
      )
    )
      continue;
    const ctes = new Set(
      [...sql.matchAll(cteDeclaration)].map((match) => match[1].toLowerCase()),
    );
    for (const match of sql.matchAll(tableReference)) {
      const table = (match[1] ?? match[2]).toLowerCase();
      if (table === "set") continue;
      if (
        knownTables.has(table) ||
        ctes.has(table) ||
        sqlFunctions.has(table) ||
        table.startsWith("pragma_")
      ) {
        continue;
      }
      errors.push(
        `${relative(root, path)}:${lineAt(source, literal.offset + match.index)} references unknown v8 table '${table}'`,
      );
    }
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exitCode = 1;
} else {
  console.log(
    `Cloud SQL table references match the v8 schema (${knownTables.size} tables).`,
  );
}
