import { PinOrderSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { isSpaceMember } from "../queries.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { HttpError, authorizeThreadAccess, json } from "./handlers.js";
import { authorizeRequest } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";
import { inTransaction } from "../../platform/tx-env.js";

/** Pins of one user and kind are written under a per-user lock (no global
 * writer lock): positions are computed from the user's current pins. */
const lockPins = (
  tx: { lock(scope: string, id: string): Promise<void> },
  userId: string,
) => tx.lock("syntila.pins", userId);

/** Pin or unpin a Space or Thread for the caller only. Both operations are
 * idempotent. Other sessions of the same user learn through a
 * recipient-scoped event, like read markers. */
export async function handleSetPin(
  request: Request,
  env: SecurityEnv,
  kind: string,
  targetId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  if (kind !== "space" && kind !== "thread")
    throw new HttpError(404, "Not found");
  const pinned = request.method === "PUT";
  let userId: string;
  let spaceId: string;
  if (kind === "space") {
    const context = await authorizeRequest(
      request,
      env,
      "spaces:read",
      targetId,
      accessContext,
    );
    userId = context.userId;
    spaceId = targetId;
    const member = await isSpaceMember(env.SYNTILA_DB, targetId, userId);
    if (!member) throw new HttpError(404, "Space not found");
  } else {
    const access = await authorizeThreadAccess(
      request,
      env,
      targetId,
      "view",
      accessContext,
    );
    userId = access.context.userId;
    spaceId = access.spaceId;
  }
  const pinnedAt = new Date().toISOString();
  await inTransaction(env, "pin.set", async (txEnv, tx) => {
    await lockPins(tx, userId);
    const mutation = pinned
      ? txEnv.SYNTILA_DB.prepare(
          // A new pin goes to the top of the user's pins of that kind.
          `INSERT INTO user_pins (user_id, kind, target_id, pinned_at, position)
         VALUES (?1, ?2, ?3, ?4,
           COALESCE((SELECT MIN(position) FROM user_pins
                      WHERE user_id = ?1 AND kind = ?2), 0) - 1)
         ON CONFLICT DO NOTHING`,
        ).bind(userId, kind, targetId, pinnedAt)
      : txEnv.SYNTILA_DB.prepare(
          `DELETE FROM user_pins WHERE user_id = ?1 AND kind = ?2 AND target_id = ?3`,
        ).bind(userId, kind, targetId);
    await publishCollaborationEvent(
      txEnv,
      kind === "space" ? "space.updated" : "thread.updated",
      spaceId,
      targetId,
      {
        ...(kind === "thread" ? { threadId: targetId } : {}),
        recipientUserIds: [userId],
        mutations: [mutation],
      },
    );
  });
  return json({ kind, id: targetId, pinned });
}

/** Store the caller's manual order of pinned items: `ids` first to last. Only
 * the caller's own pins are touched, so ids that are not pinned are ignored.
 * Threads also need their `spaceId` so other sessions can be told. */
export async function handleSetPinOrder(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const body = await readBody(request, PinOrderSchema);
  const kind = body.kind;
  const ids = [...new Set(body.ids)];
  const spaceId = kind === "space" ? ids[0]! : body.spaceId;
  if (typeof spaceId !== "string" || spaceId.length === 0)
    throw new HttpError(400, "spaceId is required for threads");
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const member = await isSpaceMember(env.SYNTILA_DB, spaceId, context.userId);
  if (!member) throw new HttpError(404, "Space not found");
  await inTransaction(env, "pin.order", async (txEnv, tx) => {
    await lockPins(tx, context.userId);
    const mutations = ids.map((id, index) =>
      txEnv.SYNTILA_DB.prepare(
        `UPDATE user_pins SET position = ?1
        WHERE user_id = ?2 AND kind = ?3 AND target_id = ?4`,
      ).bind(index, context.userId, kind, id),
    );
    await publishCollaborationEvent(
      txEnv,
      kind === "space" ? "space.updated" : "thread.updated",
      spaceId,
      kind === "space" ? spaceId : ids[0]!,
      {
        ...(kind === "thread" ? { threadId: ids[0]! } : {}),
        recipientUserIds: [context.userId],
        mutations,
      },
    );
  });
  return json({ kind, ids });
}
