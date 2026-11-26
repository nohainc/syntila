#!/usr/bin/env bun
/**
 * Local performance runner for Syntila.
 *
 * Usage:
 *   scripts/perf-local.sh [--probes N] [--chats N] [--parallel N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--no-thresholds]
 *
 * Scenarios:
 *   A "transport": retired; no Worker Agent delivery probe exists.
 *   C "workflows": bounded concurrent requests on the developer’s Worker.
 *
 * Cleanup preserves active requests and only checks resources created by this run.
 * Never logs or prints tokens, keys, or message bodies.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";
import { SQL } from "bun";
import {
  User,
  sleep,
  tokenMinter,
  waitFor,
  type Jwk,
} from "../apps/backend/scripts/lib/clients";
import { summarize } from "./latency-baseline.mjs";
import { finalizeBenchmarkSpace } from "./perf-local-cleanup.mjs";
import { runWorkerLoad } from "./perf-worker-load.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DEV_EMAIL = process.env.SYNTILA_DEV_EMAIL ?? "vitalii@nohainc.com";
const DEFAULT_THRESHOLDS_PATH = join(ROOT, "scripts/perf-thresholds.json");

interface CliOptions {
  probes: number;
  workflow: "chat" | "work";
  allowOffline: boolean;
  model: string | null;
  chats: number;
  parallel: number;
  jsonPath: string | null;
  thresholdsPath: string;
  checkThresholds: boolean;
  baseUrl: string;
}

function parseCli(argv: string[]): CliOptions {
  const opts: CliOptions = {
    probes: 0,
    workflow: "chat",
    allowOffline: false,
    model: null,
    chats: 1,
    parallel: 1,
    jsonPath: null,
    thresholdsPath: DEFAULT_THRESHOLDS_PATH,
    checkThresholds: true,
    baseUrl: `http://localhost:${process.env.BACKEND_PORT ?? "8788"}`,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    const next = () => {
      const val = argv[++i];
      if (!val || val.startsWith("--")) {
        throw new Error(`Option ${arg} requires a value`);
      }
      return val;
    };
    const nextInt = () => {
      const raw = next();
      const num = Number(raw);
      if (!Number.isInteger(num) || num < 0) {
        throw new Error(`Option ${arg} requires a non-negative integer (got ${raw})`);
      }
      return num;
    };
    if (arg === "--probes") opts.probes = nextInt();
    else if (arg === "--chats") opts.chats = nextInt();
    else if (arg === "--parallel") {
      opts.parallel = nextInt();
      if (opts.parallel < 1 || opts.parallel > 8) throw new Error("--parallel must be between 1 and 8");
    }
    else if (arg === "--workflow") {
      const value = next();
      if (value !== "chat" && value !== "work") throw new Error("--workflow must be chat or work");
      opts.workflow = value;
    }
    else if (arg === "--allow-offline") opts.allowOffline = true;
    else if (arg === "--model") opts.model = next();
    else if (arg === "--json") opts.jsonPath = next();
    else if (arg === "--thresholds") opts.thresholdsPath = resolve(next());
    else if (arg === "--no-thresholds") opts.checkThresholds = false;
    else if (arg === "-h" || arg === "--help") {
      console.log(
        "Usage: scripts/perf-local.sh [--probes N] [--chats N] [--parallel N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--thresholds file.json] [--no-thresholds]",
      );
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

interface StatSummary {
  count: number;
  p50: number | null;
  p95: number | null;
  p99: number | null;
  max: number | null;
}

function roundStat(s: StatSummary): StatSummary {
  const r = (v: number | null) => (v === null || !Number.isFinite(v) ? null : Math.round(v * 10) / 10);
  return {
    count: s.count,
    p50: r(s.p50),
    p95: r(s.p95),
    p99: r(s.p99),
    max: r(s.max),
  };
}

function formatStatLine(label: string, s: StatSummary, extra = ""): string {
  const fmt = (v: number | null) => (v === null ? "   n/a" : `${v.toFixed(1).padStart(6)}ms`);
  return `  ${label.padEnd(46)} n=${String(s.count).padStart(4)}  p50=${fmt(s.p50)}  p95=${fmt(s.p95)}  p99=${fmt(s.p99)}  max=${fmt(s.max)}${extra ? `  ${extra}` : ""}`;
}

function loadLocalSigningKey(): Jwk {
  const devVarsPath = join(ROOT, "apps/cloud/.dev.vars");
  if (!existsSync(devVarsPath)) {
    throw new Error(
      `Missing ${devVarsPath}. Run 'node scripts/setup-local-backend.mjs' or 'pnpm start:local' first.`,
    );
  }
  const vars = parseEnv(readFileSync(devVarsPath, "utf8"));
  const raw = vars.SYNTILA_BACKEND_SIGNING_KEY;
  if (!raw) {
    throw new Error(
      `SYNTILA_BACKEND_SIGNING_KEY is missing in ${devVarsPath}. Run 'node scripts/setup-local-backend.mjs'.`,
    );
  }
  return JSON.parse(raw) as Jwk;
}

function openDb(): SQL {
  const databaseUrl = process.env.DATABASE_URL;
  const host = databaseUrl ? new URL(databaseUrl).hostname : (process.env.PGHOST ?? "127.0.0.1");
  if (!["localhost", "127.0.0.1", "[::1]", "::1"].includes(host)) {
    throw new Error("Performance runner requires a local PostgreSQL host");
  }
  return databaseUrl ? new SQL(databaseUrl) : new SQL({});
}

function getGitCommit(): string {
  try {
    return execFileSync("git", ["rev-parse", "--short=12", "HEAD"], {
      cwd: ROOT,
      encoding: "utf8",
    }).trim();
  } catch {
    return "unknown";
  }
}

function isGitDirty(): boolean | null {
  try {
    return execFileSync("git", ["status", "--porcelain"], { cwd: ROOT, encoding: "utf8" }).trim().length > 0;
  } catch {
    return null;
  }
}

function getMachineInfo() {
  const cpus = os.cpus();
  return {
    os: `${os.platform()} ${os.release()} (${os.arch()})`,
    cpu: cpus[0]?.model ?? "unknown",
    cores: cpus.length,
    memoryGb: Math.round((os.totalmem() / 1024 ** 3) * 10) / 10,
  };
}

/** Verify the running backend will not update an unchanged account on reads. */
async function verifyReadOnlyDiscovery(
  sql: SQL, base: string, mint: ReturnType<typeof tokenMinter>, runId: string, createdUserIds: Set<string>,
): Promise<void> {
  const id = `perf-${runId}-discovery`;
  createdUserIds.add(id);
  const email = `${id}@syntila.invalid`;
  const timestamp = "2000-01-01T00:00:00.000Z";
  await sql`INSERT INTO users (id, email, display_name, status, created_at, updated_at)
            VALUES (${id}, ${email}, ${id}, 'active', ${timestamp}, ${timestamp})`;
  try {
    const user = new User(base, await mint(id, { email, name: id }));
    const response = await user.api("GET", "/api/session");
    const [row] = await sql<{ updated_at: Date | string }[]>`SELECT updated_at FROM users WHERE id = ${id}`;
    if (response.status !== 200 || !row || new Date(row.updated_at).toISOString() !== timestamp) {
      throw new Error("Local backend updates user data during discovery. Restart it on the current build before running Worker discovery.");
    }
  } finally {
    await sql`DELETE FROM users WHERE id = ${id}`;
  }
}

