import { describe, expect, it } from "vitest";
import {
  DESKTOP_AUTH_TRANSPORT_VERSION,
  DESKTOP_AUTH_INTENT_VERSION,
  DesktopHumanSessionCredentialSchema,
  DesktopAuthIntentCreateRequestSchema,
  DesktopAuthIntentCreateResponseSchema,
  DesktopAuthIntentClaimRequestSchema,
  RuntimePollRequestSchema,
  RuntimePollResponseSchema,
  RuntimeTransportStatusSchema,
  RuntimeTransportProjectionSchema,
  WorkspaceLifecyclePreferencesSchema,
  WorkspaceLifecycleStateSchema,
  WorkspaceRegistrationRequestSchema,
  WorkspaceRuntimeCredentialSchema,
} from "../src/index.js";

const timestamp = "2026-09-27T12:00:00.000Z";

describe("desktop auth and runtime transport contracts", () => {
  it("constructs every lifecycle combination without deriving dimensions", () => {
    const auth = ["signed_out", "signed_in", "reauth_required"] as const;
    const participation = [
      "disconnected",
      "connecting",
      "connected",
      "disconnecting",
    ] as const;
    const desired = ["connected", "disconnected"] as const;
    const states = auth.flatMap((humanAuth) =>
      participation.flatMap((state) =>
        desired.map((desiredRuntime) =>
          WorkspaceLifecycleStateSchema.parse({
            humanAuth,
            participation: state,
            desiredRuntime,
          }),
        ),
      ),
    );

    expect(states).toHaveLength(3 * 4 * 2);
    expect(
      WorkspaceLifecycleStateSchema.parse({
        humanAuth: "reauth_required",
        participation: "connected",
        desiredRuntime: "connected",
      }).participation,
    ).toBe("connected");
    expect(
      WorkspaceLifecycleStateSchema.safeParse({
        humanAuth: "signed_in",
        participation: "connected",
        managementLock: "locked",
        desiredRuntime: "connected",
      }).success,
    ).toBe(false);
    expect(RuntimeTransportProjectionSchema.parse("http_long_poll")).toBe(
      "http_long_poll",
    );
  });

  it("limits persisted lifecycle preferences to non-secret fields", () => {
    expect(
      WorkspaceLifecyclePreferencesSchema.parse({
        desiredRuntime: "connected",
        ownerUserId: "user-1",
        ownerDisplayName: "Ada",
      }).ownerUserId,
    ).toBe("user-1");
    expect(
      WorkspaceLifecyclePreferencesSchema.safeParse({
        desiredRuntime: "connected",
        desktopHumanSessionCredential: "h".repeat(32),
      }).success,
    ).toBe(false);
  });

  it("keeps human and runtime credentials as distinct typed secrets", () => {
    expect(DesktopHumanSessionCredentialSchema.parse("h".repeat(32))).toBe(
      "h".repeat(32),
    );
    expect(WorkspaceRuntimeCredentialSchema.parse("r".repeat(32))).toBe(
      "r".repeat(32),
    );
    expect(DesktopHumanSessionCredentialSchema.safeParse("short").success).toBe(
      false,
    );
  });

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
        clientName: "Syntila Workspace",
        contractVersion: DESKTOP_AUTH_INTENT_VERSION,
      }).contractVersion,
    ).toBe("1.1");
    expect(
      DesktopAuthIntentCreateRequestSchema.safeParse({
        clientName: "Syntila Workspace",
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

  it("validates versioned installation registration data", () => {
    expect(
      WorkspaceRegistrationRequestSchema.parse({
        contractVersion: DESKTOP_AUTH_TRANSPORT_VERSION,
        installationId: "install_00000000-0000-4000-8000-000000000001",
        proposedWorkspaceName: "Studio",
        hostname: "studio.local",
        platform: "macos",
        architecture: "arm64",
        appVersion: "1.2.3",
        runtimeCapabilities: {
          os: "macos",
          arch: "arm64",
          appVersion: "1.2.3",
          supportedRuntimes: ["dart"],
          maxConcurrentWorkers: 1,
        },
      }).installationId,
    ).toContain("install_00000000");
    expect(
      WorkspaceRegistrationRequestSchema.safeParse({
        contractVersion: DESKTOP_AUTH_TRANSPORT_VERSION,
        installationId: "bad",
        proposedWorkspaceName: "Studio",
        hostname: "studio.local",
        platform: "macos",
        architecture: "arm64",
        appVersion: "1.2.3",
        runtimeCapabilities: [],
      }).success,
    ).toBe(false);
  });

  it("bounds cursor-based long polling and event batches", () => {
    expect(
      RuntimePollRequestSchema.parse({
        sessionId: "session-1",
        cursor: "cursor-2",
        waitMs: 25000,
      }).cursor,
    ).toBe("cursor-2");
    expect(
      RuntimePollRequestSchema.safeParse({
        sessionId: "session-1",
        cursor: "cursor-2",
        waitMs: 90000,
      }).success,
    ).toBe(false);
    expect(
      RuntimePollResponseSchema.parse({
        cursor: "cursor-3",
        events: [],
        serverTime: timestamp,
        timedOut: true,
      }).events,
    ).toEqual([]);
  });

  it("spaces degraded fallback separately from authentication failure", () => {
    const status = {
      state: "fallback_ready",
      activeTransport: "http_long_poll",
      preferredTransport: "websocket",
      lastWebSocketFailure: {
        code: "upgrade_failed",
        message: "Proxy rejected upgrade",
        occurredAt: timestamp,
      },
      fallbackSessionId: "session-1",
      lastPollAt: timestamp,
      lastRuntimeEventAt: null,
      observedAt: timestamp,
    };
    expect(RuntimeTransportStatusSchema.parse(status).state).toBe(
      "fallback_ready",
    );
    expect(
      RuntimeTransportStatusSchema.safeParse({
        ...status,
        state: "authentication_required",
        activeTransport: "http_long_poll",
      }).success,
    ).toBe(false);
  });
});
