import { ReadReceiptPrivacySchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { dataOf } from "../../platform/data.js";
import { parseMultipart } from "../../platform/multipart";
import { getAccountPlan } from "../account-plan.js";
import { avatarObjectKeys } from "../avatar-storage.js";
import { publishPeopleProfileChanged } from "../people.js";
import { securityContext, HttpError, json } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

const MAX_AVATAR_BYTES = 5 * 1024 * 1024;
const AVATAR_TYPES = new Set([
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

function avatarKey(value: string | null | undefined): string | null {
  if (!value?.startsWith("r2://")) return null;
  return value.slice("r2://".length);
}

export function avatarUrlFor(
  request: Request,
  userId: string,
  value: string | null | undefined,
): string | null {
  if (!value) return null;
  if (!value.startsWith("r2://")) return value;
  const key = value.slice("r2://".length);
  const version = (key.split("/").pop() ?? key).replace(/-thumbnail$/, "");
  const url = new URL(
    `/api/users/${encodeURIComponent(userId)}/avatar`,
    request.url,
  );
  url.searchParams.set("v", version);
  return url.toString();
}

export async function handleUploadAvatar(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "PUT") throw new HttpError(405, "Use PUT for avatars");

  // Bound the entire multipart body before parsing, including untrusted lengths.
  const limit = MAX_AVATAR_BYTES + 256 * 1024;
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "Avatar files are required");
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      void reader.cancel().catch(() => undefined); // not awaited: it never settles while the client is still sending
      throw new HttpError(413, "Avatar upload is too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  let form: FormData;
  try {
    form = await parseMultipart(
      bytes,
      request.headers.get("content-type") ?? "",
    );
  } catch {
    throw new HttpError(400, "Upload original and thumbnail image files");
  }
  const original = form.get("original");
  const thumbnail = form.get("thumbnail");
  if (!(original instanceof File) || !(thumbnail instanceof File))
    throw new HttpError(400, "Original and thumbnail files are required");
  if (!AVATAR_TYPES.has(original.type) || thumbnail.type !== "image/png")
    throw new HttpError(
      415,
      "Original must be an image and thumbnail must be PNG",
    );
  if (
    !original.size ||
    original.size > MAX_AVATAR_BYTES ||
    !thumbnail.size ||
    thumbnail.size > 128 * 1024
  )
    throw new HttpError(
      413,
      "Original must be 1 byte–5 MB and thumbnail 1 byte–128 KB",
    );
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Avatar storage is not configured");

  const data = dataOf(env);
  const old = await data.read.row<{ avatarUrl: string | null }>`
    SELECT avatar_url AS "avatarUrl" FROM users WHERE id = ${context.userId}`;
  if (!old) throw new HttpError(404, "User not found");

  const version = crypto.randomUUID();
  const key = `user-avatars/${context.userId}/${version}-thumbnail`;
  const originalKey = key.replace(/-thumbnail$/, "-original");
  const storedValue = `r2://${key}`;
  try {
    await bucket.put(originalKey, await original.arrayBuffer(), {
      httpMetadata: { contentType: original.type },
      customMetadata: { userId: context.userId },
    });
    await bucket.put(key, await thumbnail.arrayBuffer(), {
      httpMetadata: { contentType: thumbnail.type },
      customMetadata: { userId: context.userId },
    });
    // Compare-and-set on the previous avatar: safe without the writer lock.
    const updated = await data.tx("profile.avatar", (tx) => tx.run`
      UPDATE users SET avatar_url = ${storedValue}, updated_at = ${new Date().toISOString()}
       WHERE id = ${context.userId} AND status = 'active'
         AND avatar_url IS NOT DISTINCT FROM ${old.avatarUrl}`);
    if (updated !== 1)
      throw new HttpError(409, "Profile changed; retry the upload");
    await publishPeopleProfileChanged(env, context.userId);
    // The signed-in session (served by the auth Worker) shows the avatar.
    const authSync = (
      env as {
        SYNTILA_AUTH_SYNC?: {
          avatarChanged(
            userId: string,
            avatarUrl: string | null,
          ): Promise<void>;
        };
      }
    ).SYNTILA_AUTH_SYNC;
    if (authSync) {
      await authSync.avatarChanged(context.userId, storedValue);
    } else {
      console.warn(
        JSON.stringify({
          level: "warn",
          message: "auth_worker.avatar_sync_skipped",
          userId: context.userId,
          reason: "not_configured",
        }),
      );
    }
  } catch (error) {
    await bucket.delete([key, originalKey]).catch(() => undefined);
    throw error;
  }

  const oldKey = avatarKey(old.avatarUrl);
  if (oldKey) await bucket.delete(avatarObjectKeys(oldKey));
  return json({
    avatarUrl: avatarUrlFor(request, context.userId, storedValue),
  });
}

export async function handleGetAvatar(
  request: Request,
  env: SecurityEnv,
  userId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const data = dataOf(env);
  const canView =
    context.userId === userId ||
    Boolean(
      await data.read.row`SELECT 1 FROM people_relationships
         WHERE (user_low_id = ${context.userId} AND user_high_id = ${userId})
            OR (user_low_id = ${userId} AND user_high_id = ${context.userId})
         LIMIT 1`,
    );
  if (!canView) throw new HttpError(404, "Avatar not found");

  const row = await data.read.row<{ avatarUrl: string | null }>`
    SELECT avatar_url AS "avatarUrl" FROM users WHERE id = ${userId} AND status = 'active'`;
  const key = avatarKey(row?.avatarUrl);
  if (!key) throw new HttpError(404, "Avatar not found");
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Avatar storage is not configured");
  const object = await bucket.get(key);
  if (!object) throw new HttpError(404, "Avatar not found");

  const headers = new Headers({
    "cache-control": "private, max-age=300",
    "content-type":
      object.httpMetadata?.contentType ?? "application/octet-stream",
  });
  if (object.httpEtag) headers.set("etag", object.httpEtag);
  return new Response(object.body, { headers });
}

/**
 * GET or PUT {shareReadReceipts} for the signed-in person. Read receipts are
 * reciprocal: turning them off hides your reads and theirs.
 */
export async function handleReadReceiptPrivacy(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method === "PUT") {
    const body = await readBody(request, ReadReceiptPrivacySchema, {
      message: "shareReadReceipts must be true or false",
    });
    await dataOf(env).tx("profile.read_receipts", (tx) => tx.run`
      UPDATE users SET share_read_receipts = ${body.shareReadReceipts}, updated_at = ${new Date().toISOString()}
       WHERE id = ${context.userId}`);
    return json({ shareReadReceipts: body.shareReadReceipts });
  }
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const row = await dataOf(env).read.row<{ share: boolean }>`
    SELECT share_read_receipts AS share FROM users WHERE id = ${context.userId}`;
  return json({ shareReadReceipts: row?.share ?? true });
}

/** The caller's account tier. Read-only: plans change through grants or billing. */
export async function handleAccountPlan(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const context = await securityContext(request, env, ctx);
  return json(await getAccountPlan(env, context.userId));
}
