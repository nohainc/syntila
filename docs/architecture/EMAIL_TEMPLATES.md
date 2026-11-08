# Syntila email template architecture

This document records the Phase 1 audit and the source-controlled template
contract. Rendering is deliberately separate from sender resolution and
Cloudflare Email Sending. Authentication and invitation behavior continues to
use the existing callbacks and delivery service until a later migration phase.

## Event matrix

| Business event | Current source | Template ID | Recipient and security | Priority | Delivery status |
| --- | --- | --- | --- | --- | --- |
| Account verification | Better Auth `emailVerification.sendVerificationEmail` in `apps/cloud/src/auth/better-auth.ts` | `auth.verify-email.v1` | New account email; URL contains a time-limited verification token | Essential | Existing flow; renderer available |
| Password recovery | Better Auth `emailAndPassword.sendResetPassword` | `auth.reset-password.v1` | Account email; URL contains a time-limited reset token | Essential | Existing flow; renderer available |
| Email address change codes | Syntila `/api/auth/change-email/*` handlers in `apps/cloud/src/auth/better-auth.ts` | `auth.verify-email-code.v1` (`purpose: "email-change"`) | First the requested new address, then the existing account email; each gets a 10-minute 6-digit code | Essential | Existing flow; renderer available |
| Email address change link (retired) | None; Better Auth `user.changeEmail` is disabled | `auth.confirm-email-change.v1` | Not sent | Essential | Renderer retained, unused |
| Space invitation | `sendSpaceInvitationEmail` called by `handleCreateSpaceInvitation` | `space.invitation.v1` | Invitee email; invitation URL is scoped to the pending invitation and recipient | Essential | Existing flow; renderer available |
| Invitation accepted | No current application event hook | `space.invitation-accepted.v1` | Appropriate inviter or Space owner after confirmed acceptance | Informational | Planned; renderer available |
| Space access revoked | No current application event hook | `space.access-revoked.v1` | Affected member after confirmed access removal, subject to policy | Informational | Planned; renderer available |
| Password changed | No current application event hook | `auth.password-changed.v1` | Account email after a successful password change | Informational | Planned; renderer available |
| Email address changed | No current application event hook | `auth.email-changed.v1` | Previous/account security recipient after a successful change | Informational | Planned; renderer available |
| Welcome / account activation | No current application event hook | `auth.welcome.v1` | Account email after an explicitly defined activation event | Informational | Planned; renderer available |
| Account deleted | Better Auth `user.deleteUser.afterDelete` | `auth.account-deleted.v1` | Deleted account email after confirmed deletion | Security | Connected to the centralized sender |

Account deletion sends the existing security template after Better Auth has
removed the account and sessions. Delivery is awaited; normalized failures are
logged without failing the already-completed deletion. There is no persisted
retry queue for this notification. Planned rows do not acquire a notification
trigger merely by having a renderer.

## Notification policy

The catalog assigns every template one delivery category:

| Category | Examples | Default behavior |
| --- | --- | --- |
| Essential | Verification, password reset, email-change confirmation, invitation | Always allowed by the relevant flow |
| Security | Password changed, email changed, account deleted | Allowed by the security policy |
| Optional | Invitation accepted, access updates, welcome messages | Disabled unless collaboration updates are enabled |

Optional policy currently has one preference,
`collaborationUpdatesEnabled`. It is deliberately small and is evaluated by
`sendPolicyControlledTemplateEmail` immediately before delivery. Essential and
security messages do not depend on that preference. No Worker completion,
workflow progress, or other routine execution activity is registered as an
email event.

## Aliolo comparison

Aliolo's eight template functions map one-to-one to the eight authentication and
membership IDs above: verification, password recovery, password changed,
email-change verification, email changed, invitation, welcome, and account
deletion. Syntila also keeps explicit contracts for invitation acceptance and
Space access revocation so those future event hooks can use the same layout. The
Syntila implementation keeps that useful event separation while changing the
implementation in three ways:

1. A shared table-based layout owns branding and email-client compatibility.
2. Each event has a typed input contract and produces both HTML and plain text.
3. Template identifiers and availability are explicit, so unsupported events do
   not acquire accidental triggers.

The Aliolo HTML is not copied. Syntila uses the approved Syntila identity,
neutral background, dark navy header, muted purple action, system-safe fonts,
inline styles, and a readable text fallback. The official logo is served from
the deployed email-safe public asset path, with a text identity fallback.

## Source organization and contract

The implementation lives under `apps/cloud/src/email/`:

- `email-types.ts` defines the versioned IDs, event-specific inputs and the
  `RenderedEmail` result, including the four shared presentation variants:
  action required, confirmation, security notice, and informational.
- `email-layout.ts` renders the shared responsive table layout and plain-text
  structure.
