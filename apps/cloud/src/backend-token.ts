/**
 * Access tokens for the self-hosted Syntila backend (Bun + PostgreSQL on the
 * VPS). Cloudflare stays the authentication authority: it validates the
 * Better Auth web and desktop sessions and issues a
 * short-lived EdDSA-signed JWT. The VPS holds only the public key.
 *
 * Secrets/vars (all optional until the VPS backend is enabled):
 *   SYNTILA_BACKEND_SIGNING_KEY  private Ed25519 JWK (JSON, with kid) — secret
 *   SYNTILA_BACKEND_URL          default https://api.syntila.app
 */
import { HttpError, json, securityContext, type SecurityEnv } from "./routes/http-security.js";

export const BACKEND_AUDIENCE = "syntila-backend";
export const USER_TOKEN_TTL_SECONDS = 15 * 60;

type BackendEnv = SecurityEnv & {
  readonly SYNTILA_BACKEND_SIGNING_KEY?: string;
  readonly SYNTILA_BACKEND_URL?: string;
};

interface SigningKey { key: CryptoKey; kid: string }
let cached: { source: string; key: Promise<SigningKey> } | null = null;

function signingKey(env: BackendEnv): Promise<SigningKey> {
  const source = env.SYNTILA_BACKEND_SIGNING_KEY;
  if (!source) throw new HttpError(503, "Direct backend access is not configured");
  if (cached?.source !== source) {
    cached = {
      source,
      key: (async () => {
        const jwk = JSON.parse(source) as JsonWebKey & { kid?: string };
        if (jwk.kty !== "OKP" || jwk.crv !== "Ed25519" || !jwk.d || !jwk.kid)
          throw new Error("SYNTILA_BACKEND_SIGNING_KEY must be a private Ed25519 JWK with kid");
        const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, crv: jwk.crv, x: jwk.x, d: jwk.d }, { name: "Ed25519" }, false, ["sign"]);
        return { key, kid: jwk.kid };
      })(),
    };
  }
  return cached.key;
}

export function backendIssuer(env: BackendEnv): string {
  return new URL(env.BETTER_AUTH_URL ?? env.SYNTILA_APP_URL ?? "https://syntila.app").origin;
}

export function backendUrl(env: BackendEnv): string {
  return (env.SYNTILA_BACKEND_URL ?? "https://api.syntila.app").replace(/\/+$/, "");
}

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const encodeJson = (value: unknown) => b64url(new TextEncoder().encode(JSON.stringify(value)));

export async function signBackendToken(env: BackendEnv, claims: Record<string, unknown>, ttlSeconds: number, now = Date.now()) {
  const { key, kid } = await signingKey(env);
  const iat = Math.floor(now / 1000);
  const exp = iat + ttlSeconds;
  const input = `${encodeJson({ alg: "EdDSA", typ: "JWT", kid })}.${encodeJson({ iss: backendIssuer(env), aud: BACKEND_AUDIENCE, iat, exp, jti: crypto.randomUUID(), ...claims })}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, new TextEncoder().encode(input)));
  return { token: `${input}.${b64url(signature)}`, expiresAt: new Date(exp * 1000).toISOString(), expiresIn: ttlSeconds };
}

/** POST /api/backend-token — for signed-in humans (web cookie or desktop session). */
export async function handleUserBackendToken(request: Request, env: BackendEnv, ctx?: ExecutionContext): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.user.status !== "active") throw new HttpError(403, "Account is not active");
  const row = await env.SYNTILA_DB.prepare("SELECT email_verified AS emailVerified FROM users WHERE id = ?1")
    .bind(context.user.id).first<{ emailVerified: number }>();
  const issued = await signBackendToken(env, {
    sub: context.user.id, typ: "user", email: context.user.email, name: context.user.displayName,
    sid: context.sessionId, client: context.clientType,
    ...(context.audience ? { client_aud: context.audience } : {}),
    email_verified: row?.emailVerified === 1,
    ...(context.user.avatarUrl ? { picture: context.user.avatarUrl } : {}),
  }, USER_TOKEN_TTL_SECONDS);
  return json({ ...issued, backendUrl: backendUrl(env) }, { headers: { "Cache-Control": "no-store" } });
}
