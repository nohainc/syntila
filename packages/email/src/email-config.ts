const DEFAULT_PRIMARY_SENDER = "syntila@conclaveax.com";
const DEFAULT_FALLBACK_SENDER = "vitalii@conclaveax.com";
const DEFAULT_DISPLAY_NAME = "Syntila";
const LEGACY_SENDER = "auth@auth.earthuc.com";

const EMAIL_ADDRESS_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const SENDER_REJECTION_CODES = new Set([
  "sender_not_verified",
  "sender_not_authorized",
  "sender_rejected",
  "from_address_not_verified",
  "from_address_not_authorized",
  "sender_domain_not_verified",
  "sender_domain_not_available",
  "invalid_from_address",
  "e_sender_not_verified",
  "e_sender_domain_not_available",
]);
const RATE_LIMIT_CODES = new Set([
  "rate_limited",
  "rate_limit_exceeded",
  "too_many_requests",
  "e_rate_limit_exceeded",
  "e_daily_limit_exceeded",
]);
const RECIPIENT_REJECTION_CODES = new Set([
  "recipient_rejected",
  "invalid_recipient",
  "recipient_not_found",
  "e_recipient_not_allowed",
  "e_recipient_suppressed",
]);
const CONFIGURATION_ERROR_CODES = new Set([
  "e_validation_error",
  "e_field_missing",
  "e_too_many_recipients",
  "e_too_many_attachments",
  "e_content_too_large",
]);
const SERVICE_UNAVAILABLE_CODES = new Set([
  "service_unavailable",
  "provider_unavailable",
  "e_internal_server",
  "e_not_implemented",
  "e_authentication_upstream",
]);

export interface EmailSenderEnvironment {
  readonly SYNTILA_EMAIL?: EmailTransport;
  readonly SYNTILA_EMAIL_FROM?: string;
  readonly SYNTILA_EMAIL_FALLBACK_FROM?: string;
  readonly SYNTILA_EMAIL_FROM_NAME?: string;
}

export interface EmailTransportMessage {
  readonly to: string;
  readonly from: { readonly email: string; readonly name: string };
  readonly subject: string;
  readonly text?: string;
  readonly html?: string;
}

export interface EmailTransport {
  send(message: EmailTransportMessage): Promise<{ messageId?: string } | void>;
}

export interface EmailSenderConfig {
  readonly primary: string;
  readonly fallback: string;
  readonly displayName: string;
}

export interface OutgoingEmail {
  readonly to: string;
  readonly subject: string;
  readonly text?: string;
  readonly html?: string;
  /** Safe correlation metadata; never forwarded to the provider. */
  readonly templateId?: string;
}

export interface EmailDeliveryResult {
  readonly status: "accepted";
  readonly sender: string;
  readonly usedFallback: boolean;
  readonly messageId?: string;
}

export type EmailDeliveryFailureStatus =
  | "sender_not_authorized"
  | "service_unavailable"
  | "recipient_rejected"
  | "rate_limited"
  | "temporary_failure"
  | "configuration_error";

export class EmailDeliveryError extends Error {
  override readonly name = "EmailDeliveryError";

  constructor(
    readonly status: EmailDeliveryFailureStatus,
    message: string,
    readonly providerCode?: string,
    override readonly cause?: unknown,
  ) {
    super(message);
  }
}

function configuredValue(
  value: string | undefined,
  defaultValue: string,
  fieldName: string,
): string {
  if (value === undefined) return defaultValue;
  const normalized = value.trim();
  if (!normalized) throw new Error(`${fieldName} must not be empty`);
  return normalized;
}

function validateSenderAddress(address: string, fieldName: string): string {
  const normalized = address.trim().toLowerCase();
  if (!EMAIL_ADDRESS_PATTERN.test(normalized)) {
    throw new Error(`${fieldName} must be a valid email address`);
  }
  if (normalized === LEGACY_SENDER) {
    throw new Error(`${fieldName} uses a retired sender address`);
  }
  return normalized;
}

