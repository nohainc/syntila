import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { userInfo } from "node:os";
import { randomUUID, webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const exec = promisify(execFile);
const root = resolve(fileURLToPath(new URL("../../../", import.meta.url)));
export function environment(name) {
  if (name === "local")
    return {
      database: "syntila-auth-development",
      config: "apps/cloud/wrangler.jsonc",
      flag: "--local",
      origin: "http://localhost:8787",
      backend: "http://localhost:8788",
      issuer: "http://localhost:8787",
      // Written by scripts/setup-local-backend.mjs.
      signingKey: { devVars: "apps/cloud/.dev.vars" },
    };
  if (name === "production")
    return {
      database: "syntila-auth",
      config: "infra/cloudflare/app.wrangler.jsonc",
      flag: "--remote",
      origin: "https://syntila.app",
      backend: "https://api.syntila.app",
      issuer: "https://syntila.app",
      // Private half of the Worker's SYNTILA_BACKEND_SIGNING_KEY (git-ignored).
      signingKey: { file: ".development/backend-signing-key.private.jwk" },
    };
  throw new Error("Select local or production.");
}
function literal(value) {
  if (
    typeof value !== "string" ||
    !value ||
    value.length > 320 ||
    value.includes("\0")
  )
    throw new Error("Invalid account identifier.");
  return "'" + value.replaceAll("'", "''") + "'";
}
// Accounts live in the auth D1 database; usage and plans in the backend.
export function listSQL(search = "") {
  if (typeof search !== "string" || search.length > 200)
    throw new Error("Search must be at most 200 characters.");
  const term = literal(search || " ");
  return `SELECT u.id,u.email,u.display_name,u.status,u.email_verified,u.created_at
    FROM users u ${search ? `WHERE instr(lower(u.email),lower(${term}))>0 OR instr(lower(u.display_name),lower(${term}))>0 OR u.id=${term}` : ""}
    ORDER BY u.created_at DESC,u.id LIMIT 201;`;
}
export function changeSQL(id, action, email, actor = userInfo().username) {
  if (!["lock", "unlock"].includes(action))
    throw new Error("Unsupported account action.");
  const target = literal(id);
  const from = action === "lock" ? "active" : "suspended";
  const to = action === "lock" ? "suspended" : "active";
  const details = literal(
    JSON.stringify({ operator: actor, transport: "wrangler", version: 1 }),
  );
  return `UPDATE users SET status='${to}',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=${target} AND email=${literal(email)} AND status='${from}';
    INSERT INTO auth_audit_events (id,user_id,action,outcome,details_json,created_at)
    SELECT 'account-admin-'||lower(hex(randomblob(16))),${target},'account.admin.${action}','success',${details},strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE changes()=1;
    ${
      action === "lock"
        ? `DELETE FROM auth_sessions WHERE user_id=${target} AND EXISTS(SELECT 1 FROM users WHERE id=${target} AND status='suspended');
    UPDATE desktop_human_sessions SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=${target} AND revoked_at IS NULL AND EXISTS(SELECT 1 FROM users WHERE id=${target} AND status='suspended');`
        : ""
    }
    SELECT id,email,status FROM users WHERE id=${target};`;
}
// One-minute internal token signed with the backend signing key; the backend
// accepts it on /internal/* only.
async function signingKey(config) {
  let raw;
  if (config.signingKey.file) raw = readFileSync(join(root, config.signingKey.file), "utf8");
  else {
    const vars = parseEnv(readFileSync(join(root, config.signingKey.devVars), "utf8"));
    raw = vars.SYNTILA_BACKEND_SIGNING_KEY;
  }
  if (!raw) throw new Error("Backend signing key is not available for this environment.");
  const jwk = JSON.parse(raw);
  return { kid: jwk.kid, key: await webcrypto.subtle.importKey("jwk", { kty: jwk.kty, crv: jwk.crv, x: jwk.x, d: jwk.d }, { name: "Ed25519" }, false, ["sign"]) };
}
const b64url = (buf) => Buffer.from(buf).toString("base64url");
export async function internalToken(config, now = Date.now()) {
  const { kid, key } = await signingKey(config);
  const iat = Math.floor(now / 1000);
  const input = `${b64url(JSON.stringify({ alg: "EdDSA", typ: "JWT", kid }))}.${b64url(JSON.stringify({ iss: config.issuer, aud: "syntila-backend", sub: `operator:${userInfo().username}`, typ: "internal", iat, exp: iat + 60, jti: randomUUID() }))}`;
  const signature = await webcrypto.subtle.sign({ name: "Ed25519" }, key, Buffer.from(input));
  return `${input}.${b64url(signature)}`;
}
export async function callBackend(config, path, body, fetcher = fetch) {
  const response = await fetcher(`${config.backend}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await internalToken(config)}`, "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`Backend request failed (HTTP ${response.status}).`);
  return response.json();
}
export async function executeSQL(config, sql) {
  const { stdout } = await exec(
    join(root, "node_modules/.bin/wrangler"),
    [
      "d1",
      "execute",
      config.database,
      config.flag,
      "--config",
      join(root, config.config),
      "--json",
      "--command",
      sql,
    ],
    {
      cwd: root,
      timeout: 60000,
      maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
    },
  );
  const result = JSON.parse(stdout);
  if (!Array.isArray(result) || result.some((r) => r.success === false))
    throw new Error("Database operation failed.");
  return result.flatMap((r) => r.results ?? []);
}
const EMPTY_STATS = { spaces: 0, workspaces: 0, requests: 0, failed_requests: 0, last_request_at: null, messages: 0, last_message_at: null, plan: "free", plan_source: null, plan_period_end: null };
export async function handle(input, query = executeSQL, fetcher = fetch, backend = callBackend) {
  const config = environment(input.environment);
  if (input.action === "list") {
    const users = await query(config, listSQL(input.search ?? ""));
    let stats = {};
    let statsError;
    try {
      stats = (await backend(config, "/internal/admin/accounts/stats", { ids: users.map((u) => u.id) }, fetcher)).stats ?? {};
    } catch (error) {
      statsError = error instanceof Error ? error.message : "Backend unavailable.";
    }
    return {
      users: users.map((u) => ({ ...EMPTY_STATS, ...(stats[u.id] ?? {}), ...u })),
      ...(statsError ? { warning: `Usage and plans are unavailable: ${statsError}` } : {}),
    };
  }
  if (
    !["lock", "unlock", "reset", "grant_paid", "revoke_paid"].includes(
      input.action,
    )
  )
    throw new Error("Unsupported action.");
  if (
    ["unlock", "reset"].includes(input.action) &&
    input.confirmEmail !== input.email
  )
    throw new Error("Retype the account email to confirm.");
  const rows = await query(
    config,
    `SELECT id,email,status FROM users WHERE id=${literal(input.id)} AND email=${literal(input.email)};`,
  );
  if (rows.length !== 1)
    throw new Error("Account changed or was removed. Refresh the list.");
  if (input.action === "grant_paid" || input.action === "revoke_paid") {
    const plan = input.action === "grant_paid" ? "paid" : "free";
    const result = await backend(config, `/internal/admin/accounts/${encodeURIComponent(input.id)}/plan`, { action: input.action, email: rows[0].email }, fetcher);
    if (result?.plan !== plan)
      throw new Error("Plan update was not confirmed. Refresh before retrying.");
    return {
      message:
        plan === "paid"
          ? "Paid membership enabled. Takes effect on the user's next request."
          : "Paid membership disabled. Paid features and Workspace sharing are paused.",
    };
  }
  if (input.action === "reset") {
    if (rows[0].status !== "active")
      throw new Error(
        "Unlock the account before requesting password recovery.",
      );
    const response = await fetcher(
      `${config.origin}/api/auth/request-password-reset`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", Origin: config.origin },
        body: JSON.stringify({
          email: rows[0].email,
          redirectTo: `${config.origin}/login`,
        }),
        signal: AbortSignal.timeout(30000),
      },
    );
    if (!response.ok)
      throw new Error(
        `Password reset request failed (HTTP ${response.status}).`,
      );
    return {
      message:
        "Password reset requested. The email service sends a reset link for eligible accounts; delivery is not confirmed.",
    };
  }
  const expected = input.action === "lock" ? "active" : "suspended";
  if (rows[0].status !== expected)
    throw new Error("Account status changed. Refresh before retrying.");
  const result = await query(
    config,
    changeSQL(input.id, input.action, input.email),
  );
  const status = input.action === "lock" ? "suspended" : "active";
  if (!result.some((row) => row.id === input.id && row.status === status))
    throw new Error(
      "Account update was not confirmed. Refresh before retrying.",
    );
  // Mirror the status on the backend so open backend tokens stop working too.
  let mirrored = true;
  try {
    await backend(config, `/internal/admin/accounts/${encodeURIComponent(input.id)}/status`, { status }, fetcher);
  } catch {
    mirrored = false;
  }
  const note = mirrored ? "" : " The backend could not be updated; its access ends when the current token expires (15 minutes).";
  return {
    message:
      (input.action === "lock"
        ? "Account locked. Human sessions revoked."
        : "Account unlocked. The user can sign in again.") + note,
  };
}
if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    let data = "";
    for await (const chunk of process.stdin) {
      data += chunk;
      if (data.length > 4096) throw new Error("Request too large.");
    }
    console.log(JSON.stringify(await handle(JSON.parse(data))));
  } catch (error) {
    // Wrangler errors may contain SQL/account information. Do not return raw subprocess output.
    console.log(
      JSON.stringify({
        error: error?.code
          ? "Database connection failed. Check Wrangler login, dependencies, and database migrations in Terminal."
          : error.message,
      }),
    );
    process.exitCode = 1;
  }
}
