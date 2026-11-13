import { renderEmailLayout } from "../email-layout.js";
import { escapeHtml } from "../email-escaping.js";
import type {
  AccountDeletedInput,
  ConfirmEmailChangeInput,
  EmailChangedInput,
  EmailTemplateId,
  EmailTemplateInputMap,
  EmailTemplateMetadata,
  EmailRenderOptions,
  PasswordChangedInput,
  PersonInvitationInput,
  RenderedEmail,
  RenderedEmailContent,
  ResetPasswordInput,
  SpaceAccessRevokedInput,
  SpaceInvitationInput,
  SpaceInvitationAcceptedInput,
  VerifyEmailCodeInput,
  VerifyEmailInput,
  WelcomeInput,
} from "../email-types.js";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_TEMPLATE_FIELD_LENGTH = 4096;
export const DEFAULT_APPROVED_EMAIL_ORIGINS = Object.freeze([
  "https://syntila.app",
  "http://localhost:3000",
  "http://localhost:8080",
  "http://localhost:8787",
  "http://127.0.0.1:3000",
  "http://127.0.0.1:8080",
  "http://127.0.0.1:8787",
]);

function text(value: string | null | undefined, fallback: string): string {
  const trimmed = value?.trim();
  if (trimmed && trimmed.length > MAX_TEMPLATE_FIELD_LENGTH) {
    throw new Error(
      `template text must be at most ${MAX_TEMPLATE_FIELD_LENGTH} characters`,
    );
  }
  return trimmed && trimmed.length > 0 ? trimmed : fallback;
}

function required(value: string, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${field} is required`);
  }
  const normalized = value.trim();
  if (normalized.length > MAX_TEMPLATE_FIELD_LENGTH) {
    throw new Error(
      `${field} must be at most ${MAX_TEMPLATE_FIELD_LENGTH} characters`,
    );
  }
  return normalized;
}

function subjectPart(value: string, field: string): string {
  const normalized = required(value, field);
  if (/[\r\n]/.test(normalized)) {
    throw new Error(`${field} must not contain line breaks`);
  }
  return normalized;
}

function safeUrl(value: string, field: string): string {
  const normalized = required(value, field);
  let url: URL;
  try {
    url = new URL(normalized);
  } catch {
    throw new Error(`${field} must be an absolute http(s) URL`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(`${field} must be an absolute http(s) URL`);
  }
  if (url.username || url.password) {
    throw new Error(`${field} must not contain URL credentials`);
  }
  return url.toString();
}

function safeEmail(value: string, field: string): string {
  const normalized = required(value, field).toLowerCase();
  if (/[<>"'\s]/.test(normalized) || !EMAIL_PATTERN.test(normalized))
    throw new Error(`${field} must be an email address`);
  return escapeHtml(normalized);
}

function safeName(value: string | null | undefined): string {
  return escapeHtml(text(value, "there"));
}

function safeText(value: string, field: string): string {
  return escapeHtml(required(value, field));
}

function dateLabel(value: string | null | undefined): string {
  if (!value?.trim()) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime()))
    throw new Error("date must be a valid timestamp");
  return date.toISOString();
}

function validityMinutes(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${field} must be a positive whole number of minutes`);
  }
  return value;
}

function validityText(minutes: number): string {
  return `This link is valid for ${minutes} ${minutes === 1 ? "minute" : "minutes"}.`;
}

function validityHtml(minutes: number): string {
  return `<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">${escapeHtml(validityText(minutes))}</p>`;
}