/** Discover an owned Worker without changing the developer account. */
async function resolveDeveloperIdentity(
  sql: SQL, base: string, mint: ReturnType<typeof tokenMinter>, runId: string,
  createdUserIds: Set<string>,
): Promise<{ userId: string | null; worker: { id: string; online: boolean; ready: boolean } | null; token: string | null }> {
  const [row] = await sql<{ id: string; email: string; display_name: string }[]>`
    SELECT id, email, display_name FROM users WHERE LOWER(email) = LOWER(${DEV_EMAIL}) AND status = 'active' LIMIT 1`;
  if (!row) return { userId: null, worker: null, token: null };
  if (!row.display_name) throw new Error("Developer account has no display name");
  await verifyReadOnlyDiscovery(sql, base, mint, runId, createdUserIds);
  const token = await mint(row.id, { email: row.email, name: row.display_name });
  const user = new User(base, token);
  const session = await user.api("GET", "/api/session");
  if (session.status !== 200 || session.body?.user?.id !== row.id) throw new Error("Failed to verify developer session");
  const result = await user.api("GET", "/api/workers");
  if (result.status !== 200 || !Array.isArray(result.body?.workers)) throw new Error(`Failed to list Workers (HTTP ${result.status})`);
  const requested = process.env.SYNTILA_PERF_WORKER_ID;
  const candidates = (result.body.workers as Array<Record<string, unknown>>).filter((w) =>
    w.enabled === true && typeof w.id === "string" && (!requested || w.id === requested));
  const selected = candidates.find((w) => w.online === true && w.ready === true) ?? candidates[0];
  return { userId: row.id, token, worker: selected ? { id: String(selected.id), online: selected.online === true, ready: selected.ready === true } : null };
}

