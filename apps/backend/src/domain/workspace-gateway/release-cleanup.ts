/**
 * A released Workspace keeps only its revoked record, because past work and
 * audit history still reference it. Everything that configured it is deleted
 * so a new registration starts clean: Workers (scheduling rows cascade) and
 * Allowed Folders (Space folder attachments cascade).
 */
export function releasedWorkspaceCleanup(
  db: Pick<D1Database, "prepare">,
  workspaceId: string,
) {
  return [
    db
      .prepare("DELETE FROM workspace_worker_inventory WHERE workspace_id = ?1")
      .bind(workspaceId),
    db
      .prepare("DELETE FROM workspace_allowed_folders WHERE workspace_id = ?1")
      .bind(workspaceId),
  ];
}
