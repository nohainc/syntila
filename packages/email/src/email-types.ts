/**
 * Source-controlled email template contracts.
 *
 * Template inputs are deliberately event-specific. Callers pass validated
 * values and never construct HTML or arbitrary template fragments.
 */
export type EmailTemplateId =
  | "auth.verify-email.v1"
  | "auth.verify-email-code.v1"
  | "auth.reset-password.v1"
  | "auth.password-changed.v1"
  | "auth.confirm-email-change.v1"
  | "auth.email-changed.v1"
  | "space.invitation.v1"
  | "space.invitation-accepted.v1"
  | "space.access-revoked.v1"
  | "person.invitation.v1"
  | "auth.welcome.v1"
  | "auth.account-deleted.v1";

export type EmailTemplatePriority =
  "essential" | "informational" | "preference";

export type EmailNotificationCategory = "essential" | "security" | "optional";

export type EmailTemplateAvailability = "implemented" | "planned";

export type EmailPresentationVariant =
  "action-required" | "confirmation" | "security-notice" | "informational";

export interface EmailTemplateMetadata<
  TId extends EmailTemplateId = EmailTemplateId,
> {
  readonly id: TId;
  readonly priority: EmailTemplatePriority;
  readonly category: EmailNotificationCategory;
  readonly availability: EmailTemplateAvailability;
  readonly variant: EmailPresentationVariant;
}

export interface RenderedEmailContent {
  readonly templateId: EmailTemplateId;
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

export interface RenderedEmail extends RenderedEmailContent {
  readonly templateVersion: 1;
  readonly metadata: Readonly<{
    readonly variant: EmailPresentationVariant;
    readonly category: EmailNotificationCategory;
  }>;
}

export interface EmailRenderOptions {
  /** Origins approved by the trusted application workflow. */
  readonly approvedOrigins?: readonly string[];
}

export interface VerifyEmailInput {
  readonly recipientName?: string | null;
  readonly verificationUrl: string;
  /** Better Auth's configured verification-token lifetime, in minutes. */
  readonly expiresInMinutes: number;
}

export interface VerifyEmailCodeInput {
  readonly recipientName?: string | null;
  readonly verificationCode: string;
  /** Verification code lifetime, in minutes. */
  readonly expiresInMinutes: number;
  /** Flow the code confirms; defaults to sign-up. */
  readonly purpose?: "sign-up" | "email-change";
}

export interface ResetPasswordInput {
  readonly recipientName?: string | null;
  readonly resetUrl: string;
  /** Better Auth's configured reset-token lifetime, in minutes. */
  readonly expiresInMinutes: number;
}

export interface PasswordChangedInput {
  readonly recipientName?: string | null;
  readonly changedAt?: string | null;
}

export interface ConfirmEmailChangeInput {
  readonly recipientName?: string | null;
  readonly newEmail: string;
  readonly confirmationUrl: string;
  /** Better Auth's configured email-verification lifetime, in minutes. */
  readonly expiresInMinutes: number;
}

/** @deprecated Use ConfirmEmailChangeInput for the v1 template contract. */
export type ChangeEmailInput = ConfirmEmailChangeInput;

export interface EmailChangedInput {
  readonly recipientName?: string | null;
  readonly newEmail: string;
  readonly changedAt?: string | null;
}

export interface SpaceInvitationInput {
  readonly inviterName: string;
  readonly spaceName: string;
  readonly role: string;
  readonly invitationUrl: string;
  readonly recipientEmail: string;
}

export interface PersonInvitationInput {
  readonly inviterName: string;
  readonly recipientEmail: string;
  readonly invitationUrl: string;
}

export interface SpaceInvitationAcceptedInput {
  readonly recipientName?: string | null;
  readonly memberName: string;
  readonly spaceName: string;
  readonly role: string;
}

export interface SpaceAccessRevokedInput {
  readonly recipientName?: string | null;
  readonly spaceName: string;
  readonly reason?: string | null;
}

export interface WelcomeInput {
  readonly recipientName?: string | null;
  readonly appUrl: string;
}

export interface AccountDeletedInput {
  readonly recipientName?: string | null;
  readonly deletedAt?: string | null;
  readonly appUrl?: string | null;
}

export interface EmailTemplateInputMap {
  readonly "auth.verify-email.v1": VerifyEmailInput;
  readonly "auth.verify-email-code.v1": VerifyEmailCodeInput;
  readonly "auth.reset-password.v1": ResetPasswordInput;
  readonly "auth.password-changed.v1": PasswordChangedInput;
  readonly "auth.confirm-email-change.v1": ConfirmEmailChangeInput;
  readonly "auth.email-changed.v1": EmailChangedInput;
  readonly "space.invitation.v1": SpaceInvitationInput;
  readonly "space.invitation-accepted.v1": SpaceInvitationAcceptedInput;
  readonly "space.access-revoked.v1": SpaceAccessRevokedInput;
  readonly "person.invitation.v1": PersonInvitationInput;
  readonly "auth.welcome.v1": WelcomeInput;
  readonly "auth.account-deleted.v1": AccountDeletedInput;
}

export interface EmailTemplateDefinition<
  TId extends EmailTemplateId = EmailTemplateId,
> extends EmailTemplateMetadata<TId> {
  readonly render: (input: EmailTemplateInputMap[TId]) => RenderedEmailContent;
}
