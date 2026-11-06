import type { EmailTemplateId, EmailTemplateInputMap } from "./email-types.js";

/**
 * Synthetic, non-deliverable values used by local previews and QA. These
 * values must never be used as production event data.
 */
export const EMAIL_PREVIEW_ORIGIN = "https://syntila.app";

export const emailPreviewFixtures: Readonly<{
  [TId in EmailTemplateId]: EmailTemplateInputMap[TId];
}> = Object.freeze({
  "auth.verify-email.v1": {
    recipientName: "Ada Lovelace",
    verificationUrl: `${EMAIL_PREVIEW_ORIGIN}/verify?token=preview-verification-token`,
    expiresInMinutes: 60,
  },
  "auth.verify-email-code.v1": {
    recipientName: "Ada Lovelace",
    verificationCode: "482910",
    expiresInMinutes: 10,
  },
  "auth.reset-password.v1": {
    recipientName: "Ada Lovelace",
    resetUrl: `${EMAIL_PREVIEW_ORIGIN}/reset?token=preview-reset-token`,
    expiresInMinutes: 60,
  },
  "auth.password-changed.v1": {
    recipientName: "Ada Lovelace",
    changedAt: "2026-10-12T08:00:00.000Z",
  },
  "auth.confirm-email-change.v1": {
    recipientName: "Ada Lovelace",
    newEmail: "ada.new@example.com",
    confirmationUrl: `${EMAIL_PREVIEW_ORIGIN}/change?token=preview-change-token`,
    expiresInMinutes: 60,
  },
  "auth.email-changed.v1": {
    recipientName: "Ada Lovelace",
    newEmail: "ada.new@example.com",
    changedAt: "2026-10-12T08:00:00.000Z",
  },
  "space.invitation.v1": {
    inviterName: "Grace Hopper",
    spaceName: "Syntila Research Space",
    role: "collaborator",
    invitationUrl: `${EMAIL_PREVIEW_ORIGIN}/?invitation=preview-invitation`,
    recipientEmail: "ada@example.com",
  },
  "person.invitation.v1": {
    inviterName: "Grace Hopper",
    invitationUrl: `${EMAIL_PREVIEW_ORIGIN}/?person_invitation=preview-person-invitation`,
    recipientEmail: "ada@example.com",
  },
  "space.invitation-accepted.v1": {
    recipientName: "Grace Hopper",
    memberName: "Ada Lovelace",
    spaceName: "Syntila Research Space",
    role: "collaborator",
  },
  "space.access-revoked.v1": {
    recipientName: "Ada Lovelace",
    spaceName: "Syntila Research Space",
    reason: "Membership ended",
  },
  "auth.welcome.v1": {
    recipientName: "Ada Lovelace",
    appUrl: EMAIL_PREVIEW_ORIGIN,
  },
  "auth.account-deleted.v1": {
    recipientName: "Ada Lovelace",
    deletedAt: "2026-10-12T08:00:00.000Z",
    appUrl: EMAIL_PREVIEW_ORIGIN,
  },
});
