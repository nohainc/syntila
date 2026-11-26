import { describe, expect, it } from "vitest";
import {
  SENSITIVE_OPERATIONS,
  STEP_UP_REQUIREMENTS,
  isStepUpSatisfied,
  type StepUpRecord,
} from "../src/auth/step-up.js";

const now = new Date("2026-09-23T12:00:00.000Z");

function record(overrides: Partial<StepUpRecord> = {}): StepUpRecord {
  return {
    user_id: "user-1",
    session_id: "session-1",
    method: "passkey",
    authenticated_at: "2026-09-23T11:55:00.000Z",
    expires_at: "2026-09-23T12:05:00.000Z",
    ...overrides,
  };
}

describe("sensitive operation step-up policy", () => {
  it("declares a short fresh-auth window for every sensitive operation", () => {
    expect(Object.keys(STEP_UP_REQUIREMENTS)).toEqual([
      SENSITIVE_OPERATIONS.workerOwnershipTransfer,
      SENSITIVE_OPERATIONS.billingSecurityChange,
      SENSITIVE_OPERATIONS.toolProfileStablePromotion,
      SENSITIVE_OPERATIONS.toolProfileRollback,
    ]);
    expect(
      STEP_UP_REQUIREMENTS[SENSITIVE_OPERATIONS.workerOwnershipTransfer]
        .maxAgeMs,
    ).toBe(10 * 60 * 1000);
  });

  it("accepts a fresh strong passkey proof", () => {
    expect(
      isStepUpSatisfied(
        record(),
        SENSITIVE_OPERATIONS.workerOwnershipTransfer,
        now,
      ),
    ).toBe(true);
  });

  it("requires fresh proof for stable promotion and rollback", () => {
    for (const operation of [
      SENSITIVE_OPERATIONS.toolProfileStablePromotion,
      SENSITIVE_OPERATIONS.toolProfileRollback,
    ]) {
      expect(STEP_UP_REQUIREMENTS[operation].maxAgeMs).toBe(5 * 60 * 1000);
      expect(STEP_UP_REQUIREMENTS[operation].methods).toEqual(["passkey"]);
      expect(isStepUpSatisfied(record(), operation, now)).toBe(true);
      expect(
        isStepUpSatisfied(record({ method: "totp" }), operation, now),
      ).toBe(false);
      expect(
        isStepUpSatisfied(
          record({ authenticated_at: "2026-09-23T11:54:59.000Z" }),
          operation,
          now,
        ),
      ).toBe(false);
    }
  });

  it("rejects missing, expired, stale, and unsupported proofs", () => {
    expect(
      isStepUpSatisfied(
        null,
        SENSITIVE_OPERATIONS.workerOwnershipTransfer,
        now,
      ),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ expires_at: "2026-09-23T11:59:59.000Z" }),
        SENSITIVE_OPERATIONS.workerOwnershipTransfer,
        now,
      ),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ authenticated_at: "2026-09-23T11:49:59.000Z" }),
        SENSITIVE_OPERATIONS.workerOwnershipTransfer,
        now,
      ),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ method: "totp" }),
        SENSITIVE_OPERATIONS.workerOwnershipTransfer,
        now,
      ),
    ).toBe(true);
  });
});
