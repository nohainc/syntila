// Shared human REST and realtime clients for operational scripts.
import { signToken } from "../../src/auth";

export type Jwk = JsonWebKey & { kid: string };
export const sleep = (ms: number) => Bun.sleep(ms);

export async function waitFor<T>(what: string, probe: () => T | undefined | null | false | Promise<T | undefined | null | false>, ms = 15_000): Promise<T> {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    const value = await probe();
    if (value) return value;
    await sleep(25);
  }
  throw new Error(`timed out waiting for ${what}`);
}

export function tokenMinter(jwk: Jwk) {
  const iss = process.env.AUTH_JWT_ISSUER || "https://syntila.app";
  const aud = process.env.AUTH_JWT_AUDIENCE || "syntila-backend";
  return (sub: string, extra: Record<string, unknown> = {}, ttl = 900) => {
    const now = Math.floor(Date.now() / 1000);
    return signToken(jwk, { iss, aud, sub, typ: "user", email: `${sub}@syntila.invalid`, name: sub, iat: now, exp: now + ttl, sid: `s-${sub}-${now}`, client: "web", ...extra });
  };
}

const ORIGIN = (process.env.ALLOWED_ORIGINS ?? "https://syntila.app").split(",")[0]!.trim();

export class User {
  constructor(readonly base: string, readonly token: string) {}

  async api(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
    const response = await fetch(this.base + path, {
      method,
      headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json", origin: ORIGIN, "idempotency-key": crypto.randomUUID(), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let parsed: any = text;
    try { parsed = text ? JSON.parse(text) : null; } catch { /* plain text */ }
    return { status: response.status, body: parsed };
  }

  /** Creates a Space and returns it with a Thread to talk in. */
  async spaceWithThread(name: string) {
    const created = await this.api("POST", "/api/spaces", { name });
    if (created.status !== 201) throw new Error(`create space: ${created.status} ${JSON.stringify(created.body)}`);
    const spaceId: string = created.body.space.id;
    const listed = await this.api("GET", `/api/spaces/${spaceId}/threads`);
    let threadId: string | undefined = listed.body?.threads?.[0]?.id;
    if (!threadId) {
      const thread = await this.api("POST", `/api/spaces/${spaceId}/threads`, { name: "General" });
      threadId = thread.body?.thread?.id ?? thread.body?.id;
    }
    if (!threadId) throw new Error("no thread");
    return { spaceId, threadId };
  }

  /** Browser realtime connection that reconnects with a fresh ticket. */
  realtime(subscribeTo: string[]) {
    const state = { frames: [] as any[], opens: 0, closes: [] as number[], socket: null as WebSocket | null, stopped: false };
    const connect = async () => {
      if (state.stopped) return;
      const ticket = await this.api("POST", "/api/realtime/tickets").catch(() => null);
      if (!ticket || ticket.status !== 200) { setTimeout(connect, 500); return; }
      const ws = new WebSocket(`${this.base.replace(/^http/, "ws")}/api/realtime?ticket=${ticket.body.ticket}`, { headers: { origin: ORIGIN } } as any);
      state.socket = ws;
      ws.onmessage = (event) => {
        const frame = JSON.parse(String(event.data));
        state.frames.push(frame);
        if (frame.type === "realtime.ready") {
          state.opens++;
          for (const spaceId of subscribeTo) {
            ws.send(JSON.stringify({
              protocol: "syntila.messaging/1",
              requestId: `sub-${spaceId}`,
              type: "command",
              command: "subscription.subscribe",
              payload: { stream: { kind: "space", id: spaceId }, cursor: 0 },
            }));
          }
        }
      };
      ws.onclose = (event) => { state.closes.push(event.code); if (!state.stopped) setTimeout(connect, 250 + Math.random() * 250); };
      ws.onerror = () => {};
    };
    void connect();
    return {
      state,
      waitFor: (what: string, predicate: (frame: any) => boolean, ms?: number) => waitFor(what, () => state.frames.find(predicate), ms),
      close() { state.stopped = true; state.socket?.close(); },
    };
  }
}

export type Client = { user: User; spaceId: string; threadId: string; live: ReturnType<User["realtime"]> };

/** Posts `messages` discussion messages per client concurrently and waits for each realtime fan-out event. */
export async function runMessagePosts(clients: Client[], messages: number, prefix: string) {
  const rest: number[] = [], fanout: number[] = [];
  let errors = 0;
  const t0 = performance.now();
  await Promise.all(clients.map(async (c) => {
    for (let m = 0; m < messages; m++) {
      const marker = `${prefix}-${m}-${crypto.randomUUID().slice(0, 8)}`;
      const start = performance.now();
      const mark = c.live.state.frames.length;
      const posted = await c.user.api("POST", `/api/threads/${c.threadId}/discussion-messages`, { body: marker });
      rest.push(performance.now() - start);
      if (posted.status >= 300) { errors++; continue; }
      const id = posted.body?.message?.id ?? posted.body?.id;
      await waitFor("fan-out", () => c.live.state.frames.slice(mark).find((f) => JSON.stringify(f).includes(id ?? c.threadId)), 15_000)
        .then(() => fanout.push(performance.now() - start)).catch(() => { errors++; });
    }
  }));
  const seconds = (performance.now() - t0) / 1000;
  return { rest, fanout, errors, seconds, throughput: seconds > 0 ? rest.length / seconds : 0 };
}
