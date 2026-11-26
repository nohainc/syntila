import { dataOf } from "../../platform/data.js";
import { loadSpacePermissions } from "./space-permissions.js";
import {
  AuthorizationError,
  authorizeSpaceMembership,
  type AuthenticatedUser,
  type Permission,
  type SecurityContext,
} from "@syntila/security";
import {
  canDiscussThread,
  canExecuteThread,
  canManageThread,
  canViewThread,
  DEFAULT_THREAD_ACCESS_POLICY,
  type SpaceKind,
  type SpaceMembership,
  type Thread,
  type WorkflowId,
  WORKFLOW_IDS,
  THREAD_BINDING_IDS,
} from "@syntila/core";

import type { SecurityEnv } from "./http-security.js";
import { authorizeRequest } from "./http-security.js";

import { HttpError, parseJson } from "./http-security.js";

/** Thread configuration owns authored context, never global execution choices. */
export function normalizeThreadWorkConfig(value: unknown): {
  config: Record<string, unknown>;
} {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "workConfig must be an object");
  const input = value as Record<string, unknown>;
  if (
    Object.keys(input).some(
      (key) =>
        !["defaultWorkflowId", "threadInstructions", "bindings"].includes(key),
    ) ||
    typeof input.defaultWorkflowId !== "string" ||
    !WORKFLOW_IDS.includes(input.defaultWorkflowId as WorkflowId) ||
    !input.bindings ||
    typeof input.bindings !== "object" ||
    Array.isArray(input.bindings)
  )
    throw new HttpError(400, "workConfig is invalid");
  const text = (value: unknown): string | undefined => {
    if (value === undefined) return undefined;
    if (typeof value !== "string" || value.length > 4000)
      throw new HttpError(400, "workConfig instructions are invalid");
    return value.trim() || undefined;
  };
  const threadInstructions = text(input.threadInstructions);
  const bindings: Record<string, { additionalInstructions: string }> = {};
  for (const [id, raw] of Object.entries(
    input.bindings as Record<string, unknown>,
  )) {
    if (
      !(THREAD_BINDING_IDS as readonly string[]).includes(id) ||
      !raw ||
      typeof raw !== "object" ||
      Array.isArray(raw)
    )
      throw new HttpError(400, "workConfig binding is invalid");
    const binding = raw as Record<string, unknown>;
    if (Object.keys(binding).some((key) => key !== "additionalInstructions"))
      throw new HttpError(
        400,
        "Thread execution preferences are not supported; use Workflows",
      );
    const instructions = text(binding.additionalInstructions);
    if (instructions) bindings[id] = { additionalInstructions: instructions };
  }
  return {
    config: {
      defaultWorkflowId: input.defaultWorkflowId,
      ...(threadInstructions ? { threadInstructions } : {}),
      bindings,
    },
  };
}

const VIEW_STATE_STRING_KEYS = [
  "workflowReference",
  "workerId",
  "workerTypeId",
  "model",
  "reasoningEffort",
  "catalogRevision",
  "selectionUpdatedAt",
] as const;

/**
 * Validates a Thread metadata patch. Values are merged with JSON merge-patch
 * semantics, so `null` clears a key. Only presentation state is accepted.
 *
 * View state is personal: the caller's `viewState` is stored under
 * `viewStates[userId]`, so one member's selection never replaces another's.
 * A `selectionUpdatedAt` ahead of the server clock is clamped to it, so a
 * device with a fast clock cannot outrank later choices made elsewhere.
 */
export function normalizeThreadMetadataPatch(
  value: unknown,
  userId: string,
  now: string = new Date().toISOString(),
): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "metadata must be an object");
  const input = value as Record<string, unknown>;
  if (Object.keys(input).some((key) => key !== "viewState"))
    throw new HttpError(400, "metadata contains unsupported keys");
  if (input.viewState === undefined) return {};
  if (input.viewState === null) return { viewStates: { [userId]: null } };
  if (typeof input.viewState !== "object" || Array.isArray(input.viewState))
    throw new HttpError(400, "metadata.viewState must be an object");
  const viewState = input.viewState as Record<string, unknown>;
  const allowed = new Set<string>(["tabIndex", ...VIEW_STATE_STRING_KEYS]);
  if (Object.keys(viewState).some((key) => !allowed.has(key)))
    throw new HttpError(400, "metadata.viewState contains unsupported keys");
  const patch: Record<string, unknown> = {};
  if (viewState.tabIndex !== undefined) {
    if (viewState.tabIndex !== 0 && viewState.tabIndex !== 1)
      throw new HttpError(400, "metadata.viewState.tabIndex is invalid");
    patch.tabIndex = viewState.tabIndex;
  }
  for (const key of VIEW_STATE_STRING_KEYS) {
    const entry = viewState[key];
    if (entry === undefined) continue;
    if (
      entry !== null &&
      (typeof entry !== "string" || entry.length === 0 || entry.length > 200)
    )
      throw new HttpError(400, `metadata.viewState.${key} is invalid`);
    patch[key] = entry;
  }
  const at = patch.selectionUpdatedAt;
  if (typeof at === "string") {
    const time = Date.parse(at);
    if (Number.isNaN(time))
      throw new HttpError(
        400,
        "metadata.viewState.selectionUpdatedAt is invalid",
      );
    if (time > Date.parse(now)) patch.selectionUpdatedAt = now;
  }
  return { viewStates: { [userId]: patch } };
}