- `templates/index.ts` validates inputs and defines the source-controlled event
  renderers and their catalog metadata. Its `renderEmail` API returns a
  subject, HTML body, plain-text body, template version, and safe variant-only
  metadata.
- `email-service.ts` provides `sendTemplateEmail`, which completes rendering
  and validation before calling the sender binding. `sendRenderedEmail` is the
  transport boundary for already-rendered, versioned messages, and the module's
  in-memory mock transport is reserved for tests.
- `notification-policy.ts` assigns the essential, security, and optional
  categories and applies the single collaboration-updates preference without
  creating provider-specific delivery paths.
- `email-config.ts` remains responsible for sender identity, controlled
  fallback, recipient validation, safe delivery metadata, and delivery error
  classification. It is the only module that calls `SYNTILA_EMAIL`.

The renderer accepts typed event data only. Dynamic names, email addresses and
URLs are escaped or validated at the rendering boundary. URLs must be absolute
HTTP(S) URLs with no credentials and must use an explicitly approved
application origin. Arbitrary HTML, scripts, provider credentials and raw
tokens are not accepted as template fragments. Token-bearing URLs are still
treated as security-sensitive by callers and must never be logged. Verification,
reset-password, and email-change templates receive the configured Better Auth
lifetime in minutes and state it in the message. The current configuration is
60 minutes for all three flows; the renderer rejects a missing, zero,
fractional, or negative lifetime rather than inventing one.

The shared layout renders a dark Syntila header, the approved
`syntila_email_logo.png` asset with a versioned URL to refresh email image
caches, product name, event title, optional action button, copy-and-paste
fallback link, security notice, and branded footer. The layout uses the app’s
Precision Indigo accent and neutral palette, with distinct status colors for
confirmation and security notices. The
logo is served from the deployed Syntila app asset path and has an accessible
text/alt fallback; disabling images does not remove the product identity or
instructions. The layout uses inline styles plus a narrow-screen media query,
with system-safe fonts and natural word wrapping for long translated text.

Rendering errors are local validation failures and happen before delivery is
attempted. Delivery failures remain the sender service's normalized statuses:
`sender_not_authorized`, `service_unavailable`, `recipient_rejected`,
`rate_limited`, `temporary_failure`, and `configuration_error`. This boundary
prevents a malformed template from being mistaken for a provider outage and
prevents a provider failure from being hidden as a rendering success.
Rendering has no logging side effects and the returned metadata never contains
URLs, tokens, recipients, or message content. Rendering is deterministic for a
given template version and input: the layout does not inject the current time
or other changing values; event timestamps are included only when supplied
explicitly by a typed event input.

Development fallback logs identify the event without recording authentication,
invitation, or other action URLs. Production delivery logs continue to record
only normalized sender/provider status fields.

## Compatibility requirements

Templates use tables, inline CSS, Arial/Helvetica/system-safe fonts, no
JavaScript, no external fonts, and a maximum content width of 600px. Every
message includes a plain-text alternative. The layout keeps readable contrast
when clients alter colors for dark mode and provides a text product identity
when images are unavailable.

## Preview and QA workflow

`pnpm email:preview` renders every catalog entry with synthetic data into the
ignored `.email-preview/` directory. Open its `index.html` in a browser to
review desktop and narrow-window behavior; the individual `.txt` files provide
the plain-text review surface. Preview rendering does not require or invoke a
Cloudflare binding.

For a controlled delivery test, set `SYNTILA_EMAIL_TEST_RECIPIENTS` to a
comma-separated allowlist containing an address owned by the tester, provide
`CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`, and run:

```text
pnpm email:test-send -- --template auth.verify-email.v1 --recipient you@example.com --confirm
```

The command has no default recipient, requires the explicit `--confirm` flag,
accepts only catalog fixtures, and uses the Cloudflare Email Sending REST
adapter only for this deliberate test. It never reads arbitrary message HTML
or user data. Provider failures are classified without logging response bodies
or credentials.

The preview fixtures cover every template, long human-readable names, action
links, lifecycle notices, and the plain-text output. Structural tests verify
the responsive and dark-mode layout markers, escaping, URL validation, bounded
field lengths, and absence of secret-like fixture data. Rendered HTML files
are deterministic, so reviewers can compare them between changes or capture
client screenshots in Gmail/Outlook test accounts without sending messages.

## Migration boundary

The current Better Auth verification, reset-password, email-change, and Space
invitation callbacks now call the shared renderer before the existing sender
service. Their subjects, trusted links, token lifetimes, fallback behavior and
caller-specific delivery semantics remain unchanged. Planned notification
templates have no automatic event hooks yet.

## Signup page presentation

Signup uses the title **Create your account** without a sign-in switch button.
The verification page shows one instruction above the code field, followed by
verification and resend actions. It has no Edit details or sign-in switch
button; resend confirmation and validation errors remain visible.
