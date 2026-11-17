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
    if (pinned) {
      // A new pin goes to the top of the user's pins of that kind.
      await tx.run`INSERT INTO user_pins (user_id, kind, target_id, pinned_at, position)
         VALUES (${userId}, ${kind}, ${targetId}, ${pinnedAt},
           COALESCE((SELECT MIN(position) FROM user_pins
                      WHERE user_id = ${userId} AND kind = ${kind}), 0) - 1)
         ON CONFLICT DO NOTHING`;
    } else {
      await tx.run`DELETE FROM user_pins WHERE user_id = ${userId} AND kind = ${kind} AND target_id = ${targetId}`;
    }
    await publishCollaborationEvent(
      txEnv,
      kind === "space" ? "space.updated" : "thread.updated",
      spaceId,
      targetId,
      {
        ...(kind === "thread" ? { threadId: targetId } : {}),
        recipientUserIds: [userId],
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
    for (const [index, id] of ids.entries()) {
      await tx.run`UPDATE user_pins SET position = ${index}
        WHERE user_id = ${context.userId} AND kind = ${kind} AND target_id = ${id}`;
    }
    await publishCollaborationEvent(
      txEnv,
      kind === "space" ? "space.updated" : "thread.updated",
      spaceId,
      kind === "space" ? spaceId : ids[0]!,
      {
        ...(kind === "thread" ? { threadId: ids[0]! } : {}),
        recipientUserIds: [context.userId],
      },
    );
  });
  return json({ kind, ids });
}
