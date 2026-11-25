import { z } from "zod";
import type { WorkspaceRuntimeMessage } from "./workspace-runtime.js";

/** Wire contract version for desktop account management and runtime transports. */
export const DESKTOP_AUTH_TRANSPORT_CONTRACT =
  "syntila.desktop-auth-transport" as const;
export const DESKTOP_AUTH_TRANSPORT_VERSION = "1.0" as const;
export const DESKTOP_AUTH_INTENT_VERSION = "1.1" as const;

const id = z.string().trim().min(1).max(256);
const timestamp = z.string().datetime();
const secret = z.string().min(32).max(4096);

// Brands prevent accidentally passing one credential plane to another in TS.
export const DesktopHumanSessionCredentialSchema =
  secret.brand<"DesktopHumanSessionCredential">();
export type DesktopHumanSessionCredential = z.infer<
  typeof DesktopHumanSessionCredentialSchema
>;

export const WorkspaceRuntimeCredentialSchema =
  secret.brand<"WorkspaceRuntimeCredential">();
export type WorkspaceRuntimeCredential = z.infer<
  typeof WorkspaceRuntimeCredentialSchema
>;

/** Local Worker/provider secrets are deliberately not a wire/API schema. */
declare const localWorkerCredentialBrand: unique symbol;
export type LocalWorkerProviderCredential = string & {
  readonly [localWorkerCredentialBrand]: "LocalWorkerProviderCredential";
};

export const DesktopAuthIntentCreateRequestSchema = z
  .object({
    clientName: id.max(128),
    contractVersion: z.literal(DESKTOP_AUTH_INTENT_VERSION),
  })
  .strict();
export const DesktopAuthIntentCreateResponseSchema = z
  .object({
    intentId: id,
    pollToken: secret,
    verificationUrl: z.url({ protocol: /^https$/ }),
    expiresAt: timestamp,
    pollIntervalMs: z.number().int().min(1000).max(30000),
  })
  .strict();
export const DesktopAuthIntentStatusSchema = z
  .object({
    intentId: id,
    status: z.enum(["pending", "approved", "denied", "expired", "claimed"]),
    expiresAt: timestamp,
  })
  .strict();
export const DesktopAuthIntentClaimRequestSchema = z
  .object({ intentId: id, pollToken: secret })
  .strict();
export const DesktopAuthIntentApproveRequestSchema = z.object({}).strict();
export const DesktopHumanSessionIssueSchema = z
  .object({
    credential: DesktopHumanSessionCredentialSchema,
    user: z.object({ userId: id, displayName: id, email: z.email() }).strict(),
    issuedAt: timestamp,
    expiresAt: timestamp,
    refreshAfter: timestamp.optional(),
    sessionId: id,
    audience: z.literal("syntila.desktop.management"),
  })
  .strict();
export const DesktopHumanSessionRevokeRequestSchema = z
  .object({ sessionId: id })
  .strict();

export const WorkspaceRegistrationRequestSchema = z
  .object({
    contractVersion: z.literal(DESKTOP_AUTH_TRANSPORT_VERSION),
    installationId: z
      .string()
      .regex(
        /^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      ),
    proposedWorkspaceName: z.string().trim().min(1).max(200),
    hostname: z.string().trim().min(1).max(255),
    platform: z.enum(["macos", "windows", "linux"]),
    architecture: z.enum(["arm64", "x64", "x86"]),
    appVersion: id.max(128),
    runtimeCapabilities: z
      .object({
        os: z.enum(["macos", "windows", "linux"]),
        arch: z.enum(["arm64", "x64", "x86"]),
        appVersion: id.max(128),
        supportedRuntimes: z
          .array(z.string().regex(/^[a-z0-9_-]{1,32}$/i))
          .max(16),
        maxConcurrentWorkers: z.number().int().min(1).max(256),
      })
      .strict(),
  })
  .strict();
export const WorkspaceRegistrationResponseSchema = z
  .object({
    outcome: z.enum(["created", "recovered"]),
    workspaceId: id,
    workspaceRuntimeId: id,
    workspaceName: id,
    ownerUserId: id.optional(),
    runtimeCredential: WorkspaceRuntimeCredentialSchema,
    credentialIssuedAt: timestamp,
    credentialExpiresAt: timestamp.nullable(),
    completedAt: timestamp,
  })
  .strict();