/** The removed transport probe has no Worker Agent equivalent. */
async function runScenarioA(_base: string, _sql: SQL, _mint: ReturnType<typeof tokenMinter>, _count: number, _runId: string, _createdUserIds: Set<string>): Promise<{
  status: "skipped"; warning: string; variants: Record<string, { roundTripMs: StatSummary }>;
}> {
  const warning = "Transport probe retired; no Worker Agent delivery probe is implemented";
  console.warn(`  SKIP: ${warning}`);
  return { status: "skipped", warning, variants: {} };
}

async function runScenarioC(
  base: string, sql: SQL, mint: ReturnType<typeof tokenMinter>, runId: string,
  chatsCount: number, parallel: number, workflow: "chat" | "work", allowOffline: boolean, model: string | null, createdUserIds: Set<string>, createdSpaceIds: Set<string>,
) {
  console.log(`\n== Scenario C: real Worker ${workflow} workflow (${chatsCount} requests, up to ${parallel} concurrent)`);
  if (chatsCount === 0) return { requests: 0, errors: 0, totalMs: roundStat(summarize([])) };
  const dev = await resolveDeveloperIdentity(sql, base, mint, `${runId}-workflow`, createdUserIds);
  if (!dev.token || !dev.worker) throw new Error(`An enabled Worker for ${DEV_EMAIL} is required`);
  if ((!dev.worker.online || !dev.worker.ready) && !allowOffline) {
    throw new Error("The selected Worker is offline or not ready (or use --allow-offline for a readiness test)");
  }
  const workerId = dev.worker.id;
  const [busy] = await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM worker_assignments WHERE worker_instance_id = ${workerId} AND status IN ('created', 'dispatched', 'acknowledged', 'running', 'revocation_pending', 'reconciling')`;
  if (busy?.count) console.warn(`  WARN: selected Worker already has ${busy.count} active assignment(s); admission and startup may be delayed`);
  const user = new User(base, dev.token);
  const { spaceId, threadId } = await user.spaceWithThread(`perf-${runId}-real-workflow`);
  createdSpaceIds.add(spaceId);
  const totals: number[] = [];
  const admission: number[] = [], serviceWait: number[] = [], delivery: number[] = [], startup: number[] = [];
  let errors = 0;
  let completedSuccessfully = false;
  try {
    const threadIds = [threadId];
    for (let lane = 1; lane < Math.min(parallel, chatsCount); lane++) {
      const response = await user.api("POST", `/api/spaces/${spaceId}/threads`, { name: `Load lane ${lane + 1}` });
      const id = response.body?.thread?.id ?? response.body?.id;
      if (response.status >= 300 || !id) throw new Error(`Could not create benchmark Thread: HTTP ${response.status}`);
      threadIds.push(String(id));
    }
    await runWorkerLoad(chatsCount, parallel, async (i: number, lane: number) => {
      const selectedThreadId = threadIds[lane]!;
      const start = performance.now();
      const submit = await user.api("POST", `/api/threads/${selectedThreadId}/work-requests`, {
        workflowId: workflow === "work" ? "direct" : "chat", objective: "Reply with the single word: pong. Do not use tools or modify any files.",
        workerId, ...(model ? { model } : {}),
      });
      if (submit.status >= 300 || !submit.body?.workRequest?.id) {
        console.error(`  request ${i + 1} rejected: HTTP ${submit.status} ${JSON.stringify(submit.body)}`);
        errors++;
        return;
      }
      const requestId = String(submit.body.workRequest.id);
      const done = await waitFor("real workflow completion", async () => {
        const response = await user.api("GET", `/api/work-requests/${requestId}`);
        return ["completed", "failed", "cancelled"].includes(response.body?.workRequest?.status)
          ? response.body.workRequest : undefined;
      }, 180_000).catch(() => null);
      if (done?.status !== "completed") {
        console.error(`  request ${i + 1} ${done?.status ?? "timed out"} (${requestId})`);
        errors++;
        // Do not delete a Space while its Worker may still be executing.
        if (!done) throw new Error(`Request ${requestId} is still active; preserved Space ${spaceId}`);
      } else {
        totals.push(performance.now() - start);
        const attempts = await sql<{ admission: number | null; service_wait: number | null; delivery: number | null; startup: number | null }[]>`
          SELECT EXTRACT(EPOCH FROM (a.created_at - w.created_at)) * 1000 AS admission,
                 EXTRACT(EPOCH FROM (a.dispatched_at - a.created_at)) * 1000 AS service_wait,
                 EXTRACT(EPOCH FROM (a.acknowledged_at - a.dispatched_at)) * 1000 AS delivery,
                 EXTRACT(EPOCH FROM (a.running_at - a.start_permit_issued_at)) * 1000 AS startup
            FROM work_requests w JOIN worker_assignments a
              ON a.work_request_id = w.id OR (a.work_request_id IS NULL AND a.id LIKE 'asg-task-' || w.id || '-%')
           WHERE w.id = ${requestId}`;
        for (const attempt of attempts) {
          for (const [value, samples] of [[attempt.admission, admission], [attempt.service_wait, serviceWait], [attempt.delivery, delivery], [attempt.startup, startup]] as const) {
            if (value !== null && Number.isFinite(Number(value)) && Number(value) >= 0) samples.push(Number(value));
          }
        }
      }
    });
    const totalMs = roundStat(summarize(totals));
    console.log(formatStatLine("real request -> completed result (includes polling)", totalMs));
    const intervals = {
      requestToAssignmentMs: roundStat(summarize(admission)),
      assignmentToDispatchMs: roundStat(summarize(serviceWait)),
      dispatchToAcknowledgementMs: roundStat(summarize(delivery)),
      startPermitToRunningMs: roundStat(summarize(startup)),
    };
    for (const [name, stat] of Object.entries(intervals)) console.log(formatStatLine(name, stat));
    completedSuccessfully = errors === 0;
    return { requests: chatsCount, errors, totalMs, intervals, workflow, workerId };
  } finally {
    // Preserve active or failed runs so diagnostics are not lost.
    const [active] = await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM work_requests WHERE thread_id IN (SELECT id FROM threads WHERE space_id = ${spaceId}) AND status NOT IN ('completed', 'failed', 'cancelled')`;
    if (!active) throw new Error(`Could not check benchmark Space ${spaceId}; it was preserved`);
    const outcome = await finalizeBenchmarkSpace({
      activeCount: active.count,
      succeeded: completedSuccessfully,
      remove: async () => {
        const deleted = await user.api("DELETE", `/api/spaces/${spaceId}`);
        if (deleted.status >= 300) throw new Error(`Could not clean up benchmark Space ${spaceId}: HTTP ${deleted.status}`);
      },
    });
    createdSpaceIds.delete(spaceId);
    if (outcome !== "deleted") {
      console.warn(`  Preserved benchmark Space ${spaceId}: ${outcome === "active" ? `${active.count} request(s) still active` : "the scenario failed"}`);
    }
  }
}