function renderVerifyEmail(input: VerifyEmailInput): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const verificationUrl = safeUrl(input.verificationUrl, "verificationUrl");
  const expiration = validityMinutes(
    input.expiresInMinutes,
    "expiresInMinutes",
  );
  const subject = "Verify your Syntila email address";
  return {
    templateId: "auth.verify-email.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.verify-email.v1",
      subject,
      variant: "action-required",
      eyebrow: "Account security",
      title: "Verify your email address",
      intro: `Welcome to Syntila, ${recipientName}. Confirm your email address to finish setting up your account.`,
      bodyHtml: validityHtml(expiration),
      bodyText: `Confirm your email address to finish setting up your account.\n\n${validityText(expiration)}`,
      action: { label: "Verify email address", url: verificationUrl },
      securityNotice:
        "If you did not create a Syntila account, you can safely ignore this email.",
    }),
  };
}

function renderVerifyEmailCode(
  input: VerifyEmailCodeInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const verificationCode = required(input.verificationCode, "verificationCode");
  if (!/^\d{6}$/.test(verificationCode)) {
    throw new Error("verificationCode must be a 6-digit numeric code");
  }
  const expiration = validityMinutes(
    input.expiresInMinutes,
    "expiresInMinutes",
  );
  const emailChange = input.purpose === "email-change";
  const codeValidityText = `This code is valid for ${expiration} ${expiration === 1 ? "minute" : "minutes"}.`;
  const subject = `${verificationCode} is your Syntila verification code`;
  return {
    templateId: "auth.verify-email-code.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.verify-email-code.v1",
      subject,
      variant: "action-required",
      eyebrow: "Account security",
      title: emailChange
        ? "Confirm your email change"
        : "Verify your email address",
      intro: emailChange
        ? `Hi ${recipientName}. Enter the one-time verification code below to confirm changing the email address on your Syntila account.`
        : `Welcome to Syntila, ${recipientName}. Enter the one-time verification code below to finish creating your account.`,
      bodyHtml: `<div style="margin:24px 0 8px;padding:18px 24px;background:#e0e7ff;border:1px solid #c7d2fe;border-radius:10px;text-align:center;font-family:Courier,monospace;font-size:32px;font-weight:700;letter-spacing:8px;color:#17181a;">${escapeHtml(verificationCode)}</div><p style="margin:16px 0 0;color:#434547;font-size:15px;line-height:24px;">${escapeHtml(codeValidityText)}</p>`,
      bodyText: `Enter the one-time verification code below to ${emailChange ? "confirm your email change" : "finish creating your account"}:\n\n${verificationCode}\n\n${codeValidityText}`,
      securityNotice:
        "If you did not request a Syntila verification code, you can safely ignore this email.",
    }),
  };
}

function renderResetPassword(input: ResetPasswordInput): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const resetUrl = safeUrl(input.resetUrl, "resetUrl");
  const expiration = validityMinutes(
    input.expiresInMinutes,
    "expiresInMinutes",
  );
  const subject = "Reset your Syntila password";
  return {
    templateId: "auth.reset-password.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.reset-password.v1",
      subject,
      variant: "action-required",
      eyebrow: "Account security",
      title: "Reset your password",
      intro: `Hi ${recipientName}, use the button below to choose a new Syntila password.`,
      bodyHtml: validityHtml(expiration),
      bodyText: `Use the button below to choose a new Syntila password.\n\n${validityText(expiration)}`,
      action: { label: "Reset password", url: resetUrl },
      securityNotice:
        "If you did not request a password reset, you can safely ignore this email.",
    }),
  };
}

function renderPasswordChanged(
  input: PasswordChangedInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const changedAt = dateLabel(input.changedAt);
  const detail = changedAt ? ` at ${escapeHtml(changedAt)}` : "";
  const subject = "Your Syntila password was changed";
  return {
    templateId: "auth.password-changed.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.password-changed.v1",
      subject,
      variant: "security-notice",
      eyebrow: "Account security",
      title: "Password changed",
      intro: `Hi ${recipientName}, your Syntila password was changed${detail}.`,
      bodyHtml:
        '<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">If you did not make this change, secure your account immediately by signing in and changing your password again.</p>',
      bodyText: `Your Syntila password was changed${changedAt ? ` at ${changedAt}` : ""}. If you did not make this change, secure your account immediately.`,
      securityNotice: "This is an account-security notification.",
    }),
  };
}

