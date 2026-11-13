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
  db: Pick<D1Database, "prepare">,
  ownerUserId: string,
  name: string,
  exceptWorkspaceId: string | null,
): Promise<boolean> {
  const row = await db
    .prepare(
      `SELECT 1 AS taken FROM execution_workspaces
        WHERE owner_user_id = ?1 AND status <> 'revoked'
          AND lower(name) = lower(?2) AND id <> ?3
        LIMIT 1`,
    )
    .bind(ownerUserId, name, exceptWorkspaceId ?? "")
    .first<{ taken: number }>();
  return row != null;
}
