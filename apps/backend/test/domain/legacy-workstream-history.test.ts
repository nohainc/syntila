import { describe, expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  securityContext: vi.fn(async () => ({
    userId: "user-owner",
    email: "owner@example.com",
    displayName: "Owner",
  })),
}));

import { handleListWorkRequests } from "../../src/domain/routes/work-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

describe("retired workstream history scopes", () => {
  it("returns an authenticated empty history instead of querying a missing thread", async () => {
    const response = await handleListWorkRequests(
      new Request("https://cloud.test/threads/workstream-legacy/work-requests"),
      {} as SecurityEnv,
      "workstream-legacy",
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      workRequests: [],
      nextCursor: null,
    });
  });
});