function renderConfirmEmailChange(
  input: ConfirmEmailChangeInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const newEmail = safeEmail(input.newEmail, "newEmail");
  const confirmationUrl = safeUrl(input.confirmationUrl, "confirmationUrl");
  const expiration = validityMinutes(
    input.expiresInMinutes,
    "expiresInMinutes",
  );
  const subject = "Confirm your Syntila email change";
  return {
    templateId: "auth.confirm-email-change.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.confirm-email-change.v1",
      subject,
      variant: "action-required",
      eyebrow: "Account security",
      title: "Confirm your email change",
      intro: `Hi ${recipientName}, confirm changing your Syntila email address to ${newEmail}.`,
      bodyHtml: validityHtml(expiration),
      bodyText: `Confirm changing your Syntila email address to ${newEmail}.\n\n${validityText(expiration)}`,
      action: { label: "Confirm email change", url: confirmationUrl },
      securityNotice:
        "If you did not request this change, you can safely ignore this email and keep your current address.",
    }),
  };
}

function renderEmailChanged(input: EmailChangedInput): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const newEmail = safeEmail(input.newEmail, "newEmail");
  const changedAt = dateLabel(input.changedAt);
  const detail = changedAt ? ` at ${escapeHtml(changedAt)}` : "";
  const subject = "Your Syntila email address was changed";
  return {
    templateId: "auth.email-changed.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.email-changed.v1",
      subject,
      variant: "security-notice",
      eyebrow: "Account security",
      title: "Email address changed",
      intro: `Hi ${recipientName}, your Syntila email address is now ${newEmail}${detail}.`,
      bodyHtml:
        '<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">If you did not make this change, secure your account immediately.</p>',
      bodyText: `Your Syntila email address is now ${newEmail}${changedAt ? ` at ${changedAt}` : ""}. If you did not make this change, secure your account immediately.`,
      securityNotice: "This is an account-security notification.",
    }),
  };
}

function renderInvitation(input: SpaceInvitationInput): RenderedEmailContent {
  const inviterNameValue = subjectPart(input.inviterName, "inviterName");
  const spaceNameValue = subjectPart(input.spaceName, "spaceName");
  const roleValue = subjectPart(input.role, "role");
  const inviterName = safeText(inviterNameValue, "inviterName");
  const spaceName = safeText(spaceNameValue, "spaceName");
  const role = safeText(roleValue, "role");
  const recipientEmail = safeEmail(input.recipientEmail, "recipientEmail");
  const invitationUrl = safeUrl(input.invitationUrl, "invitationUrl");
  const subject = `${inviterNameValue} invited you to ${spaceNameValue}`;
  return {
    templateId: "space.invitation.v1",
    subject,
    ...renderEmailLayout({
      templateId: "space.invitation.v1",
      subject,
      variant: "action-required",
      eyebrow: "Space invitation",
      title: "You have been invited to a Space",
      intro: `<strong>${inviterName}</strong> invited you to join <strong>${spaceName}</strong> as a <strong>${role}</strong>.`,
      bodyHtml: `<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">Sign in with <strong>${recipientEmail}</strong> to accept the invitation.</p>`,
      bodyText: `${inviterNameValue} invited you to join "${spaceNameValue}" as a ${roleValue} on Syntila.\n\nSign in with ${input.recipientEmail.trim()} to accept.`,
      action: { label: "View invitation", url: invitationUrl },
      securityNotice:
        "If you were not expecting this invitation, you can safely ignore this email.",
    }),
  };
}

