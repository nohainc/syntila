import { z } from "zod";

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
