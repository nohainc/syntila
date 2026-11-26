import { describe, expect, it } from "vitest";
import {
  DESKTOP_AUTH_TRANSPORT_VERSION,
  DESKTOP_AUTH_INTENT_VERSION,
  DesktopAuthIntentCreateRequestSchema,
  DesktopAuthIntentCreateResponseSchema,
  DesktopAuthIntentClaimRequestSchema,
} from "../src/index.js";

const timestamp = "2026-11-06T12:00:00.000Z";

describe("desktop authentication contracts", () => {
  it("requires the separate poll secret for one-time intent claim", () => {
    expect(
      DesktopAuthIntentClaimRequestSchema.safeParse({
        intentId: "intent-1",
        pollToken: "p".repeat(32),
      }).success,
    ).toBe(true);
    expect(
      DesktopAuthIntentClaimRequestSchema.safeParse({ intentId: "intent-1" })
        .success,
    ).toBe(false);
  });

  it("accepts only the current code-free desktop auth intent version", () => {
    expect(
      DesktopAuthIntentCreateRequestSchema.parse({
        clientName: "Syntila Connect",
        contractVersion: DESKTOP_AUTH_INTENT_VERSION,
      }).contractVersion,
    ).toBe("1.1");
    expect(
      DesktopAuthIntentCreateRequestSchema.safeParse({
        clientName: "Syntila Connect",
        contractVersion: DESKTOP_AUTH_TRANSPORT_VERSION,
      }).success,
    ).toBe(false);
    const response = {
      intentId: "intent-a",
      pollToken: "p".repeat(32),
      verificationUrl: "https://app.syntila.test/desktop-auth/approve",
      expiresAt: timestamp,
      pollIntervalMs: 2000,
    };
    expect(DesktopAuthIntentCreateResponseSchema.parse(response).intentId).toBe(
      "intent-a",
    );
    expect(
      DesktopAuthIntentCreateResponseSchema.safeParse({
        ...response,
        userCode: "12345678",
      }).success,
    ).toBe(false);
  });

});
