import { getAccountPlan } from "../account-plan.js";
import { avatarObjectKeys } from "../avatar-storage.js";
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
      await reader.cancel();
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
    form = await new Request(request.url, {
      method: "PUT",
      headers: request.headers,
      body: bytes,
    }).formData();
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

  const old = await env.SYNTILA_DB.prepare(
    "SELECT avatar_url AS avatarUrl FROM users WHERE id = ?1",
  )
    .bind(context.userId)
    .first<{ avatarUrl: string | null }>();
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
    const updated = await env.SYNTILA_DB.prepare(
      "UPDATE users SET avatar_url = ?1, updated_at = ?2 WHERE id = ?3 AND status = 'active' AND avatar_url IS ?4",
    )
      .bind(
        storedValue,
        new Date().toISOString(),
        context.userId,
        old.avatarUrl,
      )
      .run();
    if (updated.meta.changes !== 1)
      throw new HttpError(409, "Profile changed; retry the upload");
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
  const canView =
    context.userId === userId ||
    Boolean(
      await env.SYNTILA_DB.prepare(
        `SELECT 1 FROM people_relationships
         WHERE (user_low_id = ?1 AND user_high_id = ?2)
            OR (user_low_id = ?2 AND user_high_id = ?1)
         LIMIT 1`,
      )
        .bind(context.userId, userId)
        .first(),
    );
  if (!canView) throw new HttpError(404, "Avatar not found");

  const row = await env.SYNTILA_DB.prepare(
    "SELECT avatar_url AS avatarUrl FROM users WHERE id = ?1 AND status = 'active'",
  )
    .bind(userId)
    .first<{ avatarUrl: string | null }>();
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
    const body = (await request.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (
      !body ||
      typeof body.shareReadReceipts !== "boolean" ||
      Object.keys(body).some((key) => key !== "shareReadReceipts")
    )
      throw new HttpError(400, "shareReadReceipts must be true or false");
    await env.SYNTILA_DB.prepare(
      "UPDATE users SET share_read_receipts = ?1, updated_at = ?2 WHERE id = ?3",
    )
      .bind(
        body.shareReadReceipts ? 1 : 0,
        new Date().toISOString(),
        context.userId,
      )
      .run();
    return json({ shareReadReceipts: body.shareReadReceipts });
  }
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const row = await env.SYNTILA_DB.prepare(
    "SELECT share_read_receipts AS share FROM users WHERE id = ?1",
  )
    .bind(context.userId)
    .first<{ share: number }>();
  return json({ shareReadReceipts: (row?.share ?? 1) === 1 });
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
