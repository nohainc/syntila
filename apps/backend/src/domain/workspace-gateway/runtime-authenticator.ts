import { hashToken } from "@syntila/security";

type Database = Pick<D1Database, "prepare">;

export interface WorkspaceRuntimeIdentity {
  runtimeId: string;
  executionWorkspaceId: string;
  installationId: string | null;
  credentialTokenHash: string;
}

export interface WorkspaceRuntimeSession {
  sessionId: string;
  executionWorkspaceId: string;
  runtimeIdentityId: string;
  connectedAt: string;
  disconnectedAt: string | null;
}

/**
 * The single Cloud authentication boundary for Workspace runtime traffic.
 *
 * Routes and the Gateway Durable Object must use this service instead of
 * repeating credential-token SQL. D1 stores identity and session audit data;
 * live socket/long-poll state remains in the Durable Object.
 */
export class WorkspaceRuntimeAuthenticator {
  constructor(private readonly db: Database) {}

  async findWorkspaceRuntimeIdentity(
    runtimeId: string,
  ): Promise<WorkspaceRuntimeIdentity | null> {
    const row = await this.db
      .prepare(
        `SELECT wri.id AS runtimeId,
                wri.workspace_id AS executionWorkspaceId,
                wri.installation_id AS installationId,
                wri.credential_token_hash AS credentialTokenHash
           FROM workspace_runtime_identities wri
           JOIN execution_workspaces ew ON ew.id = wri.workspace_id
          WHERE wri.id = ?1
            AND wri.revoked_at IS NULL
            AND ew.status <> 'revoked'`,
      )
      .bind(runtimeId)
      .first<WorkspaceRuntimeIdentity>();
    return row ?? null;
  }

  async authenticateRuntime(
    runtimeId: string,
    credential: string,
  ): Promise<WorkspaceRuntimeIdentity | null> {
    return this.authenticateRuntimeHash(runtimeId, await hashToken(credential));
  }

  async authenticateRuntimeHash(
    runtimeId: string,
    credentialTokenHash: string,
  ): Promise<WorkspaceRuntimeIdentity | null> {
    const row = await this.db
      .prepare(
        `SELECT wri.id AS runtimeId,
                wri.workspace_id AS executionWorkspaceId,
                wri.installation_id AS installationId,
                wri.credential_token_hash AS credentialTokenHash
           FROM workspace_runtime_identities wri
           JOIN execution_workspaces ew ON ew.id = wri.workspace_id
          WHERE wri.id = ?1
            AND wri.credential_token_hash = ?2
            AND wri.revoked_at IS NULL
            AND ew.status <> 'revoked'`,
      )
      .bind(runtimeId, credentialTokenHash)
      .first<WorkspaceRuntimeIdentity>();
    return row &&
      (row.credentialTokenHash == null ||
        row.credentialTokenHash === credentialTokenHash)
      ? row
      : null;
  }

  async resolveRuntimeBySession(
    sessionId: string,
  ): Promise<WorkspaceRuntimeSession | null> {
    const row = await this.db
      .prepare(
        `SELECT id AS sessionId,
                workspace_id AS executionWorkspaceId,
                runtime_identity_id AS runtimeIdentityId,
                connected_at AS connectedAt,
                disconnected_at AS disconnectedAt
           FROM workspace_sessions
          WHERE id = ?1 AND disconnected_at IS NULL`,
      )
      .bind(sessionId)
      .first<WorkspaceRuntimeSession>();
    return row ?? null;
  }

  async authenticateSession(
    sessionId: string,
    credential: string,
  ): Promise<WorkspaceRuntimeIdentity | null> {
    const session = await this.resolveRuntimeBySession(sessionId);
    if (!session) return null;
    const identity = await this.authenticateRuntime(
      session.runtimeIdentityId,
      credential,
    );
    return identity?.executionWorkspaceId === session.executionWorkspaceId
      ? identity
      : null;
  }

  async assertRuntimeOwnsWorkspace(
    runtimeId: string,
    credential: string,
    workspaceId: string,
  ): Promise<WorkspaceRuntimeIdentity> {
    const identity = await this.authenticateRuntime(runtimeId, credential);
    if (!identity || identity.executionWorkspaceId !== workspaceId) {
      throw new Error("Invalid or revoked Workspace runtime credential");
    }
    return identity;
  }
}
