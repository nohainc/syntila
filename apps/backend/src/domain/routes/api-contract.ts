/**
 * The parts of the HTTP contract that every endpoint shares:
 *  - one error envelope `{ error, code, requestId }`;
 *  - an API version header on every response;
 *  - request rate limits.
 * Applied once at the edge of the domain (`domain/index.ts`), so individual
 * handlers keep returning `{ error }` or throwing `HttpError`.
 */

/** Bumped when a response or request shape changes incompatibly. */
export const API_VERSION = "1";
export const API_VERSION_HEADER = "x-syntila-api";

const STATUS_CODES: Record<number, string> = {
  400: "bad_request",
  401: "unauthenticated",
  402: "payment_required",
  403: "forbidden",
  404: "not_found",
  405: "method_not_allowed",
  409: "conflict",
  410: "gone",
  412: "precondition_failed",
  413: "payload_too_large",
  415: "unsupported_media_type",
  422: "unprocessable",
  429: "rate_limited",
  500: "internal_error",
  501: "not_implemented",
  502: "bad_gateway",
  503: "unavailable",
  504: "timeout",
};

/** The stable machine code for a status when a handler gave none. */
export function defaultErrorCode(status: number): string {
  return STATUS_CODES[status] ?? (status >= 500 ? "internal_error" : "bad_request");
}

/**
 * Makes every JSON error response carry `code` and `requestId` beside the
 * human `error` text. A handler's own `code` always wins. Clients should
 * branch on `code`; `error` is for people and may be reworded.
 * Non-JSON, streamed and successful responses pass through untouched.
 */
export async function withErrorEnvelope(response: Response, requestId: string): Promise<Response> {
  if (response.status < 400 || response.status === 101) return response;
  if (!(response.headers.get("content-type") ?? "").includes("application/json")) return response;
  let body: unknown;
  try {
    body = await response.clone().json();
  } catch {
    return response;
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return response;
  const record = body as Record<string, unknown>;
  if (typeof record.error !== "string") return response;
  if (typeof record.code === "string" && record.requestId === requestId) return response;
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  return new Response(
    JSON.stringify({
      ...record,
      code: typeof record.code === "string" ? record.code : defaultErrorCode(response.status),
      requestId,
    }),
    { status: response.status, statusText: response.statusText, headers },
  );
}

export function withApiVersion(response: Response): Response {
  if (response.status === 101 || response.headers.has(API_VERSION_HEADER)) return response;
  const headers = new Headers(response.headers);
  headers.set(API_VERSION_HEADER, API_VERSION);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/** A database failure must not reach the client as text (it names tables and constraints). */
export function isDatabaseError(error: unknown): boolean {
  return error instanceof Error && error.name === "PgD1Error";
}

/* ------------------------------------------------------------ rate limits */

export interface RateLimitConfig {
  /** All requests per caller per minute; 0 disables. */
  readonly requestsPerMinute: number;
  /** POST/PUT/PATCH/DELETE per caller per minute; 0 disables. */
  readonly mutationsPerMinute: number;
}

/** Generous defaults: they stop loops and abuse, not people or app start-up bursts. */
export const DEFAULT_RATE_LIMITS: RateLimitConfig = { requestsPerMinute: 3000, mutationsPerMinute: 600 };

export function rateLimitConfig(env: { SYNTILA_RATE_LIMIT_PER_MINUTE?: string; SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE?: string }): RateLimitConfig {
  const read = (raw: string | undefined, fallback: number) => {
    if (raw === undefined || raw === "") return fallback;
    const value = Number(raw);
    return Number.isInteger(value) && value >= 0 ? value : fallback;
  };
  return {
    requestsPerMinute: read(env.SYNTILA_RATE_LIMIT_PER_MINUTE, DEFAULT_RATE_LIMITS.requestsPerMinute),
    mutationsPerMinute: read(env.SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE, DEFAULT_RATE_LIMITS.mutationsPerMinute),
  };
}

interface Bucket { tokens: number; at: number }

/**
 * In-process token buckets (the backend is one process). A bucket refills
 * continuously and allows a burst of a quarter of its per-minute rate.
 */
export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private lastSweep = 0;

  /** Returns 0 when allowed, otherwise the seconds to wait. */
  take(key: string, perMinute: number, now = Date.now()): number {
    if (perMinute <= 0) return 0;
    const capacity = Math.max(1, Math.ceil(perMinute / 4));
    const perMs = perMinute / 60_000;
    let bucket = this.buckets.get(key);
    if (!bucket) {
      bucket = { tokens: capacity, at: now };
      this.buckets.set(key, bucket);
    } else {
      bucket.tokens = Math.min(capacity, bucket.tokens + (now - bucket.at) * perMs);
      bucket.at = now;
    }
    this.sweep(now);
    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return 0;
    }
    return Math.max(1, Math.ceil((1 - bucket.tokens) / perMs / 1000));
  }

  private sweep(now: number): void {
    if (now - this.lastSweep < 60_000) return;
    this.lastSweep = now;
    for (const [key, bucket] of this.buckets) if (now - bucket.at > 120_000) this.buckets.delete(key);
  }

  get size(): number { return this.buckets.size; }
}

const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);

/**
 * Non-API endpoints and the realtime upgrade use their own flow control.
 */
export function isRateLimitExempt(pathname: string): boolean {
  return (
    !pathname.startsWith("/api/") ||
    pathname === "/api/realtime"
  );
}

/**
 * Who a request counts against: the credential when there is one (so people
 * behind one office address do not share a budget), otherwise the client
 * address reported by the reverse proxy.
 */
export async function rateLimitKey(request: Request): Promise<string> {
  const credential = request.headers.get("authorization") ?? request.headers.get("cookie");
  if (credential) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(credential));
    return "c:" + Array.from(new Uint8Array(digest).slice(0, 12), (b) => b.toString(16).padStart(2, "0")).join("");
  }
  const address =
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown";
  return "a:" + address;
}

/** Returns a 429 response when the caller is over a limit, otherwise null. */
export async function enforceRateLimit(
  limiter: RateLimiter,
  config: RateLimitConfig,
  request: Request,
  pathname: string,
): Promise<Response | null> {
  if (request.method === "OPTIONS" || isRateLimitExempt(pathname)) return null;
  if (config.requestsPerMinute <= 0 && config.mutationsPerMinute <= 0) return null;
  const key = await rateLimitKey(request);
  let wait = limiter.take(key, config.requestsPerMinute);
  if (!wait && MUTATING.has(request.method)) wait = limiter.take(key + ":m", config.mutationsPerMinute);
  if (!wait) return null;
  return Response.json(
    { error: "Too many requests. Try again shortly.", code: "rate_limited", retryAfterSeconds: wait },
    { status: 429, headers: { "retry-after": String(wait), "cache-control": "no-store" } },
  );
}
