/**
 * Object storage self-check: writes, reads and deletes a small test object
 * with the backend's own R2 client, and with Bun's S3 client as a control.
 *
 *   On the VPS:  sudo -u syntila bash -c 'set -a; . /etc/syntila/backend.env; cd /opt/syntila/current && bun scripts/check-storage.ts'
 *
 * Reading the result:
 *   both fail      -> the credentials (key pair, bucket, account) are wrong
 *   only ours fails -> a bug in src/platform/r2.ts signing
 *   both pass      -> storage works; the failure is somewhere else
 * Exit code 0 only when the backend's client passes.
 */
import { S3Client } from "bun";
import { S3R2Bucket } from "../src/platform/r2";

const env = process.env;
const need = ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"] as const;
const missing = need.filter((k) => !env[k]);
if (missing.length) { console.error(`Missing: ${missing.join(", ")}`); process.exit(2); }

const bucket = env.R2_BUCKET ?? "syntila-artifacts";
const describe = (name: string) => {
  const v = env[name] ?? "";
  const odd = v !== v.trim() ? " (has leading/trailing whitespace!)" : /["'\r\n]/.test(v) ? " (contains a quote or line break!)" : "";
  return `${name}: ${v.length} chars${odd}`;
};
console.log(`bucket: ${bucket}${env.R2_BUCKET ? "" : " (default: R2_BUCKET is not set)"}`);
for (const n of need) console.log(describe(n));
console.log(`R2_ACCESS_KEY_ID ${/^[0-9a-f]{32}$/.test(env.R2_ACCESS_KEY_ID!.trim()) ? "looks like" : "does NOT look like"} an R2 key id (32 hex chars)`);
console.log(`R2_SECRET_ACCESS_KEY ${/^[0-9a-f]{64}$/.test(env.R2_SECRET_ACCESS_KEY!.trim()) ? "looks like" : "does NOT look like"} an R2 secret (64 hex chars)`);

const key = `healthcheck/${Date.now()}-${crypto.randomUUID()}`;
const cfg = { accountId: env.R2_ACCOUNT_ID!, bucket, accessKeyId: env.R2_ACCESS_KEY_ID!, secretAccessKey: env.R2_SECRET_ACCESS_KEY! };

let refused = false; // an answer from storage that says "no" (as opposed to no answer)
async function attempt(label: string, fn: () => Promise<void>) {
  try { await fn(); console.log(`PASS  ${label}`); return true; }
  catch (e) {
    const message = String((e as Error).message);
    if (/\b40[13]\b|SignatureDoesNotMatch|AccessDenied|InvalidAccessKeyId|NoSuchBucket/.test(message)) refused = true;
    console.log(`FAIL  ${label}: ${message.slice(0, 300)}`);
    return false;
  }
}

const ours = new S3R2Bucket(cfg);
const okOurs = await attempt("backend client: put, get, delete", async () => {
  await ours.put(key, new TextEncoder().encode("ok"), { httpMetadata: { contentType: "text/plain" }, customMetadata: { userId: "Check" } });
  const got = await ours.get(key);
  if (!got || (await got.text()) !== "ok") throw new Error("read back differs");
  await ours.delete(key);
});
const control = new S3Client({
  accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, bucket,
  endpoint: `https://${cfg.accountId}.r2.cloudflarestorage.com`, region: "auto",
});
const okControl = await attempt("Bun S3 client (control): write, read, delete", async () => {
  await control.write(`${key}-control`, "ok");
  if ((await control.file(`${key}-control`).text()) !== "ok") throw new Error("read back differs");
  await control.delete(`${key}-control`);
});
console.log(!okOurs && !okControl && !refused ? "\nNo answer from storage at all: check this machine's network access to r2.cloudflarestorage.com, and R2_ACCOUNT_ID." :
  okOurs ? "\nStorage works for the backend." :
  okControl ? "\nThe credentials work, but the backend's signing fails: bug in src/platform/r2.ts." :
  "\nBoth clients are refused: fix the credentials in /etc/syntila/backend.env (same API token for both values, no spaces or quotes), then restart the backend.");
process.exit(okOurs ? 0 : 1);
