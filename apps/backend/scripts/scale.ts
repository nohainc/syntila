#!/usr/bin/env bun
/**
 * P11 scale scenarios against a running backend (ADR-039 activation gate).
 *
 *   bun scripts/scale.ts <baseUrl> <privateJwkFile> [scenario...] [--sockets N] [--senders N] [--messages N]
 *                        [--storms N] [--soak-minutes N] [--json out.json] [--no-thresholds]
 *
 * Scenarios (default: idle active storm):
 *   idle    N idle browser sockets (default 1000): connect time, server memory per socket
 *   active  S senders (default 100) posting M messages: REST latency, post -> event fan-out
 *   storm   all sockets drop and reconnect together, repeated: time until every socket is subscribed again
 *   soak    sockets idle with one low-rate poster for N minutes (default 60): memory drift, outbox age
 *
 * Server metrics (optional): SERVER_PID = pid of the backend on this machine (memory via ps);
 * PGHOST/PGUSER/PGPASSWORD/PGDATABASE (outbox age, lock waits, connections).
 * Thresholds (ADR-039 gate): REST p99 < 150 ms, fan-out p99 < 250 ms. Exit 1 when missed.
 *
 * NOT covered here, needs separate tooling: Agent sockets at 1-2 events/s (a current Agent load client is still needed), slow readers (Bun's WebSocket client
 * always reads), event-loop lag inside the server (read it from the server's own metrics).
 */
import { SQL } from "bun";
import { User, tokenMinter, waitFor, type Jwk } from "./lib/clients";

const argv = Bun.argv.slice(2);
const flag = (name: string, fallback?: string) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : fallback; };
const positional = argv.filter((a, i) => !a.startsWith("--") && !(i > 0 && argv[i - 1]!.startsWith("--") && argv[i - 1] !== "--no-thresholds"));
const [base, jwkFile, ...named] = positional;
if (!base || !jwkFile) { console.error("usage: bun scripts/scale.ts <baseUrl> <privateJwkFile> [idle|active|storm|soak ...] [options]"); process.exit(2); }
const scenarios = new Set(named.length ? named : ["idle", "active", "storm"]);
const SOCKETS = Number(flag("sockets", "1000")), SENDERS = Number(flag("senders", "100")), MESSAGES = Number(flag("messages", "10"));
const STORMS = Number(flag("storms", "3")), SOAK_MIN = Number(flag("soak-minutes", "60"));
const thresholds = !argv.includes("--no-thresholds");
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);

const pct = (xs: number[], p: number) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]! : NaN; };
const line = (label: string, xs: number[]) => console.log(`${label.padEnd(30)} n=${String(xs.length).padStart(6)}  p50=${pct(xs, 50).toFixed(0).padStart(5)}  p95=${pct(xs, 95).toFixed(0).padStart(5)}  p99=${pct(xs, 99).toFixed(0).padStart(5)}  max=${Math.max(...xs, 0).toFixed(0).padStart(5)} ms`);
const result: Record<string, unknown> = { startedAt: new Date().toISOString(), base, sockets: SOCKETS };
let failed = false;
const require = (ok: boolean, what: string) => { if (!ok) { console.error(`FAIL ${what}`); failed = true; } };

/* ---- server-side metrics (optional) ---- */
async function rssMb(): Promise<number | null> {
  const pid = process.env.SERVER_PID; if (!pid) return null;
  const out = Bun.spawnSync(["ps", "-o", "rss=", "-p", pid]).stdout.toString().trim();
  return out ? Number(out) / 1024 : null;
}
const db = process.env.PGHOST || process.env.DATABASE_URL ? (process.env.DATABASE_URL ? new SQL(process.env.DATABASE_URL) : new SQL({ max: 1 })) : null;
async function dbMetrics() {
  if (!db) return null;
  const [o] = await db`SELECT COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)), 0)::float AS oldest_pending_s, count(*)::int AS pending FROM outbox WHERE status = 'pending'`;
  const [l] = await db`SELECT count(*)::int AS waiting FROM pg_stat_activity WHERE wait_event_type = 'Lock'`;
  const [c] = await db`SELECT count(*)::int AS connections FROM pg_stat_activity WHERE datname = current_database()`;
  return { ...(o as object), ...(l as object), ...(c as object) };
}

/* ---- sockets ---- */
type Sock = { user: User; spaceId: string; threadId: string; live: ReturnType<User["realtime"]> };
const socks: Sock[] = [];
async function connectAll(count: number): Promise<number[]> {
  const times: number[] = [];
  const batch = 50; // setup rate-limits itself; sockets are opened in batches
  for (let start = 0; start < count; start += batch) {
    await Promise.all(Array.from({ length: Math.min(batch, count - start) }, async (_, k) => {
      const i = start + k;
      const user = new User(base!, await mint(`scale-${run}-${i}`));
      const { spaceId, threadId } = await user.spaceWithThread(`Scale ${run} ${i}`);
      const t0 = performance.now();
      const live = user.realtime([spaceId]);
      await live.waitFor("subscription", (f) => f.type === "subscription.ready", 60_000);
      times.push(performance.now() - t0);
      socks.push({ user, spaceId, threadId, live });
    }));
  }
  return times;
}

