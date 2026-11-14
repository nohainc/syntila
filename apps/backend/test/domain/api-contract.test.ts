import { describe, expect, test } from "bun:test";
import {
  API_VERSION,
  API_VERSION_HEADER,
  DEFAULT_RATE_LIMITS,
  defaultErrorCode,
  enforceRateLimit,
  isRateLimitExempt,
  rateLimitConfig,
  RateLimiter,
  rateLimitKey,
  withApiVersion,
  withErrorEnvelope,
} from "../../src/domain/routes/api-contract";
import worker from "../../src/domain/index";

describe("error envelope", () => {
  test("adds a code and the request id to a plain error", async () => {
    const out = await withErrorEnvelope(Response.json({ error: "Space not found" }, { status: 404 }), "req-1");
    expect(out.status).toBe(404);
    expect(await out.json()).toEqual({ error: "Space not found", code: "not_found", requestId: "req-1" });
  });
  test("keeps a handler's own code and extra fields", async () => {
    const out = await withErrorEnvelope(Response.json({ error: "Offline", code: "workspace_offline", workspaceId: "w" }, { status: 409 }), "req-2");
    expect(await out.json()).toEqual({ error: "Offline", code: "workspace_offline", workspaceId: "w", requestId: "req-2" });
  });
  test("leaves success, non-JSON and non-error-shaped bodies alone", async () => {
    const ok = Response.json({ error: "not an error, status 200" });
    expect(await withErrorEnvelope(ok, "r")).toBe(ok);
    const text = new Response("Not found", { status: 404 });
    expect(await withErrorEnvelope(text, "r")).toBe(text);
    const list = Response.json([1], { status: 400 });
    expect(await withErrorEnvelope(list, "r")).toBe(list);
  });
  test("every status has a code", () => {
    expect(defaultErrorCode(401)).toBe("unauthenticated");
    expect(defaultErrorCode(418)).toBe("bad_request");
    expect(defaultErrorCode(599)).toBe("internal_error");
  });
});

describe("api version", () => {
  test("is stamped on responses", () => {
    expect(withApiVersion(new Response("x")).headers.get(API_VERSION_HEADER)).toBe(API_VERSION);
  });
});

describe("rate limits", () => {
  test("allows a burst, then refuses with the wait, then refills", () => {
    const limiter = new RateLimiter();
    const start = 1_000_000;
    for (let i = 0; i < 15; i++) expect(limiter.take("k", 60, start)).toBe(0); // burst = 60/4
    expect(limiter.take("k", 60, start)).toBe(1);
    expect(limiter.take("k", 60, start + 1000)).toBe(0); // one token per second
    expect(limiter.take("other", 60, start)).toBe(0);
  });
  test("forgets idle callers", () => {
    const limiter = new RateLimiter();
    limiter.take("a", 60, 0);
    limiter.take("b", 60, 200_000);
    expect(limiter.size).toBe(1);
  });
  test("keys on the credential, else on the proxied client address", async () => {
    const withToken = (t: string) => new Request("https://x/api/spaces", { headers: { authorization: `Bearer ${t}`, "x-forwarded-for": "1.1.1.1" } });
    expect(await rateLimitKey(withToken("a"))).not.toBe(await rateLimitKey(withToken("b")));
    expect(await rateLimitKey(withToken("a"))).toBe(await rateLimitKey(withToken("a")));
    expect(await rateLimitKey(new Request("https://x/api/spaces", { headers: { "x-forwarded-for": "2.2.2.2, 10.0.0.1" } }))).toBe("a:2.2.2.2");
  });
  test("Workspace machine traffic, realtime and non-API paths are exempt", () => {
    expect(isRateLimitExempt("/api/workspace-runtime/events")).toBe(true);
    expect(isRateLimitExempt("/api/realtime")).toBe(true);
    expect(isRateLimitExempt("/health")).toBe(true);
    expect(isRateLimitExempt("/api/spaces")).toBe(false);
  });
  test("mutations have their own lower budget and the 429 says when to retry", async () => {
    const limiter = new RateLimiter();
    const config = { requestsPerMinute: 1000, mutationsPerMinute: 4 };
    const post = () => new Request("https://x/api/spaces", { method: "POST", headers: { authorization: "Bearer t" } });
    const get = () => new Request("https://x/api/spaces", { headers: { authorization: "Bearer t" } });
    expect(await enforceRateLimit(limiter, config, post(), "/api/spaces")).toBeNull();
    const refused = await enforceRateLimit(limiter, config, post(), "/api/spaces");
    expect(refused?.status).toBe(429);
    expect(Number(refused?.headers.get("retry-after"))).toBeGreaterThan(0);
    expect((await refused!.json()).code).toBe("rate_limited");
    expect(await enforceRateLimit(limiter, config, get(), "/api/spaces")).toBeNull();
  });
  test("configuration: defaults, overrides, 0 disables, nonsense falls back", async () => {
    expect(rateLimitConfig({})).toEqual(DEFAULT_RATE_LIMITS);
    expect(rateLimitConfig({ SYNTILA_RATE_LIMIT_PER_MINUTE: "10", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "abc" }))
      .toEqual({ requestsPerMinute: 10, mutationsPerMinute: DEFAULT_RATE_LIMITS.mutationsPerMinute });
    const off = { requestsPerMinute: 0, mutationsPerMinute: 0 };
    const limiter = new RateLimiter();
    for (let i = 0; i < 50; i++)
      expect(await enforceRateLimit(limiter, off, new Request("https://x/api/spaces", { method: "POST" }), "/api/spaces")).toBeNull();
  });
});

describe("through the worker", () => {
  test("an unknown API path returns the full envelope and the version header", async () => {
    const response = await worker.fetch(new Request("https://syntila.app/api/does-not-exist", { headers: { "x-request-id": "req-9" } }), {} as never);
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect(response.headers.get(API_VERSION_HEADER)).toBe(API_VERSION);
    expect(response.headers.get("x-request-id")).toBe("req-9");
    const body = await response.json() as Record<string, unknown>;
    expect(typeof body.error).toBe("string");
    expect(typeof body.code).toBe("string");
    expect(body.requestId).toBe("req-9");
  });
});
