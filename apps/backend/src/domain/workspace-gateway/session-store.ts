type Database = Pick<D1Database, "prepare">;

export interface WorkspaceRuntimeSessionRecord {
  sessionId: string;
  workspaceId: string;
  runtimeIdentityId: string;
  clientVersion: string;
  protocolVersion: string;
  ipAddress?: string | null;
  connectedAt: string;
}

/** D1 audit/history boundary for runtime sessions. Live transport state stays in the DO. */
export class WorkspaceRuntimeSessionStore {
  constructor(private readonly db: Database) {}

  closeForRuntime(runtimeIdentityId: string, disconnectedAt: string) {
    return this.db
      .prepare(
        "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE runtime_identity_id = ?2 AND disconnected_at IS NULL",
      )
      .bind(disconnectedAt, runtimeIdentityId)
      .run();
  }

  open(record: WorkspaceRuntimeSessionRecord) {
    return this.db
      .prepare(
        `INSERT INTO workspace_sessions
         (id, workspace_id, runtime_identity_id, client_version, protocol_version,
          ip_address, connected_at, last_heartbeat_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
      )
      .bind(
        record.sessionId,
        record.workspaceId,
        record.runtimeIdentityId,
        record.clientVersion,
        record.protocolVersion,
        record.ipAddress ?? null,
        record.connectedAt,
      )
      .run();
  }

  close(sessionId: string, disconnectedAt: string) {
    return this.db
      .prepare(
        "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2 AND disconnected_at IS NULL",
      )
      .bind(disconnectedAt, sessionId)
      .run();
  }

  touch(sessionId: string, at: string) {
    return this.db
      .prepare(
        "UPDATE workspace_sessions SET last_heartbeat_at = ?1 WHERE id = ?2",
      )
      .bind(at, sessionId)
      .run();
  }
}
