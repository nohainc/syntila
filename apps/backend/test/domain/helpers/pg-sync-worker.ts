// Worker side of SyncPostgres: runs queries for the blocked main thread.
import { SQL } from "bun";
declare const self: Worker;
let sql: InstanceType<typeof SQL> | null = null;
self.onmessage = async (e: MessageEvent) => {
  const { url, text, params, multi, signal, buffer } = e.data as { url: string; text: string; params: unknown[]; multi: boolean; signal: SharedArrayBuffer; buffer: SharedArrayBuffer };
  const flag = new Int32Array(signal);
  let payload: unknown;
  try {
    sql ??= new SQL(url, { bigint: true, max: 1, connection: { lock_timeout: "5000" } });
    const rows: any = multi ? await sql.unsafe(text) : await sql.unsafe(text, params as any[]);
    payload = { ok: true, rows: Array.isArray(rows) ? rows : [], count: rows?.count ?? 0, command: rows?.command ?? "" };
  } catch (err: any) {
    payload = { ok: false, message: err?.message, code: err?.errno ?? err?.code, constraint: err?.constraint, table: err?.table, column: err?.column, detail: err?.detail };
  }
  const bytes = new TextEncoder().encode(JSON.stringify(payload, (_k, v) => typeof v === "bigint" ? Number(v) : typeof v === "boolean" ? (v ? 1 : 0) : v instanceof Date ? v.toISOString() : v));
  const view = new Uint8Array(buffer);
  if (bytes.length > view.length - 4) {
    const err = new TextEncoder().encode(JSON.stringify({ ok: false, message: "result too large for sync bridge" }));
    new DataView(buffer).setUint32(0, err.length); view.set(err, 4);
  } else { new DataView(buffer).setUint32(0, bytes.length); view.set(bytes, 4); }
  Atomics.store(flag, 0, 1);
  Atomics.notify(flag, 0);
};