export const WorkspaceRuntimeCredentialRotateRequestSchema = z
  .object({
    workspaceId: id,
    installationId: z
      .string()
      .regex(
        /^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      ),
  })
  .strict();
export const WorkspaceRuntimeCredentialRotateResponseSchema = z
  .object({
    workspaceId: id,
    workspaceRuntimeId: id,
    runtimeCredential: WorkspaceRuntimeCredentialSchema,
    credentialIssuedAt: timestamp,
    credentialExpiresAt: timestamp.nullable(),
  })
  .strict();

export const RuntimeTransportModeSchema = z.enum([
  "websocket",
  "http_long_poll",
]);
export const RuntimeTransportStateSchema = z.enum([
  "offline",
  "connecting_websocket",
  "websocket_ready",
  "fallback_connecting",
  "fallback_ready",
  "switching_to_websocket",
  "reconnecting",
  "authentication_required",
]);
export const RuntimeTransportStatusSchema = z
  .object({
    state: RuntimeTransportStateSchema,
    activeTransport: RuntimeTransportModeSchema.nullable(),
    preferredTransport: z.literal("websocket"),
    lastWebSocketFailure: z
      .object({ code: id, message: id, occurredAt: timestamp })
      .strict()
      .nullable(),
    fallbackSessionId: id.nullable(),
    lastPollAt: timestamp.nullable(),
    lastRuntimeEventAt: timestamp.nullable(),
    observedAt: timestamp,
  })
  .strict()
  .superRefine((status, ctx) => {
    if (
      status.state === "authentication_required" &&
      status.activeTransport !== null
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["activeTransport"],
        message:
          "Authentication-required state cannot have an active runtime transport",
      });
    }
    if (
      status.state === "websocket_ready" &&
      status.activeTransport !== "websocket"
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["activeTransport"],
        message: "websocket_ready requires WebSocket to be active",
      });
    }
    if (
      status.state === "fallback_ready" &&
      status.activeTransport !== "http_long_poll"
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["activeTransport"],
        message: "fallback_ready requires HTTP long-poll to be active",
      });
    }
  });

/**
 * ADR-014 lifecycle dimensions are deliberately independent of one another.
 * The GUI-only management-lock and launch-at-login dimensions were removed with
 * the Flutter Workspace app.
 */
export const HumanAuthStateSchema = z.enum([
  "signed_out",
  "signed_in",
  "reauth_required",
]);
export const WorkspaceParticipationStateSchema = z.enum([
  "disconnected",
  "connecting",
  "connected",
  "disconnecting",
]);
export const DesiredRuntimeStateSchema = z.enum(["connected", "disconnected"]);
export const WorkspaceLifecycleStateSchema = z
  .object({
    humanAuth: HumanAuthStateSchema,
    participation: WorkspaceParticipationStateSchema,
    desiredRuntime: DesiredRuntimeStateSchema,
  })
  .strict();

/** Persisted local preferences only; owner fields are a non-authoritative cache. */
export const WorkspaceLifecyclePreferencesSchema = z
  .object({
    desiredRuntime: DesiredRuntimeStateSchema,
    ownerUserId: id.optional(),
    ownerDisplayName: id.optional(),
  })
  .strict();

/** Read-only transport state; orthogonal to Workspace lifecycle. */
export const RuntimeTransportProjectionSchema = z.enum([
  "websocket",
  "http_long_poll",
  "reconnecting",
  "offline",
  "authentication_required",
]);

export const RuntimeSessionCreateRequestSchema = z
  .object({
    workspaceRuntimeId: id,
    contractVersion: z.literal(DESKTOP_AUTH_TRANSPORT_VERSION),
    lastCursor: id.optional(),
  })
  .strict();
export const RuntimeSessionCreateResponseSchema = z
  .object({
    sessionId: id,
    serverTime: timestamp,
    pollTimeoutMs: z.number().int().min(1000).max(60000),
    heartbeatIntervalMs: z.number().int().min(1000).max(300000),
    cursor: id,
  })
  .strict();

export const RuntimeEventEnvelopeSchema = z
  .object({
    contract: z.literal(DESKTOP_AUTH_TRANSPORT_CONTRACT),
    version: z.literal(DESKTOP_AUTH_TRANSPORT_VERSION),
    eventId: id,
    occurredAt: timestamp,
    message: z.unknown(),
  })
  .strict();
export const RuntimeEventsPostRequestSchema = z
  .object({
    sessionId: id,
    events: z.array(RuntimeEventEnvelopeSchema).min(1).max(100),
  })
  .strict();
