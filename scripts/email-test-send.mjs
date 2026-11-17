import {
  emailPreviewFixtures,
  renderEmail,
  sendRenderedEmail,
} from "../packages/email/src/index.ts";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 1) {
  const argument = process.argv[index];
  if (!argument.startsWith("--")) continue;
  const key = argument.slice(2);
  args.set(
    key,
    process.argv[index + 1] && !process.argv[index + 1].startsWith("--")
      ? process.argv[++index]
      : true,
  );
}

if (args.get("confirm") !== true) {
  throw new Error(
    "Refusing to send: add --confirm to explicitly approve this test delivery",
  );
}

const templateId = args.get("template");
const recipient =
  typeof args.get("recipient") === "string"
    ? args.get("recipient").trim().toLowerCase()
    : "";
if (typeof templateId !== "string" || !(templateId in emailPreviewFixtures)) {
  throw new Error(
    "Choose a template from the local preview catalog with --template",
  );
}
if (!recipient) throw new Error("An explicit --recipient is required");

const approvedRecipients = new Set(
  (process.env.SYNTILA_EMAIL_TEST_RECIPIENTS ?? "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean),
);
if (approvedRecipients.size === 0 || !approvedRecipients.has(recipient)) {
  throw new Error(
    "Refusing to send: --recipient must be listed in SYNTILA_EMAIL_TEST_RECIPIENTS",
  );
}

const accountId = process.env.CLOUDFLARE_ACCOUNT_ID?.trim();
const apiToken = process.env.CLOUDFLARE_API_TOKEN?.trim();
if (!accountId || !apiToken) {
  throw new Error(
    "CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN are required for test delivery",
  );
}

const rendered = renderEmail(templateId, emailPreviewFixtures[templateId]);
const transport = {
  async send(message) {
    const response = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/email/sending/send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          to: message.to,
          from: { address: message.from.email, name: message.from.name },
          subject: message.subject,
          html: message.html,
          text: message.text,
        }),
      },
    );
    let payload = {};
    try {
      const parsed = await response.json();
      payload = parsed && typeof parsed === "object" ? parsed : {};
    } catch {
      // Keep the error classification bounded when the provider returns no JSON.
    }
    if (!response.ok || payload.success === false) {
      const providerMessage = String(
        payload.errors?.[0]?.message ?? "",
      ).toLowerCase();
      const code =
        response.status === 429
          ? "rate_limited"
          : /sender|from|domain/.test(providerMessage) &&
              /verif|authoriz|valid/.test(providerMessage)
            ? "sender_not_authorized"
            : /recipient|destination/.test(providerMessage)
              ? "recipient_rejected"
              : response.status >= 500
                ? "service_unavailable"
                : "configuration_error";
      throw { code, status: response.status };
    }
    return { messageId: payload.result?.delivered?.[0] };
  },
};

const result = await sendRenderedEmail(
  {
    SYNTILA_EMAIL: transport,
    ...(process.env.SYNTILA_EMAIL_FROM
      ? { SYNTILA_EMAIL_FROM: process.env.SYNTILA_EMAIL_FROM }
      : {}),
    ...(process.env.SYNTILA_EMAIL_FALLBACK_FROM
      ? {
          SYNTILA_EMAIL_FALLBACK_FROM: process.env.SYNTILA_EMAIL_FALLBACK_FROM,
        }
      : {}),
    ...(process.env.SYNTILA_EMAIL_FROM_NAME
      ? { SYNTILA_EMAIL_FROM_NAME: process.env.SYNTILA_EMAIL_FROM_NAME }
      : {}),
  },
  { to: recipient, rendered },
);
console.log(
  `Accepted ${rendered.templateId} for ${recipient} from ${result.sender}`,
);
