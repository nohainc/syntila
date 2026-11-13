/**
 * POST /api/internal/email — the VPS backend's email outbox delivers through
 * here so all Syntila email leaves through one Cloudflare `send_email`
 * binding with one sender configuration (primary, then fallback sender).
 *
 * Authentication: HMAC-SHA256 over `${timestamp}.${body}` with the shared
 * secret EMAIL_RELAY_SECRET; the timestamp must be within five minutes. The
 * backend's outbox may retry, so a resend after a lost answer is possible —
 * acceptable for invitation-style email.
 */
import { EmailDeliveryError, sendConfiguredEmail, type EmailSenderEnvironment } from "./email/email-config.js";

type RelayEnv = EmailSenderEnvironment & { EMAIL_RELAY_SECRET?: string };
const WINDOW_SECONDS = 300;
const MAX_BODY_BYTES = 512 * 1024;
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "cache-control": "no-store" } });

function constantTimeEqual(a: Uint8Array, b: Uint8Array) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

const fromBase64Url = (value: string) => {
  try {
    return Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
  } catch {
    return new Uint8Array();
  }
};

async function verify(secret: string, timestamp: string, body: string, signature: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`)));
  return constantTimeEqual(expected, fromBase64Url(signature));
}

export async function handleEmailRelay(request: Request, env: RelayEnv, now = Date.now()): Promise<Response> {
  if (!env.EMAIL_RELAY_SECRET) return json({ error: "Email relay is not configured", code: "configuration_error" }, 503);
  const timestamp = request.headers.get("x-syntila-timestamp") ?? "";
  const signature = request.headers.get("x-syntila-signature") ?? "";
  if (!/^\d{1,12}$/.test(timestamp) || Math.abs(now / 1000 - Number(timestamp)) > WINDOW_SECONDS)
    return json({ error: "Stale or missing timestamp" }, 401);
  const body = await request.text();
  if (body.length > MAX_BODY_BYTES) return json({ error: "Message too large" }, 413);
  if (!signature || !(await verify(env.EMAIL_RELAY_SECRET, timestamp, body, signature)))
    return json({ error: "Invalid signature" }, 401);

  let message: { to?: unknown; subject?: unknown; text?: unknown; html?: unknown; templateId?: unknown };
  try { message = JSON.parse(body); } catch { return json({ error: "Invalid JSON", code: "invalid_request" }, 400); }
  const to = typeof message.to === "string" ? message.to
    : message.to && typeof message.to === "object" && typeof (message.to as { email?: unknown }).email === "string" ? (message.to as { email: string }).email : "";
  if (!to || typeof message.subject !== "string" || (typeof message.text !== "string" && typeof message.html !== "string"))
    return json({ error: "to, subject and text or html are required", code: "invalid_request" }, 400);

  try {
    // The Worker's own sender configuration decides `from` (and its fallback).
    const result = await sendConfiguredEmail(env, {
      to,
      subject: message.subject,
      ...(typeof message.text === "string" ? { text: message.text } : {}),
      ...(typeof message.html === "string" ? { html: message.html } : {}),
      templateId: typeof message.templateId === "string" ? message.templateId : "relay",
    });
    return json({ messageId: result.messageId ?? null, usedFallback: result.usedFallback });
  } catch (error) {
    if (error instanceof EmailDeliveryError) {
      // The backend outbox stops retrying on `invalid_recipient` only.
      const permanent = error.status === "recipient_rejected";
      return json({ error: error.message, code: permanent ? "invalid_recipient" : error.status }, permanent ? 400 : 503);
    }
    return json({ error: "Email delivery failed", code: "service_unavailable" }, 503);
  }
}
