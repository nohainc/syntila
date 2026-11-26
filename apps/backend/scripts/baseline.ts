#!/usr/bin/env bun
/**
 * Worker-first P0 baseline: the numbers later phases are compared against.
 * Measures, against one running backend (/api):
 *   - idle realtime sockets: how many of N stay open for the idle period,
 *     unexpected closes, time to become ready;
 *   - message latency: REST post and post -> realtime event (p50/p95/p99);
 *   - backend memory (RSS) at start, with the sockets open, after the messages.
 *
 *   bun scripts/baseline.ts <baseUrl> <privateJwkFile> [--sockets=200] [--idle-seconds=30]
 *                           [--messages=20] [--users=10] [--pid=<backend pid>] [--out=<file>]
 *
 * --pid enables the memory figures (read with `ps`, so it must run on the
 * backend's machine or its pid must be visible). Without it memory is reported
 * as null. The JSON result goes to _perf/baseline-<UTC timestamp>.json (the
 * folder `scripts/perf-report.mjs` also uses; it is not committed). Note the
 * git commit and the machine alongside the result.
 * Rate limits must be off for the run (SYNTILA_RATE_LIMIT_PER_MINUTE=0 and
 * SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE=0), as for scripts/load.ts.
 */
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { User, runMessagePosts, tokenMinter, type Client, type Jwk } from "./lib/clients";

const args = Bun.argv.slice(2);
const [base, jwkFile] = args.filter((a) => !a.startsWith("--"));
const opt = (name: string, fallback: number) => {
  const raw = args.find((a) => a.startsWith(`--${name}=`))?.split("=")[1];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`invalid --${name}`);
  return value;
};
if (!base || !jwkFile) {
  console.error("usage: bun scripts/baseline.ts <baseUrl> <privateJwkFile> [--sockets=200] [--idle-seconds=30] [--messages=20] [--users=10] [--pid=N] [--out=file]");
  process.exit(2);
}
const SOCKETS = opt("sockets", 200), IDLE_S = opt("idle-seconds", 30), MESSAGES = opt("messages", 20), USERS = Math.max(1, opt("users", 10));
const PID = args.find((a) => a.startsWith("--pid="))?.split("=")[1];
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);

const pct = (xs: number[], p: number) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]! * 10) / 10 : null;
};
const summary = (xs: number[]) => ({ n: xs.length, p50: pct(xs, 50), p95: pct(xs, 95), p99: pct(xs, 99), max: xs.length ? Math.round(Math.max(...xs) * 10) / 10 : null });

async function rssMb(): Promise<number | null> {
  if (!PID) return null;
  const proc = Bun.spawn(["ps", "-o", "rss=", "-p", PID], { stdout: "pipe", stderr: "ignore" });
  const text = (await new Response(proc.stdout).text()).trim();
  await proc.exited;
  const kb = Number(text);
  return Number.isFinite(kb) && kb > 0 ? Math.round(kb / 1024) : null;
}

const cleanup: Array<() => unknown> = [];
const result: Record<string, unknown> = { run, startedAt: new Date().toISOString(), base, options: { SOCKETS, IDLE_S, MESSAGES, USERS } };
try {
  const memory: Record<string, number | null> = { startMb: await rssMb() };

  // Users, each with a Space and Thread.
  const users: Client[] = [];
  await Promise.all(Array.from({ length: USERS }, async (_, i) => {
    const user = new User(base, await mint(`baseline-${run}-${i}`));
    const { spaceId, threadId } = await user.spaceWithThread(`Baseline ${run} ${i}`);
    const live = user.realtime([spaceId]);
    await live.waitFor("subscription", (f) => f.type === "subscription.ready", 30_000);
    users.push({ user, spaceId, threadId, live });
    cleanup.push(() => user.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }));
    cleanup.push(() => live.close());
  }));

  // Idle sockets: spread over the users, opened together, then left alone.
  const extra = Math.max(0, SOCKETS - users.length);
  const opened0 = performance.now();
  const idle = Array.from({ length: extra }, (_, i) => {
    const owner = users[i % users.length]!;
    const live = owner.user.realtime([owner.spaceId]);
    cleanup.push(() => live.close());
    return live;
  });
  const readyAt: number[] = [];
  await Promise.all(idle.map((live) =>
    live.waitFor("socket ready", (f) => f.type === "subscription.ready", 60_000)
      .then(() => readyAt.push(performance.now() - opened0), () => {})));
  const openAtStart = idle.filter((l) => l.state.opens > 0).length;
  memory.withSocketsMb = await rssMb();
  console.log(`idle sockets: ${openAtStart + users.length}/${SOCKETS} open, waiting ${IDLE_S}s`);
  await Bun.sleep(IDLE_S * 1000);
  const dropped = [...idle, ...users.map((u) => u.live)].reduce((n, l) => n + l.state.closes.length, 0);
  const reopened = [...idle, ...users.map((u) => u.live)].reduce((n, l) => n + Math.max(0, l.state.opens - 1), 0);
  result.idleSockets = {
    requested: SOCKETS, openAtStart: openAtStart + users.length, idleSeconds: IDLE_S,
    unexpectedCloses: dropped, reconnects: reopened, timeToReadyMs: summary(readyAt),
  };

  // Message latency with the idle sockets still open.
  const { rest, fanout, errors, throughput } = await runMessagePosts(users, MESSAGES, `baseline-${run}`);
  result.messages = { users: USERS, perUser: MESSAGES, errors, throughputPerSecond: Math.round(throughput), restPostMs: summary(rest), realtimeFanoutMs: summary(fanout) };
  memory.afterMessagesMb = await rssMb();
  result.memory = memory;
} finally {
  for (const step of cleanup.reverse()) { try { await step(); } catch { /* best effort */ } }
}

result.finishedAt = new Date().toISOString();
const out = args.find((a) => a.startsWith("--out="))?.split("=")[1] ?? join(import.meta.dir, "..", "..", "..", "_perf", `baseline-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
mkdirSync(join(out, ".."), { recursive: true });
await Bun.write(out, JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify(result, null, 2));
console.log(`\nwritten to ${out}`);
process.exit(0);
