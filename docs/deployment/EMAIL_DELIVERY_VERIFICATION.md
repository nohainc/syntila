# Email delivery verification

The sender migration has two separate verification layers:

1. The automated tests verify sender resolution, controlled fallback, failure
   classification, authentication/invitation behavior, and diagnostic
   redaction without sending mail.
2. A production smoke test verifies that Cloudflare accepts and delivers a
   message from each authorized sender.

The production smoke test is deliberately manual. It sends real mail and must
not run in normal CI or deployment jobs.

## Preconditions

- The `conclaveax.com` domain is enabled for Cloudflare Email Sending.
- Both `syntila@conclaveax.com` and `vitalii@conclaveax.com` are authorized sender
  identities in the same Cloudflare account.
- The recipient is a mailbox controlled by the operator and is suitable for a
  disposable test message.
- The API token has only the Email Sending permission required for the test.

Confirm the domain and sender setup before sending:

```bash
wrangler email sending list
```

## Controlled sender test

Set the account, token, and recipient only in the shell running the test. Do
not put them in source, CI variables intended for builds, or command history.

```bash
export CLOUDFLARE_ACCOUNT_ID="..."
export CLOUDFLARE_API_TOKEN="..."
export EMAIL_TEST_RECIPIENT="operator@example.com"
```

Send one message from each identity using the Cloudflare Email Sending REST
API:

```bash
for sender in syntila@conclaveax.com vitalii@conclaveax.com; do
  curl --fail-with-body \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/email/sending/send" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --header "Content-Type: application/json" \
    --data "$(node -e 'const [sender, recipient] = process.argv.slice(1); console.log(JSON.stringify({to: recipient, from: `Syntila <${sender}>`, subject: `Syntila sender smoke test (${sender})`, text: `Controlled sender verification for ${sender}.`}))' "$sender" "$EMAIL_TEST_RECIPIENT")"
done
```

Record the response for each sender. A successful API response means the
message was accepted by Cloudflare; it does not prove inbox delivery. Confirm
the following in the recipient mailbox and message headers:

- the visible sender is `Syntila` with the expected address;
- the message arrives at the intended mailbox and at an external-domain test
  mailbox when one is available;
- SPF, DKIM, and DMARC pass for `conclaveax.com`;
- replies to `syntila@conclaveax.com` reach the configured mailbox.

Run the authentication verification and invitation verification separately
through the normal application flows. Check that verification, reset, change
email, and invitation links work and that a single operation produces at most
one message. Do not induce a provider timeout to test fallback: an ambiguous
timeout is intentionally not retried because the provider may already have
accepted the message.

## Automated checks

The focused Cloud test suite covers the deterministic parts of this runbook:

```bash
pnpm --dir apps/cloud exec vitest run \
  test/email-config.test.ts \
  test/auth.test.ts \
  test/invitation-email.test.ts
```

The configuration gate is side-effect free:

```bash
pnpm email:config-check
```

Neither command sends email. Real delivery evidence must be recorded from the
controlled smoke test above and retained with the deployment release record.

## Production rollout and rollback

Before deployment, every item must be checked by the release operator:

- [ ] Primary sender is verified in Cloudflare.
- [ ] Fallback sender is verified in Cloudflare.
- [ ] Google Connect receiving and reply routing are tested.
- [ ] Sender configuration is centralized and the production Wrangler values
      are current.
- [ ] Authentication and invitation tests pass.
- [ ] Fallback behavior has been tested without duplicate messages.
- [ ] A known-good sender configuration is recorded for rollback.
- [ ] The operator has a recipient mailbox and a release record for the smoke
      test evidence.

Use this order for the release:

1. Confirm both sender identities and DNS authentication in Cloudflare and
   Google Connect.
2. Run the focused tests and `pnpm email:config-check`.
3. Record the currently deployed sender configuration as the rollback point.
4. Deploy the Worker configuration and verify that the `SYNTILA_EMAIL`
   binding remains present.
5. Send one controlled verification email from the primary sender, then run
   the authentication and invitation checks.
6. Confirm the visible sender, authentication headers, reply routing, and
   delivery errors before declaring the release complete.

Keep the previous authorized sender configuration available until all checks
are complete. If delivery fails, restore that known-good configuration and
redeploy. Do not depend on the application fallback when Cloudflare Email
Sending itself is unavailable, and do not weaken email verification or reset
security to recover from a delivery incident.

After verification, remove any remaining legacy sender configuration from
deployment systems and operational notes. The configuration validator checks
the active authentication and invitation modules, Wrangler configurations,
and the retained legacy-address rejection guard.
