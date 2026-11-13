import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";

/** Hidden identifiers only: absent and newly discovered options remain visible. */
export interface WorkspaceWorkerPreferences {
  schemaVersion: 1;
  hiddenWorkers: string[];
  hiddenModels: Record<string, string[]>;
  hiddenEfforts: Record<string, Record<string, string[]>>;
}

const MAX_BODY_BYTES = 65536;
const MAX_ENTRIES = 200;
const emptyPreferences = (): WorkspaceWorkerPreferences => ({
  schemaVersion: 1,
  hiddenWorkers: [],
  hiddenModels: {},
  hiddenEfforts: {},
});

function entries(value: unknown): [string, unknown][] {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "Expected an object");
  const result = Object.entries(value);
  if (result.length > MAX_ENTRIES || result.some(([key]) => !validId(key)))
    throw new HttpError(400, "Invalid or too many identifiers");
  return result;
}
function validId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 200;
}
function list(value: unknown): string[] {
  if (
    !Array.isArray(value) ||
    value.length > MAX_ENTRIES ||
    value.some((v) => !validId(v))
  )
    throw new HttpError(400, "Invalid identifier list");
  return [...new Set(value as string[])];
}
function parsePreferences(value: unknown): WorkspaceWorkerPreferences {
  const fields = Object.fromEntries(entries(value));
  if (
    fields.schemaVersion !== 1 ||
    Object.keys(fields).some(
      (key) =>
        ![
          "schemaVersion",
          "hiddenWorkers",
          "hiddenModels",
          "hiddenEfforts",
        ].includes(key),
    )
  )
    throw new HttpError(400, "Invalid preference document");
  return {
    schemaVersion: 1,
    hiddenWorkers: list(fields.hiddenWorkers),
    hiddenModels: Object.fromEntries(
      entries(fields.hiddenModels).map(([worker, models]) => [
        worker,
        list(models),
      ]),
    ),
    hiddenEfforts: Object.fromEntries(
      entries(fields.hiddenEfforts).map(([worker, models]) => [
        worker,
        Object.fromEntries(
          entries(models).map(([model, efforts]) => [model, list(efforts)]),
        ),
      ]),
    ),
  };
}
async function readBody(request: Request): Promise<unknown> {
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "Missing preference document");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new HttpError(413, "Preference document too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HttpError(400, "Invalid JSON");
  }
}

export async function handleWorkspaceWorkerPreferences(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const { userId } = await securityContext(request, env, ctx);
  const workspace = await env.SYNTILA_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, userId)
    .first();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (request.method === "GET") {
    const row = await env.SYNTILA_DB.prepare(
      "SELECT preferences_json AS preferencesJson FROM workspace_worker_preferences WHERE user_id = ?1 AND workspace_id = ?2",
    )
      .bind(userId, workspaceId)
      .first<{ preferencesJson: string }>();
    return json({
      preferences: row ? JSON.parse(row.preferencesJson) : emptyPreferences(),
    });
  }
  if (request.method === "DELETE") {
    await env.SYNTILA_DB.prepare(
      "DELETE FROM workspace_worker_preferences WHERE user_id = ?1 AND workspace_id = ?2",
    )
      .bind(userId, workspaceId)
      .run();
    return json({ preferences: emptyPreferences() });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const preferences = parsePreferences(await readBody(request));
  await env.SYNTILA_DB.prepare(
    `INSERT INTO workspace_worker_preferences(user_id,workspace_id,preferences_json,updated_at) VALUES(?1,?2,?3,?4)
    ON CONFLICT(user_id,workspace_id) DO UPDATE SET preferences_json=excluded.preferences_json,updated_at=excluded.updated_at`,
  )
    .bind(
      userId,
      workspaceId,
      JSON.stringify(preferences),
      new Date().toISOString(),
    )
    .run();
  return json({ preferences });
}
