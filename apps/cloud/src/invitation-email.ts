import type { SecurityEnv } from "./routes/handlers.js";
import { classifyEmailDeliveryFailure } from "./email/email-config.js";
import { sendTemplateEmail } from "./email/email-service.js";

export function resolveAppUrl(request: Request, env: SecurityEnv): string {
  if (env.SYNTILA_APP_URL && env.SYNTILA_APP_URL.trim().length > 0) {
    return env.SYNTILA_APP_URL.trim().replace(/\/+$/, "");
  }
  if (env.BETTER_AUTH_URL && env.BETTER_AUTH_URL.trim().length > 0) {
    return env.BETTER_AUTH_URL.trim().replace(/\/+$/, "");
  }
  try {
    const url = new URL(request.url);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "https://conclaveax.com";
  }
}

export interface SendInvitationEmailParams {
  readonly recipientEmail: string;
  readonly inviterName: string;
  readonly spaceName: string;
  readonly role: string;
  readonly appUrl: string;
}

export async function sendSpaceInvitationEmail(
  env: SecurityEnv,
  params: SendInvitationEmailParams,
): Promise<boolean> {
  const { recipientEmail, inviterName, spaceName, role, appUrl } = params;

  if (!env.SYNTILA_EMAIL) {
    if (
      env.SYNTILA_ENVIRONMENT === "development" ||
      env.SYNTILA_ENVIRONMENT === "test"
    ) {
      console.info("invitation.email.development", {
        recipientEmail,
        inviterName,
        spaceName,
        role,
      });
      return true;
    }
    console.warn("SYNTILA_EMAIL is not configured; invitation email skipped");
  }

  try {
    const configuredOrigin = env.SYNTILA_APP_URL ?? env.BETTER_AUTH_URL;
    const approvedOrigin = configuredOrigin
      ? new URL(configuredOrigin).origin
      : new URL(appUrl).origin;
    await sendTemplateEmail(env, {
      to: recipientEmail,
      templateId: "space.invitation.v1",
      input: {
        inviterName,
        spaceName,
        role,
        invitationUrl: appUrl,
        recipientEmail,
      },
      renderOptions: { approvedOrigins: [approvedOrigin] },
    });
    return true;
  } catch (error) {
    const failure = classifyEmailDeliveryFailure(error);
    console.error("Failed to send invitation email", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
    return false;
  }
}

export interface SendPersonInvitationEmailParams {
  readonly recipientEmail: string;
  readonly inviterName: string;
  readonly appUrl: string;
}

export async function sendPersonInvitationEmail(
  env: SecurityEnv,
  params: SendPersonInvitationEmailParams,
): Promise<boolean> {
  const { recipientEmail, inviterName, appUrl } = params;

  if (!env.SYNTILA_EMAIL) {
    if (
      env.SYNTILA_ENVIRONMENT === "development" ||
      env.SYNTILA_ENVIRONMENT === "test"
    ) {
      console.info("person.invitation.email.development", {
        recipientEmail,
        inviterName,
      });
      return true;
    }
    console.warn(
      "SYNTILA_EMAIL is not configured; personal invitation email skipped",
    );
  }

  try {
    const configuredOrigin = env.SYNTILA_APP_URL ?? env.BETTER_AUTH_URL;
    const approvedOrigin = configuredOrigin
      ? new URL(configuredOrigin).origin
      : new URL(appUrl).origin;
    await sendTemplateEmail(env, {
      to: recipientEmail,
      templateId: "person.invitation.v1",
      input: {
        inviterName,
        recipientEmail,
        invitationUrl: appUrl,
      },
      renderOptions: { approvedOrigins: [approvedOrigin] },
    });
    return true;
  } catch (error) {
    const failure = classifyEmailDeliveryFailure(error);
    console.error("Failed to send personal invitation email", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
    return false;
  }
}
