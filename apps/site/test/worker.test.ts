import { describe, expect, it } from "vitest";
import worker from "../src/worker";

function environment(setCookie = false) {
  return {
    LEGACY_AUTH: { fetch: async (request: Request) => new Response(request.method + " " + new URL(request.url).pathname, { headers: { "set-cookie": "session=preserved" } }) },
    ASSETS: {
      fetch: async () =>
        new Response("site", {
          headers: {
            "content-type": "text/html",
            ...(setCookie ? { "set-cookie": "session=should-not-leak" } : {}),
          },
        }),
    },
  };
}

describe("public site Worker", () => {
  it("redirects www to the canonical apex domain", async () => {
    const response = await worker.fetch(
      new Request("https://www.conclaveax.com/how-it-works/?source=www"),
      environment(),
    );

    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe(
      "https://syntila.app/how-it-works/?source=www",
    );
  });

  it.each(["conclaveax.com", "www.conclaveax.com", "www.syntila.app"])(
    "redirects %s to the matching canonical page", async (host) => {
      const response = await worker.fetch(new Request(`https://${host}/privacy/?from=old`), environment());
      expect(response.status).toBe(308);
      expect(response.headers.get("location")).toBe("https://syntila.app/privacy/?from=old");
    },
  );

  it("forwards legacy auth requests with their credentials and body intact", async () => {
    let forwarded: Request | undefined;
    const env = environment();
    env.LEGACY_AUTH.fetch = async (request: Request) => {
      forwarded = request;
      return new Response("ok", { headers: { "set-cookie": "session=preserved" } });
    };
    const response = await worker.fetch(new Request("https://syntila.app/api/desktop-auth/session", {
      method: "POST", headers: { authorization: "Bearer test-session" }, body: "test-body",
    }), env);
    expect(forwarded?.headers.get("authorization")).toBe("Bearer test-session");
    expect(await forwarded?.text()).toBe("test-body");
    expect(response.headers.get("set-cookie")).toBe("session=preserved");
  });

  it("continues to serve assets referenced by old application links", async () => {
    const response = await worker.fetch(new Request("https://syntila.app/assets/branding/logo.png"), environment());
    expect(await response.text()).toBe("GET /assets/branding/logo.png");
  });

  it("redirects old app links to the new app and preserves the query", async () => {
    const response = await worker.fetch(new Request("https://syntila.app/desktop-auth/approve?intentId=123"), environment());
    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe("https://app.syntila.app/desktop-auth/approve?intentId=123");
  });

  it.each(["invitation", "person_invitation"])("preserves legacy %s links", async (key) => {
    const response = await worker.fetch(new Request(`https://syntila.app/?${key}=example`), environment());
    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe(`https://app.syntila.app/?${key}=example`);
  });

  it("uses revalidation for HTML responses", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.app/"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=0, must-revalidate",
    );
  });

  it("marks fingerprinted assets immutable", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.app/_astro/site.12345678.js"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=31536000, immutable",
    );
  });

  it("sets a self-contained security boundary for public responses", async () => {
    const response = await worker.fetch(
      new Request("https://syntila.app/"),
      environment(true),
    );

    expect(response.headers.get("content-security-policy")).toContain(
      "script-src 'self'",
    );
    expect(response.headers.get("content-security-policy")).toContain(
      "style-src 'self'",
    );
    expect(response.headers.get("content-security-policy")).toContain(
      "frame-ancestors 'none'",
    );
    expect(response.headers.get("referrer-policy")).toBe(
      "strict-origin-when-cross-origin",
    );
    expect(response.headers.get("permissions-policy")).toContain("camera=()");
    expect(response.headers.get("strict-transport-security")).toBe(
      "max-age=31536000; includeSubDomains",
    );
    expect(response.headers.get("set-cookie")).toBeNull();
  });
});
