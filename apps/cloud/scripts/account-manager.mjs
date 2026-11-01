import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { userInfo } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const exec = promisify(execFile);
const root = resolve(fileURLToPath(new URL("../../../", import.meta.url)));
export function environment(name) {
  if (name === "local")
    return {
      database: "syntila-development",
      config: "apps/cloud/wrangler.jsonc",
      flag: "--local",
      origin: "http://localhost:8787",
    };
  if (name === "production")
    return {
      database: "syntila",
      config: "infra/cloudflare/app.wrangler.jsonc",
      flag: "--remote",
      origin: "https://syntila.app",
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
// Mirrors paidOwnerSql in apps/cloud/src/account-plan.ts.
const PAID_SQL = `EXISTS (SELECT 1 FROM account_plans ap
      WHERE ap.user_id=u.id AND ap.tier='paid'
        AND ap.status IN ('active','trialing','past_due')
        AND (ap.current_period_end IS NULL OR julianday(ap.current_period_end)>julianday('now')))`;
export function listSQL(search = "") {
  if (typeof search !== "string" || search.length > 200)
    throw new Error("Search must be at most 200 characters.");
  const term = literal(search || " ");
  return `SELECT u.id,u.email,u.display_name,u.status,u.email_verified,u.created_at,
    (SELECT count(*) FROM space_memberships m WHERE m.user_id=u.id) AS spaces,
    (SELECT count(*) FROM execution_workspaces w WHERE w.owner_user_id=u.id) AS workspaces,
    (SELECT count(*) FROM work_requests r WHERE r.requested_by_user_id=u.id) AS requests,
    (SELECT count(*) FROM work_requests r WHERE r.requested_by_user_id=u.id AND r.status='failed') AS failed_requests,
    (SELECT max(created_at) FROM work_requests r WHERE r.requested_by_user_id=u.id) AS last_request_at,
    (SELECT count(*) FROM discussion_messages m WHERE m.author_user_id=u.id) AS messages,
    (SELECT max(created_at) FROM discussion_messages m WHERE m.author_user_id=u.id) AS last_message_at,
    CASE WHEN ${PAID_SQL} THEN 'paid' ELSE 'free' END AS plan,
    (SELECT source FROM account_plans ap WHERE ap.user_id=u.id) AS plan_source,
    (SELECT current_period_end FROM account_plans ap WHERE ap.user_id=u.id) AS plan_period_end
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
// Manual grants are open-ended (no period end) until revoked. Revoking keeps
// the row as canceled so shared Workspaces pause rather than lose their grants.
export function planSQL(id, action, email, actor = userInfo().username) {
  if (!["grant_paid", "revoke_paid"].includes(action))
    throw new Error("Unsupported plan action.");
  const target = literal(id);
  const now = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
  const details = literal(
    JSON.stringify({ operator: actor, transport: "wrangler", version: 1 }),
  );
  const [tier, status] =
    action === "grant_paid" ? ["paid", "active"] : ["free", "canceled"];
  return `INSERT INTO account_plans (user_id,tier,status,source,current_period_end,created_at,updated_at)
    SELECT id,'${tier}','${status}','manual',NULL,${now},${now} FROM users WHERE id=${target} AND email=${literal(email)}
    ON CONFLICT(user_id) DO UPDATE SET tier=excluded.tier,status=excluded.status,source='manual',current_period_end=NULL,updated_at=excluded.updated_at;
    INSERT INTO auth_audit_events (id,user_id,action,outcome,details_json,created_at)
    SELECT 'account-admin-'||lower(hex(randomblob(16))),${target},'account.admin.${action}','success',${details},${now} WHERE changes()=1;
    SELECT u.id,CASE WHEN ${PAID_SQL} THEN 'paid' ELSE 'free' END AS plan FROM users u WHERE u.id=${target};`;
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
export async function handle(input, query = executeSQL, fetcher = fetch) {
  const config = environment(input.environment);
  if (input.action === "list")
    return { users: await query(config, listSQL(input.search ?? "")) };
  if (
    !["lock", "unlock", "reset", "grant_paid", "revoke_paid"].includes(
      input.action,
    )
  )
    throw new Error("Unsupported action.");
  if (
    ["unlock", "reset"].includes(input.action) &&
    input.confirmEmail !== input.email)
    throw new Error("Retype the account email to confirm.");
  const rows = await query(
    config,
    `SELECT id,email,status FROM users WHERE id=${literal(input.id)} AND email=${literal(input.email)};`,
  );
  if (rows.length !== 1)
    throw new Error("Account changed or was removed. Refresh the list.");
  if (input.action === "grant_paid" || input.action === "revoke_paid") {
    const plan = input.action === "grant_paid" ? "paid" : "free";
    const result = await query(
      config,
      planSQL(input.id, input.action, input.email),
    );
    if (!result.some((row) => row.id === input.id && row.plan === plan))
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
  return {
    message:
      input.action === "lock"
        ? "Account locked. Human sessions revoked."
        : "Account unlocked. The user can sign in again.",
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
