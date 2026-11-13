/**
 * In-process host for the domain's Durable Object classes (WorkspaceGateway,
 * RealtimeGateway, ThreadExecutionCoordinator).
 *
 * It implements the subset of the Workers runtime they use:
 *  - namespaces: `idFromName`, `getByName`, `get(id)` → stub with `fetch`;
 *    one live instance per name, created lazily, evicted when idle;
 *  - `state.storage`: get/put/delete/list + alarms, persisted in PostgreSQL
 *    (`durable_object_storage`, `durable_object_alarms`) behind a write-through
 *    in-memory cache, so reads after writes are immediate as in a real DO;
 *  - hibernatable WebSockets: `WebSocketPair`, `acceptWebSocket`,
 *    `getWebSockets`, attachments and auto-responses, bridged to Bun's
 *    server WebSockets (`attachUpgrade` / the `websocket` handlers below).
 *
 * Single-node by design: a second node would need routing by object name.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import type { ServerWebSocket } from "bun";

type Sql = { unsafe(text: string, params?: unknown[]): Promise<any>; begin(fn: (tx: any) => Promise<unknown>): Promise<unknown> };

/* ------------------------------------------------------------- sockets */

const OPEN = 1, CLOSING = 2, CLOSED = 3;

/** Server end of a pair, owned by a Durable Object; bound to a Bun socket after upgrade. */
export class HostedWebSocket {
  readyState = 0; // CONNECTING until Bun opens the upgraded socket
  private bun: ServerWebSocket<UpgradeData> | null = null;
  private outbox: (string | ArrayBuffer | Uint8Array)[] = [];
  private attachment: unknown = null;
  owner: HostedObject | null = null;
  readonly isClientEnd: boolean;
  peer: HostedWebSocket | null = null;
  constructor(isClientEnd = false) { this.isClientEnd = isClientEnd; }

  get bufferedAmount() { return this.bun ? this.bun.getBufferedAmount() : 0; }
  serializeAttachment(value: unknown) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return this.attachment === null ? null : structuredClone(this.attachment); }
  accept() {}
  addEventListener() {}

  send(data: string | ArrayBuffer | ArrayBufferView) {
    if (this.readyState >= CLOSING) throw new Error("WebSocket is closed");
    const payload = typeof data === "string" || data instanceof ArrayBuffer ? data : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (this.bun) this.bun.send(payload as any);
    else this.outbox.push(payload);
  }

  close(code = 1000, reason = "") {
    if (this.readyState >= CLOSING) return;
    this.readyState = CLOSING;
    if (this.bun) this.bun.close(code, reason);
    else this.readyState = CLOSED;
  }

  /** @internal */ bind(ws: ServerWebSocket<UpgradeData>) {
    this.bun = ws;
    this.readyState = OPEN;
    for (const m of this.outbox.splice(0)) ws.send(m as any);
  }
  /** @internal */ markClosed() { this.readyState = CLOSED; this.bun = null; }
}

class WebSocketPairShim {
  0: HostedWebSocket;
  1: HostedWebSocket;
  constructor() {
    const client = new HostedWebSocket(true), server = new HostedWebSocket(false);
    client.peer = server; server.peer = client;
    this[0] = client; this[1] = server;
    upgradeContext.getStore()?.pairs.push({ client, server });
  }
}

class WebSocketRequestResponsePairShim {
  constructor(readonly request: string, readonly response: string) {}
}

/** Request-scoped record of sockets a Durable Object handed back with a 101. */
export const upgradeContext = new AsyncLocalStorage<{ pairs: { client: HostedWebSocket; server: HostedWebSocket }[] }>();

export function installWebSocketGlobals() {
  (globalThis as any).WebSocketPair ??= WebSocketPairShim;
  (globalThis as any).WebSocketRequestResponsePair ??= WebSocketRequestResponsePairShim;
}

export interface UpgradeData { hosted: HostedWebSocket }

