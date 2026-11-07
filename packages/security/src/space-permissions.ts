/**
 * Version 1 Space member rights, independent of provider and Workspace
 * permissions. Owners grant exactly three rights; a fourth key is derived.
 *
 * | key                | scope                          | default (owner/collab/viewer) | enforcement |
 * | ------------------ | ------------------------------ | ----------------------------- | ----------- |
 * | `chat`             | one Space, one member          | true / true / false           | May start Chat runs (`run.start`) and, through them, answer on their own Workers (see `useOwnWorkers`). |
 * | `work`             | one Space, one member          | true / true / false           | May start Workflow runs (`run.start`) on the Space's Workflow Workspace. |
 * | `manageOwnThreads` | one Space, member's own Threads| true / true / false           | May create/rename/archive Threads they own (`spaces:write`). Never grants control of others' Threads. |
 *
 * `spaces:write` needs any of the three; `run.start` needs `chat` or `work`;
 * `spaces:read` is always allowed for members. Owners always hold all rights
 * and cannot be overridden. `runs:control` and `spaces:manage` stay owner-only.
 *
 * Compatibility with the legacy four-field contract:
 * - `useOwnWorkers` is DERIVED and always equals `chat`. It is emitted on every
 *   read so older clients and Cloud code keep working, but it is never
 *   stored or read from stored data, and any value a legacy client writes
 *   is accepted (if boolean) and ignored.
 * - Stored overrides in `settings.memberPermissions[userId]` are converted on
 *   read, never rewritten: `chat`/`work`/`manageOwnThreads` count only when
 *   strictly `true`; missing or malformed values grant nothing (fail closed).
 *   Legacy `useOwnWorkers: false` records therefore need no migration; they
 *   simply stop restricting anyone who has `chat`.
 * - Members with no stored override receive the role defaults above.
 *
 * Personal Workers: a member with `chat` may run Chat on a Worker in a
 * Workspace they own, outside the Space's Workflow Workspace. Workers shared by
 * other people never qualify. Without `chat` they get no personal-Worker use.
 * Direct Spaces ignore overrides and use collaborator defaults.
 */
export const SPACE_MEMBER_PERMISSION_KEYS = [
  "chat",
  "useOwnWorkers",
  "work",
  "manageOwnThreads",
] as const;
/** The three independently granted (and stored) rights. */
export const GRANTED_SPACE_RIGHT_KEYS = [
  "chat",
  "work",
  "manageOwnThreads",
] as const;
export type SpaceMemberPermission =
  (typeof SPACE_MEMBER_PERMISSION_KEYS)[number];
export type SpaceMemberPermissions = Readonly<
  Record<SpaceMemberPermission, boolean>
>;

/** Builds the full compatibility shape from the three granted rights. */
export function composeSpaceMemberPermissions(
  rights: Pick<SpaceMemberPermissions, "chat" | "work" | "manageOwnThreads">,
): SpaceMemberPermissions {
  return {
    chat: rights.chat,
    useOwnWorkers: rights.chat,
    work: rights.work,
    manageOwnThreads: rights.manageOwnThreads,
  };
}

/** The persisted shape: only the three granted rights, never `useOwnWorkers`. */
export function storedSpaceMemberRights(
  rights: Pick<SpaceMemberPermissions, "chat" | "work" | "manageOwnThreads">,
): Record<(typeof GRANTED_SPACE_RIGHT_KEYS)[number], boolean> {
  return {
    chat: rights.chat,
    work: rights.work,
    manageOwnThreads: rights.manageOwnThreads,
  };
}

/**
 * Reads a stored member or invitation snapshot. Absent or empty snapshots use
 * the role defaults; any other value is parsed fail-closed and legacy
 * `useOwnWorkers` is ignored.
 */
export function normalizeSpaceMemberSnapshot(
  role: string,
  snapshot: unknown,
): SpaceMemberPermissions {
  const value = parseSpaceSettings(snapshot);
  if (!Object.keys(value).length) return defaultSpaceMemberPermissions(role);
  return composeSpaceMemberPermissions({
    chat: value.chat === true,
    work: value.work === true,
    manageOwnThreads: value.manageOwnThreads === true,
  });
}

export function defaultSpaceMemberPermissions(
  role: string,
): SpaceMemberPermissions {
  const owner = role === "owner";
  const collaborator = role === "collaborator";
  return {
    chat: owner || collaborator,
    useOwnWorkers: owner || collaborator,
    work: owner || collaborator,
    manageOwnThreads: owner || collaborator,
  };
}

export function parseSpaceSettings(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return {};
    }
  }
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function spaceMemberPermissions(
  role: string,
  settings: unknown,
  userId: string,
): SpaceMemberPermissions {
  const defaults = defaultSpaceMemberPermissions(role);
  if (role === "owner") return defaults;
  const map = parseSpaceSettings(
    parseSpaceSettings(settings).memberPermissions,
  );
  const override = map[userId];
  if (!Object.hasOwn(map, userId)) return defaults;
  // Stored overrides fail closed: missing or malformed values grant no rights.
  const value = parseSpaceSettings(override);
  return {
    chat: value.chat === true,
    // Derived: any member who may Chat may answer with their own Workers.
    // A legacy stored `useOwnWorkers` value is ignored.
    useOwnWorkers: value.chat === true,
    work: value.work === true,
    manageOwnThreads: value.manageOwnThreads === true,
  };
}
