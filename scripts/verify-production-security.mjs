import { readFile } from "node:fs/promises";
import ts from "typescript";

const configPath = process.argv[2] ?? "infra/cloudflare/app.wrangler.jsonc";
const rawConfig = await readFile(configPath, "utf8");
const parsed = ts.parseConfigFileTextToJson(configPath, rawConfig);
if (parsed.error) throw new Error(`Production security preflight failed: invalid configuration: ${ts.flattenDiagnosticMessageText(parsed.error.messageText, " ")}`);
const config = parsed.config ?? {};
const databases = Array.isArray(config.d1_databases) ? config.d1_databases : [];
const buckets = Array.isArray(config.r2_buckets) ? config.r2_buckets : [];
const routes = Array.isArray(config.routes) ? config.routes : [];
const secrets = Array.isArray(config.secrets?.required) ? config.secrets.required : [];
const required = [
  ["production environment", config.vars?.SYNTILA_ENVIRONMENT === "production"],
  ["app custom domain", routes.some((route) => route.pattern === "app.syntila.app" && route.custom_domain === true)],
  ["D1 binding", databases.some((database) => database.binding === "SYNTILA_DB")],
  ["web asset binding", config.assets?.binding === "ASSETS"],
  ["API routes reach the auth Worker", Array.isArray(config.assets?.run_worker_first) && config.assets.run_worker_first.includes("/api/*")],
  ["backend URL", config.vars?.SYNTILA_BACKEND_URL === "https://api.syntila.app"],
  ["backend signing secret", secrets.includes("SYNTILA_BACKEND_SIGNING_KEY")],
  ["auth secret", secrets.includes("BETTER_AUTH_SECRET")],
  ["email relay secret", secrets.includes("EMAIL_RELAY_SECRET")],
];
const missing = required.filter(([, present]) => !present).map(([name]) => name);
if (missing.length) throw new Error(`Production security preflight failed: ${missing.join(", ")}`);
const developmentResourceNames = [
  ["D1 database", databases.some((database) => /development/i.test(database.database_name ?? ""))],
  ["R2 artifact bucket", buckets.some((bucket) => /development/i.test(bucket.bucket_name ?? ""))],
].filter(([, present]) => present).map(([name]) => name);
if (developmentResourceNames.length) throw new Error(`Production security preflight failed: development resource names are configured (${developmentResourceNames.join(", ")})`);
if (/SYNTILA_ALLOW_ANONYMOUS_DEV/.test(rawConfig)) throw new Error("Production security preflight failed: anonymous development access is configured");
console.log(`Production security preflight passed: ${configPath}`);
