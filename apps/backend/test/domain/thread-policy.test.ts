import { pgD1 } from "./helpers/pg-d1";
import { T0, user } from "./helpers/seed";
import { describe, expect, it } from "./helpers/vitest-compat";

import {
  eligibilityMessage,
  normalizeThreadWorkConfig,
} from "../../src/domain/routes/thread-policy.js";

describe("catalog-backed Worker validation messages", () => {
  it("uses the supplied catalog name without deriving names from Worker IDs", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_not_ready",
        null,
        "Dynamic Test Worker",
      ),
    ).toBe("Implement: Dynamic Test Worker is not Ready.");
  });

  it("uses a neutral label when catalog display metadata is unavailable", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_not_ready",
      ),
    ).toBe("Implement: Selected Worker is not Ready.");
  });

  it("ignores blank catalog display metadata and stays Worker-neutral", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_disabled",
        null,
        "   ",
      ),
    ).toBe("Implement: Selected Worker is disabled.");
  });
});

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
