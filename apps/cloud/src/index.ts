/**
 * Syntila auth Worker (Cloudflare). After the move to the VPS backend this
 * Worker only:
 *   - runs Better Auth (`/api/auth/*`) and desktop sign-in (`/api/desktop-auth/*`)
 *   - answers `/api/session` and `/api/session/logout`
 *   - issues short-lived backend tokens (`POST /api/backend-token`)
 *   - relays email the backend starts (`POST /api/internal/email`)
 *   - serves the web app's static assets
 * Everything else (Spaces, Threads, Work, Workspaces, realtime) is served by
 * the backend at SYNTILA_BACKEND_URL (https://api.syntila.app).
 */
import { handleBetterAuthRequest } from "./auth/index.js";
import { pruneEndedAuthSessions } from "./auth/session-retention.js";
import { handleUserBackendToken } from "./backend-token.js";
import { handleEmailRelay } from "./email-relay.js";
import { isTrustedOrigin, logStructured, requestIdFor, withRequestId } from "./observability.js";
import {
  handleApproveDesktopAuthIntent,
  handleCancelDesktopAuthIntent,
  handleClaimDesktopAuthIntent,
  handleCompleteProfileLabStepUp,
  handleCompleteStepUp,
  handleCreateDesktopAuthIntent,
  handleDenyDesktopAuthIntent,
  handleDesktopAuthIntentBrowserStatus,
  handleDesktopAuthIntentStatus,
  handleDesktopPasswordSignIn,
  handleGetDesktopHumanSession,
  handleRevokeDesktopHumanSession,
  handleRotateDesktopHumanSession,
  handleSession,
  handleSessionLogout,
} from "./routes/auth.js";
import { HttpError, json, requireSameOriginForCookieMutation, type SecurityEnv } from "./routes/http-security.js";

type AssetsEnv = { ASSETS?: { fetch(request: Request): Promise<Response> } };