interface CleanupReport {
  remainingPerfRows: number;
}

/** Historical timings are approximations from persisted timestamps, not UI
 * observations. Include requests without an assignment so stalled work is not
 * silently excluded. Multiple attempts are reported separately. */
async function runScenarioD(sql: SQL, limit: number) {
  console.log(`\n== Scenario D: real requests of the developer Worker (last ${limit}, read-only)`);
  const rows = (await sql`
    WITH recent AS (
      SELECT w.id, w.created_at
        FROM work_requests w JOIN users u ON u.id = w.requested_by_user_id
       WHERE LOWER(u.email) = LOWER(${DEV_EMAIL})
       ORDER BY w.created_at DESC LIMIT ${limit}
    )
    SELECT w.id AS request_id, a.id AS assignment_id, a.status,
           EXTRACT(EPOCH FROM (a.created_at - w.created_at)) * 1000 AS admission_ms,
           EXTRACT(EPOCH FROM (a.dispatched_at - a.created_at)) * 1000 AS service_wait_ms,
           EXTRACT(EPOCH FROM (a.acknowledged_at - a.dispatched_at)) * 1000 AS delivery_ms,
           EXTRACT(EPOCH FROM (a.running_at - a.start_permit_issued_at)) * 1000 AS start_ms,
           EXTRACT(EPOCH FROM (a.running_at - a.acknowledged_at)) * 1000 AS ack_to_running_ms
      FROM recent w LEFT JOIN worker_assignments a
        ON a.work_request_id = w.id OR (a.work_request_id IS NULL AND a.id LIKE 'asg-task-' || w.id || '-%')
     ORDER BY w.created_at DESC, a.created_at` ) as Array<{
    request_id: string;
    assignment_id: string | null;
    status: string | null;
    admission_ms: string | number | null;
    service_wait_ms: string | number | null;
    delivery_ms: string | number | null;
    start_ms: string | number | null;
    ack_to_running_ms: string | number | null;
  }>;
  const col = (k: "admission_ms" | "service_wait_ms" | "delivery_ms" | "start_ms" | "ack_to_running_ms") =>
    rows.map((r) => (r[k] === null ? NaN : Number(r[k]))).filter((v) => Number.isFinite(v) && v >= 0);
  const admission = roundStat(summarize(col("admission_ms")));
  const serviceWait = roundStat(summarize(col("service_wait_ms")));
  const delivery = roundStat(summarize(col("delivery_ms")));
  const starting = roundStat(summarize(col("start_ms")));
  const ackToRunning = roundStat(summarize(col("ack_to_running_ms")));
  const withoutAssignment = rows.filter((r) => r.assignment_id === null).length;
  const awaitingDispatch = rows.filter((r) => r.status === "created").length;
  const awaitingRunning = rows.filter((r) => r.status === "acknowledged").length;
  console.log(formatStatLine("request -> assignment (admission)", admission));
  console.log(formatStatLine("assignment -> dispatch (service wait, includes other queues)", serviceWait));
  console.log(formatStatLine("dispatch -> acknowledgement", delivery));
  console.log(formatStatLine("start permit -> running (worker startup)", starting));
  console.log(formatStatLine("acknowledgement -> running (includes queueing)", ackToRunning));
  console.log(`  Missing assignment: ${withoutAssignment}; awaiting dispatch: ${awaitingDispatch}; acknowledged but not running: ${awaitingRunning}`);
  const slow = col("admission_ms").filter((v) => v > 5_000).length;
  if (slow > 0) console.warn(`  WARN: ${slow} assignment attempts took over 5 s from request to assignment`);
  return {
    requests: new Set(rows.map((r) => r.request_id)).size,
    assignmentAttempts: rows.filter((r) => r.assignment_id !== null).length,
    requestsWithoutAssignment: withoutAssignment,
    awaitingDispatch,
    acknowledgedNotRunning: awaitingRunning,
    admissionMs: admission,
    assignmentToDispatchMs: serviceWait,
    deliveryMs: delivery,
    startingWorkerMs: starting,
    acknowledgementToRunningMs: ackToRunning,
    attemptsWithAdmissionOver5s: slow,
  };
}

