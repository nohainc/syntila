import {
  sendConfiguredEmail,
  type EmailTransport,
  type EmailTransportMessage,
  type EmailDeliveryResult,
  type EmailSenderEnvironment,
} from "./email-config.js";
import { renderEmail } from "./templates/index.js";
import {
  decideEmailNotification,
  type EmailNotificationPreferences,
} from "./notification-policy.js";
import type {
  EmailRenderOptions,
  EmailTemplateId,
  EmailTemplateInputMap,
  RenderedEmail,
} from "./email-types.js";

export interface SendTemplateEmailParams<TId extends EmailTemplateId> {
  readonly to: string;
  readonly templateId: TId;
  readonly input: EmailTemplateInputMap[TId];
  readonly renderOptions?: EmailRenderOptions;
}

export interface SendRenderedEmailParams {
  readonly to: string;
  readonly rendered: RenderedEmail;
}

export interface SkippedEmailNotification {
  readonly status: "skipped";
  readonly reason: "notification_policy";
}

export type PolicyEmailDeliveryResult =
  EmailDeliveryResult | SkippedEmailNotification;

export async function sendRenderedEmail(
  env: EmailSenderEnvironment,
  params: SendRenderedEmailParams,
): Promise<EmailDeliveryResult> {
  return sendConfiguredEmail(env, {
    to: params.to,
    subject: params.rendered.subject,
    html: params.rendered.html,
    text: params.rendered.text,
    templateId: params.rendered.templateId,
  });
}

/**
 * Render completely before invoking the provider. A rendering error therefore
 * cannot result in a partial or empty message being submitted.
 */
export async function sendTemplateEmail<TId extends EmailTemplateId>(
  env: EmailSenderEnvironment,
  params: SendTemplateEmailParams<TId>,
): Promise<EmailDeliveryResult> {
  const rendered = renderEmail(
    params.templateId,
    params.input,
    params.renderOptions,
  );
  return sendRenderedEmail(env, { to: params.to, rendered });
}

/**
 * Apply optional-notification policy immediately before delivery. Essential
 * and security templates remain unaffected; optional collaboration events are
 * skipped unless the single collaboration preference is enabled.
 */
export async function sendPolicyControlledTemplateEmail<
  TId extends EmailTemplateId,
>(
  env: EmailSenderEnvironment,
  params: SendTemplateEmailParams<TId> & {
    readonly notificationPreferences?: EmailNotificationPreferences;
  },
): Promise<PolicyEmailDeliveryResult> {
  const decision = decideEmailNotification(
    params.templateId,
    params.notificationPreferences,
  );
  if (!decision.allowed) {
    return { status: "skipped", reason: "notification_policy" };
  }
  return sendTemplateEmail(env, params);
}

export interface MockEmailTransport extends EmailTransport {
  readonly messages: readonly EmailTransportMessage[];
}

/** Explicit in-memory transport for unit and integration tests only. */
export function createMockEmailTransport(): MockEmailTransport {
  const messages: EmailTransportMessage[] = [];
  return {
    messages,
    async send(message) {
      messages.push(message);
      return { messageId: `mock-${messages.length}` };
    },
  };
}
