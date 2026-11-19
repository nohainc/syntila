#!/usr/bin/env bun
/**
 * Local performance runner for Syntila.
 *
 * Usage:
 *   scripts/perf-local.sh [--probes N] [--chats N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--no-thresholds]
 *
 * Scenarios:
 *   A "transport": Delivery probes against the developer account's live Workspace
 *                  (payloadBytes 0, 1024, 32768).
 *   C "workflows": sequential Chat requests on the developer’s real Workspace.
 *
 * Cleanup removes all synthetic spaces, workspaces, workflow instances, events,
 * and users created during the run without touching the developer account's data.
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

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DEV_EMAIL = process.env.SYNTILA_DEV_EMAIL ?? "vitalii@nohainc.com";
const DEFAULT_THRESHOLDS_PATH = join(ROOT, "scripts/perf-thresholds.json");

interface CliOptions {
  probes: number;
  workflow: "chat" | "work";
  allowOffline: boolean;
  model: string | null;
  chats: number;
  jsonPath: string | null;
  thresholdsPath: string;
  checkThresholds: boolean;
  baseUrl: string;
}

function parseCli(argv: string[]): CliOptions {
  const opts: CliOptions = {
    probes: 50,
    workflow: "chat",
    allowOffline: false,
    model: null,
    chats: 1,
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
        "Usage: scripts/perf-local.sh [--probes N] [--chats N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--thresholds file.json] [--no-thresholds]",
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
      throw new Error("Local backend updates user data during discovery. Restart it on the current build before running transport probes.");
    }
  } finally {
    await sql`DELETE FROM users WHERE id = ${id}`;
  }
}

/**
 * Discovers the developer account's user ID and Workspace ID without
 * hard-coding them or modifying the developer account's rows.
 */
async function resolveDeveloperIdentity(
  sql: SQL,
  base: string,
  mint: ReturnType<typeof tokenMinter>,
  runId: string,
  createdUserIds: Set<string>,
): Promise<{
  userId: string | null;
  workspace: {
    id: string;
    name: string;
    status: string;
    activeTransport: string | null;
  } | null;
  token: string | null;
}> {
  const rows = await sql<{ id: string; email: string; display_name: string }[]>`
    SELECT id, email, display_name FROM users WHERE LOWER(email) = LOWER(${DEV_EMAIL}) AND status = 'active' LIMIT 1
  `;
  const devRow = rows[0];
  if (!devRow) return { userId: null, workspace: null, token: null };
  if (!devRow.display_name) throw new Error("Developer account has no display name; cannot safely mint a matching token.");
  await verifyReadOnlyDiscovery(sql, base, mint, runId, createdUserIds);
  const token = await mint(devRow.id, {
    email: devRow.email,
    name: devRow.display_name,
  });
  const devUser = new User(base, token);
  // Confirm user id through /api/session and find Workspace id through /api/workspaces.
  const sessionRes = await devUser.api("GET", "/api/session");
  if (sessionRes.status !== 200 || !sessionRes.body?.user?.id) {
    throw new Error(`Failed to verify developer session via /api/session (HTTP ${sessionRes.status})`);
  }
  const confirmedUserId = String(sessionRes.body.user.id);
  const wsRes = await devUser.api("GET", "/api/workspaces");
  if (wsRes.status !== 200 || !Array.isArray(wsRes.body?.workspaces)) {
    throw new Error(`Failed to list developer Workspaces via /api/workspaces (HTTP ${wsRes.status})`);
  }
  const workspaces = wsRes.body.workspaces as Array<Record<string, unknown>>;
  const owned = workspaces.filter((w) => !w.shared);
  const chosen =
    owned.find((w) => w.activeTransport !== null) ??
    owned.find((w) => w.status === "online") ??
    owned[0] ??
    null;
  return {
    userId: confirmedUserId,
    workspace: chosen
      ? {
          id: String(chosen.id),
          name: String(chosen.name ?? chosen.id),
          status: String(chosen.status ?? "offline"),
          activeTransport:
            typeof chosen.activeTransport === "string" ? chosen.activeTransport : null,
        }
      : null,
    token,
  };
}