/** Bun `websocket` handlers that deliver frames to the owning Durable Object. */
export const hostedWebSocketHandlers = {
  open(ws: ServerWebSocket<UpgradeData>) { ws.data.hosted.bind(ws); },
  async message(ws: ServerWebSocket<UpgradeData>, message: string | Buffer) {
    const hosted = ws.data.hosted, owner = hosted.owner;
    if (!owner) return;
    const data = typeof message === "string" ? message : message.buffer.slice(message.byteOffset, message.byteOffset + message.byteLength) as ArrayBuffer;
    if (typeof data === "string" && owner.autoResponse && data === owner.autoResponse.request) {
      hosted.send(owner.autoResponse.response);
      return;
    }
    await owner.deliver("webSocketMessage", hosted, data);
  },
  async close(ws: ServerWebSocket<UpgradeData>, code: number, reason: string) {
    const hosted = ws.data.hosted;
    hosted.markClosed();
    await hosted.owner?.deliver("webSocketClose", hosted, code, reason, true);
    hosted.owner?.sockets.delete(hosted);
  },
};

/* ------------------------------------------------------------ storage */

class HostedStorage {
  private cache = new Map<string, unknown>();
  private loaded: Promise<void> | null = null;
  private writes: Promise<unknown> = Promise.resolve();
  alarmAt: number | null = null;

  constructor(private sql: Sql, private ns: string, private name: string, private onAlarmChange: (at: number | null) => void) {}

  private load() {
    return (this.loaded ??= (async () => {
      const rows = await this.sql.unsafe("SELECT key, value FROM durable_object_storage WHERE namespace = $1 AND object_name = $2", [this.ns, this.name]);
      for (const r of rows) this.cache.set(r.key, r.value);
      const alarm = await this.sql.unsafe("SELECT at FROM durable_object_alarms WHERE namespace = $1 AND object_name = $2", [this.ns, this.name]);
      this.alarmAt = alarm[0] ? new Date(alarm[0].at).getTime() : null;
    })());
  }

  private persist(fn: () => Promise<unknown>) {
    // Writes are applied in order; a failure is logged, the cache stays authoritative for this process.
    this.writes = this.writes.then(fn).catch((e) => console.error(JSON.stringify({ level: "error", message: "durable_object.storage_write_failed", ns: this.ns, name: this.name, error: String(e) })));
    return this.writes;
  }

  async get<T>(keyOrKeys: string | string[]): Promise<any> {
    await this.load();
    if (Array.isArray(keyOrKeys)) {
      const out = new Map<string, T>();
      for (const k of keyOrKeys) if (this.cache.has(k)) out.set(k, structuredClone(this.cache.get(k)) as T);
      return out;
    }
    const v = this.cache.get(keyOrKeys);
    return v === undefined ? undefined : structuredClone(v);
  }

  async put(keyOrEntries: string | Record<string, unknown>, value?: unknown): Promise<void> {
    await this.load();
    const entries = typeof keyOrEntries === "string" ? { [keyOrEntries]: value } : keyOrEntries;
    for (const [k, v] of Object.entries(entries)) this.cache.set(k, structuredClone(v));
    await this.persist(() => this.sql.begin(async (tx) => {
      for (const [k, v] of Object.entries(entries)) {
        await tx.unsafe(`INSERT INTO durable_object_storage(namespace, object_name, key, value) VALUES ($1, $2, $3, $4::text::jsonb)
          ON CONFLICT (namespace, object_name, key) DO UPDATE SET value = excluded.value, updated_at = now()`, [this.ns, this.name, k, JSON.stringify(v)]);
      }
    }));
  }

  async delete(keyOrKeys: string | string[]): Promise<any> {
    await this.load();
    const keys = Array.isArray(keyOrKeys) ? keyOrKeys : [keyOrKeys];
    let n = 0;
    for (const k of keys) if (this.cache.delete(k)) n++;
    await this.persist(() => this.sql.unsafe("DELETE FROM durable_object_storage WHERE namespace = $1 AND object_name = $2 AND key = ANY($3::text[])", [this.ns, this.name, keys]));
    return Array.isArray(keyOrKeys) ? n : n > 0;
  }