function corsHeaders(response: Response, origin: string | null, trusted: boolean): Response {
  if (!origin || !trusted) return response;
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-credentials", "true");
  headers.append("vary", "Origin");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

async function route(request: Request, env: SecurityEnv, ctx: ExecutionContext | undefined, url: URL): Promise<Response> {
  const { pathname } = url;
  const method = request.method;

  if (method === "GET" && pathname === "/health")
    return json({ ok: true, environment: env.SYNTILA_ENVIRONMENT, role: "auth" });
  if (method === "GET" && pathname === "/api/dev/sign-in") {
    if (env.SYNTILA_ENVIRONMENT !== "development") return new Response("Not found", { status: 404 });
    const provider = url.searchParams.get("provider") ?? "github";
    if (provider !== "github" && provider !== "google") return json({ error: "provider must be github or google" }, { status: 400 });
    const signIn = new URL(`/api/auth/sign-in/${provider}`, request.url);
    signIn.searchParams.set("returnTo", url.searchParams.get("returnTo") ?? "/");
    return Response.redirect(signIn.toString(), 302);
  }

  // Server-to-server (HMAC-authenticated); no cookies involved.
  if (method === "POST" && pathname === "/api/internal/email") return handleEmailRelay(request, env);

  if (method === "POST" && pathname === "/api/auth/step-up/passkey/complete") {
    requireSameOriginForCookieMutation(request);
    return handleCompleteStepUp(request, env, ctx);
  }
  if (method === "POST" && pathname === "/api/desktop-auth/profile-lab/step-up/complete")
    return handleCompleteProfileLabStepUp(request, env, ctx);
  if (pathname === "/api/auth" || pathname.startsWith("/api/auth/")) return handleBetterAuthRequest(request, env);

  if (method === "GET" && pathname === "/api/session") return handleSession(request, env, ctx);
  if (method === "POST" && pathname === "/api/session/logout") {
    requireSameOriginForCookieMutation(request);
    return handleSessionLogout(request, env, ctx);
  }
  if (method === "POST" && pathname === "/api/backend-token") {
    requireSameOriginForCookieMutation(request);
    return handleUserBackendToken(request, env, ctx);
  }

  // Desktop sign-in handoff and desktop human sessions.
  if (method === "POST" && pathname === "/api/desktop-auth/intents") return handleCreateDesktopAuthIntent(request, env);
  if (method === "POST" && pathname === "/api/desktop-auth/password") return handleDesktopPasswordSignIn(request, env);
  if (method === "GET" && pathname === "/api/desktop-auth/session") return handleGetDesktopHumanSession(request, env);
  const intent = pathname.match(/^\/api\/desktop-auth\/intents\/([^/]+)(?:\/(approve|claim|cancel|deny|browser-status))?$/);
  if (intent?.[1]) {
    const id = decodeURIComponent(intent[1]);
    const action = intent[2];
    if (method === "GET" && !action) return handleDesktopAuthIntentStatus(request, env, id);
    if (method === "GET" && action === "browser-status") return handleDesktopAuthIntentBrowserStatus(request, env, id);
    if (method === "POST" && action === "cancel") return handleCancelDesktopAuthIntent(request, env, id);
    if (method === "POST" && (action === "deny" || action === "approve")) {
      // Approving or denying happens in the signed-in browser (cookie).
      requireSameOriginForCookieMutation(request);
      return action === "deny" ? handleDenyDesktopAuthIntent(request, env, id) : handleApproveDesktopAuthIntent(request, env, id);
    }
    if (method === "POST" && action === "claim") return handleClaimDesktopAuthIntent(request, env, id);
  }
  const session = pathname.match(/^\/api\/desktop-auth\/sessions\/([^/]+)\/(revoke|rotate)$/);
  if (method === "POST" && session?.[1]) {
    const id = decodeURIComponent(session[1]);
    return session[2] === "revoke" ? handleRevokeDesktopHumanSession(request, env, id) : handleRotateDesktopHumanSession(request, env, id);
  }

  if (pathname.startsWith("/api/"))
    return json({ error: "Not found on the auth service; the Syntila API is served by the backend", code: "not_found" }, { status: 404 });
  return new Response("Not found", { status: 404 });
}

export default {
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    void controller;
    const removed = await pruneEndedAuthSessions(env.SYNTILA_DB);
    logStructured("info", "auth.sessions.pruned", {}, { removed });
  },

  async fetch(request: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
    const requestId = requestIdFor(request);
    const headers = new Headers(request.headers);
    headers.set("x-request-id", requestId);
    request = new Request(request, { headers });
    const url = new URL(request.url);
    logStructured("info", "http.request", { requestId }, { method: request.method, path: url.pathname });

    const origin = request.headers.get("origin");
    const configuredOrigins = ((env as unknown as { BETTER_AUTH_TRUSTED_ORIGINS?: string }).BETTER_AUTH_TRUSTED_ORIGINS ?? "")
      .split(",").map((item) => item.trim().replace(/\/$/, "")).filter(Boolean);
    const trusted = origin ? isTrustedOrigin(request, configuredOrigins) : false;

    if (request.method === "OPTIONS" && origin && trusted) {
      return withRequestId(new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-credentials": "true",
          "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
          "access-control-allow-headers": request.headers.get("access-control-request-headers") || "authorization, content-type, accept, x-request-id",
          "access-control-max-age": "86400",
          vary: "Origin",
        },
      }), requestId);
    }

    // The web app owns every non-API path (SPA fallback via the assets binding).
    const assets = (env as Env & AssetsEnv).ASSETS;
    if (assets && (request.method === "GET" || request.method === "HEAD") && !url.pathname.startsWith("/api/") && url.pathname !== "/health")
      return assets.fetch(request);

    let response: Response;
    try {
      response = await route(request, env as SecurityEnv, ctx, url);
    } catch (error) {
      if (!(error instanceof HttpError))
        console.error(JSON.stringify({ level: "error", message: "http.unhandled_error", details: {
          method: request.method, path: url.pathname,
          error: error instanceof Error ? error.message : String(error),
          stack: error instanceof Error ? error.stack : undefined,
        } }));
      const status = error instanceof HttpError ? error.status : 500;
      const code = error instanceof HttpError && "code" in error && typeof (error as { code?: unknown }).code === "string" ? (error as { code: string }).code : undefined;
      response = json({ error: error instanceof HttpError ? error.message : "Internal error", ...(code ? { code } : {}) }, { status });
    }
    return corsHeaders(withRequestId(response, requestId), origin, trusted);
  },
} satisfies ExportedHandler<Env>;
