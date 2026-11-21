import { extractBearerToken } from "@syntila/security";
import { dataOf } from "../../platform/data.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { authenticateAgentSession } from "../worker-agents.js";
import { readJson } from "./validation.js";
import { HttpError, json, securityContext, type SecurityEnv } from "./http-security.js";

/**
 * Folders on the owner's computers and the folder a Space works in.
 *
 * Connect reports the folders its owner allowed (PUT /api/worker-agent/folders):
 * an opaque id, the folder's own name (never its path), the access, and the
 * device with its name. They belong to the device, not to one Worker. The owner
 * picks one writable folder per Space; Work that needs a folder only goes to a
 * Worker on that device.
 */

const DEVICE_ID = /^dev-[0-9a-f]{16}$/;
const FOLDER_ID = /^fld-[0-9a-f]{16}$/;
const MAX_FOLDERS = 200;

export interface DeviceFolderView {
  deviceId: string;
  deviceName: string;
  folderId: string;
  displayName: string;
  mode: "read" | "write";
  /** A Worker on this device is connected now. */
  online: boolean;
}

const VIEW = `f.device_id AS "deviceId", f.device_name AS "deviceName", f.folder_id AS "folderId",
  f.display_name AS "displayName", f.mode,
  EXISTS (SELECT 1 FROM worker_agent_sessions s JOIN worker_instances w ON w.id = s.worker_instance_id
           WHERE s.device_id = f.device_id AND w.owner_user_id = f.owner_user_id
             AND s.disconnected_at IS NULL AND s.lease_expires_at > now()) AS online`;

/** PUT /api/worker-agent/folders: the Agent publishes the folders its computer allows. */
export async function handleAgentFolders(request: Request, env: SecurityEnv): Promise<Response> {
  if (!isFeatureEnabled("worker_agent_connect")) throw new HttpError(404, "Not found");
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  const token = extractBearerToken(request.headers);
  const principal = workerId && sessionId && token ? await authenticateAgentSession(env, { workerId, sessionId, sessionToken: token }) : null;
  if (!workerId || !sessionId || !principal) throw new HttpError(401, "Invalid Worker session");
  const body = await readJson(request);
  const deviceId = typeof body.deviceId === "string" ? body.deviceId : "";
  const deviceName = typeof body.deviceName === "string" ? body.deviceName.trim().slice(0, 100) : "";
  if (!DEVICE_ID.test(deviceId) || !deviceName) throw new HttpError(400, "deviceId and deviceName are required");
  if (!Array.isArray(body.folders) || body.folders.length > MAX_FOLDERS) throw new HttpError(400, "folders must be a list of at most 200");
  const folders: { id: string; name: string; mode: "read" | "write" }[] = [];
  for (const item of body.folders as unknown[]) {
    const f = item as { id?: unknown; name?: unknown; mode?: unknown };
    if (typeof f?.id !== "string" || !FOLDER_ID.test(f.id)) throw new HttpError(400, "A folder id is not valid");
    const name = typeof f.name === "string" ? f.name.trim().slice(0, 128) : "";
    folders.push({ id: f.id, name: name || "Folder", mode: f.mode === "write" ? "write" : "read" });
  }
  const owner = principal.ownerUserId;
  await dataOf(env).tx("device.folders.publish", async (tx) => {
    for (const f of folders) {
      await tx.run`INSERT INTO device_folders (owner_user_id, device_id, folder_id, device_name, display_name, mode)
           VALUES (${owner}, ${deviceId}, ${f.id}, ${deviceName}, ${f.name}, ${f.mode})
        ON CONFLICT (owner_user_id, device_id, folder_id) DO UPDATE
           SET device_name = EXCLUDED.device_name, display_name = EXCLUDED.display_name,
               mode = EXCLUDED.mode, updated_at = now()`;
    }
    // A folder the owner removed in Connect goes away, and with it any Space choice.
    if (folders.length === 0) {
      await tx.run`DELETE FROM device_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId}`;
    } else {
      await tx.run`DELETE FROM device_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId}
           AND folder_id NOT IN ${tx.list(folders.map((f) => f.id))}`;
    }
    // Folders belong to the device: refresh its name on every row, and remember
    // which computer this Worker runs on.
    await tx.run`UPDATE device_folders SET device_name = ${deviceName} WHERE owner_user_id = ${owner} AND device_id = ${deviceId}`;
    await tx.run`UPDATE worker_agent_sessions SET device_id = ${deviceId}
         WHERE worker_instance_id = ${workerId} AND session_id = ${sessionId}`;
  });
  return json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}

