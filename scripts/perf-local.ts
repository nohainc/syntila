#!/usr/bin/env bun
/**
 * Local performance runner for Syntila.
 *
 * Usage:
 *   scripts/perf-local.sh [--probes N] [--users N] [--messages N] [--chats N] [--json out.json] [--no-thresholds]
 *
 * Scenarios:
 *   A "transport": Delivery probes against the developer account's live Workspace
 *                  (payloadBytes 0, 1024, 32768).
 *   B "messages":  N synthetic users (prefixed perf-<runid>) each post M messages
 *                  with a live realtime WebSocket; reports REST and fan-out latency.
 *   C "workflows": C concurrent Chat requests and a Free-account serial queue
 *                  benchmark through an immediate-answering FakeWorkspace,
 *                  reporting observed Service timings and request totals.
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
  FakeWorkspace,
  User,
  publishedChatgptProfile,
  runMessagePosts,
  sleep,
  tokenMinter,
  waitFor,
  type Client,
  type Jwk,
} from "../apps/backend/scripts/lib/clients";
import { summarize } from "./latency-baseline.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DEV_EMAIL = process.env.SYNTILA_DEV_EMAIL ?? "vitalii@nohainc.com";
const DEFAULT_THRESHOLDS_PATH = join(ROOT, "scripts/perf-thresholds.json");

interface CliOptions {
  probes: number;
  users: number;
  messages: number;
  chats: number;
  jsonPath: string | null;
  thresholdsPath: string;
  checkThresholds: boolean;
  baseUrl: string;
}

function parseCli(argv: string[]): CliOptions {
  const opts: CliOptions = {
    probes: 50,
    users: 10,
    messages: 10,
    chats: 10,
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
    else if (arg === "--users") opts.users = nextInt();
    else if (arg === "--messages") opts.messages = nextInt();
    else if (arg === "--chats") opts.chats = nextInt();
    else if (arg === "--json") opts.jsonPath = next();
    else if (arg === "--thresholds") opts.thresholdsPath = resolve(next());
    else if (arg === "--no-thresholds") opts.checkThresholds = false;
    else if (arg === "-h" || arg === "--help") {
      console.log(
        "Usage: scripts/perf-local.sh [--probes N] [--users N] [--messages N] [--chats N] [--json out.json] [--thresholds file.json] [--no-thresholds]",
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

async function waitForAll<T>(tasks: Promise<T>[]): Promise<void> {
  const settled = await Promise.allSettled(tasks);
  const failed = settled.find((result) => result.status === "rejected");
  if (failed?.status === "rejected") throw failed.reason;
}

async function runScenarioB(
  base: string,
  mint: ReturnType<typeof tokenMinter>,
  runId: string,
  usersCount: number,
  messagesCount: number,
  createdUserIds: Set<string>,
  createdSpaceIds: Set<string>,
): Promise<{
  users: number;
  messagesPerUser: number;
  totalMessages: number;
  errors: number;
  throughputMsgPerSec: number;
  restPostMs: StatSummary;
  realtimeFanoutMs: StatSummary;
}> {
  console.log(
    `\n== Scenario B: messages (${usersCount} synthetic users × ${messagesCount} messages with live socket)`,
  );
  if (usersCount <= 0 || messagesCount <= 0) {
    console.log("  skipped (users=0 or messages=0)");
    const empty = roundStat(summarize([]));
    return {
      users: usersCount,
      messagesPerUser: messagesCount,
      totalMessages: 0,
      errors: 0,
      throughputMsgPerSec: 0,
      restPostMs: empty,
      realtimeFanoutMs: empty,
    };
  }

  const clients: Client[] = [];
  try {
    await waitForAll(
      Array.from({ length: usersCount }, async (_, i) => {
        const sub = `perf-${runId}-u${i}`;
        createdUserIds.add(sub);
        const user = new User(base, await mint(sub));
        const { spaceId, threadId } = await user.spaceWithThread(`perf-${runId}-space-${i}`);
        createdSpaceIds.add(spaceId);
        const live = user.realtime([spaceId]);
        await live.waitFor("subscription", (f) => f.type === "subscription.confirmed", 30_000);
        clients.push({ user, spaceId, threadId, live });
      }),
    );

    const { rest, fanout, errors, throughput } = await runMessagePosts(
      clients,
      messagesCount,
      `perf-${runId}`,
    );
    const restStat = roundStat(summarize(rest));
    const fanoutStat = roundStat(summarize(fanout));
    const throughputRounded = Math.round(throughput * 10) / 10;

    console.log(formatStatLine("POST message (REST)", restStat));
    console.log(formatStatLine("post -> realtime socket fan-out", fanoutStat));
    console.log(
      `  throughput: ${throughputRounded.toFixed(1)} messages/s, errors: ${errors}`,
    );

    return {
      users: usersCount,
      messagesPerUser: messagesCount,
      totalMessages: rest.length,
      errors,
      throughputMsgPerSec: throughputRounded,
      restPostMs: restStat,
      realtimeFanoutMs: fanoutStat,
    };
  } finally {
    for (const c of clients) c.live.close();
  }
}

interface TraceTiming {
  assignmentId: string;
  receivedMs: number;
  acceptedMs: number;
  startedMs: number;
}

async function grantPaidPlan(sql: SQL, userId: string, email: string): Promise<void> {
  const now = new Date().toISOString();
  await sql`
    INSERT INTO users (id, email, display_name, status, created_at, updated_at)
    VALUES (${userId}, ${email}, ${userId}, 'active', ${now}, ${now})
    ON CONFLICT (id) DO NOTHING
  `;
  await sql`
    INSERT INTO account_plans (user_id, tier, status, source, current_period_end, created_at, updated_at)
    VALUES (${userId}, 'paid', 'active', 'manual', NULL, ${now}, ${now})
    ON CONFLICT (user_id) DO UPDATE SET tier = 'paid', status = 'active', updated_at = ${now}
  `;
}

async function runScenarioC(
  base: string,
  sql: SQL,
  mint: ReturnType<typeof tokenMinter>,
  runId: string,
  chatsCount: number,
  createdUserIds: Set<string>,
  createdSpaceIds: Set<string>,
  createdWorkspaceIds: Set<string>,
): Promise<{
  concurrent: {
    requests: number;
    errors: number;
    totalMs: StatSummary;
    intervals: Record<string, StatSummary>;
  };
  serialFreeAccount: {
    requests: number;
    errors: number;
    requestTotalMs: StatSummary;
    queuedOverheadMs: StatSummary;
  };
}> {
  console.log(
    `\n== Scenario C: workflows (${chatsCount} concurrent Chat requests + Free-account serial queue)`,
  );
  const emptyStat = roundStat(summarize([]));
  if (chatsCount <= 0) {
    console.log("  skipped (chats=0)");
    return {
      concurrent: { requests: 0, errors: 0, totalMs: emptyStat, intervals: {} },
      serialFreeAccount: {
        requests: 0,
        errors: 0,
        requestTotalMs: emptyStat,
        queuedOverheadMs: emptyStat,
      },
    };
  }

  const profile = await publishedChatgptProfile();
  if (!profile) throw new Error("No ChatGPT Tool Profile published; cannot run workflows");

  const ownerSub = `perf-${runId}-wf-owner`;
  const ownerEmail = `${ownerSub}@syntila.invalid`;
  createdUserIds.add(ownerSub);
  // Paid owner so concurrent Chat requests (and high parallelSlots) are not capped by the Free 1-task rule.
  await grantPaidPlan(sql, ownerSub, ownerEmail);

  const owner = new User(base, await mint(ownerSub));
  const desktopToken = await mint(ownerSub, {
    client: "desktop",
    client_aud: "syntila.desktop.management",
  });

  const serviceTraces = new Map<string, TraceTiming>();
  const onAssignment = async (start: Record<string, unknown>, ws: FakeWorkspace) => {
    const receivedMs = Date.now();
    const ids = Object.fromEntries(
      ["workerId", "runId", "taskId", "attemptId", "assignmentId", "idempotencyKey"].map((k) => [
        k,
        start[k],
      ]),
    );
    ws.send("assignment.ack", { accepted: true }, ids);
    const acceptedMs = Date.now();
    ws.send("assignment.start.permit.request", {}, ids);
    await ws.waitFor(
      "start permit",
      (f) => f.type === "assignment.start.permit.grant" && f.assignmentId === start.assignmentId,
    );
    ws.send("assignment.start.ack", {}, ids);
    const startedMs = Date.now();
    serviceTraces.set(String(start.assignmentId), {
      assignmentId: String(start.assignmentId),
      receivedMs,
      acceptedMs,
      startedMs,
    });
    for (let attempt = 0; attempt < 40; attempt++) {
      ws.send(
        "assignment.result",
        { status: "completed", summary: "ok", output: { text: "ok" }, artifactIds: [] },
        ids,
      );
      const acked = await waitFor(
        "terminal ack",
        () =>
          ws.frames.find(
            (f) =>
              f.type === "assignment.ack" &&
              f.payload?.terminal === true &&
              f.assignmentId === start.assignmentId,
          ),
        1500,
      ).catch(() => null);
      if (acked) return;
    }
  };

  const workspace = await new FakeWorkspace(base, profile, onAssignment).register(
    desktopToken,
    `perf-${runId}-ws`,
  );
  createdWorkspaceIds.add(workspace.workspaceId);

  let ownerLive: ReturnType<User["realtime"]> | null = null;
  let freeLive: ReturnType<User["realtime"]> | null = null;

  try {
    workspace.connect();
    await waitFor("workspace ready", () => workspace.ready);

    // Raise parallelSlots to 10 (MAX_PARALLEL_SLOTS) so concurrent requests run in parallel.
    await owner.api("PATCH", `/api/workspaces/${workspace.workspaceId}`, { parallelSlots: 10 });

    const { spaceId, threadId } = await owner.spaceWithThread(`perf-${runId}-wf-space`);
    createdSpaceIds.add(spaceId);

    const pick = await owner.api("PUT", `/api/spaces/${spaceId}/workflow-workspace`, {
      workspaceId: workspace.workspaceId,
      confirmReset: true,
    });
    if (pick.status !== 200) throw new Error(`select workspace: ${pick.status}`);

    // Raise the Space grant's maxConcurrentAssignments so all 10 slots can be used concurrently.
    await sql`
      UPDATE workspace_space_grants
      SET concurrency_json = '{"maxConcurrentAssignments":10}'
      WHERE space_id = ${spaceId} AND workspace_id = ${workspace.workspaceId}
    `;

    ownerLive = owner.realtime([spaceId]);
    await ownerLive.waitFor("subscription", (f) => f.type === "subscription.confirmed", 30_000);

    // 1. Concurrent Chat requests
    // Only report trace endpoints observed by this runner. Database row timestamps
    // are not the corresponding Latency Trace events.
    const intervalSamples: Record<string, number[]> = {
      "service_received->service_accepted": [],
    };
    const concurrentTotals: number[] = [];
    let concurrentErrors = 0;

    await waitForAll(
      Array.from({ length: chatsCount }, async (_, i) => {
        const t0 = performance.now();
        const submit = await owner.api("POST", `/api/threads/${threadId}/work-requests`, {
          workflowId: "chat",
          objective: `perf-${runId}-chat-${i}`,
          executionSelection: { workerId: workspace.workerId },
        });
        if (submit.status >= 300) {
          concurrentErrors++;
          return;
        }
        const reqId = String(submit.body.workRequest.id);

        // Measure until polling observes the completed result.
        const done = await waitFor(
          "chat done",
          async () => {
            const r = await owner.api("GET", `/api/work-requests/${reqId}`);
            return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status)
              ? r.body.workRequest
              : undefined;
          },
          120_000,
        ).catch(() => null);

        if (done?.status !== "completed") {
          concurrentErrors++;
          return;
        }
        const totalElapsed = performance.now() - t0;
        concurrentTotals.push(totalElapsed);

        // These two endpoints are recorded by the FakeWorkspace itself. Other
        // trace events are not available here; do not synthesize their timestamps.
        const [assignment] = await sql<{ id: string }[]>`
          SELECT wa.id FROM worker_assignments wa
          JOIN workflow_tasks wt ON wt.id = wa.task_id
          WHERE wt.work_request_id = ${reqId} LIMIT 1
        `;
        const svc = assignment ? serviceTraces.get(assignment.id) : undefined;
        if (svc) {
          intervalSamples["service_received->service_accepted"]!.push(
            Math.max(0, svc.acceptedMs - svc.receivedMs),
          );
        }
      }),
    );

    const concurrentTotalStat = roundStat(summarize(concurrentTotals));
    const summarizedIntervals: Record<string, StatSummary> = {};
    for (const [name, vals] of Object.entries(intervalSamples)) {
      summarizedIntervals[name] = roundStat(summarize(vals));
    }

    console.log(formatStatLine("concurrent chat total (request -> result)", concurrentTotalStat));
    for (const [name, stat] of Object.entries(summarizedIntervals)) {
      console.log(formatStatLine(`  stage ${name}`, stat));
    }
    if (concurrentErrors > 0) {
      console.log(`  concurrent chat errors: ${concurrentErrors}`);
    }

    // 2. Single Free account serial scenario (product rule: one task at a time per Free account).
    // First measure sequential baseline (1 request at a time, N=5), then submit 2 overlapping
    // requests from the same Free account so the second waits for the first's slot release,
    // and report per-request time and queueing overhead.
    const freeSub = `perf-${runId}-free`;
    createdUserIds.add(freeSub);
    const freeUser = new User(base, await mint(freeSub));

    // Add freeSub as collaborator on the Space and grant person access on the Workspace.
    const inv = await owner.api("POST", `/api/spaces/${spaceId}/invitations`, {
      email: `${freeSub}@syntila.invalid`,
      role: "collaborator",
    });
    if (inv.status === 201 && inv.body?.invitation?.id) {
      await freeUser.api("POST", `/api/space-invitations/${inv.body.invitation.id}/accept`, {});
    }

    const freeThreads = await freeUser.api("POST", `/api/spaces/${spaceId}/threads`, {
      name: `perf-${runId}-free-thread`,
    });
    const freeThreadId = freeThreads.body?.thread?.id ?? freeThreads.body?.id ?? threadId;

    freeLive = freeUser.realtime([spaceId]);
    await freeLive.waitFor("subscription", (f) => f.type === "subscription.confirmed", 30_000);

    const serialCount = Math.min(5, Math.max(3, Math.floor(chatsCount / 2)));
    const serialDurations: number[] = [];
    const serialOverheads: number[] = [];
    let serialErrors = 0;

    for (let s = 0; s < serialCount; s++) {
      const start = performance.now();
      const submit = await freeUser.api("POST", `/api/threads/${freeThreadId}/work-requests`, {
        workflowId: "chat",
        objective: `perf-${runId}-serial-${s}`,
        executionSelection: { workerId: workspace.workerId },
      });
      if (submit.status >= 300) {
        serialErrors++;
        continue;
      }
      const reqId = String(submit.body.workRequest.id);
      const done = await waitFor(
        "serial chat done",
        async () => {
          const r = await freeUser.api("GET", `/api/work-requests/${reqId}`);
          return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status)
            ? r.body.workRequest
            : undefined;
        },
        60_000,
      ).catch(() => null);
      if (done?.status !== "completed") {
        serialErrors++;
        continue;
      }
      const totalMs = performance.now() - start;
      serialDurations.push(totalMs);

      // Estimate overhead by subtracting the fake Service receive-to-start interval.
      const [asgRow] = await sql<{ id: string }[]>`
        SELECT wa.id FROM worker_assignments wa
        JOIN workflow_tasks wt ON wt.id = wa.task_id
        WHERE wt.work_request_id = ${reqId} LIMIT 1
      `;
      const svc = asgRow ? serviceTraces.get(asgRow.id) : undefined;
      const serviceExecMs = svc ? Math.max(0, svc.startedMs - svc.receivedMs) : 0;
      serialOverheads.push(Math.max(0, totalMs - serviceExecMs));
    }

    const serialTotalStat = roundStat(summarize(serialDurations));
    const serialOverheadStat = roundStat(summarize(serialOverheads));
    console.log(
      formatStatLine("Free account serial chat (per request)", serialTotalStat),
    );
    console.log(
      formatStatLine("Free account serial overhead (estimate)", serialOverheadStat),
    );

    return {
      concurrent: {
        requests: chatsCount,
        errors: concurrentErrors,
        totalMs: concurrentTotalStat,
        intervals: summarizedIntervals,
      },
      serialFreeAccount: {
        requests: serialCount,
        errors: serialErrors,
        requestTotalMs: serialTotalStat,
        queuedOverheadMs: serialOverheadStat,
      },
    };
  } finally {
    ownerLive?.close();
    freeLive?.close();
    await workspace.release(desktopToken).catch(() => undefined);
  }
}

interface CleanupReport {
  spacesDeletedViaApi: number;
  spacesDeletedInDb: number;
  workspacesRemoved: number;
  usersRemoved: number;
  remainingPerfRows: number;
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
    `  cleaned: ${spacesDeletedViaApi} space(s) via API (+${spacesDeletedInDb} in DB), ${workspacesRemoved} fake workspace(s), ${usersRemoved} synthetic user(s); remaining rows for this run: ${remainingPerfRows}`,
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
  measuredP95: number;
  limitP95: number;
}

function checkThresholds(
  thresholdsPath: string,
  observedP95: Record<string, number | null>,
): { violations: ThresholdViolation[]; checked: number } {
  if (!existsSync(thresholdsPath)) {
    throw new Error(`Thresholds file not found: ${thresholdsPath}`);
  }
  const parsed = JSON.parse(readFileSync(thresholdsPath, "utf8")) as {
    metrics?: Record<string, { p95Ms?: number }>;
  };
  const metrics = parsed.metrics ?? {};
  const violations: ThresholdViolation[] = [];
  let checked = 0;

  for (const [metric, rule] of Object.entries(metrics)) {
    const limit = rule?.p95Ms;
    if (typeof limit !== "number" || !Number.isFinite(limit)) continue;
    const measured = observedP95[metric];
    if (measured === null || measured === undefined || !Number.isFinite(measured)) {
      continue;
    }
    checked++;
    if (measured > limit) {
      violations.push({ metric, measuredP95: measured, limitP95: limit });
    }
  }
  return { violations, checked };
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
  const date = new Date().toISOString();
  const machine = getMachineInfo();

  console.log(`Syntila Local Performance Runner`);
  console.log(`  commit: ${commit}  date: ${date}`);
  console.log(`  machine: ${machine.cpu} (${machine.cores} cores, ${machine.memoryGb} GB) — ${machine.os}`);
  console.log(`  backend: ${opts.baseUrl}  run: perf-${runId}`);

  let scenarioA: Awaited<ReturnType<typeof runScenarioA>> | null = null;
  let scenarioB: Awaited<ReturnType<typeof runScenarioB>> | null = null;
  let scenarioC: Awaited<ReturnType<typeof runScenarioC>> | null = null;
  let cleanupReport: CleanupReport | null = null;
  let fatalError: Error | null = null;

  try {
    scenarioA = await runScenarioA(opts.baseUrl, sql, mint, opts.probes, runId, createdUserIds);
    scenarioB = await runScenarioB(
      opts.baseUrl,
      mint,
      runId,
      opts.users,
      opts.messages,
      createdUserIds,
      createdSpaceIds,
    );
    scenarioC = await runScenarioC(
      opts.baseUrl,
      sql,
      mint,
      runId,
      opts.chats,
      createdUserIds,
      createdSpaceIds,
      createdWorkspaceIds,
    );
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
    "messages.rest_post": scenarioB?.restPostMs.p95 ?? null,
    "messages.realtime_fanout": scenarioB?.realtimeFanoutMs.p95 ?? null,
    "workflows.concurrent.total": scenarioC?.concurrent.totalMs.p95 ?? null,
    ...Object.fromEntries(
      Object.entries(scenarioC?.concurrent.intervals ?? {}).map(([k, v]) => [
        `workflows.concurrent.${k}`,
        v.p95,
      ]),
    ),
    "workflows.serial.request_total": scenarioC?.serialFreeAccount.requestTotalMs.p95 ?? null,
    "workflows.serial.queued_overhead": scenarioC?.serialFreeAccount.queuedOverheadMs.p95 ?? null,
  };

  let thresholdResult = { violations: [] as ThresholdViolation[], checked: 0 };
  if (opts.checkThresholds) {
    thresholdResult = checkThresholds(opts.thresholdsPath, observedP95);
    console.log(`\n== Thresholds (${opts.thresholdsPath})`);
    if (thresholdResult.violations.length === 0) {
      console.log(`  PASS (${thresholdResult.checked} p95 metrics within limits)`);
    } else {
      for (const v of thresholdResult.violations) {
        console.error(
          `  FAIL ${v.metric}: p95 ${v.measuredP95.toFixed(1)}ms > limit ${v.limitP95.toFixed(1)}ms`,
        );
      }
    }
  } else {
    console.log(`\n== Thresholds: skipped (--no-thresholds)`);
  }

  const reportJson = {
    schemaVersion: 1,
    commit,
    date,
    machine,
    parameters: {
      probes: opts.probes,
      users: opts.users,
      messages: opts.messages,
      chats: opts.chats,
      thresholdsChecked: opts.checkThresholds,
    },
    scenarios: {
      transport: scenarioA,
      messages: scenarioB,
      workflows: scenarioC,
    },
    cleanup: cleanupReport,
    thresholds: {
      checked: thresholdResult.checked,
      violations: thresholdResult.violations,
      passed: thresholdResult.violations.length === 0,
    },
  };

  if (opts.jsonPath) {
    writeFileSync(opts.jsonPath, JSON.stringify(reportJson, null, 2) + "\n");
    console.log(`\nWrote JSON report to ${opts.jsonPath}`);
  }

  const hasErrors =
    (scenarioB?.errors ?? 0) > 0 ||
    (scenarioC?.concurrent.errors ?? 0) > 0 ||
    (scenarioC?.serialFreeAccount.errors ?? 0) > 0 ||
    (cleanupReport?.remainingPerfRows ?? 0) > 0 ||
    (opts.checkThresholds && thresholdResult.violations.length > 0);

  process.exit(hasErrors ? 1 : 0);
}

void main();
