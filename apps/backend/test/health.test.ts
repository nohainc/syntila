import { describe, expect, test } from "bun:test";
import { health } from "../src/health";

describe("health endpoints", () => {
  test("liveness does not depend on PostgreSQL", async () => {
    const response = await health(new Request("http://localhost/health/live"), async () => { throw new Error("offline"); });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });
  test("readiness reflects dependencies without exposing errors", async () => {
    const request = new Request("http://localhost/health/ready");
    expect((await health(request, async () => {})).status).toBe(200);
    const failed = await health(request, async () => { throw new Error("secret"); });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("secret");
  });
  test("unknown paths and unsupported methods are rejected", async () => {
    expect((await health(new Request("http://localhost/other"), async () => {})).status).toBe(404);
    expect((await health(new Request("http://localhost/health/live", { method: "POST" }), async () => {})).status).toBe(405);
  });
});
