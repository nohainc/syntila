import { requirePaidFeature } from "../account-plan.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  SPACE_MEMBER_PERMISSION_KEYS,
  defaultSpaceMemberPermissions,
  spaceMemberPermissions,
  type SpaceMemberPermissions,
  type SecurityContext,
} from "@syntila/security";
import { HttpError } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

const GRANTED_RIGHT_KEYS = ["chat", "work", "manageOwnThreads"] as const;

/**
 * Accepts the three granted rights. Legacy clients also send `useOwnWorkers`;
 * it is tolerated (any boolean) but ignored, because it is derived from Chat.
 */
export function validateMemberPermissions(
  value: unknown,
): SpaceMemberPermissions {
  const record =
    value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  if (
    !record ||
    Object.keys(record).some(
      (key) =>
        !(SPACE_MEMBER_PERMISSION_KEYS as readonly string[]).includes(key),
    ) ||
    GRANTED_RIGHT_KEYS.some((key) => typeof record[key] !== "boolean") ||
    (Object.hasOwn(record, "useOwnWorkers") &&
      typeof record.useOwnWorkers !== "boolean")
  ) {
    throw new HttpError(400, "All member permissions must be boolean values");
  }
  const chat = record.chat as boolean;
  return {
    chat,
    work: record.work as boolean,
    manageOwnThreads: record.manageOwnThreads as boolean,
    useOwnWorkers: chat,
  };
}

export async function loadSpacePermissions(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  spaceId: string,
) {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT sm.role, s.settings_json AS settingsJson, COALESCE(s.kind, 'group') AS kind,
            EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = s.id) AS isSupport
     FROM space_memberships sm
     JOIN spaces s ON s.id = sm.space_id WHERE sm.space_id = ?1 AND sm.user_id = ?2`,
  )
    .bind(spaceId, userId)
    .first<{
      role: string;
      settingsJson: string;
      kind: string;
      isSupport: number;
    }>();
  if (!row) throw new HttpError(403, "Space membership is required");
  const isSupport = row.isSupport === 1;
  return {
    role: row.role,
    kind: row.kind,
    isSupport,
    // Support Spaces are human messaging only: no Chat, Work, or own Workers.
    rights: isSupport
      ? {
          ...defaultSpaceMemberPermissions("collaborator"),
          chat: false,
          work: false,
          useOwnWorkers: false,
        }
      : row.kind === "direct"
        ? defaultSpaceMemberPermissions("collaborator")
        : spaceMemberPermissions(row.role, row.settingsJson, userId),
    settingsJson: row.settingsJson,
  };
}

export async function requireSpaceRight(
  env: SecurityEnv,
  context: SecurityContext,
  spaceId: string,
  right: keyof SpaceMemberPermissions,
) {
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  if (!policy.rights[right])
    throw new HttpError(403, "Space permission is required: " + right);
  return policy;
}

export async function requireSpaceOwner(
  env: SecurityEnv,
  context: SecurityContext,
  spaceId: string,
) {
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  if (policy.role !== "owner")
    throw new HttpError(403, "Only the Space owner can manage invitations");
  return policy;
}

/**
 * Plan admission for a workflow, for the *requesting* account only: a Space
 * owner's, Workspace owner's or another member's plan never grants it. Only
 * the standalone Research workflow (every version) is gated; workflows that
 * merely contain a research step, such as Full Cycle, are not. Called before
 * any request, execution record, capacity reservation or dispatch exists, and
 * again for user-triggered retries. Automatic recovery of accepted work never
 * calls it, so an accepted run finishes after a plan lapses.
 */
export async function requireWorkflowEntitlement(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  workflowId: string,
): Promise<void> {
  if (workflowId === "research")
    await requirePaidFeature(
      env as unknown as Env,
      userId,
      "workflow.research",
    );
}

export async function requireWorkflowPermission(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  spaceId: string,
  workflowId: string,
  options: { entitlement?: boolean } = {},
) {
  const policy = await loadSpacePermissions(env, userId, spaceId);
  const chat = workflowId === "chat";
  if (policy.isSupport)
    throw new HttpError(403, "Support Threads accept messages only");
  if (policy.kind === "direct" && !chat)
    throw new HttpError(403, "Personal Spaces support Chat only");
  if (!(chat ? policy.rights.chat : policy.rights.work)) {
    throw new HttpError(
      403,
      chat
        ? "Chat is not allowed for this member"
        : "Work workflows are disabled or not allowed for this member",
    );
  }
  const configuration = await loadSpaceWorkflowConfigurations(
    env,
    spaceId,
    workflowId,
  );
  if (configuration.configurations[0]?.enabled === false)
    throw new HttpError(403, "Workflow is disabled in this Space");
  if (options.entitlement !== false)
    await requireWorkflowEntitlement(env, userId, workflowId);
  return policy;
}

export function permissionJsonPath(group: string, id: string): string {
  return "$." + group + "." + JSON.stringify(id);
}