interface ProbeVariantReport {
  payloadBytes: number;
  probed: number;
  acknowledged: number;
  timeouts: number;
  skippedReason?: string;
  roundTripMs: StatSummary;
}

async function runScenarioA(
  base: string,
  sql: SQL,
  mint: ReturnType<typeof tokenMinter>,
  probesCount: number,
  runId: string,
  createdUserIds: Set<string>,
): Promise<{
  status: "completed" | "skipped";
  warning?: string;
  workspaceId: string | null;
  transport: string | null;
  variants: Record<string, ProbeVariantReport>;
}> {
  console.log(`\n== Scenario A: transport (${probesCount} delivery probes per payload size)`);
  if (probesCount <= 0) {
    console.log("  skipped (--probes 0)");
    return { status: "skipped", warning: "probes=0", workspaceId: null, transport: null, variants: {} };
  }
  const dev = await resolveDeveloperIdentity(sql, base, mint, runId, createdUserIds);
  if (!dev.userId || !dev.token) {
    const warning = `Developer account (${DEV_EMAIL}) was not found in the local database; skipping transport probes.`;
    console.warn(`  WARN: ${warning}`);
    return { status: "skipped", warning, workspaceId: null, transport: null, variants: {} };
  }
  if (!dev.workspace) {
    const warning = `Developer account (${DEV_EMAIL}) has no registered Workspace; skipping transport probes.`;
    console.warn(`  WARN: ${warning}`);
    return { status: "skipped", warning, workspaceId: null, transport: null, variants: {} };
  }
  if (!dev.workspace.activeTransport && dev.workspace.status !== "online") {
    const warning = `Workspace "${dev.workspace.name}" (${dev.workspace.id}) is offline; skipping transport probes.`;
    console.warn(`  WARN: ${warning}`);
    return {
      status: "skipped",
      warning,
      workspaceId: dev.workspace.id,
      transport: null,
      variants: {},
    };
  }

  const devUser = new User(base, dev.token);
  const wsId = dev.workspace.id;
  // Quick liveness probe: if the first probe times out (504) or returns 503, the
  // Service is offline or not reading its transport; warn and skip Scenario A
  // instead of waiting 5s × 50 probes.
  const firstProbe = await devUser.api(
    "POST",
    `/api/workspaces/${encodeURIComponent(wsId)}/delivery-probe?count=1`,
  );
  if (firstProbe.status === 503) {
    const warning = `Workspace "${dev.workspace.name}" (${wsId}) is offline (HTTP 503); skipping transport probes.`;
    console.warn(`  WARN: ${warning}`);
    return { status: "skipped", warning, workspaceId: wsId, transport: null, variants: {} };
  }
  if (firstProbe.status === 504 || firstProbe.body?.outcome === "timeout") {
    const warning = `Workspace "${dev.workspace.name}" (${wsId}, transport=${dev.workspace.activeTransport ?? "unknown"}) did not acknowledge the initial delivery probe (outcome=timeout); Service is unresponsive or predates delivery probes. Skipping remaining probes.`;
    console.warn(`  WARN: ${warning}`);
    return {
      status: "skipped",
      warning,
      workspaceId: wsId,
      transport: dev.workspace.activeTransport,
      variants: {
        probe_0b: {
          payloadBytes: 0,
          probed: 1,
          acknowledged: 0,
          timeouts: 1,
          skippedReason: warning,
          roundTripMs: roundStat(summarize([])),
        },
      },
    };
  }

  if (firstProbe.status !== 200 || firstProbe.body?.outcome !== "acknowledged" ||
      typeof firstProbe.body?.roundTripMs !== "number") {
    throw new Error(`Initial delivery probe failed (HTTP ${firstProbe.status}, outcome ${String(firstProbe.body?.outcome ?? "unknown")})`);
  }

  const variants: Record<string, ProbeVariantReport> = {};
  for (const payloadBytes of [0, 1024, 32768]) {
    const key = `probe_${payloadBytes}b`;
    const rtts: number[] = [];
    let timeouts = 0;
    let probed = 0;
    let skippedReason: string | undefined;

    // Seed with the already-executed first probe when payloadBytes === 0.
    let remaining = probesCount;
    if (payloadBytes === 0 && firstProbe.status === 200 && typeof firstProbe.body?.roundTripMs === "number") {
      rtts.push(firstProbe.body.roundTripMs);
      probed += 1;
      remaining -= 1;
    }

    while (remaining > 0) {
      const batch = Math.min(20, remaining);
      const q = new URLSearchParams({ count: String(batch) });
      if (payloadBytes > 0) q.set("payloadBytes", String(payloadBytes));
      const res = await devUser.api(
        "POST",
        `/api/workspaces/${encodeURIComponent(wsId)}/delivery-probe?${q.toString()}`,
      );
      if (res.status === 409 && payloadBytes > 0) {
        skippedReason =
          res.body?.error ??
          "Connected Workspace Service does not advertise workspace.probe_payload.v1";
        console.warn(`  WARN [${key}]: ${skippedReason} (skipping ${payloadBytes}B probes)`);
        break;
      }
      if (res.status === 503) {
        skippedReason = "Workspace went offline during probe batch";
        console.warn(`  WARN [${key}]: ${skippedReason}`);
        break;
      }
      if (res.status !== 200 && res.status !== 504) {
        throw new Error(`Delivery probe failed (HTTP ${res.status})`);
      }
      if (batch === 1) {
        probed += 1;
        if (res.body?.outcome === "acknowledged" && typeof res.body?.roundTripMs === "number") {
          rtts.push(res.body.roundTripMs);
        } else if (res.body?.outcome === "timeout" || res.status === 504) {
          timeouts += 1;
        } else {
          throw new Error(`Delivery probe failed (outcome ${String(res.body?.outcome ?? "unknown")})`);
        }
      } else {
        const list = Array.isArray(res.body?.results) ? res.body.results : [];
        if (list.length !== batch) throw new Error("Delivery probe returned an incomplete batch");
        probed += list.length;
        for (const item of list) {
          if (item?.outcome === "acknowledged" && typeof item.roundTripMs === "number") {
            rtts.push(item.roundTripMs);
          } else if (item?.outcome === "timeout") {
            timeouts += 1;
          } else {
            throw new Error(`Delivery probe failed (outcome ${String(item?.outcome ?? "unknown")})`);
          }
        }
      }
      remaining -= batch;
      // If an entire batch timed out, avoid stalling for minutes on remaining batches.
      if (rtts.length === 0 && timeouts > 0) {
        skippedReason = "All probes in batch timed out; aborting remaining batches";
        console.warn(`  WARN [${key}]: ${skippedReason}`);
        break;
      }
    }

    const summary = roundStat(summarize(rtts));
    variants[key] = {
      payloadBytes,
      probed,
      acknowledged: rtts.length,
      timeouts,
      ...(skippedReason ? { skippedReason } : {}),
      roundTripMs: summary,
    };
    if (!skippedReason || rtts.length > 0) {
      console.log(
        formatStatLine(
          `delivery-probe (payloadBytes=${payloadBytes})`,
          summary,
          `timeouts=${timeouts}/${probed}`,
        ),
      );
    }
  }

  return {
    status: "completed",
    workspaceId: wsId,
    transport: dev.workspace.activeTransport ?? "websocket",
    variants,
  };
}

