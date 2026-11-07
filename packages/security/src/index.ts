export * from "./space-permissions.js";
import {
  spaceMemberPermissions,
  type SpaceMemberPermissions,
} from "./space-permissions.js";
/** Security primitives for current Syntila identities and resources. */

export const SPACE_ROLES = ["owner", "collaborator", "viewer"] as const;
export type SpaceRole = (typeof SPACE_ROLES)[number];

export const PERMISSIONS = [
  "spaces:read",
  "spaces:write",
  "spaces:manage",
  "run.start",
  "runs:control",
  "workspace:manage",
  "profiles:admin",
  "profiles:release:manage",
  "audit:read",
  "usage:read",
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const SPACE_ROLE_PERMISSIONS: Record<SpaceRole, readonly Permission[]> =
  {
    owner: [
      "spaces:read",
      "spaces:write",
      "spaces:manage",
      "run.start",
      "runs:control",
    ],
    collaborator: ["spaces:read", "spaces:write", "run.start"],
    viewer: ["spaces:read"],
  };

export class AuthorizationError extends Error {
  readonly code = "FORBIDDEN";
  constructor(
    readonly permission: Permission,
    readonly resourceId?: string,
  ) {
    super(
      `Permission '${permission}' is required${resourceId ? ` for resource '${resourceId}'` : ""}`,
    );
    this.name = "AuthorizationError";
  }
}

export class AuthenticationError extends Error {
  readonly code = "UNAUTHORIZED";
  constructor(message: string) {
    super(message);
    this.name = "AuthenticationError";
  }
}

export type ClientType = "web" | "desktop" | "cli" | "api";

export const DESKTOP_WORKSPACE_AUDIENCE = "syntila.desktop.management" as const;
export const DESKTOP_PROFILE_LAB_AUDIENCE =
  "syntila.profile-lab.management" as const;
export const SUPPORTED_DESKTOP_AUDIENCES = [
  DESKTOP_WORKSPACE_AUDIENCE,
  DESKTOP_PROFILE_LAB_AUDIENCE,
] as const;
export type DesktopAudience = (typeof SUPPORTED_DESKTOP_AUDIENCES)[number];

export interface AuthenticatedUser {
  readonly id: string;
  readonly email: string;
  readonly displayName: string;
  readonly avatarUrl?: string | null;
  readonly status: "active" | "suspended" | "deactivated";
}

/** Request identity and current Space memberships; resource access is checked separately. */
export interface SecurityContext {
  readonly userId: string;
  readonly user: AuthenticatedUser;
  readonly spaceRoles: Readonly<Record<string, SpaceRole>>;
  readonly spacePermissions?: Readonly<Record<string, SpaceMemberPermissions>>;
  readonly sessionId: string;
  readonly clientType: ClientType;
  readonly audience?: string;
}

export function canAccessSpace(
  context: SecurityContext,
  spaceId: string,
): boolean {
  return context.user.status === "active" && !!context.spaceRoles[spaceId];
}

export function authorize(
  context: SecurityContext,
  permission: Permission,
  spaceId?: string,
): void {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, spaceId);
  }
  // Unscoped Space listing/creation starts from authenticated identity and
  // is filtered/owned by its handler. Every other permission needs an explicit
  // Space, Workspace owner, or Profile administrator check.
  if (!spaceId) {
    if (permission === "spaces:read" || permission === "spaces:manage") return;
    throw new AuthorizationError(permission);
  }
  const role = context.spaceRoles[spaceId];
  if (
    !role ||
    !allowsSpacePermission(
      role,
      context.spacePermissions?.[spaceId],
      permission,
    )
  ) {
    throw new AuthorizationError(permission, spaceId);
  }
}

/**
 * Maps the Space member rights contract (see space-permissions.ts) onto
 * Permissions: `spaces:write` needs chat, work or manageOwnThreads;
 * `run.start` needs chat or work. `useOwnWorkers` is derived from `chat` and
 * never consulted here. Owners and rights-less contexts use role defaults.
 */
export function allowsSpacePermission(
  role: SpaceRole,
  rights: SpaceMemberPermissions | undefined,
  permission: Permission,
): boolean {
  if (!rights || role === "owner")
    return SPACE_ROLE_PERMISSIONS[role].includes(permission);
  if (permission === "spaces:read") return true;
  if (permission === "spaces:write")
    return rights.chat || rights.work || rights.manageOwnThreads;
  if (permission === "run.start") return rights.chat || rights.work;
  return false;
}

export interface DatabaseStatement {
  bind(...values: unknown[]): DatabaseStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{
    results?: readonly T[];
  }>;
  run(): Promise<{ success?: boolean }>;
}

export interface DatabaseAdapter {
  prepare(query: string): DatabaseStatement;
}

export interface AuthenticatedIdentity {
  readonly userId: string;
  readonly email: string;
  readonly name: string;
  readonly sessionId: string;
}

