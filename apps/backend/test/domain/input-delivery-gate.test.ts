import { describe, expect, it } from "./helpers/vitest-compat";
import { inputGateDecision } from "../../src/domain/workflow.js";
import { INPUT_DELIVERY_IDLE_TIMEOUT_MS } from "../../src/domain/routes/work-request-inputs.js";

const at = "2026-10-25T10:00:00.000Z";
const now = Date.parse(at) + 1_000;
const row = (
  name: string,
  state: "awaiting_upload" | "uploaded" | "delivered" | "failed",
  extra: { errorMessage?: string; updatedAt?: string } = {},
) => ({
  name,
  state,
  errorMessage: extra.errorMessage ?? null,
  updatedAt: extra.updatedAt ?? at,
});

describe("Input Delivery gate", () => {
  it("does not gate requests without files", () => {
    expect(inputGateDecision([], false, now)).toEqual({ outcome: "none" });
  });

  it("dispatches only when every file is delivered", () => {
    expect(
      inputGateDecision(
        [row("a", "delivered"), row("b", "uploaded")],
        false,
        now,
      ),
    ).toEqual({ outcome: "waiting" });
    expect(
      inputGateDecision(
        [row("a", "delivered"), row("b", "delivered")],
        false,
        now,
      ),
    ).toEqual({ outcome: "delivered" });
  });

  it("fails the request on a failed file with its reason", () => {
    expect(
      inputGateDecision(
        [
          row("a", "delivered"),
          row("b", "failed", { errorMessage: "b could not be uploaded" }),
        ],
        false,
        now,
      ),
    ).toEqual({ outcome: "failed", message: "b could not be uploaded" });
  });

  it("stops for cancellation", () => {
    expect(inputGateDecision([row("a", "uploaded")], true, now)).toMatchObject({
      outcome: "cancelled",
    });
  });

  it("fails when no file makes progress within the idle limit", () => {
    const later = Date.parse(at) + INPUT_DELIVERY_IDLE_TIMEOUT_MS;
    expect(
      inputGateDecision(
        [row("a", "delivered"), row("b", "awaiting_upload")],
        false,
        later,
      ),
    ).toEqual({
      outcome: "failed",
      message: "Files were not delivered to the Workspace in time: b",
    });
    // Any recent change keeps the request waiting.
    expect(
      inputGateDecision(
        [
          row("a", "uploaded", {
            updatedAt: new Date(later - 1_000).toISOString(),
          }),
          row("b", "awaiting_upload"),
        ],
        false,
        later,
      ),
    ).toEqual({ outcome: "waiting" });
  });
});
