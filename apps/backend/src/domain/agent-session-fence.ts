import type { Query } from "../platform/data.js";

/**
 * The identity of one Worker Agent session (ADR-034 decision 5). A write made
 * on behalf of an Agent carries it, and the database accepts the write only
 * while it is still the Worker's current session: connecting again increments
 * `worker_agent_sessions.session_epoch` and replaces `session_id`, so a late
 * acknowledgement or result from the older session finds no matching row.
 */
export interface AgentSessionFence {
  readonly workerInstanceId: string;
  readonly sessionId: string;
  readonly epoch: number;
}

/**
 * ` AND …` for the WHERE clause of a `worker_assignments` UPDATE: the row must
 * belong to this Worker and the session must be current. Part of the same
 * statement as the write, never an earlier SELECT, so the database decides
 * which of two racing sessions wins. Empty without a fence (legacy Workspace
 * traffic).
 */
export function agentFenceSql(q: Query, fence?: AgentSessionFence | null): unknown {
  if (!fence) return q.raw("");
  return q.frag` AND worker_instance_id = ${fence.workerInstanceId}
     AND EXISTS (SELECT 1 FROM worker_agent_sessions s
                  WHERE s.worker_instance_id = ${fence.workerInstanceId}
                    AND s.session_id = ${fence.sessionId}
                    AND s.session_epoch = ${fence.epoch}::bigint
                    AND s.disconnected_at IS NULL)`;
}

/** Whether the fence still names the Worker's current session. */
export async function agentFenceIsCurrent(q: Query, fence: AgentSessionFence): Promise<boolean> {
  const row = await q.row<{ ok: number }>`
    SELECT 1 AS ok FROM worker_agent_sessions
     WHERE worker_instance_id = ${fence.workerInstanceId} AND session_id = ${fence.sessionId}
       AND session_epoch = ${fence.epoch}::bigint AND disconnected_at IS NULL`;
  return row !== null;
}