/** JSON merge-patch (RFC 7386), matching SQLite json_patch. */
export function mergeMetadata(
  target: Record<string, unknown>,
  patch: Record<string, unknown>,
): Record<string, unknown> {
  const result = { ...target };
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) delete result[key];
    else if (typeof value === "object" && !Array.isArray(value)) {
      const current = result[key];
      result[key] = mergeMetadata(
        current && typeof current === "object" && !Array.isArray(current)
          ? (current as Record<string, unknown>)
          : {},
        value as Record<string, unknown>,
      );
    } else result[key] = value;
  }
  return result;
}

/** Returns only the viewer's own view state, as `viewState`. */
function viewerMetadata(
  metadata: Record<string, unknown>,
  viewerUserId: string,
): Record<string, unknown> {
  // A shared top-level `viewState` predates per-user storage and is ignored.
  const { viewStates, viewState: _shared, ...rest } = metadata;
  const own =
    viewStates && typeof viewStates === "object" && !Array.isArray(viewStates)
      ? (viewStates as Record<string, unknown>)[viewerUserId]
      : undefined;
  return own && typeof own === "object" ? { ...rest, viewState: own } : rest;
}

export function threadMetadata(
  row: Record<string, unknown>,
  viewerUserId: string,
): Record<string, unknown> {
  const accessPolicy = parseJson<Record<string, unknown>>(
    row.accessPolicyJson ?? row.access_policy_json,
    {},
  );
  return {
    id: String(row.id),
    spaceId: String(row.spaceId ?? row.space_id),
    name: String(row.name),
    status: String(row.status),
    createdByUserId: row.leadUserId ?? row.lead_user_id ?? null,
    creatorEmail: row.creatorEmail ?? null,
    creatorIsOwner: Number(row.creatorIsOwner) === 1,
    lead: row.leadUserId ?? row.lead_user_id ?? null,
    leadDisplayName:
      row.leadDisplayName ?? row.lead_display_name ?? row.leadName ?? null,
    brief: row.brief ?? row.lastMessageSnippet ?? "",
    briefAuthorName: row.briefAuthorName ?? null,
    accessPolicy,
    workConfig: parseJson(row.workConfigJson ?? row.configJson, {
      defaultWorkflowId: "direct",
      bindings: {},
    }),
    metadata: viewerMetadata(
      parseJson<Record<string, unknown>>(
        row.metadataJson ?? row.metadata_json,
        {},
      ),
      viewerUserId,
    ),
    queueStatus: "Idle",
    hasActiveWork: Number(row.hasActiveWork) === 1,
    hasUnread: Number(row.hasUnread) === 1,
    isGeneral:
      Number(row.isGeneral) === 1 ||
      Number(row.is_general) === 1 ||
      row.isGeneral === true ||
      row.is_general === true,
    pinnedAt: typeof row.pinnedAt === "string" ? row.pinnedAt : null,
    pinPosition: typeof row.pinPosition === "number" ? row.pinPosition : 0,
    createdAt: String(row.createdAt ?? row.created_at),
    updatedAt: String(row.updatedAt ?? row.updated_at),
  };
}

export function sortThreads<T extends Record<string, unknown>>(
  threads: T[],
): T[] {
  return [...threads].sort((a, b) => {
    const aId = String(a.id ?? "");
    const bId = String(b.id ?? "");
    const aUpdated = String(
      a.updatedAt ?? a.updated_at ?? a.createdAt ?? a.created_at ?? "",
    );
    const bUpdated = String(
      b.updatedAt ?? b.updated_at ?? b.createdAt ?? b.created_at ?? "",
    );
    const byUpdated = bUpdated.localeCompare(aUpdated);
    return byUpdated !== 0 ? byUpdated : bId.localeCompare(aId);
  });
}

export function discussionReferences(value: unknown): readonly string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new HttpError(400, "references must be an array");
  return value.flatMap((reference) => {
    if (typeof reference === "string" && reference.trim())
      return [reference.trim()];
    if (reference && typeof reference === "object") {
      const id = (reference as Record<string, unknown>).id;
      if (typeof id === "string" && id.trim()) return [id.trim()];
    }
    throw new HttpError(400, "references must contain non-empty identifiers");
  });
}

export type ThreadAccess = "view" | "discuss" | "execute" | "manage";

