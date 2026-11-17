import type { Query } from "../../platform/data.js";

/**
 * What a Workspace that was released or revoked leaves behind: its Worker
 * inventory and allowed folders. Run on the caller's transaction.
 */
export async function releasedWorkspaceCleanup(
  q: Pick<Query, "run">,
  workspaceId: string,
): Promise<void> {
  await q.run`DELETE FROM workspace_worker_inventory WHERE workspace_id = ${workspaceId}`;
  await q.run`DELETE FROM workspace_allowed_folders WHERE workspace_id = ${workspaceId}`;
}