async function cleanupRun(
  sql: SQL, _base: string, _mint: ReturnType<typeof tokenMinter>, runId: string,
  createdUserIds: Set<string>, createdSpaceIds: Set<string>,
): Promise<CleanupReport> {
  // Never delete a Space here: the workflow path deletes it only after terminal
  // completion, and intentionally preserves active or failed runs for inspection.
  const userIds = [...createdUserIds];
  const spaceIds = [...createdSpaceIds];
  const [users] = userIds.length ? await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM users WHERE id IN ${sql(userIds)}` : [{ count: 0 }];
  const [spaces] = spaceIds.length ? await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM spaces WHERE id IN ${sql(spaceIds)}` : [{ count: 0 }];
  const remainingPerfRows = (users?.count ?? 0) + (spaces?.count ?? 0);
  console.log(`\n== Cleanup (run perf-${runId}): ${remainingPerfRows} tracked resource(s) remain`);
  return { remainingPerfRows };
}

interface ThresholdViolation {
  metric: string;
  measuredP95: number | null;
  limitP95: number;
}

function checkThresholds(
  thresholdsPath: string,
  observedP95: Record<string, number | null>,
  skippedPrefixes: string[],
): { violations: ThresholdViolation[]; checked: number; skipped: number } {
  if (!existsSync(thresholdsPath)) throw new Error(`Thresholds file not found: ${thresholdsPath}`);
  const parsed = JSON.parse(readFileSync(thresholdsPath, "utf8")) as {
    metrics?: Record<string, { p95Ms?: number }>;
  };
  if (!parsed.metrics || Object.keys(parsed.metrics).length === 0) throw new Error("No performance limits configured");
  const violations: ThresholdViolation[] = [];
  let checked = 0, skipped = 0;
  for (const [metric, rule] of Object.entries(parsed.metrics)) {
    const limit = rule?.p95Ms;
    if (typeof limit !== "number" || !Number.isFinite(limit) || limit < 0) throw new Error(`Invalid limit for ${metric}`);
    if (!(metric in observedP95)) throw new Error(`Unknown performance metric: ${metric}`);
    if (skippedPrefixes.some((prefix) => metric.startsWith(prefix))) {
      console.log(`  SKIP ${metric}: scenario disabled`);
      skipped++;
      continue;
    }
    const measured = observedP95[metric];
    if (measured === null || measured === undefined || !Number.isFinite(measured)) {
      console.log(`  FAIL ${metric}: measurement unavailable (limit ${limit}ms)`);
      violations.push({ metric, measuredP95: null, limitP95: limit });
      continue;
    }
    checked++;
    const passed = measured <= limit;
    console.log(`  ${passed ? "PASS" : "FAIL"} ${metric}: ${measured.toFixed(1)}ms / ${limit.toFixed(1)}ms`);
    if (!passed) violations.push({ metric, measuredP95: measured, limitP95: limit });
  }
  return { violations, checked, skipped };
}

