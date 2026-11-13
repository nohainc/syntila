import type {
  EmailPresentationVariant,
  RenderedEmailContent,
} from "./email-types.js";
import { escapeHtml } from "./email-escaping.js";

const PRODUCT_NAME = "Syntila";
const PRODUCT_TAGLINE = "AI collaboration and execution";
export const EMAIL_LOGO_URL =
  "https://syntila.app/assets/assets/branding/syntila_email_logo.png?v=precision-indigo-20261029";

export interface EmailLayoutInput {
  readonly templateId: RenderedEmailContent["templateId"];
  readonly subject: string;
  readonly variant: EmailPresentationVariant;
  readonly eyebrow: string;
  readonly title: string;
  readonly intro: string;
  readonly bodyHtml: string;
  readonly bodyText: string;
  readonly action?: { readonly label: string; readonly url: string };
  readonly securityNotice?: string;
}

/**
 * Keep the layout intentionally conservative for Gmail, Outlook and mobile
 * clients: tables, inline styles, system fonts, and a text-only fallback.
 */
export function renderEmailLayout(
  input: EmailLayoutInput,
): Pick<RenderedEmailContent, "html" | "text"> {
  const variant = {
    "action-required": {
      accent: "#4338ca",
      accentText: "#4338ca",
      noticeBackground: "#e0e7ff",
      noticeBorder: "#c7d2fe",
    },
    confirmation: {
      accent: "#347a64",
      accentText: "#28634f",
      noticeBackground: "#eff8f4",
      noticeBorder: "#c5e7d8",
    },
    "security-notice": {
      accent: "#ad6b19",
      accentText: "#996018",
      noticeBackground: "#fff8eb",
      noticeBorder: "#f0d6a7",
    },
    informational: {
      accent: "#4338ca",
      accentText: "#4338ca",
      noticeBackground: "#e0e7ff",
      noticeBorder: "#c7d2fe",
    },
  }[input.variant];
  const actionHtml = input.action
    ? `<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:28px 0 12px;"><tr><td style="border-radius:8px;background:${variant.accent};"><a href="${escapeHtml(input.action.url)}" style="display:inline-block;padding:13px 22px;border-radius:8px;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:14px;font-weight:700;line-height:20px;text-decoration:none;">${escapeHtml(input.action.label)}</a></td></tr></table><p class="email-fallback" style="margin:0 0 24px;color:#55585b;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;word-break:break-word;">If the button does not work, copy and paste this link into your browser:<br/><a class="email-accent" href="${escapeHtml(input.action.url)}" style="color:${variant.accentText};">${escapeHtml(input.action.url)}</a></p>`
    : "";
  const securityHtml = input.securityNotice
    ? `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:24px 0 0;background:${variant.noticeBackground};border:1px solid ${variant.noticeBorder};border-radius:8px;"><tr><td style="padding:12px 14px;color:#4d5868;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;">${escapeHtml(input.securityNotice)}</td></tr></table>`
    : "";
  const actionText = input.action
    ? `\n${input.action.label}: ${input.action.url}\n`
    : "";
  const securityText = input.securityNotice
    ? `\n${input.securityNotice}\n`
    : "";

  return {
    html: `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="x-apple-disable-message-reformatting"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><style>@media only screen and (max-width:620px){.email-outer{padding:16px 8px!important}.email-card{border-radius:0!important}.email-header{padding:22px!important}.email-content{padding:28px 22px!important}.email-footer{padding:18px 22px 24px!important}}@media (prefers-color-scheme:dark){body,.email-background{background:#17181a!important}.email-card,.email-content,.email-footer{background:#1e2021!important}.email-title{color:#f1f2f4!important}.email-copy,.email-body p,.email-fallback{color:#b6b8ba!important}.email-accent{color:#a5b4fc!important}.email-footer{border-top-color:#2d2e30!important;color:#b6b8ba!important}}</style><title>${escapeHtml(input.subject)}</title></head><body style="margin:0;background:#f1f2f4;color:#17181a;"><table class="email-background" role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#f1f2f4;"><tr><td align="center" class="email-outer" style="padding:32px 12px;"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="email-card" data-template="${escapeHtml(input.templateId)}" style="max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;"><tr><td class="email-header" style="padding:24px 36px 22px;background:#17181a;color:#ffffff;font-family:Arial,Helvetica,sans-serif;"><table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr><td valign="middle"><img src="${EMAIL_LOGO_URL}" width="44" height="44" alt="Syntila" style="display:block;width:44px;height:44px;border:0;border-radius:10px;" /></td><td valign="middle" style="padding-left:12px;"><div style="font-size:20px;font-weight:700;line-height:26px;">${PRODUCT_NAME}</div><div style="margin-top:2px;color:#b6b8ba;font-size:12px;line-height:18px;">${PRODUCT_TAGLINE}</div></td></tr></table></td></tr><tr><td class="email-content" style="padding:36px;font-family:Arial,Helvetica,sans-serif;"><div class="email-accent" style="color:${variant.accentText};font-size:11px;font-weight:700;letter-spacing:1.2px;line-height:18px;text-transform:uppercase;">${escapeHtml(input.eyebrow)}</div><h1 class="email-title" style="margin:10px 0 14px;color:#17181a;font-size:28px;font-weight:700;line-height:36px;word-break:break-word;">${escapeHtml(input.title)}</h1><p class="email-copy" style="margin:0;color:#434547;font-size:16px;line-height:25px;word-break:break-word;">${input.intro}</p><div class="email-body">${input.bodyHtml}</div>${actionHtml}${securityHtml}</td></tr><tr><td class="email-footer" style="padding:20px 36px 28px;border-top:1px solid #d3d5d7;color:#626568;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;">${PRODUCT_NAME} · ${PRODUCT_TAGLINE}</td></tr></table></td></tr></table></body></html>`,
    text: `${PRODUCT_NAME}\n${PRODUCT_TAGLINE}\n\n${input.eyebrow}\n${input.title}\n\n${input.intro}\n\n${input.bodyText}${actionText}${securityText}\n${PRODUCT_NAME} · ${PRODUCT_TAGLINE}`,
  };
}
