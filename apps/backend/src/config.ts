import { parseFeatureFlags, FEATURE_FLAGS_ENV } from "./feature-flags";

export interface Config {
  providerFailureKey?: string;
  providerFailurePreviousKeys?: string;
  port: number;
  hostname: string;
  db: {
    hostname: string;
    port: number;
    username: string;
    database: string;
    password: string;
    max: number;
    /** A statement waiting this long for a lock fails (the API answers 503 busy). */
    lockTimeoutMs?: number;
    /** A session idle inside an open transaction is terminated after this long (frees its locks). */
    idleInTransactionMs?: number;
  };
  auth: {
    issuer: string;
    audience: string;
    /** JSON array of public JWKs (Ed25519 "OKP" or P-256 "EC"), each with a kid. */
    publicKeys: JsonWebKey[];
  };
  allowedOrigins: string[];
}

function int(name: string, fallback: number, min = 1, max = 65535): number {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < min || value > max)
    throw new Error(`Invalid ${name}`);
  return value;
}

export async function readDatabasePassword(): Promise<string> {
  // Production: systemd LoadCredential. Development/tests: PGPASSWORD.
  const dir = process.env.CREDENTIALS_DIRECTORY;
  if (dir) {
    const password = (await Bun.file(`${dir}/postgres-password`).text()).replace(/\r?\n$/, "");
    if (!password) throw new Error("PostgreSQL credential is empty");
    return password;
  }
  if (process.env.PGPASSWORD) return process.env.PGPASSWORD;
  throw new Error("PostgreSQL credential is not configured");
}

export async function readPublicKeys(): Promise<JsonWebKey[]> {
  const dir = process.env.CREDENTIALS_DIRECTORY;
  let raw = process.env.AUTH_JWT_PUBLIC_KEYS ?? "";
  if (!raw && process.env.AUTH_JWT_PUBLIC_KEYS_FILE)
    raw = await Bun.file(process.env.AUTH_JWT_PUBLIC_KEYS_FILE).text();
  if (!raw && dir && (await Bun.file(`${dir}/auth-public-keys`).exists()))
    raw = await Bun.file(`${dir}/auth-public-keys`).text();
  if (!raw.trim()) return [];
  const parsed = JSON.parse(raw);
  const keys = Array.isArray(parsed) ? parsed : parsed.keys;
  if (!Array.isArray(keys)) throw new Error("AUTH public keys must be a JWK array or JWKS");
  return keys;
}

export async function loadConfig(): Promise<Config> {
  // Worker-first rollout flags (docs/operations/FEATURE_FLAGS.md): a typo or a
  // flag without its prerequisite stops the boot instead of staying silently off.
  parseFeatureFlags(process.env[FEATURE_FLAGS_ENV]);
  const credentialDir = process.env.CREDENTIALS_DIRECTORY;
  const keyFile = credentialDir ? Bun.file(`${credentialDir}/provider-failure-key`) : null;
  const providerFailureKey = keyFile && await keyFile.exists()
    ? (await keyFile.text()).trim()
    : process.env.SYNTILA_PROVIDER_FAILURE_KEY;
  const previousFile = credentialDir ? Bun.file(`${credentialDir}/provider-failure-previous-keys`) : null;
  const providerFailurePreviousKeys = previousFile && await previousFile.exists()
    ? (await previousFile.text()).trim()
    : process.env.SYNTILA_PROVIDER_FAILURE_PREVIOUS_KEYS;
  return {
    providerFailureKey,
    providerFailurePreviousKeys,
    port: int("PORT", 3000),
    hostname: process.env.BIND_HOST || "127.0.0.1",
    db: {
      hostname: process.env.PGHOST || "127.0.0.1",
      port: int("PGPORT", 5432),
      username: process.env.PGUSER || "syntila_app",
      database: process.env.PGDATABASE || "syntila",
      password: await readDatabasePassword(),
      max: int("PG_POOL_MAX", 20, 1, 200),
      lockTimeoutMs: int("PG_LOCK_TIMEOUT_MS", 10_000, 100, 600_000),
      idleInTransactionMs: int("PG_IDLE_TX_TIMEOUT_MS", 30_000, 1_000, 3_600_000),
    },
    auth: {
      issuer: process.env.AUTH_JWT_ISSUER || "https://syntila.app",
      audience: process.env.AUTH_JWT_AUDIENCE || "syntila-backend",
      publicKeys: await readPublicKeys(),
    },
    allowedOrigins: (process.env.ALLOWED_ORIGINS || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  };
}