/** GET /api/device-folders: every folder on the owner's computers, with the device name. */
export async function handleListDeviceFolders(request: Request, env: SecurityEnv, ctx?: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, ctx);
  const read = dataOf(env).read;
  const rows = await read.rows<DeviceFolderView>`SELECT ${read.raw(VIEW)} FROM device_folders f
      WHERE f.owner_user_id = ${context.userId}
      ORDER BY lower(f.device_name), f.device_id, lower(f.display_name), f.folder_id`;
  return json({ folders: rows.map((row) => ({ ...row, online: row.online === true })) }, { headers: { "Cache-Control": "no-store" } });
}

/** How many Spaces use a folder (all of the computer's folders when folderId is omitted). */
async function spacesUsing(env: SecurityEnv, owner: string, deviceId: string, folderId?: string): Promise<number> {
  const read = dataOf(env).read;
  const row = folderId
    ? await read.row<{ n: number | string }>`SELECT count(*) AS n FROM space_folders
        WHERE owner_user_id = ${owner} AND device_id = ${deviceId} AND folder_id = ${folderId}`
    : await read.row<{ n: number | string }>`SELECT count(*) AS n FROM space_folders
        WHERE owner_user_id = ${owner} AND device_id = ${deviceId}`;
  return Number(row?.n ?? 0);
}

async function deviceIsOnline(env: SecurityEnv, owner: string, deviceId: string): Promise<boolean> {
  const row = await dataOf(env).read.row<{ online: boolean }>`SELECT EXISTS (
      SELECT 1 FROM worker_agent_sessions s JOIN worker_instances w ON w.id = s.worker_instance_id
       WHERE s.device_id = ${deviceId} AND w.owner_user_id = ${owner}
         AND s.disconnected_at IS NULL AND s.lease_expires_at > now()) AS online`;
  return row?.online === true;
}

/**
 * DELETE /api/device-folders/:deviceId[/:folderId]: forget a computer, or one of
 * its folders, in the owner's list. Only the record is removed; nothing on the
 * computer changes. A computer that is connected now is refused (Connect would
 * publish it again within seconds; remove it in Connect instead). Spaces that
 * used it lose their folder. `?dryRun=1` only reports how many Spaces that is,
 * so the app can warn first.
 */
export async function handleDeleteDeviceFolders(request: Request, env: SecurityEnv, deviceId: string, folderId: string | undefined, ctx?: ExecutionContext): Promise<Response> {
  if (request.method !== "DELETE") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, ctx);
  if (!DEVICE_ID.test(deviceId) || (folderId !== undefined && !FOLDER_ID.test(folderId))) throw new HttpError(400, "Not a valid folder");
  const owner = context.userId;
  const exists = await dataOf(env).read.row<{ n: number | string }>`SELECT count(*) AS n FROM device_folders
      WHERE owner_user_id = ${owner} AND device_id = ${deviceId} AND (${folderId ?? null}::text IS NULL OR folder_id = ${folderId ?? null})`;
  if (Number(exists?.n ?? 0) === 0) throw new HttpError(404, "That folder is not in your list");
  if (await deviceIsOnline(env, owner, deviceId))
    throw coded(409, "This computer is connected. Remove the folder in Syntila Connect on it instead.", "device_online");
  const spaces = await spacesUsing(env, owner, deviceId, folderId);
  if (new URL(request.url).searchParams.get("dryRun") === "1")
    return json({ spaces }, { headers: { "Cache-Control": "no-store" } });
  await dataOf(env).tx("device.folders.remove", async (tx) => {
    if (folderId) {
      await tx.run`DELETE FROM space_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId} AND folder_id = ${folderId}`;
      await tx.run`DELETE FROM device_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId} AND folder_id = ${folderId}`;
    } else {
      await tx.run`DELETE FROM space_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId}`;
      await tx.run`DELETE FROM device_folders WHERE owner_user_id = ${owner} AND device_id = ${deviceId}`;
    }
  });
  return json({ ok: true, spaces }, { headers: { "Cache-Control": "no-store" } });
}

