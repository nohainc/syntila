import { atomically } from "../../platform/data.js";
import type { AuthenticatedIdentity } from "./identity-service.js";

export interface ProvisioningStatement {
  bind(...values: unknown[]): ProvisioningStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results?: readonly T[] }>;
  run(): Promise<unknown>;
}

export interface ProvisioningDatabase {
  prepare(query: string): ProvisioningStatement & {
    first<T = Record<string, unknown>>(): Promise<T | null>;
    all<T = Record<string, unknown>>(): Promise<{ results?: readonly T[] }>;
    run(): Promise<unknown>;
  };
  batch(statements: readonly ProvisioningStatement[]): Promise<unknown>;
}

/**
 * Initialize Syntila application state after Better Auth has authenticated
 * the human. Workspace registration is not created as a side effect of
 * sign-in; Workspace creation is an explicit user action.
 */
// Tokens arrive on every request; provisioning writes at most every 5 minutes
// per user and process (and immediately when the token's name/email change).
const provisionedByDb = new WeakMap<object, Map<string, { at: number; key: string }>>();
const PROVISION_TTL_MS = 5 * 60_000;

export async function provisionSyntilaUser(
  db: ProvisioningDatabase,
  identity: AuthenticatedIdentity,
  now = new Date().toISOString(),
): Promise<void> {
  const key = `${identity.email}\u0000${identity.name}`;
  let provisioned = provisionedByDb.get(db);
  if (!provisioned) provisionedByDb.set(db, (provisioned = new Map()));
  const seen = provisioned.get(identity.userId);
  if (seen && seen.key === key && Date.now() - seen.at < PROVISION_TTL_MS) return;
  if (provisioned.size > 50_000) provisioned.clear();
  // One transaction: a per-user lock, then the upsert. Without the lock, the
  // first parallel requests of a new user both insert, and the second fails
  // on users_email_key (ON CONFLICT (id) does not cover the email index).
  await atomically(db, "provisioning-service.batch43", async (q) => {
    await q.run`SELECT pg_advisory_xact_lock(hashtextextended('syntila.user:' || ${identity.userId}, 0))`;
    await q.run`INSERT INTO users (id, email, display_name, status, created_at, updated_at)
         VALUES (${identity.userId}, ${identity.email}, ${identity.name}, 'active', ${now}, ${now})
         ON CONFLICT(id) DO UPDATE SET
           email = excluded.email,
           display_name = excluded.display_name,
           updated_at = excluded.updated_at`;
  });
  provisioned.set(identity.userId, { at: Date.now(), key });
}
