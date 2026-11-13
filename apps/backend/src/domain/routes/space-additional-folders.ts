import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  securityContext,
  HttpError,
  json,
  type SecurityEnv,
} from "./http-security.js";
import { loadWorkflowWorkspace } from "./workflow-workspace.js";

const MAX_ATTACHED_FOLDERS = 32;
const FOLDER_ID = /^folder-[a-f0-9]{16}$/;

type Eligibility =
  | { eligible: true; workspaceId: string }
  | {
      eligible: false;
      workspaceId: string | null;
      reason: "not_space_owner" | "no_workspace" | "not_workspace_owner";
    };

/**
 * Additional folders are owner-only: the requester must own the Space and the
 * Workspace the Space runs on. Shared and borrowed Workspaces never expose the
 * owner's local folders.
 */
async function eligibility(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
): Promise<Eligibility> {
  const space = await env.SYNTILA_DB.prepare(
    "SELECT s.owner_user_id AS ownerUserId FROM spaces s JOIN space_memberships m ON m.space_id = s.id WHERE s.id = ?1 AND m.user_id = ?2",
  )
    .bind(spaceId, userId)
    .first<{ ownerUserId: string }>();
  if (!space) throw new HttpError(403, "Space membership required");
  const { workspaceId } = await loadWorkflowWorkspace(
    env,
    space.ownerUserId,
    spaceId,
  );
  if (space.ownerUserId !== userId)
    return { eligible: false, workspaceId, reason: "not_space_owner" };
  if (!workspaceId)
    return { eligible: false, workspaceId: null, reason: "no_workspace" };
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, userId)
    .first();
  return owned
    ? { eligible: true, workspaceId }
    : { eligible: false, workspaceId, reason: "not_workspace_owner" };
}

async function listFolders(
  env: SecurityEnv,
  spaceId: string,
  workspaceId: string,
) {
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT f.folder_id AS id, f.display_name AS displayName, f.status,
            f.checked_at AS checkedAt,
            CASE WHEN a.folder_id IS NULL THEN 0 ELSE 1 END AS attached
       FROM workspace_allowed_folders f
       LEFT JOIN space_additional_folders a
         ON a.space_id = ?1 AND a.workspace_id = f.workspace_id
        AND a.folder_id = f.folder_id
      WHERE f.workspace_id = ?2
      ORDER BY lower(f.display_name), f.folder_id`,
  )
    .bind(spaceId, workspaceId)
    .all<{
      id: string;
      displayName: string;
      status: string;
      checkedAt: string;
      attached: number;
    }>();
  return (rows.results ?? []).map((row) => ({
    ...row,
    attached: Number(row.attached) === 1,
  }));
}

/** GET/PUT `/api/spaces/:spaceId/additional-folders`. */
export async function handleSpaceAdditionalFolders(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  ctx?: ExecutionContext,
) {
  const context = await securityContext(request, env, ctx);
  const access = await eligibility(env, context.userId, spaceId);
  if (request.method === "GET") {
    if (!access.eligible)
      return json({
        eligible: false,
        reason: access.reason,
        workspaceId: access.workspaceId,
        folders: [],
      });
    return json({
      eligible: true,
      workspaceId: access.workspaceId,
      folders: await listFolders(env, spaceId, access.workspaceId),
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  if (!access.eligible)
    throw new HttpError(
      403,
      "Only the owner of the Space and its Workspace can attach folders",
    );
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  const folderIds = body?.folderIds;
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).some((key) => key !== "folderIds") ||
    !Array.isArray(folderIds) ||
    folderIds.length > MAX_ATTACHED_FOLDERS ||
    folderIds.some((id) => typeof id !== "string" || !FOLDER_ID.test(id)) ||
    new Set(folderIds).size !== folderIds.length
  )
    throw new HttpError(400, "Invalid folder selection");
  const available = new Set(
    (await listFolders(env, spaceId, access.workspaceId)).map(
      (folder) => folder.id,
    ),
  );
  if ((folderIds as string[]).some((id) => !available.has(id)))
    throw new HttpError(409, "A selected folder is no longer allowed");
  const db = env.SYNTILA_DB;
  const now = new Date().toISOString();
  await db.batch([
    db
      .prepare("DELETE FROM space_additional_folders WHERE space_id = ?1")
      .bind(spaceId),
    ...(folderIds as string[]).map((folderId) =>
      db
        .prepare(
          "INSERT INTO space_additional_folders(space_id,workspace_id,folder_id,created_at) VALUES(?1,?2,?3,?4)",
        )
        .bind(spaceId, access.workspaceId, folderId, now),
    ),
  ]);
  await publishCollaborationEvent(env, "space.updated", spaceId, spaceId);
  return json({
    eligible: true,
    workspaceId: access.workspaceId,
    folders: await listFolders(env, spaceId, access.workspaceId),
  });
}
