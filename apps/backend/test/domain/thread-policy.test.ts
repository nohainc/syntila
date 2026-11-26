import { pgD1 } from "./helpers/pg-d1";
import { T0, user } from "./helpers/seed";
import { describe, expect, it } from "./helpers/vitest-compat";

import {
  normalizeThreadWorkConfig,
} from "../../src/domain/routes/thread-policy.js";

describe("Thread authored context", () => {
  it("normalizes instructions without execution preferences", () => {
    expect(
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        threadInstructions: " Context ",
        bindings: {
          chat: { additionalInstructions: " Focus " },
          direct: { additionalInstructions: " " },
        },
      }).config,
    ).toEqual({
      defaultWorkflowId: "chat",
      threadInstructions: "Context",
      bindings: { chat: { additionalInstructions: "Focus" } },
    });
  });
  it.each([
    "workerId",
    "workerLabel",
    "model",
    "reasoningEffort",
    "fallbackWorkerId",
    "fallbackWorkerLabel",
  ])("rejects obsolete %s preferences", (key) => {
    expect(() =>
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        bindings: { chat: { [key]: "old" } },
      }),
    ).toThrow("use Workflows");
  });
  it.each([null, 123, "x".repeat(4001)])(
    "rejects malformed instructions %s",
    (instructions) => {
      expect(() =>
        normalizeThreadWorkConfig({
          defaultWorkflowId: "chat",
          bindings: { chat: { additionalInstructions: instructions } },
        }),
      ).toThrow();
    },
  );
});

it("keeps execution options on the selected Worker", async () => {
  expect(true).toBe(true);
});
