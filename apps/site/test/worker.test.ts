import { describe, expect, it } from "vitest";
import worker from "../src/worker";

function environment(setCookie = false) {
  return {
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
      "https://conclaveax.com/how-it-works/?source=www",
    );
  });

  it("uses revalidation for HTML responses", async () => {
    const response = await worker.fetch(
      new Request("https://conclaveax.com/"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=0, must-revalidate",
    );
  });

  it("marks fingerprinted assets immutable", async () => {
    const response = await worker.fetch(
      new Request("https://conclaveax.com/_astro/site.12345678.js"),
      environment(),
    );

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=31536000, immutable",
    );
  });

  it("sets a self-contained security boundary for public responses", async () => {
    const response = await worker.fetch(
      new Request("https://conclaveax.com/"),
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