function renderInvitationAccepted(
  input: SpaceInvitationAcceptedInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const memberNameValue = subjectPart(input.memberName, "memberName");
  const spaceNameValue = subjectPart(input.spaceName, "spaceName");
  const roleValue = subjectPart(input.role, "role");
  const memberName = safeText(memberNameValue, "memberName");
  const spaceName = safeText(spaceNameValue, "spaceName");
  const role = safeText(roleValue, "role");
  const subject = `${memberNameValue} joined ${spaceNameValue}`;
  return {
    templateId: "space.invitation-accepted.v1",
    subject,
    ...renderEmailLayout({
      templateId: "space.invitation-accepted.v1",
      subject,
      variant: "confirmation",
      eyebrow: "Space update",
      title: "A new member joined your Space",
      intro: `Hi ${recipientName}, <strong>${memberName}</strong> accepted the invitation to <strong>${spaceName}</strong> as a <strong>${role}</strong>.`,
      bodyHtml: "",
      bodyText: `${memberNameValue} accepted the invitation to "${spaceNameValue}" as a ${roleValue}.`,
      securityNotice:
        "This notification is sent only after the invitation has been accepted.",
    }),
  };
}

function renderAccessRevoked(
  input: SpaceAccessRevokedInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const spaceNameValue = subjectPart(input.spaceName, "spaceName");
  const spaceName = safeText(spaceNameValue, "spaceName");
  const reasonValue = input.reason?.trim();
  const reason = reasonValue ? safeText(reasonValue, "reason") : undefined;
  const subject = `Your access to ${spaceNameValue} was removed`;
  return {
    templateId: "space.access-revoked.v1",
    subject,
    ...renderEmailLayout({
      templateId: "space.access-revoked.v1",
      subject,
      variant: "security-notice",
      eyebrow: "Space update",
      title: "Space access removed",
      intro: `Hi ${recipientName}, your access to <strong>${spaceName}</strong> has been removed.${reason ? ` Reason: <strong>${reason}</strong>` : ""}`,
      bodyHtml:
        '<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">Contact the Space owner if you believe this happened by mistake.</p>',
      bodyText: `Your access to "${spaceNameValue}" has been removed.${reasonValue ? ` Reason: ${reasonValue}` : ""}\n\nContact the Space owner if you believe this happened by mistake.`,
      securityNotice: "This is a Space membership notification.",
    }),
  };
}

function renderPersonInvitation(
  input: PersonInvitationInput,
): RenderedEmailContent {
  const inviterNameValue = subjectPart(input.inviterName, "inviterName");
  const inviterName = safeText(inviterNameValue, "inviterName");
  const recipientEmail = safeEmail(input.recipientEmail, "recipientEmail");
  const invitationUrl = safeUrl(input.invitationUrl, "invitationUrl");
  const subject = `${inviterNameValue} invited you to connect on Syntila`;
  return {
    templateId: "person.invitation.v1",
    subject,
    ...renderEmailLayout({
      templateId: "person.invitation.v1",
      subject,
      variant: "action-required",
      eyebrow: "Personal invitation",
      title: "You have been invited to connect",
      intro: `<strong>${inviterName}</strong> invited you to connect on Syntila.`,
      bodyHtml: `<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">Sign in with <strong>${recipientEmail}</strong> to accept the invitation and start a direct conversation.</p>`,
      bodyText: `${inviterNameValue} invited you to connect on Syntila.\n\nSign in with ${input.recipientEmail.trim()} to accept:\n${invitationUrl}`,
      action: { label: "View invitation", url: invitationUrl },
      securityNotice:
        "If you were not expecting this invitation, you can safely ignore this email.",
    }),
  };
}

