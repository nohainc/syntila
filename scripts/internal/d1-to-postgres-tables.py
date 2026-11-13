#!/usr/bin/env python3
"""Converts the final D1 (SQLite) schema to a PostgreSQL initial migration.

Tables and indexes are converted textually; triggers are emitted separately
(hand-ported PL/pgSQL). Type policy for the port:
  *_at TEXT            -> timestamptz (adapter returns ISO-8601 strings)
  INTEGER (0/1 check)  -> smallint     (code compares with 0/1)
  other INTEGER        -> bigint
  REAL                 -> double precision
  TEXT / *_json TEXT   -> text (+ IS JSON checks); hot JSON columns move to jsonb later
"""
import re, sys
from graphlib import TopologicalSorter

src = open(sys.argv[1]).read()
stmts = [x.strip() for x in src.split(';\n\n') if x.strip()]
tables = {re.match(r'CREATE TABLE "?(\w+)"?', s).group(1): s for s in stmts if s.startswith('CREATE TABLE')}
indexes = [s for s in stmts if s.startswith('CREATE') and ' INDEX ' in s.split('(')[0]]
DROP_TABLES = {t for t in tables if t.startswith('__')}

def glob_to_regex(g):
    out = '^'
    i = 0
    while i < len(g):
        c = g[i]
        if c == '*': out += '.*'
        elif c == '?': out += '.'
        elif c == '[':
            j = g.index(']', i)
            body = g[i + 1:j]
            if body.startswith('^'): body = '^' + body[1:]
            out += '[' + body + ']'
            i = j
        else: out += re.escape(c)
        i += 1
    return out + '$'

def convert_expr(sql):
    sql = re.sub(r"json_extract\(profile_json, '\$\.schemaVersion'\) = schema_version", "(profile_json::jsonb ->> 'schemaVersion') = schema_version::text", sql)
    sql = re.sub(r"json_extract\(([\w.]+),\s*'\$\.([\w.]+)'\)", lambda m: f"({m.group(1)}::jsonb #>> '{{{m.group(2).replace('.', ',')}}}')", sql)
    sql = re.sub(r"json_valid\((\w+)\)", r"(\1 IS JSON)", sql)
    sql = re.sub(r"json_type\((\w+)\)\s*=\s*'object'", r"(\1 IS JSON OBJECT)", sql)
    sql = re.sub(r"json_type\((\w+)\)\s*=\s*'array'", r"(\1 IS JSON ARRAY)", sql)
    sql = re.sub(r"typeof\((\w+)\)\s*=\s*'integer'", "TRUE", sql)
    sql = re.sub(r"(\w+)\s+NOT GLOB\s+'([^']*)'", lambda m: f"{m.group(1)} !~ '{glob_to_regex(m.group(2))}'", sql)
    sql = re.sub(r"(\w+)\s+GLOB\s+'([^']*)'", lambda m: f"{m.group(1)} ~ '{glob_to_regex(m.group(2))}'", sql)
    sql = sql.replace("DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", "DEFAULT now()")
    sql = sql.replace("DEFAULT ('history-' || lower(hex(randomblob(16))))", "DEFAULT ('history-' || replace(gen_random_uuid()::text, '-', ''))")
    return sql

def convert_table(name, sql):
    body = re.sub(r'--[^\n]*', '', sql[sql.index('(') + 1: sql.rindex(')')])
    lines = []
    for raw in split_top(body):
        part = raw.strip()
        m = re.match(r'"?(\w+)"?\s+(TEXT|INTEGER|REAL|BLOB|NUMERIC)\b(.*)$', part, re.S)
        if m and m.group(1).upper() not in ('PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN', 'CONSTRAINT'):
            col, typ, rest = m.groups()
            if typ == 'TEXT' and (col.endswith('_at') or col.endswith('_since') or col == 'current_period_end'):
                pg = 'timestamptz'
                # timestamps compared against '' or using string functions are left as text
            elif typ == 'INTEGER' and re.search(rf'\b{col}\s+IN\s*\(\s*0\s*,\s*1\s*\)', body):
                pg = 'smallint'
            elif typ == 'INTEGER':
                pg = 'bigint'
            elif typ == 'REAL':
                pg = 'double precision'
            elif typ == 'BLOB':
                pg = 'bytea'
            else:
                pg = 'text'
            rest = rest.replace('AUTOINCREMENT', '')
            if pg == 'smallint':
                rest = re.sub(r"DEFAULT\s+'?(0|1)'?", r'DEFAULT \1', rest)
            part = f'"{col}" {pg}{convert_expr(rest)}' if col.lower() in RESERVED else f'{col} {pg}{convert_expr(rest)}'
        else:
            part = convert_expr(part)
        lines.append('  ' + part.strip())
    return f'CREATE TABLE {name} (\n' + ',\n'.join(lines) + '\n);'

RESERVED = {'references', 'user', 'order', 'group', 'check', 'default', 'limit', 'offset', 'position', 'role', 'end', 'window'}

def split_top(body):
    parts, depth, cur, quote = [], 0, '', False
    for ch in body:
        if ch == "'" : quote = not quote
        if not quote:
            if ch == '(': depth += 1
            elif ch == ')': depth -= 1
            elif ch == ',' and depth == 0:
                parts.append(cur); cur = ''; continue
        cur += ch
    if cur.strip(): parts.append(cur)
    # strip SQL comments
    return [re.sub(r'--[^\n]*', '', p) for p in parts if re.sub(r'--[^\n]*', '', p).strip()]

deps = {}
for name, sql in tables.items():
    if name in DROP_TABLES: continue
    deps[name] = {r for r in re.findall(r'REFERENCES\s+"?(\w+)"?', sql) if r != name and r in tables and r not in DROP_TABLES}
order = list(TopologicalSorter(deps).static_order())

out = ['-- Syntila initial PostgreSQL schema (generated from the final D1 schema, then reviewed).',
       '-- Regenerate: python3 scripts/internal/d1-to-postgres-schema.py',
       '']
for name in order:
    out.append(convert_table(name, tables[name]))
    out.append('')
for idx in indexes:
    tbl = re.search(r' ON "?(\w+)"?', idx).group(1)
    if tbl in DROP_TABLES: continue
    idx = re.sub(r'\bMIN\((\w+), (\w+)\)', r'(LEAST(\1, \2))', idx)
    idx = re.sub(r'\bMAX\((\w+), (\w+)\)', r'(GREATEST(\1, \2))', idx)
    out.append(convert_expr(idx.replace('"', '')) + ';')
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
print(f'{len(order)} tables, {len(indexes)} indexes')
