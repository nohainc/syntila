/**
 * Calls from this auth Worker to the VPS backend's internal endpoints
 * (`/internal/accounts/:userId/{deletion,profile}`). They are authenticated
 * with a one-minute EdDSA token (`typ: "internal"`) signed by the same key as
 * user tokens, so the backend needs no extra secret.
 */
import { backendUrl, signBackendToken } from "./backend-token.js";
import type { SecurityEnv } from "./routes/http-security.js";

type BackendEnv = SecurityEnv & { SYNTILA_BACKEND_SIGNING_KEY?: string; SYNTILA_BACKEND_URL?: string };

export class BackendUnavailableError extends Error {}

async function callBackend(env: BackendEnv, path: string, body: unknown, attempts: number): Promise<unknown> {
  let lastError: unknown;
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (attempt) await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
    try {
      const { token } = await signBackendToken(env, { sub: "syntila-auth", typ: "internal" }, 60);
      const response = await fetch(`${backendUrl(env)}${path}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10_000),
      });
      if (response.ok) return await response.json();
      lastError = new Error(`backend ${path} answered ${response.status}`);
      if (response.status < 500 && response.status !== 429) break; // not retryable
    } catch (error) {
      lastError = error;
    }
  }
  throw new BackendUnavailableError(lastError instanceof Error ? lastError.message : String(lastError));
}

/**
 * Before an account is deleted: the backend runs the domain cleanup (Spaces,
 * connections, avatars) and anonymizes the user. Throws when the backend could
 * not confirm, which aborts the deletion so data never outlives its account.
 */
export async function prepareBackendAccountDeletion(env: BackendEnv, userId: string): Promise<void> {
  if (!env.SYNTILA_BACKEND_SIGNING_KEY) return; // local development without a backend
  await callBackend(env, `/internal/accounts/${encodeURIComponent(userId)}/deletion`, {}, 3);
}

/** After a profile change: syncs it and notifies the user's connected people. Best effort. */
export async function syncBackendProfile(env: BackendEnv, userId: string): Promise<void> {
  if (!env.SYNTILA_BACKEND_SIGNING_KEY) return;
  const user = await env.SYNTILA_DB.prepare(
    "SELECT email, display_name AS name, avatar_url AS image, email_verified AS emailVerified FROM users WHERE id = ?1",
  ).bind(userId).first<{ email: string; name: string; image: string | null; emailVerified: number }>();
  if (!user) return;
  try {
    await callBackend(env, `/internal/accounts/${encodeURIComponent(userId)}/profile`,
      { email: user.email, name: user.name, image: user.image, emailVerified: user.emailVerified === 1 }, 3);
  } catch (error) {
    // The backend also refreshes name and email from every token it sees.
    console.warn(JSON.stringify({ level: "warn", message: "backend.profile_sync_failed", userId, error: String(error) }));
  }
}
