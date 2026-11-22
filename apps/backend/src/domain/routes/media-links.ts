import { HttpError, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { authorizeThreadAccess } from "./handlers.js";
import {
  isWorkRequestFileId,
  threadFileReferenced,
  workRequestFileKey,
} from "./work-request-files.js";

/**
 * Short-lived signed links for playing Thread audio and video. A browser
 * `<audio>`/`<video>` element cannot send the sign-in header, so a signed-in
 * viewer asks for a link, and the link itself is the permission: the Thread,
 * the file and an expiry, signed with HMAC-SHA256. Playback reads byte ranges
 * so it can start at once and seek.
 */

/** How long a link plays. A player asks for a new one when it reopens. */
export const MEDIA_LINK_TTL_SECONDS = 15 * 60;

const PLAYABLE = /^(audio|video)\//;

let fallbackKey: Uint8Array | undefined;

/**
 * `SYNTILA_MEDIA_LINK_KEY` signs links. Without it a random key per process
 * is used: links then stop working when the backend restarts, which is only
 * acceptable because they are short-lived anyway.
 */
function linkKey(): Uint8Array {
  const configured = process.env.SYNTILA_MEDIA_LINK_KEY?.trim();
  if (configured) return new TextEncoder().encode(configured);
  fallbackKey ??= crypto.getRandomValues(new Uint8Array(32));
  return fallbackKey;
}

async function signature(threadId: string, fileId: string, expires: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    linkKey() as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`media:v1\n${threadId}\n${fileId}\n${expires}`),
  );
  return Buffer.from(mac).toString("base64url");
}

function timingSafeEqualText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * `POST /api/threads/:threadId/files/:fileId/media-link` — for a viewer of
 * the Thread, a link that plays this audio or video file for a short time.
 */
export async function handleCreateThreadMediaLink(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  if (!(await threadFileReferenced(env, threadId, fileId)))
    throw new HttpError(404, "File not found");
  const object = await env.SYNTILA_ARTIFACTS?.head(workRequestFileKey(fileId));
  if (!object || object.customMetadata?.threadId !== threadId)
    throw new HttpError(404, "File not found");
  const mediaType = object.httpMetadata?.contentType ?? "";
  if (!PLAYABLE.test(mediaType))
    throw new HttpError(415, "Only audio and video files can be played");
  const expires = Math.floor(Date.now() / 1000) + MEDIA_LINK_TTL_SECONDS;
  const query = new URLSearchParams({
    thread: threadId,
    expires: String(expires),
    sig: await signature(threadId, fileId, expires),
  });
  return json({
    path: `/api/media/${fileId}?${query}`,
    expiresAt: new Date(expires * 1000).toISOString(),
    mediaType,
  });
}

/** Parses one `bytes=a-b` range against [size]; null means the whole file. */
export function parseByteRange(
  header: string | null,
  size: number,
): { offset: number; length: number } | null | "invalid" {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (match[1] === "" && match[2] === "")) return "invalid";
  let start: number;
  let end: number;
  if (match[1] === "") {
    // A suffix: the last N bytes.
    const suffix = Number(match[2]);
    if (suffix === 0) return "invalid";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  }
  if (!Number.isSafeInteger(start) || start >= size || end < start) return "invalid";
  return { offset: start, length: end - start + 1 };
}

/**
 * `GET /api/media/:fileId?thread=…&expires=…&sig=…` — serves the signed file
 * inline, honoring one byte range. No sign-in header: the signature is the
 * permission, and it names exactly this Thread and file.
 */
export async function handleGetMediaFile(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const threadId = url.searchParams.get("thread") ?? "";
  const expires = Number(url.searchParams.get("expires"));
  const sig = url.searchParams.get("sig") ?? "";
  if (
    !isWorkRequestFileId(fileId) ||
    !threadId ||
    !Number.isSafeInteger(expires) ||
    expires < Date.now() / 1000 ||
    !timingSafeEqualText(sig, await signature(threadId, fileId, expires))
  )
    throw new HttpError(403, "This media link is not valid or has expired");
  const key = workRequestFileKey(fileId);
  const bucket = env.SYNTILA_ARTIFACTS;
  const head = await bucket?.head(key);
  if (!bucket || !head || head.customMetadata?.threadId !== threadId)
    throw new HttpError(404, "File not found");
  const mediaType = head.httpMetadata?.contentType ?? "application/octet-stream";
  if (!PLAYABLE.test(mediaType)) throw new HttpError(404, "File not found");
  const headers: Record<string, string> = {
    "Content-Type": mediaType,
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, max-age=300",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox",
  };
  const range = parseByteRange(request.headers.get("range"), head.size);
  if (range === "invalid")
    return new Response(null, {
      status: 416,
      headers: { ...headers, "Content-Range": `bytes */${head.size}` },
    });
  const object = await (bucket.get as (k: string, o?: unknown) => Promise<{ body: ReadableStream } | null>)(
    key,
    range ? { range } : undefined,
  );
  if (!object) throw new HttpError(404, "File not found");
  if (!range)
    return new Response(object.body, {
      headers: { ...headers, "Content-Length": String(head.size) },
    });
  return new Response(object.body, {
    status: 206,
    headers: {
      ...headers,
      "Content-Length": String(range.length),
      "Content-Range": `bytes ${range.offset}-${range.offset + range.length - 1}/${head.size}`,
    },
  });
}
