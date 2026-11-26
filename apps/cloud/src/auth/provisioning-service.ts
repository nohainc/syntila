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
 * the human. Connect registration is not created as a side effect of
 * sign-in; Connect creation is an explicit user action.
 */
export async function provisionSyntilaUser(
  db: ProvisioningDatabase,
  identity: AuthenticatedIdentity,
  now = new Date().toISOString(),
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'active', ?4, ?4)
       ON CONFLICT(id) DO UPDATE SET
         email = excluded.email,
         display_name = excluded.display_name,
         updated_at = excluded.updated_at`,
    )
    .bind(identity.userId, identity.email, identity.name, now)
    .run();
}
