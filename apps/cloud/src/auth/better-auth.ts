import { prepareBackendAccountDeletion, syncBackendProfile } from "../backend-calls.js";
import {
  classifyEmailDeliveryFailure,
  EmailDeliveryError,
  type EmailSenderEnvironment,
} from "../email/email-config.js";
import { sendTemplateEmail } from "../email/email-service.js";
import type { EmailTemplateInputMap } from "../email/email-types.js";
import { betterAuth } from "better-auth";
import { passkey } from "@better-auth/passkey";
import {
  recordAuthAuditEvent,
  recordAuthMetric,
  safeAuthProvider,
} from "./observability.js";

type SocialProviderCredentials = {
  clientId: string;
  clientSecret: string;
  scope: string[];
};

const AUTH_EMAIL_LINK_EXPIRATION_SECONDS = 60 * 60;
const AUTH_EMAIL_LINK_EXPIRATION_MINUTES =
  AUTH_EMAIL_LINK_EXPIRATION_SECONDS / 60;
const SIGNUP_OTP_EXPIRATION_SECONDS = 10 * 60;
const SIGNUP_OTP_EXPIRATION_MINUTES = SIGNUP_OTP_EXPIRATION_SECONDS / 60;
const SIGNUP_OTP_MAX_ATTEMPTS = 5;
const SIGNUP_OTP_PREFIX = "signup-otp:";
const EMAIL_CHANGE_OTP_PREFIX = "email-change-otp:";

export type BetterAuthRuntimeEnv = Pick<Env, "SYNTILA_DB"> &
  EmailSenderEnvironment & {
    SYNTILA_ENVIRONMENT: string;
    SYNTILA_E2E?: string;
    BETTER_AUTH_SECRET?: string;
    BETTER_AUTH_URL?: string;
    BETTER_AUTH_TRUSTED_ORIGINS?: string;
    BETTER_AUTH_RP_ID?: string;
    BETTER_AUTH_ORIGIN?: string;
    SYNTILA_APP_URL?: string;
    SYNTILA_AUTH_GITHUB_CLIENT_ID?: string;
    SYNTILA_AUTH_GITHUB_CLIENT_SECRET?: string;
    SYNTILA_AUTH_GOOGLE_CLIENT_ID?: string;
    SYNTILA_AUTH_GOOGLE_CLIENT_SECRET?: string;
  };

function providerCredentials(
  clientId: string | undefined,
  clientSecret: string | undefined,
  scope: string[],
): SocialProviderCredentials | undefined {
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret, scope };
}

export type SocialProviderId = "github" | "google";

/** True when both OAuth credentials for the provider are configured. */
export function isSocialProviderConfigured(
  env: Pick<
    BetterAuthRuntimeEnv,
    | "SYNTILA_AUTH_GITHUB_CLIENT_ID"
    | "SYNTILA_AUTH_GITHUB_CLIENT_SECRET"
    | "SYNTILA_AUTH_GOOGLE_CLIENT_ID"
    | "SYNTILA_AUTH_GOOGLE_CLIENT_SECRET"
  >,
  provider: SocialProviderId,
): boolean {
  return provider === "google"
    ? Boolean(
        env.SYNTILA_AUTH_GOOGLE_CLIENT_ID &&
        env.SYNTILA_AUTH_GOOGLE_CLIENT_SECRET,
      )
    : Boolean(
        env.SYNTILA_AUTH_GITHUB_CLIENT_ID &&
        env.SYNTILA_AUTH_GITHUB_CLIENT_SECRET,
      );
}

/**
 * Origin of the browser application when it differs from the API origin (local
 * development serves the Flutter app and the Worker on different ports). In
 * production both share one origin and this equals the request origin.
 */
export function configuredAppOrigin(
  env: Pick<BetterAuthRuntimeEnv, "SYNTILA_APP_URL">,
): string | undefined {
  if (!env.SYNTILA_APP_URL) return undefined;
  try {
    return new URL(env.SYNTILA_APP_URL).origin;
  } catch {
    return undefined;
  }
}

function isSignUpRequest(request: Request | undefined): boolean {
  if (!request) return false;
  try {
    return new URL(request.url).pathname.endsWith("/sign-up/email");
  } catch {
    return false;
  }
}

async function sendAuthEmail<
  TId extends
    | "auth.verify-email.v1"
    | "auth.reset-password.v1"
    | "auth.confirm-email-change.v1",
>(
  env: BetterAuthRuntimeEnv,
  user: { email: string; name?: string | null },
  templateId: TId,
  input: EmailTemplateInputMap[TId],
  action: string,
  actionUrl: string,
): Promise<void> {
  if (!env.SYNTILA_EMAIL) {
    if (env.SYNTILA_ENVIRONMENT === "development") {
      console.info("auth.email.development", {
        action,
        email: user.email,
      });
      return;
    }
    throw new EmailDeliveryError(
      "configuration_error",
      "SYNTILA_EMAIL is required for authentication emails",
    );
  }

  const configuredOrigin = env.BETTER_AUTH_URL
    ? new URL(env.BETTER_AUTH_URL).origin
    : new URL(actionUrl).origin;
  await sendTemplateEmail(env, {
    to: user.email,
    templateId,
    input,
    renderOptions: { approvedOrigins: [configuredOrigin] },
  });
}