async function runScenarioC(
  base: string, sql: SQL, mint: ReturnType<typeof tokenMinter>, runId: string,
  chatsCount: number, workflow: "chat" | "work", allowOffline: boolean, model: string | null, createdUserIds: Set<string>, createdSpaceIds: Set<string>,
) {
  console.log(`\n== Scenario C: real Workspace ${workflow} workflow (${chatsCount} sequential requests)`);
  if (chatsCount === 0) return { requests: 0, errors: 0, totalMs: roundStat(summarize([])) };
  const dev = await resolveDeveloperIdentity(sql, base, mint, `${runId}-workflow`, createdUserIds);
  if (!dev.token || !dev.workspace) {
    throw new Error(`A registered Workspace for ${DEV_EMAIL} is required for the real workflow benchmark`);
  }
  if (!dev.workspace.activeTransport && dev.workspace.status !== "online") {
    if (!allowOffline) throw new Error(`A connected Workspace for ${DEV_EMAIL} is required (or use --allow-offline for a controlled readiness test)`);
    console.log(`  Workspace ${dev.workspace.id} is offline; start it within 180 seconds to measure recovery.`);
  }
  const [worker] = await sql<{ worker_id: string }[]>`
    SELECT worker_id FROM workspace_worker_inventory
     WHERE workspace_id = ${dev.workspace.id} AND activation_state = 'enabled' AND readiness_state = 'ready'
       AND (${process.env.SYNTILA_PERF_WORKER_ID ?? null}::text IS NULL OR worker_id = ${process.env.SYNTILA_PERF_WORKER_ID ?? null})
     ORDER BY CASE WHEN worker_type_id = 'chatgpt' THEN 0 ELSE 1 END, worker_id LIMIT 1`;
  if (!worker) throw new Error("No ready Worker found on the real Workspace; check SYNTILA_PERF_WORKER_ID");
  const user = new User(base, dev.token);
  const { spaceId, threadId } = await user.spaceWithThread(`perf-${runId}-real-workflow`);
  createdSpaceIds.add(spaceId);
  const totals: number[] = [];
  const admission: number[] = [], serviceWait: number[] = [], delivery: number[] = [], startup: number[] = [];
  let errors = 0;
  try {
    const pick = await user.api("PUT", `/api/spaces/${spaceId}/workflow-workspace`, {
      workspaceId: dev.workspace.id, confirmReset: true,
    });
    if (pick.status !== 200) throw new Error(`select real workspace: HTTP ${pick.status} ${JSON.stringify(pick.body)}`);
    for (let i = 0; i < chatsCount; i++) {
      const start = performance.now();
      const submit = await user.api("POST", `/api/threads/${threadId}/work-requests`, {
        workflowId: workflow === "work" ? "direct" : "chat", objective: "Reply with the single word: pong. Do not use tools or modify any files.",
        executionSelection: { workerId: worker.worker_id, ...(model ? { model } : {}) },
      });
      if (submit.status >= 300 || !submit.body?.workRequest?.id) {
        console.error(`  request ${i + 1} rejected: HTTP ${submit.status} ${JSON.stringify(submit.body)}`);
        errors++;
        continue;
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
    }
    const totalMs = roundStat(summarize(totals));
    console.log(formatStatLine("real request -> completed result (includes polling)", totalMs));
    const intervals = {
      requestToAssignmentMs: roundStat(summarize(admission)),
      assignmentToDispatchMs: roundStat(summarize(serviceWait)),
      dispatchToAcknowledgementMs: roundStat(summarize(delivery)),
      startPermitToRunningMs: roundStat(summarize(startup)),
    };
    for (const [name, stat] of Object.entries(intervals)) console.log(formatStatLine(name, stat));
    return { requests: chatsCount, errors, totalMs, intervals, workflow, workspaceId: dev.workspace.id };
  } finally {
    // Delete only after no request is active; retain timed-out runs for inspection.
    const [active] = await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM work_requests WHERE thread_id = ${threadId} AND status NOT IN ('completed', 'failed', 'cancelled')`;
    if (!active?.count) {
      const deleted = await user.api("DELETE", `/api/spaces/${spaceId}`);
      if (deleted.status >= 300) throw new Error(`Could not clean up benchmark Space ${spaceId}: HTTP ${deleted.status}`);
      createdSpaceIds.delete(spaceId);
    } else {
      createdSpaceIds.delete(spaceId);
      console.warn(`  Preserved benchmark Space ${spaceId}: ${active.count} request(s) still active`);
    }
  }
}

interface CleanupReport {
  spacesDeletedViaApi: number;
  spacesDeletedInDb: number;
  workspacesRemoved: number;
  usersRemoved: number;
  remainingPerfRows: number;
}

/** Historical timings are approximations from persisted timestamps, not UI
 * observations. Include requests without an assignment so stalled work is not
 * silently excluded. Multiple attempts are reported separately. */
async function runScenarioD(sql: SQL, limit: number) {
  console.log(`\n== Scenario D: real requests of the developer Workspace (last ${limit}, read-only)`);
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
  sql: SQL,
  base: string,
  mint: ReturnType<typeof tokenMinter>,
  runId: string,
  createdUserIds: Set<string>,
  createdSpaceIds: Set<string>,
  createdWorkspaceIds: Set<string>,
): Promise<CleanupReport> {
  console.log(`\n== Cleanup (run perf-${runId})`);
  let spacesDeletedViaApi = 0;

  // Let in-flight background workflow/realtime tasks settle before cleanup.
  await sleep(150);

  // Recover resources created before a request failed, but only for this run.
  const perfPattern = `perf-${runId}-%`;

  // Find all synthetic user IDs, space IDs, workspace IDs, thread IDs, work request IDs, and run IDs.
  const perfUsers = await sql<{ id: string }[]>`
    SELECT id FROM users WHERE id LIKE ${perfPattern} OR email LIKE ${perfPattern}
  `;
  for (const u of perfUsers) createdUserIds.add(u.id);

  const perfSpaces = await sql<{ id: string }[]>`
    SELECT id FROM spaces WHERE name LIKE ${perfPattern} OR owner_user_id LIKE ${perfPattern}
  `;
  for (const s of perfSpaces) createdSpaceIds.add(s.id);

  const perfWorkspaces = await sql<{ id: string }[]>`
    SELECT id FROM execution_workspaces WHERE name LIKE ${perfPattern} OR owner_user_id LIKE ${perfPattern}
  `;
  for (const w of perfWorkspaces) createdWorkspaceIds.add(w.id);

  const userList = [...createdUserIds];
  const spaceList = [...createdSpaceIds];
  const wsList = [...createdWorkspaceIds];

  let spacesDeletedInDb = 0;
  let workspacesRemoved = 0;
  let usersRemoved = 0;

  // Capture workflow instances while the Space and run records still exist.
  // Deleting Spaces first cascades away the links needed to identify them.
  if (spaceList.length > 0) {
    await sql`
      DELETE FROM workflow_instances
      WHERE params::jsonb ->> 'spaceId' IN ${sql(spaceList)}
         OR id IN (
           SELECT COALESCE(r.workflow_instance_id, 'workflow-' || r.work_request_id)
           FROM runs r WHERE r.space_id IN ${sql(spaceList)}
         )
    `;
  }

  for (const spaceId of createdSpaceIds) {
    const [row] = await sql<{ owner_user_id: string }[]>`
      SELECT owner_user_id FROM spaces WHERE id = ${spaceId}
    `;
    if (row && userList.includes(row.owner_user_id)) {
      const owner = new User(base, await mint(row.owner_user_id));
      const res = await owner.api("DELETE", `/api/spaces/${spaceId}`).catch(() => null);
      if (res && res.status < 300) spacesDeletedViaApi++;
    }
  }

  if (wsList.length > 0) {
    await sql`DELETE FROM account_execution_waiters WHERE requester_user_id IN ${sql(userList.length ? userList : ["__none__"])}`;
    await sql`DELETE FROM worker_activity_history WHERE workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM worker_assignments WHERE execution_workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM work_request_inputs WHERE workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM thread_runtime_leases WHERE workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM thread_execution_policies WHERE primary_workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM work_requests WHERE primary_workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM workspace_space_grants WHERE workspace_id IN ${sql(wsList)}`;
    await sql`
      DELETE FROM worker_scheduling
      WHERE worker_id IN (SELECT worker_id FROM workspace_worker_inventory WHERE workspace_id IN ${sql(wsList)})
    `;
    await sql`DELETE FROM workspace_worker_inventory WHERE workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM workspace_installations WHERE workspace_id IN ${sql(wsList)}`;
    await sql`DELETE FROM durable_object_storage WHERE namespace = 'WorkspaceGateway' AND object_name IN ${sql(wsList)}`;
    await sql`DELETE FROM durable_object_alarms WHERE namespace = 'WorkspaceGateway' AND object_name IN ${sql(wsList)}`;
  }

  if (spaceList.length > 0) {
    await sql`
      DELETE FROM durable_object_storage
      WHERE (namespace = 'RealtimeGateway' AND (object_name IN ${sql(spaceList)} OR object_name IN ${sql(spaceList.map((id) => `space:${id}`))}))
         OR (namespace = 'ThreadExecutionCoordinator' AND object_name IN (SELECT id FROM threads WHERE space_id IN ${sql(spaceList)}))
    `;
    await sql`DELETE FROM realtime_events WHERE space_id IN ${sql(spaceList)} OR stream_id IN ${sql(spaceList)}`;
    await sql`DELETE FROM realtime_event_cursors WHERE stream_key IN ${sql(spaceList)} OR stream_id IN ${sql(spaceList)}`;
    const delSpaces = await sql`DELETE FROM spaces WHERE id IN ${sql(spaceList)} RETURNING id`;
    spacesDeletedInDb = delSpaces.length;
  }

  if (wsList.length > 0) {
    await sql`DELETE FROM realtime_events WHERE workspace_id IN ${sql(wsList)} OR stream_id IN ${sql(wsList)}`;
    await sql`DELETE FROM realtime_event_cursors WHERE stream_key IN ${sql(wsList)} OR workspace_id IN ${sql(wsList)}`;
    const delWs = await sql`DELETE FROM execution_workspaces WHERE id IN ${sql(wsList)} RETURNING id`;
    workspacesRemoved = delWs.length;
  }

  if (userList.length > 0) {
    await sql`DELETE FROM mutation_receipts WHERE user_id IN ${sql(userList)}`;
    await sql`DELETE FROM auth_audit_events WHERE user_id IN ${sql(userList)}`;
    await sql`DELETE FROM email_outbox WHERE message::text LIKE ${`%perf-${runId}-%@syntila.invalid%`}`;
    await sql`DELETE FROM realtime_events WHERE stream_id IN ${sql(userList)}`;
    await sql`DELETE FROM realtime_event_cursors WHERE stream_key IN ${sql(userList)} OR stream_id IN ${sql(userList)}`;
    await sql`DELETE FROM conversation_user_messages WHERE author_user_id IN ${sql(userList)}`;
    await sql`DELETE FROM work_requests WHERE requested_by_user_id IN ${sql(userList)}`;
    await sql`DELETE FROM spaces WHERE owner_user_id IN ${sql(userList)}`;
    const delUsers = await sql`DELETE FROM users WHERE id IN ${sql(userList)} RETURNING id`;
    usersRemoved = delUsers.length;
  }

  const [remRow] = await sql<{ remaining: number | bigint }[]>`
    SELECT (
      (SELECT count(*) FROM users WHERE id LIKE ${perfPattern} OR email LIKE ${perfPattern}) +
      (SELECT count(*) FROM spaces WHERE name LIKE ${perfPattern} OR owner_user_id LIKE ${perfPattern}) +
      (SELECT count(*) FROM execution_workspaces WHERE name LIKE ${perfPattern} OR owner_user_id LIKE ${perfPattern}) +
      (SELECT count(*) FROM discussion_messages WHERE author_user_id LIKE ${perfPattern} OR body LIKE ${perfPattern}) +
      (SELECT count(*) FROM work_requests WHERE requested_by_user_id LIKE ${perfPattern}) +
      (SELECT count(*) FROM worker_assignments WHERE requested_by_user_id LIKE ${perfPattern}) +
      (SELECT count(*) FROM workflow_instances WHERE params::jsonb ->> 'spaceId' IN ${sql(spaceList.length ? spaceList : ["__none__"])})
    ) AS remaining
  `;
  const remainingPerfRows = Number(remRow?.remaining ?? 0);

  console.log(
    `  cleaned: ${spacesDeletedViaApi} space(s) via API (+${spacesDeletedInDb} in DB), ${workspacesRemoved} synthetic workspace(s), ${usersRemoved} synthetic user(s); remaining rows for this run: ${remainingPerfRows}`,
  );

  return {
    spacesDeletedViaApi,
    spacesDeletedInDb,
    workspacesRemoved,
    usersRemoved,
    remainingPerfRows,
  };
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
  const createdWorkspaceIds = new Set<string>();

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
        createdWorkspaceIds,
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
      ...(opts.probes === 0 ? ["transport."] : []),
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