  async deleteAll(): Promise<void> {
    await this.load();
    this.cache.clear();
    await this.persist(() => this.sql.unsafe("DELETE FROM durable_object_storage WHERE namespace = $1 AND object_name = $2", [this.ns, this.name]));
  }

  async list<T>(options: { prefix?: string; start?: string; end?: string; limit?: number; reverse?: boolean } = {}): Promise<Map<string, T>> {
    await this.load();
    let keys = [...this.cache.keys()].sort();
    if (options.prefix) keys = keys.filter((k) => k.startsWith(options.prefix!));
    if (options.start) keys = keys.filter((k) => k >= options.start!);
    if (options.end) keys = keys.filter((k) => k < options.end!);
    if (options.reverse) keys.reverse();
    if (options.limit) keys = keys.slice(0, options.limit);
    return new Map(keys.map((k) => [k, structuredClone(this.cache.get(k)) as T]));
  }

  async getAlarm(): Promise<number | null> { await this.load(); return this.alarmAt; }

  async setAlarm(at: number | Date): Promise<void> {
    await this.load();
    this.alarmAt = typeof at === "number" ? at : at.getTime();
    this.onAlarmChange(this.alarmAt);
    const iso = new Date(this.alarmAt).toISOString();
    await this.persist(() => this.sql.unsafe(`INSERT INTO durable_object_alarms(namespace, object_name, at) VALUES ($1, $2, $3)
      ON CONFLICT (namespace, object_name) DO UPDATE SET at = excluded.at`, [this.ns, this.name, iso]));
  }

  async deleteAlarm(): Promise<void> {
    await this.load();
    this.alarmAt = null;
    this.onAlarmChange(null);
    await this.persist(() => this.sql.unsafe("DELETE FROM durable_object_alarms WHERE namespace = $1 AND object_name = $2", [this.ns, this.name]));
  }

  sync() { return this.writes; }
}

/* ------------------------------------------------------------- objects */

interface DurableObjectLike {
  fetch(request: Request): Promise<Response>;
  alarm?(): Promise<void>;
  webSocketMessage?(ws: unknown, data: string | ArrayBuffer): unknown;
  webSocketClose?(ws: unknown, code: number, reason: string, wasClean: boolean): unknown;
  webSocketError?(ws: unknown, error: unknown): unknown;
}

class HostedObject {
  instance!: DurableObjectLike;
  storage: HostedStorage;
  sockets = new Set<HostedWebSocket>();
  autoResponse: WebSocketRequestResponsePairShim | null = null;
  inFlight = 0;
  lastUsed = Date.now();
  private alarmTimer: Timer | null = null;

  constructor(readonly ns: DurableObjectNamespaceHost, readonly name: string, sql: Sql) {
    this.storage = new HostedStorage(sql, ns.name, name, (at) => this.scheduleAlarm(at));
  }

  state() {
    const self = this;
    return {
      id: { name: this.name, toString: () => this.name, equals: (o: { name?: string }) => o?.name === this.name },
      storage: this.storage,
      acceptWebSocket(ws: HostedWebSocket) { ws.owner = self; self.sockets.add(ws); },
      getWebSockets() { return [...self.sockets].filter((s) => s.readyState <= OPEN); },
      setWebSocketAutoResponse(pair?: WebSocketRequestResponsePairShim) { self.autoResponse = pair ?? null; },
      getWebSocketAutoResponse() { return self.autoResponse; },
      blockConcurrencyWhile<T>(fn: () => Promise<T>) { return fn(); },
      waitUntil(p: Promise<unknown>) { void p.catch(() => {}); },
    };
  }

  async run<T>(fn: () => Promise<T>): Promise<T> {
    this.inFlight++; this.lastUsed = Date.now();
    try { return await fn(); } finally { this.inFlight--; this.lastUsed = Date.now(); }
  }

