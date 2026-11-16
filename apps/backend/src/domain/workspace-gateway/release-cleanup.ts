import type { Tx } from "../../platform/data.js";

/**
 * A released Workspace keeps only its revoked record, because past work and
 * audit history still reference it. Everything that configured it is deleted
 * so a new registration starts clean: Workers (scheduling rows cascade) and
 * Allowed Folders (Space folder attachments cascade).
 */
export async function releasedWorkspaceCleanup(
  tx: Tx,
  workspaceId: string,
): Promise<void> {
  await tx.run`DELETE FROM workspace_worker_inventory WHERE workspace_id = ${workspaceId}`;
  await tx.run`DELETE FROM workspace_allowed_folders WHERE workspace_id = ${workspaceId}`;
}
