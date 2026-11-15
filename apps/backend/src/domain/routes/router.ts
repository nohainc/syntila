import { isDatabaseError } from "./api-contract.js";
import { withRouteIdempotency } from "./route-idempotency.js";
import {
  findRoute,
  requiresSameOrigin,
  routeTable,
  type RouteHandler,
  type WorkerRouteHandlers,
} from "./table.js";

export type { RouteHandler, WorkerRouteHandlers };

export interface WorkerRouteDependencies {
  readonly json: (data: unknown, init?: ResponseInit) => Response;
  readonly requireSameOriginForCookieMutation: (request: Request) => void;
  readonly errorMessage: (error: unknown) => string;
  readonly HttpError: new (...args: unknown[]) => Error;
}

/**
 * Dispatches an API request through the route table (`table.ts`) and turns
 * errors into the API error envelope.
 */
export async function routeWorkerRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext | undefined,
  handlers: WorkerRouteHandlers,
  deps: WorkerRouteDependencies,
): Promise<Response> {
  const url = new URL(request.url);
  try {
    const { match, allowed } = findRoute(routeTable(handlers), request.method, url.pathname);
    if (requiresSameOrigin(match?.route ?? null, request.method, url.pathname))
      deps.requireSameOriginForCookieMutation(request);
    if (match) {
      const { route, params } = match;
      if (route.idempotent === "route")
        return await withRouteIdempotency(request, env, ctx, (req) =>
          Promise.resolve(route.handler({ request: req, env, ctx, params })),
        );
      return await route.handler({ request, env, ctx, params });
    }
    if (allowed.length)
      return deps.json(
        { error: `${request.method} is not supported here`, code: "method_not_allowed" },
        { status: 405, headers: { allow: allowed.join(", ") } },
      );
  } catch (error) {
    const status =
      typeof error === "object" &&
      error !== null &&
      "status" in error &&
      typeof error.status === "number"
        ? error.status
        : undefined;
    // A deliberate error (HttpError or anything carrying a status) is the
    // handler talking to the client: pass its message, status and code on.
    if (error instanceof deps.HttpError || status !== undefined) {
      const code =
        "code" in (error as object) &&
        typeof (error as { code?: unknown }).code === "string"
          ? (error as { code: string }).code
          : undefined;
      const details = (error as { details?: unknown }).details;
      return deps.json(
        {
          error: deps.errorMessage(error),
          ...(code ? { code } : {}),
          ...(Array.isArray(details) ? { details } : {}),
        },
        { status: status ?? 400 },
      );
    }
    // A body that is not JSON is the client's mistake.
    if (error instanceof SyntaxError)
      return deps.json(
        { error: "Request body must be valid JSON", code: "invalid_json" },
        { status: 400 },
      );
    // Anything else is a fault on our side. Its message may name tables,
    // files or internals, so it goes to the log and never to the client.
    console.error(
      JSON.stringify({
        level: "error",
        message: "http.unhandled_error",
        details: {
          method: request.method,
          path: url.pathname,
          database: isDatabaseError(error),
          error: error instanceof Error ? error.message : String(error),
          stack: error instanceof Error ? error.stack : undefined,
        },
      }),
    );
    return deps.json(
      { error: "Something went wrong on our side.", code: "internal_error" },
      { status: 500 },
    );
  }

  return deps.json({ error: "not_found" }, { status: 404 });
}
