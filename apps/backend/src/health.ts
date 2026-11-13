export async function health(
  request: Request,
  checkReady: () => Promise<void>,
): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method !== "GET")
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { Allow: "GET" },
    });
  if (pathname === "/health/live") return Response.json({ status: "ok" });
  if (pathname === "/health/ready") {
    try {
      await checkReady();
      return Response.json({ status: "ready" });
    } catch {
      return Response.json({ status: "not_ready" }, { status: 503 });
    }
  }
  return new Response("Not Found", { status: 404 });
}
