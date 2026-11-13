export async function recordExecutionWorkspaceAudit(
  db: D1Database,
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
  await db
    .prepare(
      `INSERT INTO workspace_audit_log
       (id, workspace_id, actor_type, actor_id,
        action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
    )
    .bind(
      `ewa-${crypto.randomUUID()}`,
      input.workspaceId,
      input.actorType === "workspace_runtime" ? "workspace" : input.actorType,
      input.actorId,
      input.action,
      input.targetType,
      input.targetId,
      JSON.stringify(input.details ?? {}),
      new Date().toISOString(),
    )
    .run();
}