function renderWelcome(input: WelcomeInput): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const appUrl = safeUrl(input.appUrl, "appUrl");
  const subject = "Welcome to Syntila — your account is ready";
  return {
    templateId: "auth.welcome.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.welcome.v1",
      subject,
      variant: "confirmation",
      eyebrow: "Welcome to Syntila",
      title: "Congratulations! Your account is ready",
      intro: `Congratulations, ${recipientName}! Your Syntila account has been created and your email address is verified.`,
      bodyHtml:
        '<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">Your workspace for AI collaboration and execution is ready. Create or join a Space, connect a Workspace, and start your first conversation.</p>',
      bodyText:
        "Congratulations! Your Syntila account has been created and your email address is verified.\n\nYour workspace for AI collaboration and execution is ready. Create or join a Space, connect a Workspace, and start your first conversation.",
      action: { label: "Open Syntila", url: appUrl },
      securityNotice:
        "You are receiving this email because a new Syntila account was created with this email address.",
    }),
  };
}

function renderAccountDeleted(
  input: AccountDeletedInput,
): RenderedEmailContent {
  const recipientName = safeName(input.recipientName);
  const deletedAt = dateLabel(input.deletedAt);
  const detail = deletedAt ? ` at ${escapeHtml(deletedAt)}` : "";
  const appUrl = input.appUrl ? safeUrl(input.appUrl, "appUrl") : undefined;
  const subject = "Your Syntila account was deleted";
  return {
    templateId: "auth.account-deleted.v1",
    subject,
    ...renderEmailLayout({
      templateId: "auth.account-deleted.v1",
      subject,
      variant: "security-notice",
      eyebrow: "Account security",
      title: "Account deleted",
      intro: `Hi ${recipientName}, your Syntila account was deleted${detail}.`,
      bodyHtml:
        '<p style="margin:20px 0 0;color:#434547;font-size:15px;line-height:24px;">If you did not request this, contact Syntila support as soon as possible.</p>',
      bodyText: `Your Syntila account was deleted${deletedAt ? ` at ${deletedAt}` : ""}. If you did not request this, contact Syntila support as soon as possible.`,
      ...(appUrl ? { action: { label: "Open Syntila", url: appUrl } } : {}),
      securityNotice: "This is an account-security notification.",
    }),
  };
}

export const emailTemplateCatalog = Object.freeze([
  {
    id: "auth.verify-email.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderVerifyEmail,
  },
  {
    id: "auth.verify-email-code.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderVerifyEmailCode,
  },
  {
    id: "auth.reset-password.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderResetPassword,
  },
  {
    id: "auth.password-changed.v1",
    priority: "informational",
    category: "security",
    availability: "planned",
    variant: "security-notice",
    render: renderPasswordChanged,
  },
  {
    id: "auth.confirm-email-change.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderConfirmEmailChange,
  },
  {
    id: "auth.email-changed.v1",
    priority: "informational",
    category: "security",
    availability: "planned",
    variant: "security-notice",
    render: renderEmailChanged,
  },
  {
    id: "space.invitation.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderInvitation,
  },
  {
    id: "space.invitation-accepted.v1",
    priority: "informational",
    category: "optional",
    availability: "planned",
    variant: "confirmation",
    render: renderInvitationAccepted,
  },
  {
    id: "space.access-revoked.v1",
    priority: "informational",
    category: "optional",
    availability: "planned",
    variant: "security-notice",
    render: renderAccessRevoked,
  },
  {
    id: "person.invitation.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "action-required",
    render: renderPersonInvitation,
  },
  {
    id: "auth.welcome.v1",
    priority: "essential",
    category: "essential",
    availability: "implemented",
    variant: "confirmation",
    render: renderWelcome,
  },
  {
    id: "auth.account-deleted.v1",
    priority: "informational",
    category: "security",
    availability: "implemented",
    variant: "security-notice",
    render: renderAccountDeleted,
  },
] as const satisfies readonly (EmailTemplateMetadata & {
  readonly render: unknown;
})[]);

