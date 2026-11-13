import {
  DESKTOP_PROFILE_LAB_AUDIENCE,
  authorizeProfileAdmin,
  type SecurityContext,
} from "@syntila/security";
import type { SecurityEnv } from "./http-security.js";

/** A configured owner replaces ID allowlists; it never expands them. */
export async function isProfileLabOwner(
  env: SecurityEnv,
  userId: string,
): Promise<boolean> {
  const email = env.SYNTILA_PROFILE_LAB_OWNER_EMAIL?.trim().toLowerCase();
  if (!email) return false;
  const user = await env.SYNTILA_DB.prepare(
    "SELECT email, status FROM users WHERE id = ?1",
  )
    .bind(userId)
    .first<{ email: string; status: string }>();
  return user?.status === "active" && user.email.trim().toLowerCase() === email;
}

export async function hasProfileLabPermission(
  env: SecurityEnv,
  actor: SecurityContext,
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): Promise<boolean> {
  if (
    actor.user.status !== "active" ||
    (actor.clientType === "desktop" &&
      actor.audience !== DESKTOP_PROFILE_LAB_AUDIENCE)
  )
    return false;
  if (env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined)
    return isProfileLabOwner(env, actor.userId);
  const configured =
    permission === "profiles:release:manage"
      ? env.SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS
      : env.SYNTILA_PROFILE_ADMIN_USER_IDS;
  try {
    authorizeProfileAdmin(
      actor,
      (configured ?? "")
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean),
      permission,
    );
    return true;
  } catch {
    return false;
  }
}
