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
    // Concurrency outcomes are answered as such: the client can retry or
    // reload. A unique violation means a parallel request created the same
    // thing first; a foreign-key violation that what it belongs to was just
    // deleted; a lock or serialization timeout that it waited too long.
    const sqlState = databaseErrorCode(error);
    if (sqlState === "23505" || sqlState === "23503" || sqlState === "40001" || sqlState === "40P01" || sqlState === "55P03") {
      const conflict = sqlState === "23505" || sqlState === "23503";
      console.warn(
        JSON.stringify({
          level: "warn",
          message: conflict ? "http.concurrent_conflict" : "http.concurrent_timeout",
          details: {
            method: request.method,
            path: url.pathname,
            sqlState,
            constraint: (error as { constraint?: string }).constraint,
          },
        }),
      );
      const specific = conflict ? CONSTRAINT_MESSAGES[(error as { constraint?: string }).constraint ?? ""] : undefined;
      return deps.json(
        conflict
          ? { error: specific ?? "This changed at the same time elsewhere. Reload and try again.", code: "conflict" }
          : { error: "The server is busy with the same item. Try again.", code: "busy" },
        { status: conflict ? 409 : 503 },
      );
    }
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

/** SQLSTATE of a PostgreSQL error, through the adapter's wrapper too. */
/**
 * Unique constraints that express a rule a person can break by choosing a
 * name: the message tells them what to change instead of "reload".
 */
const CONSTRAINT_MESSAGES: Record<string, string> = {
  threads_space_name_key: "This Space already has a Thread with this name",
  spaces_owner_group_name_key: "You already have a Space with this name",
  space_memberships_space_id_user_id_key: "You are already a member of this Space",
  idx_space_invitations_pending_email: "A pending invitation already exists for this user",
  idx_space_invitations_pending_user: "A pending invitation already exists for this user",
  idx_workspace_invitations_pending_email: "An invitation is already pending",
  workspace_invitations_no_active_grant: "This person already has access",
};

function databaseErrorCode(error: unknown): string | undefined {
  for (let e: any = error, depth = 0; e && depth < 3; e = e.cause, depth++) {
    const code = e.errno ?? e.code;
    if (typeof code === "string" && /^[0-9A-Z]{5}$/.test(code)) return code;
  }
  return undefined;
}