try {
  const before = await rssMb();
  if (scenarios.has("idle") || scenarios.has("active") || scenarios.has("storm") || scenarios.has("soak")) {
    console.log(`connecting ${SOCKETS} sockets...`);
    const times = await connectAll(SOCKETS);
    line("connect + subscribe", times);
    const after = await rssMb();
    if (before != null && after != null) {
      const perSocket = ((after - before) * 1024) / SOCKETS;
      console.log(`server memory: ${before.toFixed(0)} -> ${after.toFixed(0)} MB (${perSocket.toFixed(1)} KB per idle socket)`);
      result.idle = { connectMs: { p50: pct(times, 50), p99: pct(times, 99) }, kbPerSocket: perSocket };
    }
    console.log("db:", JSON.stringify(await dbMetrics()));
  }

  if (scenarios.has("active")) {
    const senders = socks.slice(0, SENDERS);
    console.log(`active: ${senders.length} senders x ${MESSAGES} messages`);
    const rest: number[] = [], fanout: number[] = [];
    let errors = 0;
    const t0 = performance.now();
    await Promise.all(senders.map(async (c) => {
      for (let m = 0; m < MESSAGES; m++) {
        const marker = `scale-${run}-${m}-${crypto.randomUUID().slice(0, 8)}`;
        const start = performance.now(), mark = c.live.state.frames.length;
        const posted = await c.user.api("POST", `/api/threads/${c.threadId}/discussion-messages`, { body: marker });
        rest.push(performance.now() - start);
        if (posted.status >= 300) { errors++; continue; }
        const id = posted.body?.message?.id ?? posted.body?.id;
        await waitFor("fan-out", () => c.live.state.frames.slice(mark).find((f) => JSON.stringify(f).includes(id ?? c.threadId)), 15_000)
          .then(() => fanout.push(performance.now() - start)).catch(() => { errors++; });
      }
    }));
    line("POST message (REST)", rest); line("post -> realtime event", fanout);
    console.log(`throughput ${(rest.length / ((performance.now() - t0) / 1000)).toFixed(0)}/s, errors ${errors}`);
    result.active = { restP99: pct(rest, 99), fanoutP99: pct(fanout, 99), errors };
    require(errors === 0, "no errors in the active scenario");
    if (thresholds) { require(pct(rest, 99) < 150, `REST p99 ${pct(rest, 99).toFixed(0)} ms < 150 ms`); require(pct(fanout, 99) < 250, `fan-out p99 ${pct(fanout, 99).toFixed(0)} ms < 250 ms`); }
    console.log("db:", JSON.stringify(await dbMetrics()));
  }

  if (scenarios.has("storm")) {
    const storms: number[] = [];
    for (let s = 0; s < STORMS; s++) {
      const marks = socks.map((c) => c.live.state.opens);
      const t0 = performance.now();
      for (const c of socks) c.live.state.socket?.close(); // the helper reconnects itself with a fresh ticket
      await Promise.all(socks.map((c, i) => waitFor("reconnect", () => c.live.state.opens > marks[i]!, 120_000)));
      storms.push(performance.now() - t0);
      console.log(`storm ${s + 1}: all ${socks.length} sockets back in ${(storms.at(-1)! / 1000).toFixed(1)} s`);
    }
    result.storm = { seconds: storms.map((ms) => ms / 1000) };
    console.log("db:", JSON.stringify(await dbMetrics()));
  }

  if (scenarios.has("soak")) {
    console.log(`soak: ${SOAK_MIN} minutes`);
    const end = Date.now() + SOAK_MIN * 60_000, samples: Array<Record<string, unknown>> = [];
    const poster = socks[0]!;
    while (Date.now() < end) {
      const res = await poster.user.api("POST", `/api/threads/${poster.threadId}/discussion-messages`, { body: `soak-${Date.now()}` });
      if (res.status >= 300) { failed = true; console.error(`soak post failed: ${res.status}`); }
      const sample = { minute: Math.round((Date.now() - (end - SOAK_MIN * 60_000)) / 60_000), rssMb: await rssMb(), ...(await dbMetrics()) };
      samples.push(sample); console.log(JSON.stringify(sample));
      await Bun.sleep(60_000);
    }
    result.soak = samples;
    const first = samples[0]?.rssMb as number | null, last = samples.at(-1)?.rssMb as number | null;
    if (first != null && last != null) require(last < first * 1.25, `memory drift under 25% (${first.toFixed(0)} -> ${last.toFixed(0)} MB)`);
  }
} finally {
  for (const c of socks) c.live.close();
  await Promise.allSettled(socks.map((c) => c.user.api("PATCH", `/api/spaces/${c.spaceId}`, { archived: true })));
  await db?.close();
}
const out = flag("json");
if (out) await Bun.write(out, JSON.stringify({ ...result, failed }, null, 2));
console.log(failed ? "SCALE: FAILED" : "SCALE: ok");
process.exit(failed ? 1 : 0);