async function sendSignUpVerificationCodeEmail(
  env: BetterAuthRuntimeEnv,
  recipient: { email: string; name?: string | null },
  verificationCode: string,
  purpose: "sign-up" | "email-change" = "sign-up",
): Promise<void> {
  if (!env.SYNTILA_EMAIL) {
    if (env.SYNTILA_ENVIRONMENT === "development") {
      console.info("auth.signup_otp.development", {
        email: recipient.email,
        verificationCode,
        purpose,
      });
      return;
    }
    throw new EmailDeliveryError(
      "configuration_error",
      "SYNTILA_EMAIL is required for authentication emails",
    );
  }

  await sendTemplateEmail(env, {
    to: recipient.email,
    templateId: "auth.verify-email-code.v1",
    input: {
      recipientName: recipient.name,
      verificationCode,
      expiresInMinutes: SIGNUP_OTP_EXPIRATION_MINUTES,
      purpose,
    },
  });
}

async function sendWelcomeEmail(
  env: BetterAuthRuntimeEnv,
  recipient: { email: string; name?: string | null },
): Promise<void> {
  const rawEmail = recipient.email?.trim();
  if (!rawEmail) return;
  if (!env.SYNTILA_EMAIL) {
    if (env.SYNTILA_ENVIRONMENT === "development") {
      console.info("auth.welcome.development", {
        email: rawEmail,
      });
      return;
    }
    return;
  }

  const appOrigin =
    configuredAppOrigin(env) ??
    (env.BETTER_AUTH_URL
      ? (() => {
          try {
            return new URL(env.BETTER_AUTH_URL).origin;
          } catch {
            return undefined;
          }
        })()
      : undefined) ??
    "https://syntila.app";

  try {
    await sendTemplateEmail(env, {
      to: rawEmail,
      templateId: "auth.welcome.v1",
      input: {
        recipientName: recipient.name,
        appUrl: appOrigin,
      },
      renderOptions: { approvedOrigins: [appOrigin] },
    });
  } catch (error) {
    const failure = classifyEmailDeliveryFailure(error);
    console.error("auth.welcome_email.failed", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
  }
}

function generateSixDigitCode(): string {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  const value = (bytes[0] ?? 0) % 1_000_000;
  return value.toString().padStart(6, "0");
}

function signupOtpIdentifier(email: string): string {
  return `${SIGNUP_OTP_PREFIX}${email.trim().toLowerCase()}`;
}

function parseStoredOtpValue(
  rawValue: string,
): { code: string; attempts: number } | null {
  const [code, attemptsRaw] = rawValue.split(":");
  if (!code || !/^\d{6}$/.test(code)) return null;
  const attempts = Number.parseInt(attemptsRaw ?? "0", 10);
  return {
    code,
    attempts: Number.isFinite(attempts) && attempts >= 0 ? attempts : 0,
  };
}

function jsonAuthError(
  status: number,
  code: string,
  message: string,
): Response {
  return new Response(JSON.stringify({ code, message, error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Build the Better Auth instance for one Worker request.
 *
 * Better Auth is intentionally confined to this module. The rest of Cloud
 * consumes IdentityService instead of importing Better Auth APIs.
 */
export function createBetterAuth(
  env: BetterAuthRuntimeEnv,
  options?: { sendOnSignUp?: boolean },
) {
  return betterAuth(buildBetterAuthOptions(env, options));
}

export function buildBetterAuthOptions(
  env: BetterAuthRuntimeEnv,
  options?: { sendOnSignUp?: boolean },
) {
  if (!env.BETTER_AUTH_SECRET) {
    throw new Error("BETTER_AUTH_SECRET is required to use Better Auth");
  }

  const github = providerCredentials(
    env.SYNTILA_AUTH_GITHUB_CLIENT_ID,
    env.SYNTILA_AUTH_GITHUB_CLIENT_SECRET,
    ["user:email"],
  );
  const google = providerCredentials(
    env.SYNTILA_AUTH_GOOGLE_CLIENT_ID,
    env.SYNTILA_AUTH_GOOGLE_CLIENT_SECRET,
    ["email", "profile"],
  );
  const trustedOrigins = [
    "https://syntila.app",
    "http://localhost:3000",
    "http://localhost:8080",
    "http://localhost:8787",
    "http://127.0.0.1:3000",
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8787",
    ...(env.BETTER_AUTH_URL ? [new URL(env.BETTER_AUTH_URL).origin] : []),
    ...(configuredAppOrigin(env) ? [configuredAppOrigin(env) as string] : []),
    ...(env.BETTER_AUTH_TRUSTED_ORIGINS?.split(",") ?? []),
  ]
    .map((origin) => origin.trim().replace(/\/$/, ""))
    .filter(
      (origin, index, origins) =>
        origin.length > 0 && origins.indexOf(origin) === index,
    );

  const passkeyOptions = {
    rpID: env.BETTER_AUTH_RP_ID,
    rpName: "Syntila",
    origin: env.BETTER_AUTH_ORIGIN,
    schema: {
      passkey: {
        modelName: "passkeys",
        fields: {
          publicKey: "public_key",
          userId: "user_id",
          credentialID: "credential_id",
          deviceType: "device_type",
          backedUp: "backed_up",
          createdAt: "created_at",
        },
      },
    },
    authentication: {
      afterVerification: async ({
        clientData,
      }: {
        clientData: { id?: string };
      }) => {
        const credentialId = clientData.id;
        if (!credentialId) return;
        await env.SYNTILA_DB.prepare(
          `INSERT INTO auth_step_up_events
             (id, user_id, method, created_at)
           SELECT ?1, user_id, 'passkey', ?2
           FROM passkeys WHERE credential_id = ?3`,
        )
          .bind(crypto.randomUUID(), new Date().toISOString(), credentialId)
          .run();
      },
    },
  };

  const requestFromContext = (context: unknown): Request | undefined => {
    if (!context || typeof context !== "object") return undefined;
    const request = (context as { request?: unknown }).request;
    return request instanceof Request ? request : undefined;
  };
  const providerFromContext = (context: unknown): string | undefined => {
    const request = requestFromContext(context);
    if (!request) return undefined;
    const path = new URL(request.url).pathname;
    const match = path.match(
      /(?:sign-in|callback|link-social)\/(github|google|passkey)/,
    );
    return safeAuthProvider(match?.[1]);
  };

  return {
    database: env.SYNTILA_DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    user: {
      modelName: "users",
      fields: {
        name: "display_name",
        image: "avatar_url",
        emailVerified: "email_verified",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
      // Email changes use the Syntila two-step one-time-code flow
      // (`/api/auth/change-email/*`); Better Auth's link flow stays disabled.
      changeEmail: { enabled: false },
      deleteUser: {
        enabled: true,
        beforeDelete: async (user: { id: string }) => {
          // The backend cleans up Spaces, connections and avatars first;
          // if it cannot confirm, the account is not deleted.
          await prepareBackendAccountDeletion(env as never, user.id);
        },
        afterDelete: async (user: { email: string; name?: string | null }) => {
          try {
            await sendTemplateEmail(env, {
              to: user.email,
              templateId: "auth.account-deleted.v1",
              input: {
                recipientName: user.name,
                deletedAt: new Date().toISOString(),
              },
            });
          } catch (error) {
            // Deletion has already committed; delivery failure must not make
            // the client believe its account still exists.
            const failure = classifyEmailDeliveryFailure(error);
            console.error("auth.account_deleted_email.failed", {
              status: failure.status,
              providerCode: failure.providerCode,
            });
          }
        },
      },
    },
    account: {
      modelName: "auth_accounts",
      fields: {
        userId: "user_id",
        accountId: "account_id",
        providerId: "provider_id",
        accessToken: "access_token",
        refreshToken: "refresh_token",
        idToken: "id_token",
        accessTokenExpiresAt: "access_token_expires_at",
        refreshTokenExpiresAt: "refresh_token_expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
      encryptOAuthTokens: true,
      accountLinking: {
        enabled: true,
        disableImplicitLinking: true,
        trustedProviders: ["github", "google"],
        // Explicit linking proves control of the signed-in Syntila session
        // and the provider account; their email addresses may differ.
        allowDifferentEmails: true,
      },
    },
    verification: {
      modelName: "auth_verifications",
      fields: {
        expiresAt: "expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
    },
    emailVerification: {
      sendOnSignUp: options?.sendOnSignUp ?? true,
      sendVerificationEmail: async (
        {
          user,
          url,
        }: {
          user: { email: string; name?: string | null };
          url: string;
        },
        request?: Request,
      ) => {
        try {
          await sendAuthEmail(
            env,
            user,
            "auth.verify-email.v1",
            {
              recipientName: user.name,
              verificationUrl: url,
              expiresInMinutes: AUTH_EMAIL_LINK_EXPIRATION_MINUTES,
            },
            "Verify your email address",
            url,
          );
        } catch (error) {
          // Sign-up has already created the account when this runs. Failing
          // the request would leave a user who cannot retry sign-up ("already
          // exists") and never learns why. The user can request another link
          // from the sign-in page, and that explicit request still reports
          // the failure to the caller.
          if (!isSignUpRequest(request)) throw error;
          const failure = classifyEmailDeliveryFailure(error);
          console.error("auth.verification_email.signup_failed", {
            status: failure.status,
            providerCode: failure.providerCode,
          });
        }
      },
      expiresIn: AUTH_EMAIL_LINK_EXPIRATION_SECONDS,
    },
    emailAndPassword: {
      enabled: true,
      disableSignUp: false,
      minPasswordLength: 8,
      maxPasswordLength: 128,
      autoSignIn: true,
      revokeSessionsOnPasswordReset: true,
      resetPasswordTokenExpiresIn: AUTH_EMAIL_LINK_EXPIRATION_SECONDS,
      sendResetPassword: async ({
        user,
        url,
      }: {
        user: { email: string; name?: string | null };
        url: string;
      }) =>
        sendAuthEmail(
          env,
          user,
          "auth.reset-password.v1",
          {
            recipientName: user.name,
            resetUrl: url,
            expiresInMinutes: AUTH_EMAIL_LINK_EXPIRATION_MINUTES,
          },
          "Reset your password",
          url,
        ),
    },
    socialProviders: {
      ...(github ? { github } : {}),
      ...(google ? { google } : {}),
    },
    plugins: [passkey(passkeyOptions)],
    databaseHooks: {
      user: {
        create: {
          after: async (user: {
            id: string;
            email: string;
            name?: string | null;
          }) => {
            await sendWelcomeEmail(env, user);
          },
        },
        update: {
          after: async (user: { id: string }) => {
            await syncBackendProfile(env as never, user.id);
          },
        },
      },
      session: {
        create: {
          after: async (
            session: { userId: string; id: string },
            context: unknown,
          ) => {
            try {
              await recordAuthAuditEvent(env.SYNTILA_DB, {
                action: "auth.sign_in",
                outcome: "success",
                userId: session.userId,
                sessionId: session.id,
                provider: providerFromContext(context),
              });
              recordAuthMetric(providerFromContext(context), "success");
            } catch {
              // Authentication must remain available if observability storage is unavailable.
            }
          },
        },
        delete: {
          after: async (session: { userId: string; id: string }) => {
            try {
              await recordAuthAuditEvent(env.SYNTILA_DB, {
                action: "auth.session.revoked",
                outcome: "success",
                userId: session.userId,
                sessionId: session.id,
              });
            } catch {
              // Best-effort audit only.
            }
          },
        },
      },
    },
    session: {
      modelName: "auth_sessions",
      fields: {
        userId: "user_id",
        expiresAt: "expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
        ipAddress: "ip_address",
        userAgent: "user_agent",
      },
      cookieCache: {
        enabled: false,
      },
      expiresIn: 60 * 60 * 24 * 14,
      // Account management (session list, deletion) must work for any valid
      // session; deletion is guarded by typed email confirmation instead.
      freshAge: 0,
      updateAge: 60 * 60 * 24,
      disableSessionRefresh: false,
    },
    trustedOrigins,
    advanced: {
      ...(env.SYNTILA_ENVIRONMENT === "development" &&
      env.SYNTILA_E2E === "true"
        ? { database: { validateSchema: false } }
        : {}),
      useSecureCookies:
        env.SYNTILA_ENVIRONMENT === "production" &&
        Boolean(env.BETTER_AUTH_URL?.startsWith("https://")),
      defaultCookieAttributes: {
        httpOnly: true,
        sameSite: "Lax" as const,
        path: "/",
      },
    },
  };
}

export async function handleBetterAuthRequest(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<Response> {
  if (!env.BETTER_AUTH_SECRET) {
    return new Response(
      JSON.stringify({
        error: "Authentication is not configured on this deployment",
        code: "auth_not_configured",
      }),
      {
        status: 503,
        headers: { "content-type": "application/json" },
      },
    );
  }
  const url = new URL(request.url);
  if (
    request.method === "POST" &&
    url.pathname.endsWith("/api/auth/sign-up/send-code")
  ) {
    return handleSignUpSendCode(request, env);
  }
  if (request.method === "POST") {
    const emailChangeStep = url.pathname.match(
      /\/api\/auth\/change-email\/(send-code|verify-new|confirm)$/,
    )?.[1];
    if (emailChangeStep) {
      const user = await authenticatedUser(request, env);
      if (!user) return jsonAuthError(401, "UNAUTHORIZED", "Sign in again.");
      if (emailChangeStep === "send-code") {
        return handleEmailChangeSendCode(request, env, user);
      }
      return emailChangeStep === "verify-new"
        ? handleEmailChangeVerifyNew(request, env, user)
        : handleEmailChangeConfirm(request, env, user);
    }
    if (url.pathname.endsWith("/api/auth/change-email")) {
      return jsonAuthError(
        410,
        "EMAIL_CHANGE_FLOW_REPLACED",
        "Email changes require one-time codes from the new and current addresses.",
      );
    }
    if (url.pathname.endsWith("/api/auth/delete-user")) {
      const rejected = await requireDeletionEmailConfirmation(request, env);
      if (rejected) return rejected;
    }
  }

  let verifiedSignUpEmail: string | undefined;
  let effectiveRequest = request;
  if (
    request.method === "POST" &&
    url.pathname.endsWith("/api/auth/sign-up/email")
  ) {
    const preVerified = await verifySignUpOtpIfProvided(request, env);
    if (preVerified instanceof Response) {
      return preVerified;
    }
    if (preVerified) {
      verifiedSignUpEmail = preVerified.email;
      effectiveRequest = preVerified.request;
    }
  }

  let auth: ReturnType<typeof createBetterAuth>;
  try {
    auth = createBetterAuth(env, {
      sendOnSignUp: verifiedSignUpEmail === undefined,
    });
  } catch {
    return new Response(
      JSON.stringify({
        error: "Authentication is not configured on this deployment",
        code: "auth_not_configured",
      }),
      {
        status: 503,
        headers: { "content-type": "application/json" },
      },
    );
  }
  const socialSignIn = url.pathname.match(
    /^\/api\/auth\/sign-in\/(github|google)$/,
  );

  if (request.method === "GET" && socialSignIn?.[1]) {
    const appOrigin = configuredAppOrigin(env);
    const callbackURL = safeAuthReturnTo(
      request,
      url.searchParams.get("returnTo"),
      appOrigin,
    );
    // Failures land on the browser application's sign-in page, which shows the
    // provider error code. The return target travels as a path.
    const errorCallbackURL = new URL("/login", appOrigin ?? request.url);
    errorCallbackURL.searchParams.set(
      "returnTo",
      callbackURL.startsWith("/")
        ? callbackURL
        : `${new URL(callbackURL).pathname}${new URL(callbackURL).search}${new URL(callbackURL).hash}`,
    );
    if (!isSocialProviderConfigured(env, socialSignIn[1] as SocialProviderId)) {
      recordAuthMetric(socialSignIn[1], "failure", "invalid_callback");
      errorCallbackURL.searchParams.set("error", "provider_not_configured");
      return new Response(null, {
        status: 302,
        headers: { location: errorCallbackURL.toString() },
      });
    }
    const authRequest = new Request(
      new URL("/api/auth/sign-in/social", request.url),
      {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          origin: request.headers.get("origin") ?? url.origin,
          ...(request.headers.get("cookie")
            ? { cookie: request.headers.get("cookie") as string }
            : {}),
        },
        body: JSON.stringify({
          provider: socialSignIn[1],
          callbackURL,
          errorCallbackURL: errorCallbackURL.toString(),
        }),
      },
    );
    const response = await auth.handler(authRequest);
    if (!response.ok) {
      recordAuthMetric(socialSignIn[1], "failure", "invalid_callback");
      return response;
    }
    const body = (await response.json()) as { url?: unknown };
    if (typeof body.url !== "string") {
      recordAuthMetric(socialSignIn[1], "failure", "invalid_callback");
      return new Response("Authentication provider did not return a redirect", {
        status: 502,
      });
    }
    recordAuthMetric(socialSignIn[1], "success");
    const redirect = new Response(null, {
      status: 302,
      headers: { location: body.url },
    });
    copySetCookieHeaders(response.headers, redirect.headers);
    return redirect;
  }

  const metadata = await requestMetadata(effectiveRequest);
  const before = await sessionSummary(effectiveRequest, env);
  const response = await auth.handler(effectiveRequest);
  const statusOutcome = response.status >= 400 ? "failure" : "success";
  if (verifiedSignUpEmail && statusOutcome === "success") {
    try {
      await env.SYNTILA_DB.prepare(
        `UPDATE users
            SET email_verified = 1, updated_at = ?1
          WHERE lower(email) = ?2`,
      )
        .bind(new Date().toISOString(), verifiedSignUpEmail)
        .run();
    } catch {
      // Best-effort post-signup verification flag update.
    }
  }
  if (metadata.signIn) {
    if (statusOutcome === "failure") {
      recordAuthMetric(metadata.provider, "failure", "invalid_credentials");
      await safeRecord(env, {
        action: "auth.sign_in_failure",
        outcome: "failure",
        provider: metadata.provider,
        reason: "invalid_credentials",
      });
    }
  } else if (before && statusOutcome === "success" && metadata.action) {
    await safeRecord(env, {
      action: metadata.action,
      outcome: "success",
      userId: before.userId,
      sessionId: before.sessionId,
      provider: metadata.provider,
    });
  }
  return response;
}

const SIGNUP_EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function handleSignUpSendCode(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<Response> {
  let body: { email?: unknown; name?: unknown };
  try {
    body = (await request.json()) as { email?: unknown; name?: unknown };
  } catch {
    return jsonAuthError(
      400,
      "invalid_request",
      "Enter a valid email address.",
    );
  }

  const rawEmail = typeof body.email === "string" ? body.email.trim() : "";
  const normalizedEmail = rawEmail.toLowerCase();
  if (
    !normalizedEmail ||
    !SIGNUP_EMAIL_PATTERN.test(normalizedEmail) ||
    /[<>"'\r\n]/.test(normalizedEmail)
  ) {
    return jsonAuthError(400, "invalid_email", "Enter a valid email address.");
  }
  const recipientName =
    typeof body.name === "string" && body.name.trim().length > 0
      ? body.name.trim()
      : null;

  const existingUser = await env.SYNTILA_DB.prepare(
    "SELECT id FROM users WHERE lower(email) = ?1 LIMIT 1",
  )
    .bind(normalizedEmail)
    .first<{ id: string }>();
  if (existingUser) {
    return jsonAuthError(
      409,
      "USER_ALREADY_EXISTS",
      "An account with this email already exists. Sign in instead.",
    );
  }

  const verificationCode = generateSixDigitCode();
  const identifier = signupOtpIdentifier(normalizedEmail);
  const now = new Date();
  const expiresAt = new Date(
    now.getTime() + SIGNUP_OTP_EXPIRATION_SECONDS * 1000,
  );

  await env.SYNTILA_DB.prepare(
    "DELETE FROM auth_verifications WHERE identifier = ?1",
  )
    .bind(identifier)
    .run();

  const verificationId = `ver-${crypto.randomUUID()}`;
  await env.SYNTILA_DB.prepare(
    `INSERT INTO auth_verifications
       (id, identifier, value, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      verificationId,
      identifier,
      `${verificationCode}:0`,
      expiresAt.toISOString(),
      now.toISOString(),
      now.toISOString(),
    )
    .run();

  try {
    await sendSignUpVerificationCodeEmail(
      env,
      { email: normalizedEmail, name: recipientName },
      verificationCode,
    );
  } catch (error) {
    await env.SYNTILA_DB.prepare("DELETE FROM auth_verifications WHERE id = ?1")
      .bind(verificationId)
      .run();
    const failure = classifyEmailDeliveryFailure(error);
    console.error("auth.signup_otp.delivery_failed", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
    const status = failure.status === "rate_limited" ? 429 : 503;
    return jsonAuthError(
      status,
      `email_${failure.status}`,
      "We could not send a verification code to that email address right now. Please check the address and try again.",
    );
  }

  return new Response(
    JSON.stringify({
      sent: true,
      expiresInSeconds: SIGNUP_OTP_EXPIRATION_SECONDS,
    }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    },
  );
}

async function verifySignUpOtpIfProvided(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<{ email: string; request: Request } | Response | null> {
  let payload: Record<string, unknown>;
  try {
    payload = (await request.clone().json()) as Record<string, unknown>;
  } catch {
    return null;
  }

  if (
    !("otp" in payload) ||
    payload.otp === undefined ||
    payload.otp === null
  ) {
    return null;
  }

  const rawEmail =
    typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
  const rawOtp = typeof payload.otp === "string" ? payload.otp.trim() : "";
  if (!rawEmail) {
    return jsonAuthError(400, "invalid_email", "Enter a valid email address.");
  }
  if (!/^\d{6}$/.test(rawOtp)) {
    return jsonAuthError(
      400,
      "INVALID_OTP",
      "Enter the 6-digit verification code sent to your email.",
    );
  }

  const identifier = signupOtpIdentifier(rawEmail);
  const record = await env.SYNTILA_DB.prepare(
    `SELECT id, value, expires_at
       FROM auth_verifications
      WHERE identifier = ?1
      ORDER BY created_at DESC
      LIMIT 1`,
  )
    .bind(identifier)
    .first<{ id: string; value: string; expires_at: string }>();

  if (!record) {
    return jsonAuthError(
      400,
      "OTP_EXPIRED",
      "That verification code has expired or was not found. Request a new code.",
    );
  }

  const expiresAtMs = Date.parse(record.expires_at);
  if (Number.isNaN(expiresAtMs) || expiresAtMs < Date.now()) {
    await env.SYNTILA_DB.prepare("DELETE FROM auth_verifications WHERE id = ?1")
      .bind(record.id)
      .run();
    return jsonAuthError(
      400,
      "OTP_EXPIRED",
      "That verification code has expired. Request a new code.",
    );
  }

  const parsed = parseStoredOtpValue(record.value);
  if (!parsed || parsed.attempts >= SIGNUP_OTP_MAX_ATTEMPTS) {
    await env.SYNTILA_DB.prepare("DELETE FROM auth_verifications WHERE id = ?1")
      .bind(record.id)
      .run();
    return jsonAuthError(
      400,
      "TOO_MANY_ATTEMPTS",
      "Too many invalid attempts. Request a new verification code.",
    );
  }

  if (parsed.code !== rawOtp) {
    const nextAttempts = parsed.attempts + 1;
    if (nextAttempts >= SIGNUP_OTP_MAX_ATTEMPTS) {
      await env.SYNTILA_DB.prepare(
        "DELETE FROM auth_verifications WHERE id = ?1",
      )
        .bind(record.id)
        .run();
      return jsonAuthError(
        400,
        "TOO_MANY_ATTEMPTS",
        "Too many invalid attempts. Request a new verification code.",
      );
    }
    await env.SYNTILA_DB.prepare(
      `UPDATE auth_verifications
          SET value = ?1, updated_at = ?2
        WHERE id = ?3`,
    )
      .bind(
        `${parsed.code}:${nextAttempts}`,
        new Date().toISOString(),
        record.id,
      )
      .run();
    return jsonAuthError(
      400,
      "INVALID_OTP",
      "That verification code is not valid. Check the 6-digit code and try again.",
    );
  }

  await env.SYNTILA_DB.prepare(
    "DELETE FROM auth_verifications WHERE identifier = ?1",
  )
    .bind(identifier)
    .run();

  const forwardedPayload = { ...payload };
  delete forwardedPayload.otp;
  const forwardedRequest = new Request(request.url, {
    method: request.method,
    headers: request.headers,
    body: JSON.stringify(forwardedPayload),
  });
  return { email: rawEmail, request: forwardedRequest };
}

export type AuthenticatedUser = {
  id: string;
  email: string;
  name?: string | null;
};

async function authenticatedUser(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<AuthenticatedUser | undefined> {
  try {
    const session = await createBetterAuth(env).api.getSession({
      headers: request.headers,
    });
    if (!session?.user?.id || !session.user.email) return undefined;
    return {
      id: session.user.id,
      email: session.user.email,
      name: session.user.name,
    };
  } catch {
    return undefined;
  }
}

async function readJsonBody(
  request: Request,
): Promise<Record<string, unknown> | undefined> {
  try {
    const body = (await request.clone().json()) as unknown;
    return body && typeof body === "object"
      ? (body as Record<string, unknown>)
      : undefined;
  } catch {
    return undefined;
  }
}

/** Account deletion requires the signed-in user to retype their email. */
async function requireDeletionEmailConfirmation(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<Response | undefined> {
  const user = await authenticatedUser(request, env);
  if (!user) return jsonAuthError(401, "UNAUTHORIZED", "Sign in again.");
  const body = await readJsonBody(request);
  const confirmation =
    typeof body?.confirmEmail === "string"
      ? body.confirmEmail.trim().toLowerCase()
      : "";
  if (confirmation !== user.email.trim().toLowerCase()) {
    return jsonAuthError(
      400,
      "EMAIL_CONFIRMATION_MISMATCH",
      "Enter your account email address to confirm deletion.",
    );
  }
  return undefined;
}

type EmailChangeState = {
  stage: "new" | "current";
  newEmail: string;
  code: string;
  attempts: number;
};

function emailChangeIdentifier(userId: string): string {
  return `${EMAIL_CHANGE_OTP_PREFIX}${userId}`;
}

function parseEmailChangeState(raw: string): EmailChangeState | null {
  try {
    const value = JSON.parse(raw) as Partial<EmailChangeState>;
    if (
      (value.stage !== "new" && value.stage !== "current") ||
      typeof value.newEmail !== "string" ||
      typeof value.code !== "string" ||
      !/^\d{6}$/.test(value.code)
    ) {
      return null;
    }
    const attempts = Number(value.attempts ?? 0);
    return {
      stage: value.stage,
      newEmail: value.newEmail,
      code: value.code,
      attempts: Number.isFinite(attempts) && attempts >= 0 ? attempts : 0,
    };
  } catch {
    return null;
  }
}

async function storeEmailChangeState(
  env: BetterAuthRuntimeEnv,
  userId: string,
  state: EmailChangeState,
): Promise<string> {
  const identifier = emailChangeIdentifier(userId);
  const now = new Date();
  const expiresAt = new Date(
    now.getTime() + SIGNUP_OTP_EXPIRATION_SECONDS * 1000,
  );
  const id = `ver-${crypto.randomUUID()}`;
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "DELETE FROM auth_verifications WHERE identifier = ?1",
    ).bind(identifier),
    env.SYNTILA_DB.prepare(
      `INSERT INTO auth_verifications
         (id, identifier, value, expires_at, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    ).bind(
      id,
      identifier,
      JSON.stringify(state),
      expiresAt.toISOString(),
      now.toISOString(),
      now.toISOString(),
    ),
  ]);
  return id;
}

async function deliverEmailChangeCode(
  env: BetterAuthRuntimeEnv,
  verificationId: string,
  recipient: { email: string; name?: string | null },
  code: string,
): Promise<Response | undefined> {
  try {
    await sendSignUpVerificationCodeEmail(env, recipient, code, "email-change");
    return undefined;
  } catch (error) {
    await env.SYNTILA_DB.prepare("DELETE FROM auth_verifications WHERE id = ?1")
      .bind(verificationId)
      .run();
    const failure = classifyEmailDeliveryFailure(error);
    console.error("auth.email_change_otp.delivery_failed", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
    return jsonAuthError(
      failure.status === "rate_limited" ? 429 : 503,
      `email_${failure.status}`,
      "We could not send a verification code to that email address right now. Please try again.",
    );
  }
}

async function emailInUse(
  env: BetterAuthRuntimeEnv,
  email: string,
  userId: string,
): Promise<boolean> {
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT id FROM users WHERE lower(email) = ?1 AND id != ?2 LIMIT 1",
  )
    .bind(email, userId)
    .first<{ id: string }>();
  return Boolean(existing);
}

function emailChangeSent(email: string, stage: "new" | "current"): Response {
  return new Response(
    JSON.stringify({
      sent: true,
      stage,
      email,
      expiresInSeconds: SIGNUP_OTP_EXPIRATION_SECONDS,
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

/** Step 1: send a one-time code to the requested new address. */
export async function handleEmailChangeSendCode(
  request: Request,
  env: BetterAuthRuntimeEnv,
  user: AuthenticatedUser,
): Promise<Response> {
  const body = await readJsonBody(request);
  const newEmail =
    typeof body?.newEmail === "string"
      ? body.newEmail.trim().toLowerCase()
      : "";
  if (
    !newEmail ||
    !SIGNUP_EMAIL_PATTERN.test(newEmail) ||
    /[<>"'\r\n]/.test(newEmail)
  ) {
    return jsonAuthError(400, "invalid_email", "Enter a valid email address.");
  }
  if (newEmail === user.email.trim().toLowerCase()) {
    return jsonAuthError(
      400,
      "EMAIL_UNCHANGED",
      "Enter an email address different from your current one.",
    );
  }
  if (await emailInUse(env, newEmail, user.id)) {
    return jsonAuthError(
      409,
      "USER_ALREADY_EXISTS",
      "Another account already uses this email address.",
    );
  }
  const code = generateSixDigitCode();
  const verificationId = await storeEmailChangeState(env, user.id, {
    stage: "new",
    newEmail,
    code,
    attempts: 0,
  });
  const failed = await deliverEmailChangeCode(
    env,
    verificationId,
    { email: newEmail, name: user.name },
    code,
  );
  return failed ?? emailChangeSent(newEmail, "new");
}

/** Validates the submitted code against the user's pending email change. */
async function consumeEmailChangeCode(
  request: Request,
  env: BetterAuthRuntimeEnv,
  user: AuthenticatedUser,
  expectedStage: "new" | "current",
): Promise<{ state: EmailChangeState } | Response> {
  const body = await readJsonBody(request);
  const code = typeof body?.code === "string" ? body.code.trim() : "";
  if (!/^\d{6}$/.test(code)) {
    return jsonAuthError(
      400,
      "INVALID_OTP",
      "Enter the 6-digit verification code.",
    );
  }
  const record = await env.SYNTILA_DB.prepare(
    `SELECT id, value, expires_at FROM auth_verifications
      WHERE identifier = ?1 ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(emailChangeIdentifier(user.id))
    .first<{ id: string; value: string; expires_at: string }>();
  const state = record ? parseEmailChangeState(record.value) : null;
  const expiresAtMs = record ? Date.parse(record.expires_at) : Number.NaN;
  if (
    !record ||
    !state ||
    state.stage !== expectedStage ||
    Number.isNaN(expiresAtMs) ||
    expiresAtMs < Date.now()
  ) {
    if (record) {
      await env.SYNTILA_DB.prepare(
        "DELETE FROM auth_verifications WHERE id = ?1",
      )
        .bind(record.id)
        .run();
    }
    return jsonAuthError(
      400,
      "OTP_EXPIRED",
      "That verification code has expired. Start the email change again.",
    );
  }
  if (state.code !== code) {
    const attempts = state.attempts + 1;
    if (attempts >= SIGNUP_OTP_MAX_ATTEMPTS) {
      await env.SYNTILA_DB.prepare(
        "DELETE FROM auth_verifications WHERE id = ?1",
      )
        .bind(record.id)
        .run();
      return jsonAuthError(
        400,
        "TOO_MANY_ATTEMPTS",
        "Too many invalid attempts. Start the email change again.",
      );
    }
    await env.SYNTILA_DB.prepare(
      "UPDATE auth_verifications SET value = ?1, updated_at = ?2 WHERE id = ?3",
    )
      .bind(
        JSON.stringify({ ...state, attempts }),
        new Date().toISOString(),
        record.id,
      )
      .run();
    return jsonAuthError(
      400,
      "INVALID_OTP",
      "That verification code is not valid. Check the 6-digit code and try again.",
    );
  }
  return { state };
}

/** Step 2: the new address is proven; send a code to the current address. */
export async function handleEmailChangeVerifyNew(
  request: Request,
  env: BetterAuthRuntimeEnv,
  user: AuthenticatedUser,
): Promise<Response> {
  const result = await consumeEmailChangeCode(request, env, user, "new");
  if (result instanceof Response) return result;
  const { state } = result;
  const code = generateSixDigitCode();
  const verificationId = await storeEmailChangeState(env, user.id, {
    stage: "current",
    newEmail: state.newEmail,
    code,
    attempts: 0,
  });
  const failed = await deliverEmailChangeCode(
    env,
    verificationId,
    { email: user.email, name: user.name },
    code,
  );
  return failed ?? emailChangeSent(user.email, "current");
}

/** Step 3: the current address is proven; apply the new email. */
export async function handleEmailChangeConfirm(
  request: Request,
  env: BetterAuthRuntimeEnv,
  user: AuthenticatedUser,
): Promise<Response> {
  const result = await consumeEmailChangeCode(request, env, user, "current");
  if (result instanceof Response) return result;
  const { state } = result;
  const identifier = emailChangeIdentifier(user.id);
  if (await emailInUse(env, state.newEmail, user.id)) {
    await env.SYNTILA_DB.prepare(
      "DELETE FROM auth_verifications WHERE identifier = ?1",
    )
      .bind(identifier)
      .run();
    return jsonAuthError(
      409,
      "USER_ALREADY_EXISTS",
      "Another account already uses this email address.",
    );
  }
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      `UPDATE users SET email = ?1, email_verified = 1, updated_at = ?2
        WHERE id = ?3`,
    ).bind(state.newEmail, new Date().toISOString(), user.id),
    env.SYNTILA_DB.prepare(
      "DELETE FROM auth_verifications WHERE identifier = ?1",
    ).bind(identifier),
  ]);
  await safeRecord(env, {
    action: "auth.email.changed",
    outcome: "success",
    userId: user.id,
  });
  try {
    await syncBackendProfile(env as never, user.id);
  } catch {
    // Profile fan-out is best effort; the email change has committed.
  }
  return new Response(JSON.stringify({ status: true, email: state.newEmail }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/** Preserve Better Auth's OAuth state/CSRF cookies across the redirect shim. */
export function copySetCookieHeaders(source: Headers, target: Headers): void {
  const getSetCookie = (source as Headers & { getSetCookie?: () => string[] })
    .getSetCookie;
  const cookies =
    typeof getSetCookie === "function"
      ? getSetCookie.call(source)
      : source.get("set-cookie")
        ? [source.get("set-cookie") as string]
        : [];
  for (const cookie of cookies) target.append("set-cookie", cookie);
}

type AuthRequestMetadata = {
  action?:
    | "auth.logout"
    | "auth.provider.linked"
    | "auth.provider.unlinked"
    | "auth.passkey.enrolled"
    | "auth.passkey.removed";
  provider?: string;
  signIn?: boolean;
};

async function requestMetadata(request: Request): Promise<AuthRequestMetadata> {
  const path = new URL(request.url).pathname;
  if (path.endsWith("/sign-out")) return { action: "auth.logout" };
  if (path.endsWith("/link-social")) {
    return {
      action: "auth.provider.linked",
      provider: await bodyProvider(request),
    };
  }
  if (path.endsWith("/unlink-account")) {
    return {
      action: "auth.provider.unlinked",
      provider: await bodyProvider(request),
    };
  }
  if (path.endsWith("/add-passkey"))
    return { action: "auth.passkey.enrolled", provider: "passkey" };
  if (path.endsWith("/delete-passkey"))
    return { action: "auth.passkey.removed", provider: "passkey" };
  if (path.endsWith("/sign-in/social") || path.endsWith("/sign-in/passkey")) {
    return { signIn: true, provider: await bodyProvider(request) };
  }
  return {};
}

async function bodyProvider(request: Request): Promise<string | undefined> {
  try {
    const body = (await request.clone().json()) as { provider?: unknown };
    return safeAuthProvider(body.provider);
  } catch {
    return undefined;
  }
}

async function sessionSummary(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<{ userId: string; sessionId: string } | undefined> {
  try {
    const session = await createBetterAuth(env).api.getSession({
      headers: request.headers,
    });
    if (!session?.user?.id || !session.session?.id) return undefined;
    return { userId: session.user.id, sessionId: session.session.id };
  } catch {
    return undefined;
  }
}

async function safeRecord(
  env: BetterAuthRuntimeEnv,
  event: Parameters<typeof recordAuthAuditEvent>[1],
): Promise<void> {
  try {
    await recordAuthAuditEvent(env.SYNTILA_DB, event);
  } catch {
    // Do not turn a successful authentication or account operation into a 500.
  }
}

/**
 * Keep OAuth callbacks on this AX origin and prevent open redirects.
 *
 * Only the request origin and the operator-configured application origin
 * (`SYNTILA_APP_URL`) are accepted. Relative targets resolve against the
 * application origin when one is configured, so local development, where the
 * app and the API use different ports, returns to the app. Same-origin targets
 * stay path-only; a distinct application origin yields an absolute URL.
 */
export function safeAuthReturnTo(
  request: Request,
  value: string | null,
  appOrigin?: string,
): string {
  if (!value)
    return appOrigin && appOrigin !== requestOriginOf(request)
      ? `${appOrigin}/`
      : "/";
  try {
    const requestOrigin = requestOriginOf(request);
    const candidate = new URL(value, appOrigin ?? request.url);
    if (
      (candidate.origin !== requestOrigin && candidate.origin !== appOrigin) ||
      !candidate.pathname.startsWith("/") ||
      candidate.pathname.startsWith("/api/auth")
    ) {
      return "/";
    }
    const target = `${candidate.pathname}${candidate.search}${candidate.hash}`;
    return candidate.origin === requestOrigin
      ? target
      : `${candidate.origin}${target}`;
  } catch {
    return "/";
  }
}

function requestOriginOf(request: Request): string {
  return new URL(request.url).origin;
}
