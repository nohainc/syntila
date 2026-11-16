/**
 * Syntila backend process: serves the ported domain API (`/api/*`) on Bun with
 * PostgreSQL, plus health endpoints, background tasks and scheduled jobs.
 */
import { SQL } from "bun";
import { TokenVerifier } from "./auth";
import { loadConfig } from "./config";
import { health } from "./health";
import { pendingMigrations } from "./migrate";
import { pruneOperationalTables } from "./retention";
import { backgroundTaskCount, drainBackgroundTasks, executionContext } from "./platform/background";
import { AuthWorkerSync, EmailOutbox, EmailRelay } from "./platform/email";
import { drainWriterLockStats, PgD1Database } from "./platform/pg-d1";
import { drainTxStats } from "./platform/data";
import { sampleDbHealth } from "./platform/db-health";
import { S3R2Bucket, unconfiguredBucket } from "./platform/r2";
import { configureIdentityVerifier } from "./domain/auth/identity-service";
import worker from "./domain/index";
import { createRuntime } from "./runtime";

// A failed background task must never take down the process (and with it
// every open WebSocket and in-flight request): log it and keep serving.
process.on("unhandledRejection", (reason) => {
  console.error(JSON.stringify({ level: "error", message: "process.unhandled_rejection", error: String((reason as Error)?.stack ?? reason) }));
});
process.on("uncaughtException", (error) => {
  console.error(JSON.stringify({ level: "error", message: "process.uncaught_exception", error: String(error?.stack ?? error) }));
});

const config = await loadConfig();
// Local-only Paddle sandbox settings live outside the repository and are read again
// on development reload. Nonempty environment variables take precedence.
const localPaddle: Record<string, string> = {};
if (process.env.SYNTILA_ENVIRONMENT === 'development') {
  const file = Bun.file('../../.development/local-backend/paddle.env');
  if (await file.exists()) {
    for (const line of (await file.text()).split(/\r?\n/)) {
      const match = line.match(/^(PADDLE_SANDBOX_(?:CLIENT_TOKEN|MONTHLY_PRICE_ID|ANNUAL_PRICE_ID|REFERENCE_SECRET|WEBHOOK_SECRET|API_KEY))=(.*)$/);
      if (match) localPaddle[match[1]!] = match[2]!;
    }
  }
}
const sql = new SQL({
  hostname: config.db.hostname, port: config.db.port, username: config.db.username,
  database: config.db.database, password: config.db.password, max: config.db.max,
  bigint: true, connectionTimeout: 5, idleTimeout: 60,
  connection: { application_name: "syntila-backend", statement_timeout: "30000" },
});
// The global writer lock is off (concurrency plan); SYNTILA_DB_WRITER_LOCK=on
// in /etc/syntila/backend.env turns it back on after a restart.
const writerLock = process.env.SYNTILA_DB_WRITER_LOCK === "on";
const db = new PgD1Database(sql, { writerLock });
if (writerLock) console.warn("SYNTILA_DB_WRITER_LOCK=on: every write takes the global writer lock");

const verifier = new TokenVerifier(config.auth.publicKeys, config.auth.issuer, config.auth.audience);
configureIdentityVerifier(config.auth.publicKeys.length ? verifier : null);
if (!config.auth.publicKeys.length) console.warn("AUTH public keys are not configured: every API call will be unauthenticated");

// Email the backend starts goes through a durable outbox to the auth Worker's relay.
const emailOutbox = process.env.EMAIL_RELAY_URL && process.env.EMAIL_RELAY_SECRET
  ? new EmailOutbox(sql as any, new EmailRelay(process.env.EMAIL_RELAY_URL, process.env.EMAIL_RELAY_SECRET)) : null;
if (!emailOutbox) console.warn("EMAIL_RELAY_URL / EMAIL_RELAY_SECRET are not configured: invitation email is disabled");