export const RuntimeEventsPostResponseSchema = z
  .object({
    acceptedEventIds: z.array(id),
    rejected: z.array(z.object({ eventId: id, code: id }).strict()),
    cursor: id,
  })
  .strict();
export const RuntimePollRequestSchema = z
  .object({
    sessionId: id,
    cursor: id,
    waitMs: z.number().int().min(0).max(60000),
  })
  .strict();
export const RuntimePollResponseSchema = z
  .object({
    cursor: id,
    events: z.array(RuntimeEventEnvelopeSchema).max(100),
    serverTime: timestamp,
    timedOut: z.boolean(),
  })
  .strict();
export const RuntimeSessionCloseRequestSchema = z
  .object({ sessionId: id })
  .strict();
export const RuntimeSessionCloseResponseSchema = z
  .object({ closed: z.boolean(), closedAt: timestamp })
  .strict();

export type DesktopAuthIntentCreateRequest = z.infer<
  typeof DesktopAuthIntentCreateRequestSchema
>;
export type DesktopAuthIntentCreateResponse = z.infer<
  typeof DesktopAuthIntentCreateResponseSchema
>;
export type DesktopAuthIntentStatus = z.infer<
  typeof DesktopAuthIntentStatusSchema
>;
export type DesktopAuthIntentClaimRequest = z.infer<
  typeof DesktopAuthIntentClaimRequestSchema
>;
export type DesktopAuthIntentApproveRequest = z.infer<
  typeof DesktopAuthIntentApproveRequestSchema
>;
export type DesktopHumanSessionIssue = z.infer<
  typeof DesktopHumanSessionIssueSchema
>;
export type WorkspaceRegistrationRequest = z.infer<
  typeof WorkspaceRegistrationRequestSchema
>;
export type WorkspaceRegistrationResponse = z.infer<
  typeof WorkspaceRegistrationResponseSchema
>;
export type WorkspaceRuntimeCredentialRotateRequest = z.infer<
  typeof WorkspaceRuntimeCredentialRotateRequestSchema
>;
export type WorkspaceRuntimeCredentialRotateResponse = z.infer<
  typeof WorkspaceRuntimeCredentialRotateResponseSchema
>;
export type RuntimeTransportStatus = z.infer<
  typeof RuntimeTransportStatusSchema
>;
export type HumanAuthState = z.infer<typeof HumanAuthStateSchema>;
export type WorkspaceParticipationState = z.infer<
  typeof WorkspaceParticipationStateSchema
>;
export type DesiredRuntimeState = z.infer<typeof DesiredRuntimeStateSchema>;
export type WorkspaceLifecycleState = z.infer<
  typeof WorkspaceLifecycleStateSchema
>;
export type WorkspaceLifecyclePreferences = z.infer<
  typeof WorkspaceLifecyclePreferencesSchema
>;
export type RuntimeTransportProjection = z.infer<
  typeof RuntimeTransportProjectionSchema
>;
export type RuntimeSessionCreateRequest = z.infer<
  typeof RuntimeSessionCreateRequestSchema
>;
export type RuntimeSessionCreateResponse = z.infer<
  typeof RuntimeSessionCreateResponseSchema
>;
export type RuntimeEventEnvelope = z.infer<typeof RuntimeEventEnvelopeSchema>;
export type RuntimeEventsPostRequest = z.infer<
  typeof RuntimeEventsPostRequestSchema
>;
export type RuntimeEventsPostResponse = z.infer<
  typeof RuntimeEventsPostResponseSchema
>;
export type RuntimePollRequest = z.infer<typeof RuntimePollRequestSchema>;
export type RuntimePollResponse = z.infer<typeof RuntimePollResponseSchema>;
export type RuntimeSessionCloseRequest = z.infer<
  typeof RuntimeSessionCloseRequestSchema
>;
export type RuntimeSessionCloseResponse = z.infer<
  typeof RuntimeSessionCloseResponseSchema
>;

/** Transport implementations move the existing logical runtime messages unchanged. */
export interface WorkspaceTransport {
  readonly mode: z.infer<typeof RuntimeTransportModeSchema>;
  readonly status: RuntimeTransportStatus;
  connect(): Promise<void>;
  send(message: WorkspaceRuntimeMessage): Promise<void>;
  readonly messages: AsyncIterable<WorkspaceRuntimeMessage>;
  close(): Promise<void>;
}