export async function resolveSpaceSecurityContextFromIdentity(
  db: DatabaseAdapter,
  identity: AuthenticatedIdentity,
  clientType: ClientType = "web",
  audience?: string,
): Promise<SecurityContext> {
  const userRow = await db
    .prepare(
      `SELECT id, email, display_name, avatar_url, status
       FROM users WHERE id = ?1`,
    )
    .bind(identity.userId)
    .first<{
      id: string;
      email: string;
      display_name: string;
      avatar_url: string | null;
      status: string;
    }>();
  if (!userRow) throw new AuthenticationError("Syntila user not found");
  if (!["active", "suspended", "deactivated"].includes(userRow.status)) {
    throw new AuthenticationError("Invalid Syntila user status");
  }
  const user: AuthenticatedUser = {
    id: userRow.id,
    email: userRow.email,
    displayName: userRow.display_name,
    avatarUrl: userRow.avatar_url,
    status: userRow.status as AuthenticatedUser["status"],
  };
  if (user.status !== "active") {
    throw new AuthenticationError(`User account is ${user.status}`);
  }
  const memberships = await db
    .prepare(
      `SELECT sm.space_id, sm.role, s.settings_json AS settingsJson
       FROM space_memberships sm JOIN spaces s ON s.id = sm.space_id
       WHERE sm.user_id = ?1`,
    )
    .bind(user.id)
    .all<{ space_id: string; role: SpaceRole; settingsJson: string }>();
  const spaceRoles: Record<string, SpaceRole> = {};
  const spacePermissions: Record<string, SpaceMemberPermissions> = {};
  for (const membership of memberships.results ?? []) {
    if (SPACE_ROLES.includes(membership.role)) {
      spaceRoles[membership.space_id] = membership.role;
      spacePermissions[membership.space_id] = spaceMemberPermissions(
        membership.role,
        membership.settingsJson,
        user.id,
      );
    }
  }
  return {
    userId: user.id,
    user,
    spaceRoles,
    spacePermissions,
    sessionId: identity.sessionId,
    clientType,
    ...(audience ? { audience } : {}),
  };
}

export async function authorizeSpaceMembership(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  spaceId: string,
  permission: Permission,
): Promise<{ role: SpaceRole }> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, spaceId);
  }
  const membership = await db
    .prepare(
      `SELECT sm.role, s.settings_json AS settingsJson FROM space_memberships sm
       JOIN spaces s ON s.id = sm.space_id
       WHERE sm.space_id = ?1 AND sm.user_id = ?2`,
    )
    .bind(spaceId, context.userId)
    .first<{ role: SpaceRole; settingsJson?: string }>();
  if (
    !membership ||
    !SPACE_ROLES.includes(membership.role) ||
    !allowsSpacePermission(
      membership.role,
      spaceMemberPermissions(
        membership.role,
        membership.settingsJson,
        context.userId,
      ),
      permission,
    )
  ) {
    throw new AuthorizationError(permission, spaceId);
  }
  return membership;
}

export async function authorizeWorkspaceOwner(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  workspaceId: string,
  permission: Permission = "workspace:manage",
): Promise<void> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, workspaceId);
  }
  const workspace = await db
    .prepare(
      "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status <> 'revoked'",
    )
    .bind(workspaceId, context.userId)
    .first<{ id: string }>();
  if (!workspace) throw new AuthorizationError(permission, workspaceId);
}

export async function authorizeSpaceOwner(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  spaceId: string,
  permission: Permission = "spaces:manage",
): Promise<void> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, spaceId);
  }
  const owner = await db
    .prepare("SELECT id FROM spaces WHERE id = ?1 AND owner_user_id = ?2")
    .bind(spaceId, context.userId)
    .first<{ id: string }>();
  if (!owner) throw new AuthorizationError(permission, spaceId);
}

export interface InvitationAuthorizationTarget {
  readonly id: string;
  readonly spaceId: string;
  readonly email: string;
  readonly status: string;
  readonly expiresAt: string;
}

export function authorizeSpaceInvitationResponse(
  context: Pick<SecurityContext, "userId" | "user">,
  invitation: InvitationAuthorizationTarget,
  now = new Date().toISOString(),
): void {
  if (context.user.status !== "active") {
    throw new AuthorizationError("spaces:write", invitation.spaceId);
  }
  if (
    context.user.email.trim().toLowerCase() !==
    invitation.email.trim().toLowerCase()
  ) {
    throw new AuthorizationError("spaces:write", invitation.spaceId);
  }
  if (invitation.status !== "pending") {
    throw new AuthorizationError("spaces:write", invitation.spaceId);
  }
  const expiryTime = new Date(invitation.expiresAt).getTime();
  const currentTime = new Date(now).getTime();
  if (Number.isNaN(expiryTime) || expiryTime <= currentTime) {
    throw new AuthorizationError("spaces:write", invitation.spaceId);
  }
}

export function canAccessSpaceInvitation(
  context: SecurityContext,
  invitation: InvitationAuthorizationTarget,
): boolean {
  if (context.user.status !== "active") return false;
  const isOwner = context.spaceRoles[invitation.spaceId] === "owner";
  const isRecipient =
    context.user.email.trim().toLowerCase() ===
    invitation.email.trim().toLowerCase();
  return isOwner || isRecipient;
}

export function authorizeProfileAdmin(
  context: Pick<SecurityContext, "userId" | "user"> & {
    audience?: string;
    clientType?: ClientType;
  },
  adminUserIds: readonly string[],
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): void {
  if (
    context.user.status !== "active" ||
    !adminUserIds.includes(context.userId)
  ) {
    throw new AuthorizationError(permission);
  }
  if (
    context.clientType === "desktop" &&
    context.audience !== DESKTOP_PROFILE_LAB_AUDIENCE
  ) {
    throw new AuthorizationError(permission);
  }
}

const encoder = new TextEncoder();

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export async function hashToken(token: string): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest(
    "SHA-256",
    encoder.encode(token),
  );
  return bytesToHex(new Uint8Array(digest));
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

export async function computePackageDigest(
  data: Uint8Array | ArrayBuffer | string,
): Promise<string> {
  const source =
    typeof data === "string"
      ? encoder.encode(data)
      : data instanceof ArrayBuffer
        ? data
        : (data as BufferSource);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", source);
  return `sha256:${bytesToHex(new Uint8Array(digest))}`;
}

export function extractBearerToken(headers: Headers): string | null {
  const value = headers.get("authorization");
  if (!value) return null;
  const match = value.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}