async function readSpaceFolder(env: SecurityEnv, spaceId: string): Promise<DeviceFolderView | null> {
  const read = dataOf(env).read;
  const row = await read.row<DeviceFolderView>`SELECT ${read.raw(VIEW)}
      FROM space_folders sf JOIN device_folders f
        ON f.owner_user_id = sf.owner_user_id AND f.device_id = sf.device_id AND f.folder_id = sf.folder_id
     WHERE sf.space_id = ${spaceId}`;
  return row ? { ...row, online: row.online === true } : null;
}

/** GET, PUT and DELETE `/api/spaces/:spaceId/folder`: the folder the Space works in. Owner only. */
export async function handleSpaceFolder(request: Request, env: SecurityEnv, spaceId: string, ctx?: ExecutionContext): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const space = await dataOf(env).read.row<{ ownerUserId: string }>`SELECT s.owner_user_id AS "ownerUserId"
      FROM spaces s JOIN space_memberships m ON m.space_id = s.id WHERE s.id = ${spaceId} AND m.user_id = ${context.userId}`;
  if (!space) throw new HttpError(403, "Space membership required");
  const headers = { "Cache-Control": "no-store" };
  if (space.ownerUserId !== context.userId) {
    if (request.method === "GET") return json({ eligible: false, reason: "not_space_owner", folder: null }, { headers });
    throw new HttpError(403, "Only the Space owner can choose its folder");
  }
  if (request.method === "GET") return json({ eligible: true, folder: await readSpaceFolder(env, spaceId) }, { headers });
  if (request.method === "DELETE") {
    await dataOf(env).read.run`DELETE FROM space_folders WHERE space_id = ${spaceId}`;
    return json({ eligible: true, folder: null }, { headers });
  }
  if (request.method === "PUT") {
    const body = await readJson(request);
    const deviceId = typeof body.deviceId === "string" ? body.deviceId : "";
    const folderId = typeof body.folderId === "string" ? body.folderId : "";
    if (!DEVICE_ID.test(deviceId) || !FOLDER_ID.test(folderId)) throw new HttpError(400, "deviceId and folderId are required");
    const folder = await dataOf(env).read.row<{ mode: string }>`SELECT mode FROM device_folders
       WHERE owner_user_id = ${context.userId} AND device_id = ${deviceId} AND folder_id = ${folderId}`;
    if (!folder) throw new HttpError(404, "That folder is not available any more");
    if (folder.mode !== "write") throw new HttpError(422, "Work needs a folder that allows writing; grant write access in Connect");
    await dataOf(env).read.run`INSERT INTO space_folders (space_id, owner_user_id, device_id, folder_id)
         VALUES (${spaceId}, ${context.userId}, ${deviceId}, ${folderId})
      ON CONFLICT (space_id) DO UPDATE SET owner_user_id = EXCLUDED.owner_user_id, device_id = EXCLUDED.device_id,
             folder_id = EXCLUDED.folder_id, updated_at = now()`;
    return json({ eligible: true, folder: await readSpaceFolder(env, spaceId) }, { headers });
  }
  throw new HttpError(405, "Method not allowed");
}

function coded(status: number, message: string, code: string): HttpError {
  return Object.assign(new HttpError(status, message), { code });
}

/**
 * Work that changes files runs in a folder on a computer. The Space must have
 * one, and the chosen Worker must run on that computer. A Worker whose device
 * is not known yet (an older Connect) is not refused here; the Agent still
 * checks the folder against its own allowed folders.
 */
export async function requireSpaceFolder(env: SecurityEnv, spaceId: string, workerId: string | undefined): Promise<void> {
  const read = dataOf(env).read;
  const folder = await read.row<{ deviceId: string; deviceName: string }>`SELECT f.device_id AS "deviceId", f.device_name AS "deviceName"
      FROM space_folders sf JOIN device_folders f
        ON f.owner_user_id = sf.owner_user_id AND f.device_id = sf.device_id AND f.folder_id = sf.folder_id
     WHERE sf.space_id = ${spaceId}`;
  if (!folder) throw coded(422, "Select a folder for this Space to use the selected Workflow.", "space_folder_required");
  if (!workerId) return;
  const worker = await read.row<{ deviceId: string | null }>`SELECT device_id AS "deviceId" FROM worker_agent_sessions WHERE worker_instance_id = ${workerId}`;
  if (worker?.deviceId && worker.deviceId !== folder.deviceId)
    throw coded(422, `The folder for this Space is on ${folder.deviceName}. Choose a Worker on that computer, or select another folder.`, "worker_not_on_folder_device");
}