export function validateRecipientAddress(address: string): string {
  const normalized = address.trim();
  if (!EMAIL_ADDRESS_PATTERN.test(normalized)) {
    throw new EmailDeliveryError(
      "recipient_rejected",
      "Recipient email address is invalid",
    );
  }
  if (/[<>"'\r\n]/.test(normalized)) {
    throw new EmailDeliveryError(
      "recipient_rejected",
      "Recipient email address is invalid",
    );
  }
  return normalized;
}

export function resolveEmailSenderConfig(
  env: EmailSenderEnvironment,
): EmailSenderConfig {
  const primary = validateSenderAddress(
    configuredValue(
      env.SYNTILA_EMAIL_FROM,
      DEFAULT_PRIMARY_SENDER,
      "SYNTILA_EMAIL_FROM",
    ),
    "SYNTILA_EMAIL_FROM",
  );
  const fallback = validateSenderAddress(
    configuredValue(
      env.SYNTILA_EMAIL_FALLBACK_FROM,
      DEFAULT_FALLBACK_SENDER,
      "SYNTILA_EMAIL_FALLBACK_FROM",
    ),
    "SYNTILA_EMAIL_FALLBACK_FROM",
  );
  if (primary === fallback) {
    throw new Error(
      "SYNTILA_EMAIL_FROM and SYNTILA_EMAIL_FALLBACK_FROM must differ",
    );
  }

  const displayName = configuredValue(
    env.SYNTILA_EMAIL_FROM_NAME,
    DEFAULT_DISPLAY_NAME,
    "SYNTILA_EMAIL_FROM_NAME",
  );
  return { primary, fallback, displayName };
}

function errorRecord(error: unknown): Record<string, unknown> {
  return error !== null && typeof error === "object"
    ? (error as Record<string, unknown>)
    : {};
}

function normalizedErrorCode(error: unknown): string {
  const record = errorRecord(error);
  const code = record.code ?? record.errorCode ?? record.type;
  return typeof code === "string" || typeof code === "number"
    ? String(code).trim().toLowerCase()
    : "";
}

function numericErrorStatus(error: unknown): number | undefined {
  const status = errorRecord(error).status;
  return typeof status === "number" ? status : undefined;
}

function errorWithStatus(
  error: unknown,
  status: EmailDeliveryFailureStatus,
): EmailDeliveryError {
  if (error instanceof EmailDeliveryError && error.status === status) {
    return error;
  }
  const code = normalizedErrorCode(error) || undefined;
  return new EmailDeliveryError(
    status,
    `Email delivery failed (${status})`,
    code,
    error,
  );
}

export function classifyEmailDeliveryFailure(
  error: unknown,
): EmailDeliveryError {
  if (error instanceof EmailDeliveryError) return error;

  const code = normalizedErrorCode(error);
  const status = numericErrorStatus(error);
  if (isPreAcceptanceSenderRejection(error)) {
    return errorWithStatus(error, "sender_not_authorized");
  }
  if (status === 429 || RATE_LIMIT_CODES.has(code)) {
    return errorWithStatus(error, "rate_limited");
  }
  if (RECIPIENT_REJECTION_CODES.has(code)) {
    return errorWithStatus(error, "recipient_rejected");
  }
  if (CONFIGURATION_ERROR_CODES.has(code)) {
    return errorWithStatus(error, "configuration_error");
  }
  if (
    status === 502 ||
    status === 503 ||
    status === 504 ||
    SERVICE_UNAVAILABLE_CODES.has(code)
  ) {
    return errorWithStatus(error, "service_unavailable");
  }
  return errorWithStatus(error, "temporary_failure");
}

/**
 * Cloudflare may reject an unverified From address before accepting a message.
 * Only those explicit sender errors are safe to retry with another sender.
 * Transport, timeout, recipient, and unknown errors never trigger a second send.
 */
export function isPreAcceptanceSenderRejection(error: unknown): boolean {
  const record = errorRecord(error);
  if (record.accepted === true || record.messageAccepted === true) return false;
  if (record.senderRejected === true && record.accepted !== true) return true;

  return SENDER_REJECTION_CODES.has(normalizedErrorCode(error));
}

export async function sendConfiguredEmail(
  env: EmailSenderEnvironment,
  message: OutgoingEmail,
): Promise<EmailDeliveryResult> {
  if (!env.SYNTILA_EMAIL) {
    throw new EmailDeliveryError(
      "configuration_error",
      "SYNTILA_EMAIL is required to send email",
    );
  }

  const recipient = validateRecipientAddress(message.to);

  let config: EmailSenderConfig;
  try {
    config = resolveEmailSenderConfig(env);
  } catch (error) {
    throw new EmailDeliveryError(
      "configuration_error",
      "Email sender configuration is invalid",
      undefined,
      error,
    );
  }
  const send = (sender: string) =>
    env.SYNTILA_EMAIL!.send({
      to: recipient,
      from: { email: sender, name: config.displayName },
      subject: message.subject,
      ...(message.text === undefined ? {} : { text: message.text }),
      ...(message.html === undefined ? {} : { html: message.html }),
    });

  console.info("email.sender.resolved", {
    sender: config.primary,
    fallbackConfigured: true,
  });
  try {
    const result = await send(config.primary);
    console.info("email.delivery.accepted", {
      templateId: message.templateId ?? "unknown",
      status: "accepted",
      sender: config.primary,
      usedFallback: false,
    });
    return {
      status: "accepted",
      sender: config.primary,
      usedFallback: false,
      messageId: result?.messageId,
    };
  } catch (error) {
    if (!isPreAcceptanceSenderRejection(error)) {
      const failure = classifyEmailDeliveryFailure(error);
      console.warn("email.delivery.failed", {
        templateId: message.templateId ?? "unknown",
        status: failure.status,
        providerCode: failure.providerCode,
      });
      throw failure;
    }
    console.warn("email.sender.primary_rejected", {
      sender: config.primary,
      fallback: config.fallback,
      code: normalizedErrorCode(error) || "unknown",
    });
    try {
      const result = await send(config.fallback);
      console.info("email.delivery.accepted", {
        templateId: message.templateId ?? "unknown",
        status: "accepted",
        sender: config.fallback,
        usedFallback: true,
      });
      return {
        status: "accepted",
        sender: config.fallback,
        usedFallback: true,
        messageId: result?.messageId,
      };
    } catch (fallbackError) {
      const failure = classifyEmailDeliveryFailure(fallbackError);
      console.warn("email.delivery.failed", {
        templateId: message.templateId ?? "unknown",
        status: failure.status,
        providerCode: failure.providerCode,
      });
      throw failure;
    }
  }
}
