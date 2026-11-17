import type { Query } from "../platform/data.js";
export async function recordExecutionWorkspaceAudit(
  q: Query,
  input: {
    readonly workspaceId: string;
    readonly ownerUserId: string;
    readonly actorType: "user" | "workspace_runtime" | "worker" | "system";
    readonly actorId: string;
    readonly action: string;
    readonly targetType: string;
    readonly targetId: string;
    readonly details?: Record<string, unknown>;
  },
): Promise<void> {
  await q.run`
    INSERT INTO workspace_audit_log
      (id, workspace_id, actor_type, actor_id,
       action, target_type, target_id, details_json, created_at)
    VALUES (${`ewa-${crypto.randomUUID()}`}, ${input.workspaceId},
      ${input.actorType === "workspace_runtime" ? "workspace" : input.actorType},
      ${input.actorId}, ${input.action}, ${input.targetType}, ${input.targetId},
      ${input.details ?? {}}, ${new Date().toISOString()})`;
}