const templateById: {
  readonly [TId in EmailTemplateId]: (
    input: EmailTemplateInputMap[TId],
  ) => RenderedEmailContent;
} = {
  "auth.verify-email.v1": renderVerifyEmail,
  "auth.verify-email-code.v1": renderVerifyEmailCode,
  "auth.reset-password.v1": renderResetPassword,
  "auth.password-changed.v1": renderPasswordChanged,
  "auth.confirm-email-change.v1": renderConfirmEmailChange,
  "auth.email-changed.v1": renderEmailChanged,
  "space.invitation.v1": renderInvitation,
  "space.invitation-accepted.v1": renderInvitationAccepted,
  "space.access-revoked.v1": renderAccessRevoked,
  "person.invitation.v1": renderPersonInvitation,
  "auth.welcome.v1": renderWelcome,
  "auth.account-deleted.v1": renderAccountDeleted,
};

function urlForTemplate<TId extends EmailTemplateId>(
  templateId: TId,
  input: EmailTemplateInputMap[TId],
): readonly [string, string][] {
  switch (templateId) {
    case "auth.verify-email.v1":
      return [["verificationUrl", (input as VerifyEmailInput).verificationUrl]];
    case "auth.reset-password.v1":
      return [["resetUrl", (input as ResetPasswordInput).resetUrl]];
    case "auth.confirm-email-change.v1":
      return [
        ["confirmationUrl", (input as ConfirmEmailChangeInput).confirmationUrl],
      ];
    case "space.invitation.v1":
      return [["invitationUrl", (input as SpaceInvitationInput).invitationUrl]];
    case "person.invitation.v1":
      return [
        ["invitationUrl", (input as PersonInvitationInput).invitationUrl],
      ];
    case "auth.welcome.v1":
      return [["appUrl", (input as WelcomeInput).appUrl]];
    case "auth.account-deleted.v1":
      return (input as AccountDeletedInput).appUrl
        ? [["appUrl", (input as AccountDeletedInput).appUrl as string]]
        : [];
    case "auth.verify-email-code.v1":
    case "auth.password-changed.v1":
    case "auth.email-changed.v1":
    case "space.invitation-accepted.v1":
    case "space.access-revoked.v1":
      return [];
  }
}

function validateApprovedUrls<TId extends EmailTemplateId>(
  templateId: TId,
  input: EmailTemplateInputMap[TId],
  options: EmailRenderOptions,
): void {
  const approvedOrigins =
    options.approvedOrigins ?? DEFAULT_APPROVED_EMAIL_ORIGINS;
  const normalizedOrigins = new Set(
    approvedOrigins.map((origin) => {
      try {
        return new URL(origin).origin;
      } catch {
        throw new Error("approvedOrigins must contain valid absolute URLs");
      }
    }),
  );
  if (normalizedOrigins.size === 0) {
    throw new Error("At least one approved email origin is required");
  }
  for (const [field, value] of urlForTemplate(templateId, input)) {
    const normalized = safeUrl(value, field);
    const origin = new URL(normalized).origin;
    if (!normalizedOrigins.has(origin)) {
      throw new Error(
        `${field} origin is not approved for this email template`,
      );
    }
  }
}

export function renderEmail<TId extends EmailTemplateId>(
  templateId: TId,
  input: EmailTemplateInputMap[TId],
  options: EmailRenderOptions = {},
): RenderedEmail {
  const template = templateById[templateId] as
    ((input: EmailTemplateInputMap[TId]) => RenderedEmailContent) | undefined;
  if (!template) throw new Error(`Unknown email template: ${templateId}`);
  validateApprovedUrls(templateId, input, options);
  const content = template(input);
  const metadata = emailTemplateCatalog.find(
    (entry) => entry.id === templateId,
  );
  if (!metadata) throw new Error(`Unknown email template: ${templateId}`);
  return {
    ...content,
    templateVersion: 1,
    metadata: { variant: metadata.variant, category: metadata.category },
  };
}

/** Backwards-compatible name for the phase-1 renderer API. */
export function renderEmailTemplate<TId extends EmailTemplateId>(
  templateId: TId,
  input: EmailTemplateInputMap[TId],
  options: EmailRenderOptions = {},
): RenderedEmail {
  return renderEmail(templateId, input, options);
}