  deliver(method: "webSocketMessage" | "webSocketClose" | "webSocketError", ...args: unknown[]) {
    const handler = this.instance[method] as ((...a: unknown[]) => unknown) | undefined;
    if (!handler) return;
    return this.run(async () => { await handler.apply(this.instance, args); }).catch((e) =>
      console.error(JSON.stringify({ level: "error", message: `durable_object.${method}_failed`, ns: this.ns.name, name: this.name, error: String(e?.stack ?? e) })));
  }

  private scheduleAlarm(at: number | null) {
    if (this.alarmTimer) clearTimeout(this.alarmTimer);
    this.alarmTimer = null;
    if (at === null || !this.instance?.alarm) return;
    const delay = Math.max(0, Math.min(at - Date.now(), 2 ** 31 - 1));
    this.alarmTimer = setTimeout(() => void this.fireAlarm(at), delay);
  }

  async fireAlarm(at: number) {
    if (this.storage.alarmAt !== at) return;
    await this.storage.deleteAlarm();
    try {
      await this.run(() => this.instance.alarm!());
    } catch (e) {
      // Workers retries failed alarms with backoff; retry once a minute here.
      console.error(JSON.stringify({ level: "error", message: "durable_object.alarm_failed", ns: this.ns.name, name: this.name, error: String((e as Error)?.stack ?? e) }));
      if ((await this.storage.getAlarm()) === null) await this.storage.setAlarm(Date.now() + 60_000);
    }
  }

  idle(now: number) {
    return this.inFlight === 0 && this.sockets.size === 0 && this.storage.alarmAt === null && now - this.lastUsed > 15 * 60_000;
  }
}

export class DurableObjectNamespaceHost {
  private objects = new Map<string, HostedObject>();
  private sweeper: Timer;

  constructor(
    readonly name: string,
    private sql: Sql,
    private create: (state: ReturnType<HostedObject["state"]>, env: unknown) => DurableObjectLike,
    private env: () => unknown,
  ) {
    this.sweeper = setInterval(() => {
      const now = Date.now();
      for (const [k, o] of this.objects) if (o.idle(now)) this.objects.delete(k);
    }, 60_000);
    this.sweeper.unref?.();
  }

  private object(name: string): HostedObject {
    let o = this.objects.get(name);
    if (!o) {
      o = new HostedObject(this, name, this.sql);
      o.instance = this.create(o.state(), this.env());
      this.objects.set(name, o);
    }
    return o;
  }

  idFromName(name: string) { return { name, toString: () => name, equals: (o: { name?: string }) => o?.name === name }; }
  idFromString(id: string) { return this.idFromName(id); }
  newUniqueId() { return this.idFromName(crypto.randomUUID()); }

  get(id: { name?: string; toString(): string }) { return this.stub(id.name ?? id.toString()); }
  getByName(name: string) { return this.stub(name); }

  private stub(name: string) {
    return {
      id: this.idFromName(name),
      name,
      fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
        const request = input instanceof Request && !init ? input : new Request(input as any, init);
        const o = this.object(name);
        return o.run(() => o.instance.fetch(request));
      },
    };
  }

  /** Re-arms persisted alarms after a restart (objects are recreated on demand). */
  async restoreAlarms() {
    const rows = await this.sql.unsafe("SELECT object_name, at FROM durable_object_alarms WHERE namespace = $1", [this.name]);
    for (const r of rows) {
      const o = this.object(r.object_name);
      await o.storage.getAlarm();
      const at = new Date(r.at).getTime();
      setTimeout(() => void o.fireAlarm(at), Math.max(0, Math.min(at - Date.now(), 2 ** 31 - 1)));
    }
  }

  async flush() { await Promise.all([...this.objects.values()].map((o) => o.storage.sync())); }
  stop() { clearInterval(this.sweeper); }
  get size() { return this.objects.size; }
}
