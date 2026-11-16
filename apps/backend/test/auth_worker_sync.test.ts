import { describe, expect, it } from "bun:test";
import { AuthWorkerSync } from "../src/platform/email.js";

describe("AuthWorkerSync", () => {
  it("sends a signed POST /api/internal/profile-avatar request", async () => {
    const originalFetch = globalThis.fetch;
    let capturedUrl = "";
    let capturedHeaders: Record<string, string> = {};
    let capturedBody = "";

    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = String(input);
      capturedHeaders = (init?.headers ?? {}) as Record<string, string>;
      capturedBody = String(init?.body ?? "");
      return Response.json({ ok: true, updated: true });
    }) as typeof fetch;

    try {
      const sync = new AuthWorkerSync("https://app.syntila.app", "test-secret");
      await sync.avatarChanged("user-1", "r2://user-avatars/user-1/abc-thumbnail");

      expect(capturedUrl).toBe("https://app.syntila.app/api/internal/profile-avatar");
      expect(capturedHeaders["x-syntila-timestamp"]).toMatch(/^\d+$/);
      expect(capturedHeaders["x-syntila-signature"]).toBeTruthy();
      expect(JSON.parse(capturedBody)).toEqual({
        userId: "user-1",
        avatarUrl: "r2://user-avatars/user-1/abc-thumbnail",
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("logs a warning with status when the Worker returns an error", async () => {
    const originalFetch = globalThis.fetch;
    const originalWarn = console.warn;
    const warnings: string[] = [];

    globalThis.fetch = (async () =>
      Response.json({ error: "Invalid signature" }, { status: 401 })) as typeof fetch;
    console.warn = (msg: unknown) => {
      warnings.push(String(msg));
    };

    try {
      const sync = new AuthWorkerSync("https://app.syntila.app", "test-secret");
      await sync.avatarChanged("user-1", "r2://user-avatars/user-1/abc-thumbnail");

      expect(warnings.length).toBe(1);
      const parsed = JSON.parse(warnings[0]!);
      expect(parsed).toMatchObject({
        level: "warn",
        message: "auth_worker.avatar_sync_failed",
        userId: "user-1",
        status: 401,
      });
    } finally {
      globalThis.fetch = originalFetch;
      console.warn = originalWarn;
    }
  });
});
