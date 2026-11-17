/**
 * For tests whose fake database routes on SQL text: gives the fake a `sql`
 * tagged-template function, so the tagged data layer (`dataOf`) can run on it.
 * Placeholders arrive as ?1, ?2 … in order, like the former prepare/bind calls.
 * Fragments embedded in another statement are inlined, not executed.
 */
type Statement = { bind(...v: unknown[]): any; all?: () => any; first?: () => any; run?: () => any };
type FakeDb = { prepare(sql: string): Statement; sql?: unknown };

class Piece implements PromiseLike<any> {
  constructor(readonly text: string, readonly values: unknown[], private readonly exec: (t: string, v: unknown[]) => Promise<any>) {}
  then<A, B>(ok?: (v: any) => A, bad?: (e: unknown) => B) {
    return this.exec(this.text, this.values).then(ok, bad);
  }
}

export function withSql<T>(fake: T): T {
  const db = fake as unknown as FakeDb;
  const exec = async (text: string, values: unknown[]) => {
    if (process.env.FAKE_SQL_DEBUG) console.log("FAKE_SQL", text.replace(/\s+/g, " ").slice(0, 160));
    const st = db.prepare(text).bind(...values);
    const write = /^\s*(INSERT|UPDATE|DELETE)\b/i.test(text) && !/\bRETURNING\b/i.test(text);
    if (write && st.run) {
      const r = await st.run();
      const out: any = [];
      out.count = Number(r?.meta?.changes ?? r?.changes ?? (r?.success === false ? 0 : 1));
      return out;
    }
    const all = st.all ? await st.all() : { results: [] };
    let rows: any[] = Array.isArray(all) ? all : (all?.results ?? []);
    if (!rows.length && st.first) {
      const one = await st.first();
      if (one) rows = [one];
    }
    const out: any = [...rows];
    out.count = rows.length;
    return out;
  };
  const build = (strings: TemplateStringsArray | readonly unknown[], values: unknown[]) => {
    let text = "";
    const params: unknown[] = [];
    const parts = strings as readonly string[];
    parts.forEach((s, i) => {
      text += s;
      if (i >= values.length) return;
      const v = values[i];
      if (v instanceof Piece) {
        const base = params.length;
        text += v.text.replace(/\?(\d+)/g, (_m, n) => `?${base + Number(n)}`);
        params.push(...v.values);
      } else if (v && typeof v === "object" && (v as any).raw !== undefined) {
        text += (v as any).raw;
      } else if (Array.isArray(v)) {
        text += `(${v.map((x) => { params.push(x); return `?${params.length}`; }).join(", ")})`;
      } else {
        params.push(v);
        text += `?${params.length}`;
      }
    });
    return new Piece(text, params, exec);
  };
  const sql: any = (strings: any, ...values: unknown[]) =>
    Array.isArray(strings) && "raw" in strings ? build(strings, values) : strings;
  sql.unsafe = (text: string) => ({ raw: text });
  db.sql = sql;
  return fake;
}

/**
 * For a test env with a hand-written `SYNTILA_DATA` fake next to a text-routing
 * `SYNTILA_DB` fake: whatever the data fake answers with no rows is answered
 * by the text-routing fake instead.
 */
export function chainData<T extends { SYNTILA_DATA?: any; SYNTILA_DB?: any }>(env: T): T {
  const primary = env.SYNTILA_DATA.sql;
  const fallback = withSql(env.SYNTILA_DB).sql;
  const chained: any = async (strings: any, ...values: unknown[]) => {
    const first = await primary(strings, ...values);
    if (!Array.isArray(strings) || !("raw" in strings)) return first;
    if (Array.isArray(first) && first.length === 0) return await fallback(strings, ...values);
    return first;
  };
  chained.unsafe = primary.unsafe?.bind(primary);
  chained.begin = primary.begin?.bind(primary);
  env.SYNTILA_DATA = new (env.SYNTILA_DATA.constructor)(chained);
  return env;
}

/** A data-layer Tx over a text-routing fake database: statements run through the fake, nothing is transactional. */
export function fakeTx(db: unknown): any {
  const holder = db as { sql?: any };
  const sql = holder.sql ?? (withSql(db as never) as any).sql;
  return {
    run: async (s: any, ...v: unknown[]) => Number((await sql(s, ...v)).count ?? 0),
    row: async (s: any, ...v: unknown[]) => (await sql(s, ...v))[0] ?? null,
    rows: async (s: any, ...v: unknown[]) => [...(await sql(s, ...v))],
    lock: async () => {},
    afterCommit: () => {},
  };
}