const runtime = createRuntime(sql, db, {
  SYNTILA_ENVIRONMENT: process.env.SYNTILA_ENVIRONMENT ?? "production",
  PADDLE_LIVE_CHECKOUT_ENABLED: process.env.PADDLE_LIVE_CHECKOUT_ENABLED,
  PADDLE_LIVE_CLIENT_TOKEN: process.env.PADDLE_LIVE_CLIENT_TOKEN,
  PADDLE_LIVE_MONTHLY_PRICE_ID: process.env.PADDLE_LIVE_MONTHLY_PRICE_ID,
  PADDLE_LIVE_ANNUAL_PRICE_ID: process.env.PADDLE_LIVE_ANNUAL_PRICE_ID,
  PADDLE_LIVE_REFERENCE_SECRET: process.env.PADDLE_LIVE_REFERENCE_SECRET,
  PADDLE_SANDBOX_CLIENT_TOKEN: process.env.PADDLE_SANDBOX_CLIENT_TOKEN || localPaddle.PADDLE_SANDBOX_CLIENT_TOKEN,
  PADDLE_SANDBOX_MONTHLY_PRICE_ID: process.env.PADDLE_SANDBOX_MONTHLY_PRICE_ID || localPaddle.PADDLE_SANDBOX_MONTHLY_PRICE_ID,
  PADDLE_SANDBOX_ANNUAL_PRICE_ID: process.env.PADDLE_SANDBOX_ANNUAL_PRICE_ID || localPaddle.PADDLE_SANDBOX_ANNUAL_PRICE_ID,
  PADDLE_SANDBOX_REFERENCE_SECRET: process.env.PADDLE_SANDBOX_REFERENCE_SECRET || localPaddle.PADDLE_SANDBOX_REFERENCE_SECRET,
  PADDLE_SANDBOX_WEBHOOK_SECRET: process.env.PADDLE_SANDBOX_WEBHOOK_SECRET || localPaddle.PADDLE_SANDBOX_WEBHOOK_SECRET,
  PADDLE_SANDBOX_API_KEY: process.env.PADDLE_SANDBOX_API_KEY || localPaddle.PADDLE_SANDBOX_API_KEY,
  SYNTILA_APP_URL: process.env.SYNTILA_APP_URL ?? "https://app.syntila.app",
  BETTER_AUTH_URL: process.env.SYNTILA_APP_URL ?? "https://app.syntila.app",
  BETTER_AUTH_TRUSTED_ORIGINS: config.allowedOrigins.join(","),
  SYNTILA_SUPPORT_ACCOUNT_EMAIL: process.env.SYNTILA_SUPPORT_ACCOUNT_EMAIL,
  SYNTILA_PROFILE_LAB_OWNER_EMAIL: process.env.SYNTILA_PROFILE_LAB_OWNER_EMAIL,
  SYNTILA_RELEASE_TRUST_KEYS_JSON: process.env.SYNTILA_RELEASE_TRUST_KEYS_JSON,
  SYNTILA_RELEASE_PUBLISHER: process.env.SYNTILA_RELEASE_PUBLISHER,
  SYNTILA_EMAIL_FROM: process.env.SYNTILA_EMAIL_FROM,
  SYNTILA_EMAIL_FALLBACK_FROM: process.env.SYNTILA_EMAIL_FALLBACK_FROM,
  SYNTILA_EMAIL_FROM_NAME: process.env.SYNTILA_EMAIL_FROM_NAME ?? "Syntila",
  SYNTILA_EMAIL: emailOutbox ?? undefined,
  // The relay URL's origin is the auth Worker; it also takes avatar updates.
  SYNTILA_AUTH_SYNC: process.env.EMAIL_RELAY_URL && process.env.EMAIL_RELAY_SECRET
    ? new AuthWorkerSync(new URL(process.env.EMAIL_RELAY_URL).origin, process.env.EMAIL_RELAY_SECRET) : undefined,
  // Values are trimmed: a stray space or line break in the env file makes R2
  // answer 403 SignatureDoesNotMatch. `scripts/check-storage.sh` tests them.
  SYNTILA_ARTIFACTS: process.env.R2_ACCOUNT_ID?.trim()
    ? new S3R2Bucket({ accountId: process.env.R2_ACCOUNT_ID.trim(), bucket: (process.env.R2_BUCKET ?? "syntila-artifacts").trim(),
        accessKeyId: (process.env.R2_ACCESS_KEY_ID ?? "").trim(), secretAccessKey: (process.env.R2_SECRET_ACCESS_KEY ?? "").trim() })
    : unconfiguredBucket,
});