async function main() {
  const opts = parseCli(Bun.argv.slice(2));

  // Verify local backend is up before doing anything else.
  const health = await fetch(`${opts.baseUrl}/health/ready`).catch(() => null);
  if (!health || !health.ok) {
    console.error(
      `Error: Local backend is not reachable or not ready at ${opts.baseUrl}/health/ready.\n` +
        `Start the local stack first with: pnpm start:local`,
    );
    process.exit(1);
  }

  const jwk = loadLocalSigningKey();
  const mint = tokenMinter(jwk);
  const sql = openDb();
  const runId = `${Date.now().toString(36)}-${crypto.randomUUID().slice(0, 6)}`;
  const createdUserIds = new Set<string>();
  const createdSpaceIds = new Set<string>();

  const commit = getGitCommit();
  const gitDirty = isGitDirty();
  const date = new Date().toISOString();
  const machine = getMachineInfo();

  console.log(`Syntila Local Performance Runner`);
  console.log(`  commit: ${commit}${gitDirty ? " (working tree modified)" : ""}  date: ${date}`);
  console.log(`  machine: ${machine.cpu} (${machine.cores} cores, ${machine.memoryGb} GB) — ${machine.os}`);
  console.log(`  backend: ${opts.baseUrl}  run: perf-${runId}`);

  let scenarioA: Awaited<ReturnType<typeof runScenarioA>> | null = null;
  let scenarioC: Awaited<ReturnType<typeof runScenarioC>> | null = null;
  let scenarioD: Awaited<ReturnType<typeof runScenarioD>> | null = null;
  let cleanupReport: CleanupReport | null = null;
  let fatalError: Error | null = null;

  try {
    scenarioA = await runScenarioA(opts.baseUrl, sql, mint, opts.probes, runId, createdUserIds);
    scenarioC = await runScenarioC(
      opts.baseUrl,
      sql,
      mint,
      runId,
      opts.chats,
      opts.parallel,
      opts.workflow,
      opts.allowOffline,
      opts.model,
      createdUserIds,
      createdSpaceIds,
    );
    scenarioD = await runScenarioD(sql, 50).catch((err: Error) => {
      console.warn(`  WARN: real-request scenario skipped: ${err.message}`);
      return null;
    });
  } catch (err) {
    fatalError = err as Error;
    console.error(`\nERROR: ${fatalError.message}`);
  } finally {
    try {
      cleanupReport = await cleanupRun(
        sql,
        opts.baseUrl,
        mint,
        runId,
        createdUserIds,
        createdSpaceIds,
      );
    } finally {
      await sql.close();
    }
  }

  if (fatalError) {
    process.exit(1);
  }

  const observedP95: Record<string, number | null> = {
    "transport.probe_0b": scenarioA?.variants.probe_0b?.roundTripMs.p95 ?? null,
    "transport.probe_1024b": scenarioA?.variants.probe_1024b?.roundTripMs.p95 ?? null,
    "transport.probe_32768b": scenarioA?.variants.probe_32768b?.roundTripMs.p95 ?? null,
    "workflows.real.total": scenarioC?.totalMs.p95 ?? null,
    "workflows.real.requestToAssignment": scenarioC && "intervals" in scenarioC ? scenarioC.intervals?.requestToAssignmentMs.p95 ?? null : null,
    "workflows.real.assignmentToDispatch": scenarioC && "intervals" in scenarioC ? scenarioC.intervals?.assignmentToDispatchMs.p95 ?? null : null,
    "workflows.real.dispatchToAcknowledgement": scenarioC && "intervals" in scenarioC ? scenarioC.intervals?.dispatchToAcknowledgementMs.p95 ?? null : null,
    "workflows.real.startPermitToRunning": scenarioC && "intervals" in scenarioC ? scenarioC.intervals?.startPermitToRunningMs.p95 ?? null : null,
  };

  let thresholdResult = { violations: [] as ThresholdViolation[], checked: 0, skipped: 0 };
  if (opts.checkThresholds) {
    console.log(`\n== Thresholds (${opts.thresholdsPath})`);
    thresholdResult = checkThresholds(opts.thresholdsPath, observedP95, [
      "transport.",
      ...(opts.chats === 0 ? ["workflows."] : []),
    ]);
    console.log(`  ${thresholdResult.violations.length ? "FAIL" : "PASS"}: ${thresholdResult.checked} checked, ${thresholdResult.skipped} deliberately skipped`);
  } else {
    console.log(`\n== Thresholds: skipped (--no-thresholds)`);
  }

  const reportJson = {
    schemaVersion: 1,
    commit,
    gitDirty,
    date,
    machine,
    parameters: {
      probes: opts.probes,
      chats: opts.chats,
      parallel: opts.parallel,
      workflow: opts.workflow,
      allowOffline: opts.allowOffline,
      model: opts.model,
      thresholdsChecked: opts.checkThresholds,
    },
    scenarios: {
      transport: scenarioA,
      workflows: scenarioC,
      realRequests: scenarioD,
    },
    cleanup: cleanupReport,
    thresholds: {
      checked: thresholdResult.checked,
      violations: thresholdResult.violations,
      skipped: thresholdResult.skipped,
      passed: opts.checkThresholds ? thresholdResult.violations.length === 0 : null,
    },
  };

  if (opts.jsonPath) {
    writeFileSync(opts.jsonPath, JSON.stringify(reportJson, null, 2) + "\n");
    console.log(`\nWrote JSON report to ${opts.jsonPath}`);
  }

  const hasErrors =
    (scenarioC?.errors ?? 0) > 0 ||
    (cleanupReport?.remainingPerfRows ?? 0) > 0 ||
    (opts.checkThresholds && thresholdResult.violations.length > 0);

  process.exit(hasErrors ? 1 : 0);
}

void main();