async function loadThreadRow(env: SecurityEnv, threadId: string) {
  const row = await dataOf(env).read.row<Record<string, unknown>>`SELECT t.id, t.space_id AS "spaceId", t.name, t.status,
            t.access_policy_json AS "accessPolicyJson", t.lead_user_id AS "leadUserId",
            t.is_general AS "isGeneral",
            t.created_at AS "createdAt", t.updated_at AS "updatedAt",
            COALESCE(s.kind, 'group') AS "spaceKind"
     FROM threads t
     JOIN spaces s ON s.id = t.space_id
     WHERE t.id = ${threadId}`;
  if (!row) throw new HttpError(404, "Thread not found");
  return row;
}

function threadAccessPermission(access: ThreadAccess): Permission {
  return access === "view"
    ? "spaces:read"
    : access === "discuss"
      ? "spaces:write"
      : access === "execute"
        ? "run.start"
        : "spaces:write";
}

export async function authorizeThreadAccess(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  access: ThreadAccess,
  accessContext?: ExecutionContext,
): Promise<{
  context: SecurityContext;
  thread: Thread;
  spaceId: string;
}> {
  const row = await loadThreadRow(env, threadId);
  const context = await authorizeRequest(
    request,
    env,
    threadAccessPermission(access),
    String(row.spaceId),
    accessContext,
  );
  return threadAccessForContext(env, context, row, access);
}

/**
 * Thread access for a person who is not making this HTTP request, such as
 * the author of a queued request Cloud sends on their behalf. Checks the same
 * account status, Space membership and Thread rules as a live request.
 */
export async function authorizeThreadAccessAsUser(
  env: SecurityEnv,
  userId: string,
  threadId: string,
  access: ThreadAccess,
): Promise<{
  context: SecurityContext;
  thread: Thread;
  spaceId: string;
}> {
  const row = await loadThreadRow(env, threadId);
  const user = await dataOf(env).read.row<AuthenticatedUser>`SELECT id, email, display_name AS "displayName", status FROM users WHERE id = ${userId}`;
  if (!user) throw new HttpError(403, `Thread ${access} access is required`);
  const spaceId = String(row.spaceId);
  try {
    const { role } = await authorizeSpaceMembership(
      dataOf(env).read,
      { userId, user },
      spaceId,
      threadAccessPermission(access),
    );
    const context: SecurityContext = {
      userId,
      user,
      spaceRoles: { [spaceId]: role },
      sessionId: "thread-request-queue",
      clientType: "web",
    };
    return await threadAccessForContext(env, context, row, access);
  } catch (error) {
    if (error instanceof AuthorizationError)
      throw new HttpError(403, `Thread ${access} access is required`);
    throw error;
  }
}

async function threadAccessForContext(
  env: SecurityEnv,
  context: SecurityContext,
  row: Record<string, unknown>,
  access: ThreadAccess,
) {
  const membership = await dataOf(env).read.row<SpaceMembership>`SELECT id, space_id AS "spaceId", user_id AS "userId", role,
            created_at AS "createdAt", updated_at AS "updatedAt"
     FROM space_memberships WHERE space_id = ${String(row.spaceId)} AND user_id = ${context.userId}`;
  const policy = await loadSpacePermissions(
    env,
    context.userId,
    String(row.spaceId),
  );
  const effectiveMembership = membership
    ? { ...membership, permissions: policy.rights }
    : null;
  const thread: Thread = {
    id: String(row.id),
    spaceId: String(row.spaceId),
    name: String(row.name),
    status: String(row.status) as Thread["status"],
    accessPolicy: {
      ...DEFAULT_THREAD_ACCESS_POLICY,
      ...parseJson(row.accessPolicyJson, {}),
    },
    lead: {
      userId: String(row.leadUserId),
      assignedAt: String(row.createdAt),
      assignedByUserId: String(row.leadUserId),
    },
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
  const spaceKind = (row.spaceKind as SpaceKind) ?? "group";
  const allowed =
    access === "view"
      ? canViewThread(context.userId, effectiveMembership, thread)
      : access === "discuss"
        ? canDiscussThread(context.userId, effectiveMembership, thread)
        : access === "execute"
          ? canExecuteThread(context.userId, effectiveMembership, thread)
          : canManageThread(
              context.userId,
              effectiveMembership,
              thread,
              spaceKind,
            );
  if (!allowed) throw new HttpError(403, `Thread ${access} access is required`);
  return { context, thread, spaceId: String(row.spaceId) };
}

export function summarizeTestCounts(text: string): string | null {
  const counts: string[] = [];
  for (const status of ["failed", "passed", "skipped"] as const) {
    const matches = text.matchAll(
      new RegExp(`\\b(\\d+)\\s+(?:tests?\\s+)?${status}\\b`, "gi"),
    );
    const match = [...matches].at(-1);
    if (match) counts.push(`${match[1]} ${status}`);
  }
  return counts.length > 0 ? counts.join(", ") : null;
}
