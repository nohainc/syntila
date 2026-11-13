import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "./helpers/vitest-compat";

const spaces = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/spaces.ts", import.meta.url)),
  "utf8",
);
const threads = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/threads.ts", import.meta.url)),
  "utf8",
);
const work = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/work-creation.ts", import.meta.url)),
  "utf8",
);
const threadPolicy = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/thread-policy.ts", import.meta.url)),
  "utf8",
);
const router = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/router.ts", import.meta.url)),
  "utf8",
);
const gateway = readFileSync(
  fileURLToPath(new URL("../../src/domain/workspace-gateway.ts", import.meta.url)),
  "utf8",
);

describe("Thread Discuss / Work boundary", () => {
  it("routes discussion through the Thread", () => {
    expect(router).toMatch(/threads.*discussion-messages/);
    expect(spaces).toContain("handleCreateSpace");
  });

  it("exposes separate discussion and explicit Work Request routes", () => {
    expect(router).toMatch(/threads.*discussion-messages/);
    expect(router).toMatch(/threads.*work-requests/);
    expect(`${work}\n${threadPolicy}`).toContain('"run.start"');
    expect(work).toContain("validateWorkRequest(workRequest, policy)");
    expect(work).toContain("thread.work_requested");
  });

  it("does not expose the removed Checkout control plane", () => {
    expect(router).not.toMatch(/threads.*checkouts/);
    expect(threads).not.toMatch(/ThreadCheckout|checkout/);
    expect(gateway).not.toMatch(/checkout|checkpoint|rollback/i);
  });
});
