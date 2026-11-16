import { dataOf } from "../../platform/data.js";
import type { SecurityEnv } from "./handlers.js";

export function hasControlCharacters(value: string): boolean {
  return Array.from(value).some((character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || code === 0x7f;
  });
}

/**
 * Workspace names are unique among one owner's registered (not released)
 * Workspaces, ignoring case, so the owner can tell them apart.
 */
export async function workspaceNameTaken(
  env: SecurityEnv,
  ownerUserId: string,
  name: string,
  exceptWorkspaceId: string | null,
): Promise<boolean> {
  const row = await dataOf(env).read.row<{ taken: number }>`
    SELECT 1 AS taken FROM execution_workspaces
     WHERE owner_user_id = ${ownerUserId} AND status <> 'revoked'
       AND lower(name) = lower(${name}) AND id <> ${exceptWorkspaceId ?? ""}
     LIMIT 1`;
  return row != null;
}
