/** Content revisions cover the exact authorized representation, including
 * permissions and ordering. Call only after authorization and existence checks.
 * This saves response bandwidth; it deliberately does not bypass database reads.
 */
export async function conditionalJson(
  request: Request,
  data: unknown,
): Promise<Response> {
  const body = JSON.stringify(data);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(body),
  );
  const revision = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const etag = `"ax-read-v1-${revision}"`;
  const headers = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "private, no-cache",
    vary: "Cookie, Authorization",
    etag,
  };
  const condition = request.headers.get("if-none-match")?.trim();
  const matches =
    condition === "*" ||
    (condition?.match(/(?:W\/)?"[^"]*"/g) ?? []).some(
      (tag) => tag.replace(/^W\//, "") === etag,
    );
  if ((request.method === "GET" || request.method === "HEAD") && matches) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(request.method === "HEAD" ? null : body, { headers });
}