let readyCache = { at: 0, ok: false };
async function checkReady() {
  if (Date.now() - readyCache.at > 2000) {
    try {
      await sql`SELECT 1`;
      readyCache = { at: Date.now(), ok: (await pendingMigrations(sql as any)).length === 0 && config.auth.publicKeys.length > 0 };
    } catch { readyCache = { at: Date.now(), ok: false }; }
  }
  if (!readyCache.ok) throw new Error("not ready");
}

const server = Bun.serve({
  hostname: config.hostname,
  port: config.port,
  idleTimeout: 120,
  async fetch(request, srv) {
    const { pathname } = new URL(request.url);
    if (pathname.startsWith("/health/")) return health(request, checkReady);
    return runtime.fetch(request, srv);
  },
  websocket: runtime.websocket,
});
await runtime.start();
emailOutbox?.start();
console.log(`Syntila backend listening on ${config.hostname}:${server.port}`);
const env = runtime.env;

/* ---------------------------------------------------------- scheduler */
// Same jobs as the Cloudflare cron triggers; an advisory lock keeps them
// single-run when more than one process is deployed.
async function runScheduled(cron: string) {
  const reserved = await sql.reserve();
  try {
    const [{ locked }] = await reserved`SELECT pg_try_advisory_lock(hashtext(${"syntila.cron:" + cron})) AS locked`;
    if (!locked) return;
    try {
      await worker.scheduled({ cron, scheduledTime: Date.now(), noRetry() {} } as any, env);
    } finally {
      await reserved`SELECT pg_advisory_unlock(hashtext(${"syntila.cron:" + cron}))`;
    }
  } catch (e) {
    console.error(JSON.stringify({ level: "error", message: "scheduled.failed", cron, error: String((e as Error)?.stack ?? e) }));
  } finally {
    reserved.release();
  }
}
async function logDbHealth() {
  const tx = drainTxStats();
  if (tx.length) console.log(JSON.stringify({ level: "info", message: "db.tx", details: { count: tx.reduce((n, s) => n + s.count, 0), top: tx.slice(0, 12) } }));
  try {
    console.log(JSON.stringify({ level: "info", message: "db.health", details: await sampleDbHealth(sql as any) }));
  } catch (e) {
    console.error(JSON.stringify({ level: "error", message: "db.health_failed", error: String(e) }));
  }
}
function logWriterLock() {
  const stats = drainWriterLockStats();
  if (!stats.length) return;
  const total = stats.reduce((sum, s) => ({ count: sum.count + s.count, waitMs: sum.waitMs + s.waitMs, holdMs: sum.holdMs + s.holdMs }), { count: 0, waitMs: 0, holdMs: 0 });
  // With the lock on, holdMs / 300000 is the share of the last five minutes it
  // was taken. With it off the same numbers describe adapter write
  // transactions: waitMs is waiting for a pool connection, holdMs their time.
  console.log(JSON.stringify({ level: "info", message: writerLock ? "db.writer_lock" : "db.writes", details: { ...total, top: stats.slice(0, 12) } }));
}
const every5 = setInterval(() => { void runScheduled("*/5 * * * *"); logWriterLock(); void logDbHealth(); }, 5 * 60_000);
let lastDaily = "";
const daily = setInterval(() => {
  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  if (now.getUTCHours() === 3 && now.getUTCMinutes() >= 17 && lastDaily !== day) {
    lastDaily = day;
    void runScheduled("17 3 * * *");
    void pruneOperationalTables(sql as any)
      .then((deleted) => console.log(JSON.stringify({ level: "info", message: "retention.complete", deleted })))
      .catch((e) => console.error(JSON.stringify({ level: "error", message: "retention.failed", error: String((e as Error)?.stack ?? e) })));
  }
}, 60_000);

/* ----------------------------------------------------------- shutdown */
let stopping = false;
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, async () => {
    if (stopping) return;
    stopping = true;
    console.log(`${signal}: draining (${backgroundTaskCount()} background tasks)`);
    clearInterval(every5); clearInterval(daily);
    logWriterLock();
    await logDbHealth();
    // Stop accepting; in-flight HTTP requests get a short drain. Open
    // WebSockets never finish on their own, so they are closed after that and
    // clients reconnect to the next process.
    const drained = server.stop();
    await Promise.race([drained, Bun.sleep(3_000)]);
    await server.stop(true);
    await runtime.stop();
    await emailOutbox?.stop();
    await drainBackgroundTasks(10_000);
    await sql.close({ timeout: 5 });
    process.exit(0);
  });
}
