import { queryOf } from "../../platform/data.js";
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
    return queryOf(this.db).run`UPDATE workspace_sessions SET disconnected_at = ${disconnectedAt} WHERE runtime_identity_id = ${runtimeIdentityId} AND disconnected_at IS NULL`;
  }

  open(record: WorkspaceRuntimeSessionRecord) {
    return queryOf(this.db).run`INSERT INTO workspace_sessions
         (id, workspace_id, runtime_identity_id, client_version, protocol_version,
          ip_address, connected_at, last_heartbeat_at)
         VALUES (${record.sessionId}, ${record.workspaceId}, ${record.runtimeIdentityId}, ${record.clientVersion}, ${record.protocolVersion}, ${record.ipAddress ?? null}, ${record.connectedAt}, ${record.connectedAt})`;
  }

  close(sessionId: string, disconnectedAt: string) {
    return queryOf(this.db).run`UPDATE workspace_sessions SET disconnected_at = ${disconnectedAt} WHERE id = ${sessionId} AND disconnected_at IS NULL`;
  }

  touch(sessionId: string, at: string) {
    return queryOf(this.db).run`UPDATE workspace_sessions SET last_heartbeat_at = ${at} WHERE id = ${sessionId}`;
  }
}
