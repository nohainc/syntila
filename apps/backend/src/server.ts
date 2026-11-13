/**
 * Syntila backend process: serves the ported domain API (`/api/*`) on Bun with
 * PostgreSQL, plus health endpoints, background tasks and scheduled jobs.
 */
import { SQL } from "bun";
import { TokenVerifier } from "./auth";
import { loadConfig } from "./config";
import { health } from "./health";
import { pendingMigrations } from "./migrate";
import { backgroundTaskCount, drainBackgroundTasks, executionContext } from "./platform/background";
import { EmailOutbox, EmailRelay } from "./platform/email";
import { PgD1Database } from "./platform/pg-d1";
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
const sql = new SQL({
  hostname: config.db.hostname, port: config.db.port, username: config.db.username,
  database: config.db.database, password: config.db.password, max: config.db.max,
  bigint: true, connectionTimeout: 5, idleTimeout: 60,
  connection: { application_name: "syntila-backend", statement_timeout: "30000" },
});
const db = new PgD1Database(sql);

const verifier = new TokenVerifier(config.auth.publicKeys, config.auth.issuer, config.auth.audience);
configureIdentityVerifier(config.auth.publicKeys.length ? verifier : null);
if (!config.auth.publicKeys.length) console.warn("AUTH public keys are not configured: every API call will be unauthenticated");

// Email the backend starts goes through a durable outbox to the auth Worker's relay.
const emailOutbox = process.env.EMAIL_RELAY_URL && process.env.EMAIL_RELAY_SECRET
  ? new EmailOutbox(sql as any, new EmailRelay(process.env.EMAIL_RELAY_URL, process.env.EMAIL_RELAY_SECRET)) : null;
if (!emailOutbox) console.warn("EMAIL_RELAY_URL / EMAIL_RELAY_SECRET are not configured: invitation email is disabled");

const runtime = createRuntime(sql, db, {
  SYNTILA_ENVIRONMENT: process.env.SYNTILA_ENVIRONMENT ?? "production",
  SYNTILA_APP_URL: process.env.SYNTILA_APP_URL ?? "https://syntila.app",
  BETTER_AUTH_URL: process.env.SYNTILA_APP_URL ?? "https://syntila.app",
  BETTER_AUTH_TRUSTED_ORIGINS: config.allowedOrigins.join(","),
  SYNTILA_SUPPORT_ACCOUNT_EMAIL: process.env.SYNTILA_SUPPORT_ACCOUNT_EMAIL,
  SYNTILA_PROFILE_LAB_OWNER_EMAIL: process.env.SYNTILA_PROFILE_LAB_OWNER_EMAIL,
  SYNTILA_RELEASE_TRUST_KEYS_JSON: process.env.SYNTILA_RELEASE_TRUST_KEYS_JSON,
  SYNTILA_RELEASE_PUBLISHER: process.env.SYNTILA_RELEASE_PUBLISHER,
  SYNTILA_EMAIL_FROM: process.env.SYNTILA_EMAIL_FROM,
  SYNTILA_EMAIL_FALLBACK_FROM: process.env.SYNTILA_EMAIL_FALLBACK_FROM,
  SYNTILA_EMAIL_FROM_NAME: process.env.SYNTILA_EMAIL_FROM_NAME ?? "Syntila",
  SYNTILA_EMAIL: emailOutbox ?? undefined,
  SYNTILA_ARTIFACTS: process.env.R2_ACCOUNT_ID
    ? new S3R2Bucket({ accountId: process.env.R2_ACCOUNT_ID, bucket: process.env.R2_BUCKET ?? "syntila-artifacts",
        accessKeyId: process.env.R2_ACCESS_KEY_ID ?? "", secretAccessKey: process.env.R2_SECRET_ACCESS_KEY ?? "" })
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
const every5 = setInterval(() => void runScheduled("*/5 * * * *"), 5 * 60_000);
let lastDaily = "";
const daily = setInterval(() => {
  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  if (now.getUTCHours() === 3 && now.getUTCMinutes() >= 17 && lastDaily !== day) {
    lastDaily = day;
    void runScheduled("17 3 * * *");
    void sql`DELETE FROM email_outbox WHERE status <> 'pending' AND created_at < now() - interval '30 days'`.catch(() => {});
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
